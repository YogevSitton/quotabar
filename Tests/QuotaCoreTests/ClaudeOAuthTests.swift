import XCTest
@testable import QuotaCore

final class ClaudeOAuthTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_700_000)
    func data(_ value: String) -> Data { Data(value.utf8) }
    func testMixedTimestampsAndOptionalCredits() throws {
        let result = try UsageParser.claudeOAuth(data("""
        {"five_hour":{"utilization":20,"resets_at":1792761243},"seven_day":{"utilization":28,"resets_at":"2026-10-25T09:59:59.646678+00:00"},"unknown_future_field":{"anything":true}}
        """), now: now)
        XCTAssertEqual(result.session?.remaining, 80)
        XCTAssertEqual(result.weekly?.remaining, 72)
        XCTAssertEqual(result.session?.resetsAt, Date(timeIntervalSince1970: 1792761243))
        XCTAssertNotNil(result.weekly?.resetsAt)
        XCTAssertFalse(result.showsResetCredits)
        XCTAssertNil(result.resetCount)
        XCTAssertEqual(result.source, .live)
    }
    func testCreditCountsPausedGrantsNextExpiryAndCooldown() throws {
        let result = try UsageParser.claudeOAuth(data("""
        {"five_hour":{"utilization":20},"cedar_ember":{"eligible":true,"next_grant_id":"weekly","cooldown_until":1792761243000,"grants":[
         {"id":"weekly","label":"Weekly gift","type":"weekly","resets_left":2,"paused":false,"usable_now":false,"use_requires_limit":true,"ends_at":"2026-11-06T22:33:00Z"},
         {"id":"session","type":"session","resets_left":1,"paused":false,"usable_now":true,"ends_at":1792761243},
         {"id":"paused","resets_left":5,"paused":true},
         {"id":"spent","resets_left":0,"paused":false}]}}
        """), now: now)
        XCTAssertTrue(result.showsResetCredits)
        XCTAssertEqual(result.resetCount, 3)
        XCTAssertEqual(result.offers.count, 2)
        XCTAssertEqual(result.offers.first?.id, "session")
        let offer = try XCTUnwrap(result.offers.first { $0.id == "weekly" })
        XCTAssertEqual(offer.remainingCount, 2)
        XCTAssertTrue(offer.isNext)
        XCTAssertEqual(offer.usableNow, false)
        XCTAssertEqual(offer.kind, "weekly")
        XCTAssertNotNil(offer.detail)
        XCTAssertEqual(result.cooldownUntil, Date(timeIntervalSince1970: 1792761243))
    }
    func testCreditsMissingGrantsIsUnknownButEmptyGrantsIsZero() throws {
        let unknown = try UsageParser.claudeOAuth(data("{\"five_hour\":{\"utilization\":0},\"cedar_ember\":{\"eligible\":true}}"))
        XCTAssertTrue(unknown.showsResetCredits); XCTAssertNil(unknown.resetCount)
        let empty = try UsageParser.claudeOAuth(data("{\"five_hour\":{\"utilization\":0},\"cedar_ember\":{\"grants\":[]}}"))
        XCTAssertEqual(empty.resetCount, 0)
    }
    func testUnvalidatedGrantIsNotAssumedAvailable() throws {
        let result = try UsageParser.claudeOAuth(data("""
        {"five_hour":{"utilization":20},"cedar_ember":{"grants":[{"id":"bad","resets_left":true,"paused":false},{"id":"unknown","resets_left":2}]}}
        """))
        XCTAssertNil(result.resetCount); XCTAssertTrue(result.offers.isEmpty)
    }
    func testAdditionalLimitsAndMoneyInMinorUnits() throws {
        let result = try UsageParser.claudeOAuth(data("""
        {"five_hour":{"utilization":20},"seven_day_sonnet":{"utilization":35},"limits":[{"kind":"weekly_scoped","percent":40,"scope":{"model":{"display_name":"Test model"},"surface":{"display_name":"Code"}}}],"extra_usage":{"is_enabled":false,"monthly_limit":12345,"used_credits":678,"currency":"gbp"}}
        """))
        XCTAssertEqual(result.additionalWindows.count, 2)
        XCTAssertEqual(result.additionalWindows.last?.title, "Test model · Code · weekly")
        XCTAssertEqual(result.extraUsage?.monthlyLimit, 123.45)
        XCTAssertEqual(result.extraUsage?.used, 6.78)
        XCTAssertEqual(result.extraUsage?.enabled, false)
    }
    func testHistorySelectsLatestMatchingOrganizationAndLabelsCache() throws {
        let result = try UsageParser.claudeHistory(data("""
        {"version":2,"samples":[{"t":1792690000000,"org":"mine","u":{"fh":10,"sd":25}},{"t":1792699000000,"org":"other","u":{"fh":80}},{"t":1792680000000,"org":"mine","u":{"fh":5}}]}
        """), organizationID: "mine", now: now)
        XCTAssertEqual(result.session?.remaining, 90)
        XCTAssertEqual(result.observedAt, Date(timeIntervalSince1970: 1792690000))
        XCTAssertEqual(result.source, .cached)
        XCTAssertNil(result.session?.resetsAt)
        XCTAssertFalse(result.showsResetCredits)
        XCTAssertThrowsError(try UsageParser.claudeHistory(data("{\"version\":2,\"samples\":[]}"), organizationID: nil))
    }
    func testStatusLineRequiresAccountAndCaptureTimestamp() throws {
        let raw = data("""
        {"organizationID":"mine","capturedAt":1792699999000,"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1792761243},"seven_day":{"used_percentage":28}}}
        """)
        let result = try UsageParser.claudeStatusLine(raw, organizationID: "mine", now: now)
        XCTAssertEqual(result.session?.remaining, 80); XCTAssertEqual(result.source, .cached)
        XCTAssertNotNil(result.session?.resetsAt); XCTAssertNil(result.resetCount)
        XCTAssertThrowsError(try UsageParser.claudeStatusLine(raw, organizationID: "other", now: now))
    }
    func testCredentialsValidateShapeAndNormalizeExpiryWithoutRefresh() throws {
        let credential = try ClaudeCredential.parse(data("{\"claudeAiOauth\":{\"accessToken\":\"test-token\",\"expiresAt\":1792761243000,\"refreshToken\":\"never-used\"}}"))
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1792761243))
        XCTAssertTrue(credential.isExpired(at: Date(timeIntervalSince1970: 1792761243)))
        XCTAssertFalse(credential.isExpired(at: now))
        XCTAssertThrowsError(try ClaudeCredential.parse(data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}")))
    }
    func testRequestIsOnlyReadOnlyUsageEndpoint() {
        let request = ClaudeUsageRequest.make(accessToken: "test-token")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.url?.path, "/api/oauth/usage")
        XCTAssertEqual(request.url?.query, "cedar_ember=1&skip_spend=1")
        XCTAssertNil(request.httpBody)
    }
    func testBackoffHonorsRetryAfterAndAuthorizationDelays() {
        XCTAssertEqual(ClaudeBackoff.delay(status: 429, failureCount: 1, retryAfter: "1200", now: now), 1200)
        XCTAssertEqual(ClaudeBackoff.delay(status: 401, failureCount: 1, retryAfter: nil, now: now), 900)
        XCTAssertEqual(ClaudeBackoff.delay(status: 403, failureCount: 3, retryAfter: nil, now: now), 3600)
        XCTAssertEqual(ClaudeBackoff.delay(status: 500, failureCount: 2, retryAfter: nil, now: now), 600)
    }
    func testInvalidPercentagesNeverBecomeFullQuota() {
        XCTAssertThrowsError(try UsageParser.claudeOAuth(data("{\"five_hour\":{\"utilization\":true},\"seven_day\":{\"utilization\":-1}}")))
        XCTAssertThrowsError(try UsageParser.claudeOAuth(data("{\"five_hour\":{\"utilization\":101}}")))
    }
}
