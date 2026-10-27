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
    static func claudeCLI(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let root = try ClaudeValue.object(data)
        guard ClaudeValue.bool(root["rate_limits_available"]) == true else {
            throw UsageError.message("Claude Code did not report eligible subscription usage. Check your plan or retry later.")
        }
        guard let limits = root["rate_limits"] as? [String: Any] else {
            throw UsageError.message("Claude Code could not retrieve subscription usage. Try again later.")
        }
        var snapshot = try claudeOAuth(JSONSerialization.data(withJSONObject: limits), now: now)
        snapshot.plan = root["subscription_type"] as? String
        snapshot.sourceName = "Claude Code CLI"
        for (index, row) in (limits["model_scoped"] as? [[String: Any]] ?? []).enumerated() {
            guard let used = ClaudeValue.percent(row["utilization"]), let title = row["display_name"] as? String, !title.isEmpty else { continue }
            let window = UsageWindow(used: used, resetsAt: ClaudeValue.date(row["resets_at"]))
            guard !snapshot.additionalWindows.contains(where: { ($0.title == title || $0.title == "\(title) · weekly") && $0.window == window }) else { continue }
            snapshot.additionalWindows.append(NamedUsageWindow(id: "cli-model-\(index)", title: "\(title) · weekly", window: window))
        }
        return snapshot
    }

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
        // The official CLI preserves explicit null from subscription usage;
        // header-derived missing windows are omitted instead. Support the
        // explicit-null shape only alongside a valid weekly reading. Claude's
        // no-five-hour-limit behavior has not yet been verified live.
        if root["five_hour"] is NSNull, weekly != nil {
            result.sessionLimit = .noLimit
        }
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
