import Foundation
import QuotaCore

struct ClaudeReadResult {
    let snapshot: UsageSnapshot?
    let error: String?
    var issue: ClaudeConnectionIssue? = nil
    var nextRequestAt: Date? = nil
}

actor ClaudeProvider {
    private let home: URL
    private var latestLive: UsageSnapshot?
    private var activeIdentity: String?
    private var nextRequestAt = Date.distantPast
    private let pollStore: ClaudePollStore
    private var localRetryAt = Date.distantPast
    private var lastError: String?
    private var lastIssue: ClaudeConnectionIssue?
    private var inFlight = false
    private var checkedCLI: URL?
    private var loggedDeadline: Date?
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.pollStore = ClaudePollStore(home: home)
    }
    private func account() -> (organization: String?, identity: String?) {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any] else { return (nil, nil) }
        return (oauth["organizationUuid"] as? String, oauth["accountUuid"] as? String)
    }
    func statusLineSnapshot() -> UsageSnapshot? {
        let url = home.appendingPathComponent("Library/Application Support/QuotaBar/claude-statusline.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? UsageParser.claudeStatusLine(data, organizationID: account().organization)
    }
    private func fallback(organization: String?, error: String?) -> ClaudeReadResult {
        var candidates: [UsageSnapshot] = []
        if var previous = latestLive {
            previous.source = .cached; previous.sourceName = "Last live Claude reading"; candidates.append(previous)
        }
        if let cached = persistedUsage(identity: account().identity) { candidates.append(cached) }
        let history = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        if let data = try? Data(contentsOf: history), let snapshot = try? UsageParser.claudeHistory(data, organizationID: organization) {
            candidates.append(snapshot)
        }
        let statusLine = home.appendingPathComponent("Library/Application Support/QuotaBar/claude-statusline.json")
        if let data = try? Data(contentsOf: statusLine), let snapshot = try? UsageParser.claudeStatusLine(data, organizationID: organization) {
            candidates.append(snapshot)
        }
        return ClaudeReadResult(snapshot: candidates.max { $0.observedAt < $1.observedAt }, error: error, issue: lastIssue, nextRequestAt: nextRequestAt)
    }
    func read(reconnect: Bool = false) async -> ClaudeReadResult {
        let current = account()
        let identity = [current.identity, current.organization].compactMap { $0 }.joined(separator: ":")
        if activeIdentity != identity {
            if activeIdentity != nil { DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .accountChanged)) }
            latestLive = nil; lastError = nil; lastIssue = nil
            activeIdentity = identity
            // Account changes must not discard a cooldown from an earlier read.
        }
        guard !inFlight else { return fallback(organization: current.organization, error: lastError) }
        if reconnect {
            checkedCLI = nil
            // Setup may just have installed the missing helper. Rediscovery
            // is local; the durable usage budget still applies below.
            if lastIssue == .helperMissing { localRetryAt = .distantPast }
        }
        if !reconnect, Date() < localRetryAt {
            return fallback(organization: current.organization, error: lastError)
        }
        inFlight = true; defer { inFlight = false }
        var lease: ClaudePollLease?
        var attemptedRead = false
        var phase: DiagnosticEvent.Phase = .launch
        var failureLogged = false
        do {
            if checkedCLI == nil { checkedCLI = try ClaudeHelper.existing() }
            guard let binary = checkedCLI else {
                lastIssue = .helperMissing
                DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .readFailed, reason: .helperMissing))
                failureLogged = true
                throw UsageError.message("Claude Code is not available. Choose Connect Claude to set up the official helper, then check your saved sign-in.")
            }
            if lastIssue == .helperMissing { lastIssue = nil; lastError = nil; localRetryAt = .distantPast }
            if Date() < localRetryAt {
                return await deferredResult(current: current, binary: binary, reconnect: reconnect)
            }
            // Reserve durably before launching the helper. Retry, wake, other
            // copies and restarts all respect the same per-user request budget.
            phase = .savingSchedule
            switch try pollStore.reserve(at: Date()) {
            case .deferred(let state):
                nextRequestAt = state.nextRequestAt
                if loggedDeadline != state.nextRequestAt {
                    DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .readDeferred,
                        reason: state.pending ? .pendingRequest : state.failureCount > 0 ? .cooldown : .scheduled,
                        failureCount: state.failureCount, nextAttemptAt: state.nextRequestAt))
                    loggedDeadline = state.nextRequestAt
                }
                if state.failureCount == 0, lastError == nil, let latestLive {
                    return ClaudeReadResult(snapshot: latestLive, error: nil, nextRequestAt: nextRequestAt)
                }
                if lastError == nil {
                    lastError = state.failureCount > 0
                        ? "Claude usage checks are cooling down after an unsuccessful refresh. Retrying automatically."
                        : "Waiting for the next scheduled Claude usage check."
                    lastIssue = .usageUnavailable
                }
                return await deferredResult(current: current, binary: binary, reconnect: reconnect)
            case .ready(let reserved): lease = reserved
            }
            guard let lease else { throw UsageError.message("Claude usage could not be scheduled safely.") }
            DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .readStarted,
                failureCount: lease.failureCount, nextAttemptAt: lease.nextRequestAt))
            let before = persistedUsage(identity: current.identity)?.observedAt
            let startedAt = Date()
            attemptedRead = true
            phase = .usage
            let data = try await Task.detached(priority: .utility) {
                try ClaudeCLIReader(binary: binary).readUsage()
            }.value
            phase = .parsing
            var snapshot = try UsageParser.claudeCLI(data)
            let updated = account()
            guard updated.organization == current.organization, updated.identity == current.identity else {
                DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .accountChanged))
                latestLive = nil
                lastError = "Claude account changed. Waiting to read the active account."
                lastIssue = .usageUnavailable
                finishFailure(lease)
                return fallback(organization: updated.organization, error: lastError)
            }
            // A successful control reply can hide a failed HTTP fetch. Match the
            // account and values, then distinguish the CLI's <60-second cache
            // shortcut from an expired cache returned after a failed refresh.
            let cached = persistedUsage(identity: updated.identity)
            let cacheMatches = cached.map { snapshot.hasMatchingUsage(in: $0) } == true
            let observedAt = cacheMatches ? cached?.observedAt : nil
            let completedAt = Date()
            let classification = ClaudeRefreshPolicy.classify(before: before, after: observedAt,
                requestStartedAt: startedAt, completedAt: completedAt)
            guard classification.isAccepted, let observedAt else {
                let reason: DiagnosticEvent.Reason
                switch ClaudeRefreshPolicy.rejection(before: before, after: observedAt,
                    requestStartedAt: startedAt, completedAt: completedAt) {
                case .missingSample, nil: reason = cached == nil ? .missingProvenance : .valuesMismatch
                case .sampleTooOld: reason = .sampleTooOld
                case .reusedSampleExpired: reason = .reusedSampleExpired
                case .inconsistentTiming: reason = .inconsistentTiming
                }
                DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .sampleRejected, reason: reason,
                    sampleAgeSeconds: cacheAge(cached?.observedAt, at: completedAt),
                    cacheAdvanced: cached.flatMap { sample in before.map { sample.observedAt > $0 } }))
                if let observedAt, observedAt <= completedAt,
                   observedAt >= (latestLive?.observedAt ?? .distantPast) {
                    snapshot.observedAt = observedAt
                    snapshot.source = .cached; snapshot.sourceName = "Claude Code CLI cached reading"
                    latestLive = snapshot
                }
                lastError = "Claude Code did not provide a fresh, verifiable usage reading. Retrying after a cooldown."
                lastIssue = .usageUnavailable
                finishFailure(lease)
                return fallback(organization: current.organization, error: lastError)
            }
            snapshot.observedAt = observedAt
            phase = .savingSchedule
            let state = try pollStore.complete(lease, outcome: .success(observedAt: observedAt), at: completedAt)
            nextRequestAt = state.nextRequestAt
            guard state.failureCount == 0 else {
                DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .readDeferred, reason: .cooldown,
                    failureCount: state.failureCount, nextAttemptAt: state.nextRequestAt))
                lastError = "Claude usage checks are cooling down. Retrying automatically."
                lastIssue = .usageUnavailable
                return fallback(organization: current.organization, error: lastError)
            }
            latestLive = snapshot; lastError = nil; lastIssue = nil
            DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .readSucceeded,
                reason: classification == .newSample ? .freshSample : .recentCache,
                durationMS: DiagnosticEvent.durationMS(from: startedAt, to: completedAt),
                sampleAgeSeconds: cacheAge(observedAt, at: completedAt),
                failureCount: state.failureCount, nextAttemptAt: state.nextRequestAt))
            return ClaudeReadResult(snapshot: snapshot, error: nil, nextRequestAt: nextRequestAt)
        } catch {
            let reason: DiagnosticEvent.Reason
            switch error {
            case let failure as ClaudeCLIReader.Failure: reason = failure.reason
            case ClaudePollStore.StoreError.busy: reason = .pollStoreBusy
            case ClaudePollStore.StoreError.invalidState: reason = .pollStoreInvalid
            case ClaudePollStore.StoreError.unavailable: reason = .pollStoreUnavailable
            default:
                switch phase {
                case .launch: reason = .helperCheckFailed
                case .savingSchedule: reason = .pollStoreUnavailable
                default: reason = .invalidUsage
                }
            }
            if !failureLogged {
                DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .readFailed, reason: reason,
                    phase: (error as? ClaudeCLIReader.Failure)?.phase ?? phase))
            }
            // Reservation starts backoff even if the app quits mid-request.
            finishFailure(lease)
            // Only our own fixed messages can reach the UI, never raw CLI output.
            lastError = (error as? UsageError)?.localizedDescription
                ?? (error as? ClaudeCLIReader.Failure)?.localizedDescription
                ?? (attemptedRead ? "Claude Code usage could not be read or its next check saved. Retrying after a cooldown."
                    : "Claude usage checks are paused because the local polling schedule could not be saved. Try again later.")
            if attemptedRead, let binary = checkedCLI {
                let auth = await Task.detached(priority: .utility) { ClaudeAuthStatus.read(binary: binary) }.value
                logAuthentication(auth)
                switch auth {
                case .signedOut:
                    lastIssue = .signInRequired
                    lastError = "Claude Code reports no saved sign-in. Connect your Claude subscription to see usage."
                case .otherAuthentication:
                    lastIssue = .subscriptionRequired
                    lastError = "Claude Code is using a different authentication method. Connect a Claude subscription to see its plan usage."
                case .signedIn, .unknown:
                    // A usage, compatibility, cache or network failure is not
                    // evidence that the saved login needs to be replaced.
                    lastIssue = .usageUnavailable
                }
            } else if lastIssue != .helperMissing { lastIssue = .usageUnavailable }
            let updated = account()
            guard updated.organization == current.organization, updated.identity == current.identity else {
                latestLive = nil; lastIssue = .usageUnavailable
                lastError = "Claude account changed. Waiting to read the active account."
                return fallback(organization: updated.organization, error: lastError)
            }
            return fallback(organization: current.organization, error: lastError)
        }
    }
    private func deferredResult(current: (organization: String?, identity: String?),
                                binary: URL, reconnect: Bool) async -> ClaudeReadResult {
        if reconnect {
            // Explicit verification may follow a completed login. Refresh only
            // the CLI's authentication classification while usage is deferred;
            // an old signed-out result must not start another browser login.
            // Preserve usage failures on Retry, but remove an obsolete sign-in
            // instruction after the official CLI verifies authentication again.
            if lastError == nil || lastIssue?.needsSignIn == true {
                lastError = "Waiting for the next scheduled Claude usage check."
            }
            lastIssue = .usageUnavailable
            let auth = await Task.detached(priority: .utility) { ClaudeAuthStatus.read(binary: binary) }.value
            logAuthentication(auth)
            switch auth {
            case .signedOut:
                lastIssue = .signInRequired
                lastError = "Claude Code reports no saved sign-in. Connect your Claude subscription to see usage."
            case .otherAuthentication:
                lastIssue = .subscriptionRequired
                lastError = "Claude Code is using a different authentication method. Connect a Claude subscription to see its plan usage."
            case .signedIn, .unknown: break
            }
        }
        let updated = account()
        if updated.organization != current.organization || updated.identity != current.identity {
            latestLive = nil; lastIssue = .usageUnavailable
            lastError = "Claude account changed. Waiting to read the active account."
        }
        return fallback(organization: updated.organization, error: lastError)
    }
    private func finishFailure(_ lease: ClaudePollLease?) {
        if let lease, let state = try? pollStore.complete(lease, outcome: .failure, at: Date()) {
            nextRequestAt = state.nextRequestAt
            DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .readDeferred, reason: .cooldown,
                failureCount: state.failureCount, nextAttemptAt: state.nextRequestAt))
            loggedDeadline = state.nextRequestAt
        } else {
            // Storage/lock failures are fail-closed: no helper is launched.
            localRetryAt = Date().addingTimeInterval(300)
            nextRequestAt = max(nextRequestAt, localRetryAt)
            DiagnosticLog.shared.record(DiagnosticEvent(area: .claude,
                kind: lease == nil ? .readDeferred : .scheduleSaveFailed,
                nextAttemptAt: nextRequestAt))
        }
    }
    private func cacheAge(_ date: Date?, at now: Date) -> Int? {
        date.map { Int(min(1_000_000_000, max(-1_000_000_000, now.timeIntervalSince($0)))) }
    }
    private func logAuthentication(_ status: ClaudeAuthStatus) {
        let reason: DiagnosticEvent.Reason
        switch status {
        case .signedIn: reason = .signedIn
        case .signedOut: reason = .signedOut
        case .otherAuthentication: reason = .otherAuthentication
        case .unknown: reason = .unknownAuthentication
        }
        DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .authenticationChecked, reason: reason))
    }
    private func persistedUsage(identity: String?) -> UsageSnapshot? {
        guard let identity, !identity.isEmpty,
              let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              cache["accountUuid"] as? String == identity,
              let rawDate = cache["fetchedAtMs"] as? NSNumber, rawDate.doubleValue.isFinite, rawDate.doubleValue > 0,
              let limits = cache["utilization"] as? [String: Any],
              let limitsData = try? JSONSerialization.data(withJSONObject: limits),
              var cached = try? UsageParser.claudeOAuth(limitsData) else { return nil }
        cached.observedAt = Date(timeIntervalSince1970: rawDate.doubleValue / 1000)
        guard cached.observedAt <= Date().addingTimeInterval(60) else { return nil }
        cached.source = .cached; cached.sourceName = "Claude Code CLI saved reading"
        return cached
    }
}
