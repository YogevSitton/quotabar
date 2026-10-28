import Foundation
import CoreFoundation

/// Antigravity supplies quota groups dynamically. A group is not a separate
/// account, and equally sized buckets are not evidence of a shared quota pool.
public struct AntigravitySnapshot: Equatable {
    public let groups: [AntigravityQuotaGroup]
    public let description: String?
    /// Local request time, not a server-provided sample timestamp or account proof.
    public let observedAt: Date
    public var source: ReadingSource

    public init(groups: [AntigravityQuotaGroup], description: String? = nil,
                observedAt: Date, source: ReadingSource = .live) {
        self.groups = groups
        self.description = description
        self.observedAt = observedAt
        self.source = source
    }

    public func isCurrent(at now: Date, maximumAge: TimeInterval, hasConnectionError: Bool) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return source == .live && !hasConnectionError && maximumAge.isFinite && maximumAge > 0
            && age.isFinite && age >= 0 && age < maximumAge
    }

    /// Never silently switch an existing selection to another quota group.
    /// A lone group needs no picker; multiple groups require an explicit selection.
    public func selectedGroup(named name: String?) -> AntigravityQuotaGroup? {
        guard let name else { return groups.count == 1 ? groups.first : nil }
        let matches = groups.filter { $0.name == name }
        return matches.count == 1 ? matches.first : nil
    }
}

public struct AntigravityQuotaGroup: Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String?
    public let buckets: [AntigravityQuotaBucket]

    public init(name: String, description: String? = nil, buckets: [AntigravityQuotaBucket]) {
        self.name = name
        self.description = description
        self.buckets = buckets
    }

    public var session: UsageWindow? { uniqueWindow(.fiveHour) }
    public var weekly: UsageWindow? { uniqueWindow(.weekly) }

    private func uniqueWindow(_ kind: AntigravityQuotaBucket.WindowKind) -> UsageWindow? {
        // Even a disabled or malformed duplicate makes this summary ambiguous.
        let matches = buckets.filter { $0.windowKind == kind }
        return matches.count == 1 ? matches.first?.usageWindow : nil
    }
}

public struct AntigravityQuotaBucket: Equatable, Identifiable {
    public let id: String
    public let reportedID: String?
    public let name: String
    public let description: String?
    /// Preserve the provider's label even when its meaning is not recognized.
    public let window: String?
    public let disabled: Bool
    public let remainingFraction: Double?
    public let remainingAmount: Int?
    public let resetsAt: Date?

    public init(id: String, reportedID: String? = nil, name: String, description: String? = nil,
                window: String? = nil, disabled: Bool = false, remainingFraction: Double? = nil,
                remainingAmount: Int? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.reportedID = reportedID
        self.name = name
        self.description = description
        self.window = window
        self.disabled = disabled
        self.remainingFraction = remainingFraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        self.remainingAmount = remainingAmount.flatMap { $0 >= 0 ? $0 : nil }
        self.resetsAt = resetsAt
    }

    public enum WindowKind: Equatable {
        case fiveHour, weekly

        public var duration: TimeInterval {
            switch self {
            case .fiveHour: return 5 * 3600
            case .weekly: return 7 * 86400
            }
        }
    }

    public var windowKind: WindowKind? {
        // This is an interpretation of explicit duration text, not a list of
        // observed live bucket IDs. Never classify from model names or reset offsets.
        switch window?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "5h", "5-hour", "5 hours": return .fiveHour
        case "weekly", "7d", "7 days": return .weekly
        default: return nil
        }
    }

    public var usageWindow: UsageWindow? {
        guard !disabled, let remainingFraction,
              let decimal = Decimal(string: String(remainingFraction), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        // Decimal scaling avoids turning a reported 0.29 into 28% through
        // binary floating-point multiplication followed by downward rounding.
        let remainingPercent = NSDecimalNumber(decimal: decimal * 100).doubleValue
        return UsageWindow(used: 100 - remainingPercent, resetsAt: resetsAt)
    }

    public func currentWindow(at now: Date) -> UsageWindow? {
        guard let usageWindow, !usageWindow.awaitingReset(at: now) else { return nil }
        return usageWindow
    }
}

public extension UsageParser {
    /// Parse only the read-only command envelope. The launcher must independently
    /// prevent a model turn; rejecting an envelope afterward cannot undo one.
    static func antigravity(_ data: Data, observedAt: Date) throws -> AntigravitySnapshot {
        guard data.count <= 2_000_000,
              observedAt.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970 > 0,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "SUCCESS",
              AntigravityValue.number(root["num_turns"]) == 0,
              root["error"] == nil || root["error"] as? String == "",
              let command = root["command"] as? [String: Any], command["name"] as? String == "usage",
              let report = command["data"] as? [String: Any],
              let rows = report["groups"] as? [[String: Any]], !rows.isEmpty else {
            throw UsageError.message("Antigravity did not return a successful usage command report.")
        }
        var names = Set<String>()
        let groups = try rows.map { row -> AntigravityQuotaGroup in
            guard let name = AntigravityValue.text(row["name"]), names.insert(name).inserted,
                  let buckets = row["buckets"] as? [[String: Any]] else {
                throw UsageError.message("Antigravity returned invalid or ambiguous quota groups.")
            }
            var bucketIDs = Set<String>()
            let parsed = try buckets.enumerated().map { index, bucket -> AntigravityQuotaBucket in
                guard let name = AntigravityValue.text(bucket["name"]),
                      let disabled = AntigravityValue.disabled(bucket["disabled"]) else {
                    throw UsageError.message("Antigravity returned an invalid quota bucket.")
                }
                let reportedID = AntigravityValue.text(bucket["id"])
                if let reportedID, !bucketIDs.insert(reportedID).inserted {
                    throw UsageError.message("Antigravity returned ambiguous quota bucket identifiers.")
                }
                return AntigravityQuotaBucket(id: reportedID.map { "reported:\($0)" } ?? "position:\(index)",
                    reportedID: reportedID, name: name, description: AntigravityValue.text(bucket["description"]),
                    window: AntigravityValue.text(bucket["window"]), disabled: disabled,
                    remainingFraction: AntigravityValue.number(bucket["remaining_fraction"]),
                    remainingAmount: AntigravityValue.count(bucket["remaining_amount"]),
                    resetsAt: AntigravityValue.date(bucket["reset_time"]))
            }
            return AntigravityQuotaGroup(name: name, description: AntigravityValue.text(row["description"]), buckets: parsed)
        }
        return AntigravitySnapshot(groups: groups, description: AntigravityValue.text(report["description"]), observedAt: observedAt)
    }
}

private enum AntigravityValue {
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func count(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, let number = number(value), number >= 0 else { return nil }
        if let exact = Int(value.stringValue) { return exact >= 0 ? exact : nil }
        guard number < Double(Int.max), number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }

    static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func disabled(_ value: Any?) -> Bool? {
        // Go's omitempty excludes a false bool; omission therefore means false.
        guard let value else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = text(value) else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: text) ?? ISO8601DateFormatter().date(from: text),
              date.timeIntervalSince1970.isFinite else { return nil }
        return date
    }
}
