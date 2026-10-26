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
    private var failureCount = 0
    private var lastError: String?
    private var lastIssue: ClaudeConnectionIssue?
    private var inFlight = false
    private var checkedCLI: URL?
    private var lastRequestStartedAt: Date?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
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
    func read(reconnect: Bool = false, minimumInterval: TimeInterval = 60) async -> ClaudeReadResult {
        let cadence = max(60, minimumInterval)
        let current = account()
        let identity = [current.identity, current.organization].compactMap { $0 }.joined(separator: ":")
        if activeIdentity != identity {
            latestLive = nil; nextRequestAt = .distantPast; lastError = nil; lastIssue = nil; failureCount = 0
            lastRequestStartedAt = nil
            activeIdentity = identity
        }
        guard !inFlight else { return fallback(organization: current.organization, error: lastError) }
        if reconnect { checkedCLI = nil; nextRequestAt = .distantPast }
        // Another official Claude process may recover while we are backing off.
        // A newly fetched account-matched cache is only a reason to recheck via
        // get_usage, never permission to display disk values as live usage.
        let now = Date()
        if lastIssue == .usageUnavailable, now < nextRequestAt,
           let lastRequestStartedAt, let cached = persistedUsage(identity: current.identity),
           ClaudeCacheRecovery.shouldRecheck(observedAt: cached.observedAt,
               lastRequestStartedAt: lastRequestStartedAt, now: now, minimumInterval: cadence) {
            nextRequestAt = now
        }
        if Date() < nextRequestAt {
            if lastError == nil, let latestLive { return ClaudeReadResult(snapshot: latestLive, error: nil, nextRequestAt: nextRequestAt) }
            return fallback(organization: current.organization, error: lastError)
        }
        inFlight = true; defer { inFlight = false }
        lastIssue = nil
        do {
            if checkedCLI == nil { checkedCLI = try ClaudeHelper.existing() }
            guard let binary = checkedCLI else {
                lastIssue = .helperMissing
                throw UsageError.message("Claude Code is not available. Choose Connect Claude to set up the official helper, then check your saved sign-in.")
            }
            let startedAt = Date()
            lastRequestStartedAt = startedAt
            let data = try await Task.detached(priority: .utility) {
                try ClaudeCLIReader(binary: binary).readUsage()
            }.value
            var snapshot = try UsageParser.claudeCLI(data)
            let updated = account()
            guard updated.organization == current.organization, updated.identity == current.identity else {
                latestLive = nil
                lastError = "Claude account changed. Refresh to read the active account."
                lastIssue = .usageUnavailable
                nextRequestAt = .distantPast
                return fallback(organization: updated.organization, error: lastError)
            }
            // get_usage may answer from Claude Code's own cache, including on a
            // failed network read. Preserve its account-matched observation time.
            guard let observedAt = observationDate(matching: snapshot, identity: updated.identity),
                  observedAt <= Date().addingTimeInterval(60) else {
                throw UsageError.message("Claude Code returned usage without a verifiable sample time. A fresh reading is unavailable.")
            }
            snapshot.observedAt = observedAt
            guard Date().timeIntervalSince(observedAt) < 120 else {
                snapshot.source = .cached; snapshot.sourceName = "Claude Code CLI cached reading"
                latestLive = snapshot
                lastError = "Claude Code returned an older cached reading. A fresh usage reading is unavailable."
                lastIssue = .usageUnavailable
                failureCount += 1
                nextRequestAt = Date().addingTimeInterval(max(cadence, transientRetryDelay))
                return ClaudeReadResult(snapshot: snapshot, error: lastError, issue: lastIssue, nextRequestAt: nextRequestAt)
            }
            latestLive = snapshot; failureCount = 0; lastError = nil; lastIssue = nil
            // Claude Code's locally inspected cache lasts 60 seconds. Read
            // after both that observation and our own previous request, with
            // a small margin so a timer firing early cannot reuse it again.
            nextRequestAt = max(startedAt, observedAt).addingTimeInterval(cadence + 0.5)
            return ClaudeReadResult(snapshot: snapshot, error: nil, nextRequestAt: nextRequestAt)
        } catch {
            failureCount += 1
            // Only our own fixed messages can reach the UI, never raw CLI output.
            lastError = (error as? UsageError)?.localizedDescription ?? "Claude Code usage could not be read. Try again later."
            if let binary = checkedCLI {
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
            let delay = lastIssue == .usageUnavailable ? transientRetryDelay : 300
            nextRequestAt = Date().addingTimeInterval(max(cadence, delay))
            let updated = account()
            guard updated.organization == current.organization, updated.identity == current.identity else {
                latestLive = nil; lastIssue = .usageUnavailable
                lastError = "Claude account changed. Refresh to read the active account."
                nextRequestAt = .distantPast
                return fallback(organization: updated.organization, error: lastError)
            }
            return fallback(organization: current.organization, error: lastError)
        }
    }
    private var transientRetryDelay: TimeInterval {
        min(300, 60 * pow(2, Double(max(0, min(3, failureCount - 1)))))
    }
    private func observationDate(matching snapshot: UsageSnapshot, identity: String?) -> Date? {
        guard let cached = persistedUsage(identity: identity),
              snapshot.session == nil || cached.session == snapshot.session,
              snapshot.weekly == nil || cached.weekly == snapshot.weekly else { return nil }
        // An absent response window is not displayed and need not equal a
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
