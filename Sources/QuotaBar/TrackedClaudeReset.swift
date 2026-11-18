import CryptoKit
import Foundation
import QuotaCore

struct ClaudeResetTrackingAccount: Equatable, Sendable {
    fileprivate let preferenceKey: String

    init?(accountID: String?, organizationID: String?) {
        guard let accountID, !accountID.isEmpty else { return nil }
        // Keep the reminder scoped to this subscription without saving the identifiers.
        let identity = "\(accountID.utf8.count):\(accountID)\(organizationID ?? "")"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        preferenceKey = "trackedClaudeReset.\(digest)"
    }
}

struct TrackedClaudeReset: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case full = "Full reset"
        case weekly = "Weekly reset"
        case session = "5-hour reset"
        case fable = "Fable limit reset"
    }

    let kind: Kind
    let expiresAt: Date

    func isUnexpired(at now: Date) -> Bool {
        let timeLeft = expiresAt.timeIntervalSince(now)
        return timeLeft.isFinite && timeLeft > 0
    }

    static func load(for account: ClaudeResetTrackingAccount, defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: account.preferenceKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func save(_ reset: Self?, for account: ClaudeResetTrackingAccount, now: Date = .now,
                     defaults: UserDefaults = .standard) throws {
        if let reset {
            guard reset.isUnexpired(at: now) else {
                throw UsageError.message("Choose an expiry date and time in the future.")
            }
            defaults.set(try JSONEncoder().encode(reset), forKey: account.preferenceKey)
        } else {
            defaults.removeObject(forKey: account.preferenceKey)
        }
    }
}
