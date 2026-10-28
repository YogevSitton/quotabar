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
        do {
            if checkedCLI == nil { checkedCLI = try ClaudeHelper.existing() }
            guard let binary = checkedCLI else {
                lastIssue = .helperMissing
                throw UsageError.message("Claude Code is not available. Choose Connect Claude to set up the official helper, then check your saved sign-in.")
            }
            if lastIssue == .helperMissing { lastIssue = nil; lastError = nil; localRetryAt = .distantPast }
            if Date() < localRetryAt {
                return await deferredResult(current: current, binary: binary, reconnect: reconnect)
            }
            // Reserve durably before launching the helper. Retry, wake, other
            // copies and restarts all respect the same per-user request budget.
            switch try pollStore.reserve(at: Date()) {
            case .deferred(let state):
                nextRequestAt = state.nextRequestAt
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
            let before = persistedUsage(identity: current.identity)?.observedAt
            let startedAt = Date()
            attemptedRead = true
            let data = try await Task.detached(priority: .utility) {
                try ClaudeCLIReader(binary: binary).readUsage()
            }.value
            var snapshot = try UsageParser.claudeCLI(data)
            let updated = account()
            guard updated.organization == current.organization, updated.identity == current.identity else {
                latestLive = nil
                lastError = "Claude account changed. Waiting to read the active account."
                lastIssue = .usageUnavailable
                finishFailure(lease)
                return fallback(organization: updated.organization, error: lastError)
            }
            // A successful control reply can hide a failed HTTP fetch. Match the
            // account and values, then distinguish the CLI's <60-second cache
            // shortcut from an expired cache returned after a failed refresh.
            let observedAt = observationDate(matching: snapshot, identity: updated.identity)
            let completedAt = Date()
            let classification = ClaudeRefreshPolicy.classify(before: before, after: observedAt,
                requestStartedAt: startedAt, completedAt: completedAt)
            guard classification.isAccepted, let observedAt else {
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
            let state = try pollStore.complete(lease, outcome: .success(observedAt: observedAt), at: completedAt)
            nextRequestAt = state.nextRequestAt
            guard state.failureCount == 0 else {
                lastError = "Claude usage checks are cooling down. Retrying automatically."
                lastIssue = .usageUnavailable
                return fallback(organization: current.organization, error: lastError)
            }
            latestLive = snapshot; lastError = nil; lastIssue = nil
            return ClaudeReadResult(snapshot: snapshot, error: nil, nextRequestAt: nextRequestAt)
        } catch {
            // Reservation starts backoff even if the app quits mid-request.
            finishFailure(lease)
            // Only our own fixed messages can reach the UI, never raw CLI output.
            lastError = (error as? UsageError)?.localizedDescription
                ?? (attemptedRead ? "Claude Code usage could not be read or its next check saved. Retrying after a cooldown."
                    : "Claude usage checks are paused because the local polling schedule could not be saved. Try again later.")
            if attemptedRead, let binary = checkedCLI {
                let auth = await Task.detached(priority: .utility) { ClaudeAuthStatus.read(binary: binary) }.value
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
            lastError = "Waiting for the next scheduled Claude usage check."
            lastIssue = .usageUnavailable
            let auth = await Task.detached(priority: .utility) { ClaudeAuthStatus.read(binary: binary) }.value
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
        } else {
            // Storage/lock failures are fail-closed: no helper is launched.
            localRetryAt = Date().addingTimeInterval(300)
            nextRequestAt = max(nextRequestAt, localRetryAt)
        }
    }
    private func observationDate(matching snapshot: UsageSnapshot, identity: String?) -> Date? {
        guard let cached = persistedUsage(identity: identity),
              snapshot.hasMatchingUsage(in: cached) else { return nil }
        // An unavailable response window is not displayed and need not equal a
        // populated cache window. Every displayed value must still match.
        return cached.observedAt
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
