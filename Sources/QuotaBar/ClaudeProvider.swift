import Foundation
import QuotaCore

struct ClaudeReadResult {
    let snapshot: UsageSnapshot?
    let error: String?
}

actor ClaudeProvider {
    private let home: URL
    private var latestLive: UsageSnapshot?
    private var activeIdentity: String?
    private var nextRequestAt = Date.distantPast
    private var failureCount = 0
    private var lastError: String?
    private var inFlight = false
    private var checkedCLI: URL?

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
        let history = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        if let data = try? Data(contentsOf: history), let snapshot = try? UsageParser.claudeHistory(data, organizationID: organization) {
            candidates.append(snapshot)
        }
        let statusLine = home.appendingPathComponent("Library/Application Support/QuotaBar/claude-statusline.json")
        if let data = try? Data(contentsOf: statusLine), let snapshot = try? UsageParser.claudeStatusLine(data, organizationID: organization) {
            candidates.append(snapshot)
        }
        return ClaudeReadResult(snapshot: candidates.max { $0.observedAt < $1.observedAt }, error: error)
    }
    func read(reconnect: Bool = false) async -> ClaudeReadResult {
        let current = account()
        let identity = [current.identity, current.organization].compactMap { $0 }.joined(separator: ":")
        if activeIdentity != identity {
            latestLive = nil; nextRequestAt = .distantPast; lastError = nil
            activeIdentity = identity
        }
        guard !inFlight else { return fallback(organization: current.organization, error: lastError) }
        if reconnect { checkedCLI = nil; nextRequestAt = .distantPast }
        if Date() < nextRequestAt {
            if lastError == nil, let latestLive { return ClaudeReadResult(snapshot: latestLive, error: nil) }
            return fallback(organization: current.organization, error: lastError)
        }
        inFlight = true; defer { inFlight = false }
        do {
            if checkedCLI == nil { checkedCLI = try ClaudeHelper.existing() }
            guard let binary = checkedCLI else {
                throw UsageError.message("Choose Connect Claude to prepare the official Claude Code helper and sign in.")
            }
            let startedAt = Date()
            let data = try await Task.detached(priority: .utility) {
                try ClaudeCLIReader(binary: binary).readUsage()
            }.value
            var snapshot = try UsageParser.claudeCLI(data)
            let updated = account()
            guard updated.organization == current.organization, updated.identity == current.identity else {
                latestLive = nil
                lastError = "Claude account changed. Refresh to read the active account."
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
                latestLive = nil
                lastError = "Claude Code returned an older cached reading. A fresh usage reading is unavailable."
                failureCount += 1
                nextRequestAt = Date().addingTimeInterval(ClaudeBackoff.delay(status: 0, failureCount: failureCount, retryAfter: nil, now: Date()))
                return ClaudeReadResult(snapshot: snapshot, error: lastError)
            }
            latestLive = snapshot; failureCount = 0; lastError = nil
            nextRequestAt = startedAt.addingTimeInterval(60)
            return ClaudeReadResult(snapshot: snapshot, error: nil)
        } catch {
            failureCount += 1
            nextRequestAt = Date().addingTimeInterval(ClaudeBackoff.delay(status: 0, failureCount: failureCount, retryAfter: nil, now: Date()))
            // Only our own fixed messages can reach the UI, never raw CLI output.
            lastError = (error as? UsageError)?.localizedDescription ?? "Claude Code usage could not be read. Check your connection and Claude Code sign-in."
            return fallback(organization: current.organization, error: lastError)
        }
    }
    private func observationDate(matching snapshot: UsageSnapshot, identity: String?) -> Date? {
        guard let identity, !identity.isEmpty,
              let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              cache["accountUuid"] as? String == identity,
              let rawDate = cache["fetchedAtMs"] as? NSNumber, rawDate.doubleValue.isFinite, rawDate.doubleValue > 0,
              let limits = cache["utilization"] as? [String: Any],
              let limitsData = try? JSONSerialization.data(withJSONObject: limits),
              let cached = try? UsageParser.claudeOAuth(limitsData),
              cached.session == snapshot.session, cached.weekly == snapshot.weekly else { return nil }
        return Date(timeIntervalSince1970: rawDate.doubleValue / 1000)
    }
}
