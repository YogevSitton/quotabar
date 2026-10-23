import Foundation
import CoreFoundation

// Central validation for undocumented provider fields. Unknown never means zero.
enum ClaudeValue {
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func count(_ value: Any?) -> Int? {
        guard let n = number(value), n >= 0, n < Double(Int.max), n.rounded(.towardZero) == n else { return nil }
        return Int(n)
    }
    static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    static func percent(_ value: Any?) -> Double? {
        guard let n = number(value), (0...100).contains(n) else { return nil }; return n
    }
    static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0, n < 100_000_000_000_000 {
            return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
        }
        guard let text = value as? String else { return nil }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message("Claude returned an invalid usage response.")
        }; return object
    }
}

public struct ClaudeCredential {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?
    public static func parse(_ data: Data) throws -> ClaudeCredential {
        let root = try ClaudeValue.object(data)
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw UsageError.message("Claude is not connected. Choose Connect Claude to sign in.")
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.message("The saved Claude Code OAuth login has no access token. Sign in to Claude Code again.")
        }
        guard !token.contains("\n"), !token.contains("\r") else {
            throw UsageError.message("The saved Claude Code access token has an invalid format. Sign in to Claude Code again.")
        }
        // Deliberately do not read, retain, refresh, or write the refresh token.
        return ClaudeCredential(accessToken: token, expiresAt: ClaudeValue.date(oauth["expiresAt"]),
            subscriptionType: oauth["subscriptionType"] as? String)
    }
    public func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now.addingTimeInterval(30) } ?? false }
}

public enum ClaudeUsageRequest {
    public static func make(accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!)
        request.httpMethod = "GET"; request.timeoutInterval = 25
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaBar/1.1 (macOS; read-only usage monitor)", forHTTPHeaderField: "User-Agent")
        return request
    }
}

public enum ClaudeBackoff {
    public static func delay(status: Int, failureCount: Int, retryAfter: String?, now: Date) -> TimeInterval {
        let minimum: Double = status == 401 || status == 403 ? 900 : 300
        var retry: Double = 0
        if let raw = retryAfter {
            if let seconds = Double(raw), seconds.isFinite { retry = max(0, seconds) }
            else {
                let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
                parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                retry = parser.date(from: raw).map { max(0, $0.timeIntervalSince(now)) } ?? 0
            }
        }
        return max(retry, min(3600, minimum * pow(2, Double(max(0, min(4, failureCount - 1))))))
    }
}

