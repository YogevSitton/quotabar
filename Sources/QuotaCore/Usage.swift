import Foundation

public struct UsageWindow: Equatable {
    public let used: Double
    public let resetsAt: Date?
    public var remaining: Int { Int(max(0, min(100, 100 - used)).rounded(.down)) }
    public init(used: Double, resetsAt: Date?) { self.used = used; self.resetsAt = resetsAt }
    public func awaitingReset(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public func currentRemaining(at now: Date) -> Int? { awaitingReset(at: now) ? nil : remaining }

    // An even budget across a known window, not a forecast of future activity.
    // Compare at the reading's timestamp so an unchanged sample cannot appear
    // to improve its pace merely by aging between provider reads.
    public func pace(over duration: TimeInterval, at sampleTime: Date) -> UsagePace? {
        guard duration.isFinite, duration > 0, used.isFinite, (0...100).contains(used),
              let resetsAt else { return nil }
        let timeLeft = resetsAt.timeIntervalSince(sampleTime)
        guard timeLeft.isFinite, timeLeft > 0, timeLeft <= duration else { return nil }
        let expectedUsed = 100 * (1 - timeLeft / duration)
        return UsagePace(expectedUsed: expectedUsed, percentagePointsOverBudget: used - expectedUsed)
    }
}

public struct UsagePace: Equatable {
    public let expectedUsed: Double
    public let percentagePointsOverBudget: Double
    public var expectedRemaining: Double { 100 - expectedUsed }
    // A small tolerance avoids warning on rounding noise in provider percentages.
    public var overBudget: Bool { percentagePointsOverBudget > 2 }
    public var underBudget: Bool { percentagePointsOverBudget < -2 }
}

public enum ResetExpiryUrgency: Int, Comparable {
    case normal, soon, imminent
    /// Orange within 3 days, red within 24 hours; a past expiry is not urgent.
    public init(timeLeft: TimeInterval) {
        guard timeLeft > 0 else { self = .normal; return }
        self = timeLeft <= 86400 ? .imminent : timeLeft <= 3 * 86400 ? .soon : .normal
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ResetOffer: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let expiresAt: Date?
    public let detail: String?
    public let expiryText: String?
    public var supportsDirectRedemption = false
    public var remainingCount: Int? = 1
    public var kind: String?
    public var isNext = false
    public var usableNow: Bool?
    public var startsAt: Date?
    public var unavailableReason: String?
    public init(id: String, title: String, expiresAt: Date?, detail: String? = nil, expiryText: String? = nil) {
        self.id = id; self.title = title; self.expiresAt = expiresAt; self.detail = detail; self.expiryText = expiryText
    }
    /// Time left on an offer that still has credit; nil when unknown, used up or past.
    public func timeUntilExpiry(at now: Date) -> TimeInterval? {
        guard remainingCount.map({ $0 > 0 }) ?? true, let expiresAt else { return nil }
        let timeLeft = expiresAt.timeIntervalSince(now)
        return timeLeft > 0 ? timeLeft : nil
    }
    public func expiryUrgency(at now: Date) -> ResetExpiryUrgency {
        timeUntilExpiry(at: now).map(ResetExpiryUrgency.init(timeLeft:)) ?? .normal
    }
}

public enum ReadingSource: String { case live = "Live", cached = "Cached" }
public struct NamedUsageWindow: Identifiable {
    public let id: String
    public let title: String
    public let window: UsageWindow
    public init(id: String, title: String, window: UsageWindow) { self.id = id; self.title = title; self.window = window }
}
public struct ExtraUsage {
    public let enabled: Bool?
    public let monthlyLimit: Double?
    public let used: Double?
    public let currency: String?
    public init(enabled: Bool?, monthlyLimit: Double?, used: Double?, currency: String?) {
        self.enabled = enabled; self.monthlyLimit = monthlyLimit; self.used = used; self.currency = currency
    }
}

public struct UsageSnapshot {
    public var accountID: String?
    public var source: ReadingSource = .live
    public var sourceName: String?
    public var showsResetCredits = true
    public var cooldownUntil: Date?
    public var additionalWindows: [NamedUsageWindow] = []
    public var extraUsage: ExtraUsage?
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var plan: String?
    public var resetCount: Int?
    public var offers: [ResetOffer]
    public var resetNote: String?
    public var observedAt: Date
    public func orderedResetOffers(at now: Date) -> [ResetOffer] {
        offers.sorted {
            // Past expiries must not hide upcoming expiries in the compact list.
            let leftExpired = $0.expiresAt.map { $0 <= now } ?? false
            let rightExpired = $1.expiresAt.map { $0 <= now } ?? false
            if leftExpired != rightExpired { return !leftExpired }
            let left = $0.expiresAt ?? .distantFuture, right = $1.expiresAt ?? .distantFuture
            return left == right ? $0.id < $1.id : left < right
        }
    }
    /// The soonest expiry among offers that still have credit.
    public func nextResetExpiry(at now: Date) -> Date? {
        offers.filter { $0.timeUntilExpiry(at: now) != nil }.compactMap(\.expiresAt).min()
    }
    public func isCurrent(at now: Date, maximumAge: TimeInterval, hasConnectionError: Bool) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return source == .live && !hasConnectionError && age >= -60 && age < maximumAge
    }
    public init(session: UsageWindow? = nil, weekly: UsageWindow? = nil, plan: String? = nil,
                resetCount: Int? = nil, offers: [ResetOffer] = [], resetNote: String? = nil, observedAt: Date = Date()) {
        self.session = session; self.weekly = weekly; self.plan = plan; self.resetCount = resetCount
        self.offers = offers; self.resetNote = resetNote; self.observedAt = observedAt
    }
}

public enum UsageError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public enum UsageParser {
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func unix(_ value: Any?) -> Date? { number(value).map(Date.init(timeIntervalSince1970:)) }
    private static func iso(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    public static func codex(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.message("Invalid Codex response.") }
        let mapped = root["rateLimitsByLimitId"] as? [String: [String: Any]]
        guard let bucket = mapped?["codex"] ?? root["rateLimits"] as? [String: Any] else { throw UsageError.message("Codex did not return subscription limits.") }
        let windows = [bucket["primary"], bucket["secondary"]].compactMap { $0 as? [String: Any] }
        func window(_ duration: Double) -> UsageWindow? {
            guard let raw = windows.first(where: { number($0["windowDurationMins"]) == duration }), let used = number(raw["usedPercent"]) else { return nil }
            return UsageWindow(used: used, resetsAt: unix(raw["resetsAt"]))
        }
        let summary = root["rateLimitResetCredits"] as? [String: Any]
        let offers = (summary?["credits"] as? [[String: Any]] ?? []).compactMap { row -> ResetOffer? in
            guard row["status"] as? String == "available", let id = row["id"] as? String else { return nil }
            let expiry = unix(row["expiresAt"])
            var offer = ResetOffer(id: id, title: row["title"] as? String ?? "Usage reset", expiresAt: expiry,
                                   detail: row["description"] as? String)
            offer.supportsDirectRedemption = row["resetType"] as? String == "codexRateLimits"
            return offer
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        var snapshot = UsageSnapshot(session: window(300), weekly: window(10080), plan: bucket["planType"] as? String,
            resetCount: number(summary?["availableCount"]).map { max(0, Int($0)) }, offers: offers,
            resetNote: summary == nil ? "Reset availability not reported by Codex." : nil, observedAt: now)
        snapshot.accountID = root["accountId"] as? String
        return snapshot
    }
    public static func claude(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let usage = root["usage"] as? [String: Any] else {
            throw UsageError.message("Claude did not return usage. Open Claude and sign in.")
        }
        func window(_ key: String) -> UsageWindow? {
            guard let row = usage[key] as? [String: Any], let used = number(row["utilization"]) else { return nil }
            return UsageWindow(used: used, resetsAt: iso(row["resets_at"]))
        }
        let session = window("five_hour"), weekly = window("seven_day")
        guard session != nil || weekly != nil else { throw UsageError.message("Claude's usage format changed or this account has no subscription limits.") }
        let offers = (root["resetOffers"] as? [[String: Any]] ?? []).compactMap { row -> ResetOffer? in
            guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
            return ResetOffer(id: id, title: title, expiresAt: iso(row["expiresAt"]),
                detail: row["detail"] as? String, expiryText: row["expiryText"] as? String)
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return UsageSnapshot(session: session, weekly: weekly, plan: root["organizationName"] as? String,
            resetCount: number(root["resetCount"]).map { max(0, Int($0)) }, offers: offers,
            resetNote: root["resetText"] as? String ?? (offers.isEmpty ? "Open Claude Usage to check reset offers and expiry dates." : nil), observedAt: now)
    }
}

import CoreFoundation
