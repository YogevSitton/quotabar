import Foundation
import Security
import LocalAuthentication
import CryptoKit
import QuotaCore

struct ClaudeReadResult {
    let snapshot: UsageSnapshot?
    let error: String?
}

private enum ClaudeKeychain {
    static func read(allowInteraction: Bool) throws -> ClaudeCredential {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        // Background polls cannot repeatedly summon a system permission dialog.
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status == errSecSuccess, let data = found as? Data else {
            switch status {
            case errSecItemNotFound:
                throw UsageError.message("Claude is not connected. Choose Connect Claude to sign in.")
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                throw UsageError.message("Choose Connect Claude, then Use existing sign-in to allow Keychain access.")
            default:
                throw UsageError.message("Claude Code's Keychain sign-in is unavailable (\(status)).")
            }
        }
        return try ClaudeCredential.parse(data)
    }
}

// Never forward account credentials to a redirect destination.
private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor ClaudeProvider {
    private let home: URL
    private let session: URLSession
    private var latestLive: UsageSnapshot?
    private var activeIdentity: String?
    private var nextRequestAt = Date.distantPast
    private var failureCount = 0
    private var lastError: String?
    private var rejectedToken: String?
    private var inFlight = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: NoUsageRedirects(), delegateQueue: nil)
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
    func read(allowInteraction: Bool = false) async -> ClaudeReadResult {
        let current = account()
        let identity = [current.identity, current.organization].compactMap { $0 }.joined(separator: ":")
        if activeIdentity != identity {
            latestLive = nil; rejectedToken = nil; nextRequestAt = .distantPast; lastError = nil
            activeIdentity = identity
        }
        guard !inFlight else { return fallback(organization: current.organization, error: lastError) }
        // Honor cooldowns even for manual refresh. No extra calls between polls.
        if Date() < nextRequestAt {
            if lastError == nil, let latestLive { return ClaudeReadResult(snapshot: latestLive, error: nil) }
            // A changed sign-in can release a 401 block; 403/429 cooldowns stay in force.
            if rejectedToken == nil { return fallback(organization: current.organization, error: lastError) }
        }
        inFlight = true; defer { inFlight = false }
        let credential: ClaudeCredential
        do { credential = try ClaudeKeychain.read(allowInteraction: allowInteraction) }
        catch {
            lastError = error.localizedDescription
            return fallback(organization: current.organization, error: lastError)
        }
        guard !credential.isExpired(at: Date()) else {
            lastError = "Your Claude Code sign-in has expired. Choose Connect Claude to sign in again."
            return fallback(organization: current.organization, error: lastError)
        }
        let fingerprint = SHA256.hash(data: Data(credential.accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
        if rejectedToken == fingerprint { return fallback(organization: current.organization, error: lastError) }
        if rejectedToken != nil { rejectedToken = nil; nextRequestAt = .distantPast }
        do {
            let (data, response) = try await session.data(for: ClaudeUsageRequest.make(accessToken: credential.accessToken))
            guard let http = response as? HTTPURLResponse else { throw UsageError.message("Claude did not return an HTTP usage response.") }
            guard http.statusCode == 200 else {
                failureCount += 1
                nextRequestAt = Date().addingTimeInterval(ClaudeBackoff.delay(status: http.statusCode, failureCount: failureCount,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After"), now: Date()))
                switch http.statusCode {
                case 401:
                    rejectedToken = fingerprint
                    lastError = "Claude's saved sign-in was rejected. Choose Connect Claude to sign in again."
                case 403: lastError = "Claude denied usage access. Check the Claude Code sign-in. Retrying after \(nextRequestAt.formatted(date: .omitted, time: .shortened))."
                case 429: lastError = "Claude is rate-limiting usage checks. Retrying after \(nextRequestAt.formatted(date: .omitted, time: .shortened))."
                default: lastError = "Claude usage unavailable (HTTP \(http.statusCode)). Retrying after \(nextRequestAt.formatted(date: .omitted, time: .shortened))."
                }
                return fallback(organization: current.organization, error: lastError)
            }
            var snapshot = try UsageParser.claudeOAuth(data)
            snapshot.plan = credential.subscriptionType
            // Do not attribute a response to an account that changed in flight.
            let updated = account()
            guard updated.organization == current.organization, updated.identity == current.identity else {
                latestLive = nil; lastError = "Claude account changed. Refresh to read the active account."
                return fallback(organization: updated.organization, error: lastError)
            }
            latestLive = snapshot; failureCount = 0; lastError = nil
            nextRequestAt = Date().addingTimeInterval(300)
            return ClaudeReadResult(snapshot: snapshot, error: nil)
        } catch {
            failureCount += 1
            nextRequestAt = Date().addingTimeInterval(ClaudeBackoff.delay(status: 0, failureCount: failureCount, retryAfter: nil, now: Date()))
            // Never expose raw network diagnostics or server bodies containing account data.
            lastError = "Claude usage could not be read. Check your connection and Claude Code sign-in; a cached reading is shown when available."
            return fallback(organization: current.organization, error: lastError)
        }
    }
}
