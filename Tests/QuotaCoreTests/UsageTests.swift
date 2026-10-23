import XCTest
@testable import QuotaCore

final class UsageTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }
    func testCodexUsesNamedBucketAndDurationsNotPosition() throws {
        let value = try UsageParser.codex(data("""
        {"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},
         "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":{"usedPercent":44,"windowDurationMins":300},"planType":"plus"}},
         "rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"a","status":"available","expiresAt":1800000000,"title":"Full reset"},{"id":"b","status":"redeemed","expiresAt":1800000001}]}}
        """))
        XCTAssertEqual(value.session?.remaining, 56)
        XCTAssertEqual(value.weekly?.remaining, 93)
        XCTAssertEqual(value.resetCount, 3) // Count remains authoritative when rows are capped.
        XCTAssertEqual(value.offers.count, 1)
        XCTAssertEqual(value.offers.first?.expiresAt, Date(timeIntervalSince1970: 1800000000))
    }
    func testMissingDataDoesNotMeanFullOrZeroCredits() throws {
        let value = try UsageParser.codex(data("""
        {"rateLimits":{"primary":null,"secondary":{"usedPercent":10,"windowDurationMins":60}},"rateLimitResetCredits":null}
        """))
        XCTAssertNil(value.session); XCTAssertNil(value.weekly); XCTAssertNil(value.resetCount)
    }
    func testResetCreditUnknownExpiryAndCountOnly() throws {
        let value = try UsageParser.codex(data("""
        {"rateLimits":{},"rateLimitResetCredits":{"availableCount":2,"credits":null}}
        """))
        XCTAssertEqual(value.resetCount, 2); XCTAssertTrue(value.offers.isEmpty)
        let unknownExpiry = try UsageParser.codex(data("""
        {"rateLimits":{},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"x","status":"available","expiresAt":null}]}}
        """))
        XCTAssertNil(unknownExpiry.offers.first?.expiresAt)
    }
    func testClaudeDecimalsISOTimeAndResetText() throws {
        let value = try UsageParser.claude(data("""
        {"usage":{"five_hour":{"utilization":18.5,"resets_at":"2026-10-23T16:49:59.646658+00:00"},"seven_day":{"utilization":28,"resets_at":"2026-10-25T09:59:59.646678+00:00"}},"resetCount":0,"resetText":"No resets right now"}
        """))
        XCTAssertEqual(value.session?.remaining, 81); XCTAssertEqual(value.weekly?.remaining, 72)
        XCTAssertNotNil(value.session?.resetsAt); XCTAssertNotNil(value.weekly?.resetsAt)
        XCTAssertEqual(value.resetCount, 0); XCTAssertEqual(value.resetNote, "No resets right now")
    }
    func testClampAndNeverAssumeReplenishedAfterReset() {
        XCTAssertEqual(UsageWindow(used: -5, resetsAt: nil).remaining, 100)
        let depleted = UsageWindow(used: 120, resetsAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(depleted.remaining, 0)
        XCTAssertTrue(depleted.awaitingReset(at: Date()))
    }
    func testRejectsMalformedAndBooleanUsage() throws {
        XCTAssertThrowsError(try UsageParser.claude(data("{}")))
        XCTAssertThrowsError(try UsageParser.claude(data("{\"usage\":{\"five_hour\":{\"utilization\":true}}}")))
        XCTAssertThrowsError(try UsageParser.codex(data("[]")))
    }
}
