import Foundation
import XCTest
@testable import QuotaBar

final class TrackedClaudeResetTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_700_000)

    func testReminderPersistsForTheSameAccountAndOrganization() throws {
        let suite = "TrackedClaudeResetTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = try XCTUnwrap(ClaudeResetTrackingAccount(accountID: "first", organizationID: "one"))
        let otherAccount = try XCTUnwrap(ClaudeResetTrackingAccount(accountID: "second", organizationID: "one"))
        let otherOrganization = try XCTUnwrap(ClaudeResetTrackingAccount(accountID: "first", organizationID: "two"))
        let accountOnly = try XCTUnwrap(ClaudeResetTrackingAccount(accountID: "first", organizationID: nil))
        let reset = TrackedClaudeReset(kind: .full, expiresAt: now.addingTimeInterval(3600))

        try TrackedClaudeReset.save(reset, for: original, now: now, defaults: defaults)
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(TrackedClaudeReset.load(for: original, defaults: reopenedDefaults), reset)
        XCTAssertNil(TrackedClaudeReset.load(for: otherAccount, defaults: defaults))
        XCTAssertNil(TrackedClaudeReset.load(for: otherOrganization, defaults: defaults))
        XCTAssertNil(TrackedClaudeReset.load(for: accountOnly, defaults: defaults))
        XCTAssertNil(ClaudeResetTrackingAccount(accountID: nil, organizationID: "one"))

        XCTAssertTrue(reset.isUnexpired(at: now))
        XCTAssertFalse(reset.isUnexpired(at: reset.expiresAt))
        XCTAssertThrowsError(try TrackedClaudeReset.save(reset, for: original, now: reset.expiresAt, defaults: defaults))

        try TrackedClaudeReset.save(nil, for: original, defaults: defaults)
        XCTAssertNil(TrackedClaudeReset.load(for: original, defaults: reopenedDefaults))
    }
}
