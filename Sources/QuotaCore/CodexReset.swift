import Foundation

// A logical redemption always targets one account and one specific credit.
// Persist before sending; retain the same UUID after any uncertain response.
public struct CodexResetAttempt: Codable, Equatable, Sendable {
    public let id: UUID
    public let accountID: String
    public let creditID: String
    public let title: String
    public let expiresAt: Date?
    public let createdAt: Date

    public init(snapshot: UsageSnapshot, offer: ResetOffer, now: Date = Date()) throws {
        try Self.validate(snapshot: snapshot, creditID: offer.id, now: now)
        id = UUID(); accountID = snapshot.accountID!; creditID = offer.id
        title = offer.title; expiresAt = offer.expiresAt; createdAt = now
    }
    public var parameters: [String: String] {
        ["creditId": creditID, "idempotencyKey": id.uuidString]
    }
    public static func validate(snapshot: UsageSnapshot, creditID: String, now: Date = Date()) throws {
        guard snapshot.isCurrent(at: now, maximumAge: 120, hasConnectionError: false) else {
            throw UsageError.message("Refresh Codex usage before using a reset.")
        }
        guard let account = snapshot.accountID, !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageError.message("The Codex account could not be verified. Open ChatGPT Usage to manage resets.")
        }
        guard (snapshot.resetCount ?? 0) > 0,
              let offer = snapshot.offers.first(where: { $0.id == creditID }),
              !creditID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              offer.supportsDirectRedemption else {
            throw UsageError.message("This reset is no longer available or cannot be redeemed by this Codex version. Refresh or open ChatGPT Usage.")
        }
        guard offer.expiresAt.map({ $0 > now }) ?? true else {
            throw UsageError.message("This reset has expired. Refresh Codex usage.")
        }
    }
}

public enum CodexResetOutcome: String, Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit

    public static func parse(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["outcome"] as? String, let outcome = Self(rawValue: raw) else {
            throw UsageError.message("Codex returned an unrecognized reset result. The same request is saved for safe recovery.")
        }
        return outcome
    }
    public var message: String {
        switch self {
        case .reset: return "Codex used one reset. Refreshing your limits…"
        case .alreadyRedeemed: return "Codex confirmed that this reset request already completed. Refreshing your limits…"
        case .nothingToReset: return "Codex found no eligible usage to reset. No reset was consumed."
        case .noCredit: return "Codex reports that this reset credit is unavailable."
        }
    }
}