public extension UsageParser {
    static func claudeOAuth(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let root = try ClaudeValue.object(data)
        func window(_ key: String) -> UsageWindow? {
            guard let row = root[key] as? [String: Any], let used = ClaudeValue.percent(row["utilization"]) else { return nil }
            return UsageWindow(used: used, resetsAt: ClaudeValue.date(row["resets_at"]))
        }
        let session = window("five_hour"), weekly = window("seven_day")
        guard session != nil || weekly != nil else {
            throw UsageError.message("Claude did not report valid subscription windows. The usage format or account access may have changed.")
        }
        var result = UsageSnapshot(session: session, weekly: weekly, observedAt: now)
        result.sourceName = "Claude Code sign-in"
        let credits = root["cedar_ember"] as? [String: Any]
        result.showsResetCredits = credits != nil
        if let credits {
            result.cooldownUntil = ClaudeValue.date(credits["cooldown_until"])
            if ClaudeValue.bool(credits["eligible"]) == false {
                result.resetNote = credits["ineligible_reason"] as? String ?? "Resets are not currently eligible for this account."
            }
            if let grants = credits["grants"] as? [[String: Any]] {
                let nextID = credits["next_grant_id"] as? String
                var count = 0, countKnown = true
                for row in grants {
                    guard let left = ClaudeValue.count(row["resets_left"]), let paused = ClaudeValue.bool(row["paused"]) else { countKnown = false; continue }
                    guard left > 0, !paused else { continue }
                    let sum = count.addingReportingOverflow(left); count = sum.partialValue
                    if sum.overflow { countKnown = false }
                    guard let id = row["id"] as? String else { continue }
                    let kind = row["type"] as? String
                    let defaultTitle = ["session": "5-hour reset", "weekly": "Weekly reset", "full": "Full reset (weekly + 5-hour)"][kind ?? ""] ?? "Usage reset"
                    var offer = ResetOffer(id: id, title: row["label"] as? String ?? defaultTitle,
                        expiresAt: ClaudeValue.date(row["ends_at"]),
                        detail: ClaudeValue.bool(row["use_requires_limit"]) == true ? "Requires a usage limit to be reached" : nil)
                    offer.remainingCount = left; offer.kind = kind; offer.isNext = id == nextID
                    offer.usableNow = ClaudeValue.bool(row["usable_now"])
                    offer.startsAt = ClaudeValue.date(row["starts_at"])
                    offer.unavailableReason = row["unavailable_reason"] as? String
                    result.offers.append(offer)
                }
                result.resetCount = countKnown ? count : nil
                result.offers.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            }
        }
        let additional = [("seven_day_sonnet", "Sonnet · weekly"), ("seven_day_opus", "Opus · weekly"),
            ("seven_day_oauth_apps", "OAuth apps · weekly"), ("seven_day_cowork", "Cowork · weekly"),
            ("seven_day_omelette", "Additional weekly limit"), ("omelette_promotional", "Promotional limit")]
        result.additionalWindows = additional.compactMap { key, title in window(key).map { NamedUsageWindow(id: key, title: title, window: $0) } }
        for (index, row) in (root["limits"] as? [[String: Any]] ?? []).enumerated() {
            guard row["kind"] as? String == "weekly_scoped", let percent = ClaudeValue.percent(row["percent"]) else { continue }
            let scope = row["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
            let title = [model, surface].compactMap { $0 }.joined(separator: " · ")
            result.additionalWindows.append(NamedUsageWindow(id: "scoped-\(index)", title: title.isEmpty ? "Additional weekly limit" : "\(title) · weekly",
                window: UsageWindow(used: percent, resetsAt: ClaudeValue.date(row["resets_at"]))))
        }
        if let extra = root["extra_usage"] as? [String: Any] {
            result.extraUsage = ExtraUsage(enabled: ClaudeValue.bool(extra["is_enabled"]),
                monthlyLimit: ClaudeValue.number(extra["monthly_limit"]).flatMap { $0 >= 0 ? $0 / 100 : nil },
                used: ClaudeValue.number(extra["used_credits"]).flatMap { $0 >= 0 ? $0 / 100 : nil },
                currency: extra["currency"] as? String)
        }
        return result
    }

    static func claudeHistory(_ data: Data, organizationID: String?, now: Date = Date()) throws -> UsageSnapshot {
        let root = try ClaudeValue.object(data)
        guard let org = organizationID, root["version"] as? Int == 2, let samples = root["samples"] as? [[String: Any]] else {
            throw UsageError.message("No account-matched Claude history is available.")
        }
        let candidates = samples.compactMap { row -> UsageSnapshot? in
            guard row["org"] as? String == org, let time = ClaudeValue.date(row["t"]), time <= now.addingTimeInterval(60),
                  let usage = row["u"] as? [String: Any] else { return nil }
            let session = ClaudeValue.percent(usage["fh"]).map { UsageWindow(used: $0, resetsAt: nil) }
            let weekly = ClaudeValue.percent(usage["sd"]).map { UsageWindow(used: $0, resetsAt: nil) }
            guard session != nil || weekly != nil else { return nil }
            var snapshot = UsageSnapshot(session: session, weekly: weekly, observedAt: time)
            snapshot.source = .cached; snapshot.sourceName = "Claude Desktop history"; snapshot.showsResetCredits = false
            return snapshot
        }
        guard let latest = candidates.max(by: { $0.observedAt < $1.observedAt }) else {
            throw UsageError.message("No account-matched Claude history is available.")
        }; return latest
    }

    static func claudeStatusLine(_ data: Data, organizationID: String?, now: Date = Date()) throws -> UsageSnapshot {
        let root = try ClaudeValue.object(data)
        guard let org = organizationID, root["organizationID"] as? String == org,
              let captured = ClaudeValue.date(root["capturedAt"]), captured <= now.addingTimeInterval(60),
              let rate = root["rate_limits"] as? [String: Any] else {
            throw UsageError.message("No account-matched Claude Code status-line reading is available.")
        }
        func window(_ key: String) -> UsageWindow? {
            guard let row = rate[key] as? [String: Any], let used = ClaudeValue.percent(row["used_percentage"]) else { return nil }
            return UsageWindow(used: used, resetsAt: ClaudeValue.date(row["resets_at"]))
        }
        let session = window("five_hour"), weekly = window("seven_day")
        guard session != nil || weekly != nil else { throw UsageError.message("The status-line reading has no valid usage windows.") }
        var result = UsageSnapshot(session: session, weekly: weekly, observedAt: captured)
        result.source = .cached; result.sourceName = "Claude Code status line"; result.showsResetCredits = false
        return result
    }
}
