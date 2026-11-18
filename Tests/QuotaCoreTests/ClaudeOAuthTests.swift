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
    func testCLIUsagePreservesWindowsPlanAndModelLimits() throws {
        let raw = data("""
        {"rate_limits_available":true,"subscription_type":"pro","rate_limits":{
          "five_hour":{"utilization":34,"resets_at":"2026-10-23T16:50:00Z"},
          "seven_day":{"utilization":30,"resets_at":"2026-10-25T10:00:00Z"},
          "model_scoped":[{"display_name":"Example model","utilization":12,"resets_at":"2026-10-25T10:00:00Z"}]
        }}
        """)
        let result = try UsageParser.claudeCLI(raw, now: now)
        XCTAssertEqual(result.session?.remaining, 66)
        XCTAssertEqual(result.weekly?.remaining, 70)
        XCTAssertNotNil(result.session?.resetsAt)
        XCTAssertEqual(result.plan, "pro")
        XCTAssertEqual(result.additionalWindows.first?.title, "Example model · weekly")
        XCTAssertFalse(result.showsResetCredits)
        XCTAssertNil(result.resetCount)
    }

    func testFableWeeklyUsesScopedWindowAndMatchesItsCache() throws {
        let limits = """
        "five_hour":{"utilization":34},"seven_day":{"utilization":30,"resets_at":1792761243},
        "limits":[
          {"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable 5.2"}},"percent":62,"resets_at":1792770000},
          {"kind":"weekly_scoped","scope":{"model":{"display_name":"Opus"}},"percent":95}
        ]
        """
        let cached = try UsageParser.claudeOAuth(data("{\(limits)}"), now: now)
        let reply = try UsageParser.claudeCLI(data("""
        {"rate_limits_available":true,"rate_limits":{
          "five_hour":{"utilization":34},"seven_day":{"utilization":30,"resets_at":1792761243},
          "model_scoped":[{"display_name":"Claude Fable 5.2","utilization":62,"resets_at":1792770000}]
        }}
        """), now: now)
        XCTAssertEqual(reply.weekly?.remaining, 70)
        XCTAssertEqual(reply.claudeFableWeekly?.title, "Fable 5.2")
        XCTAssertEqual(reply.claudeFableWeekly?.window.remaining, 38)
        XCTAssertEqual(reply.claudeFableWeekly?.window.resetsAt, Date(timeIntervalSince1970: 1792770000))
        XCTAssertTrue(reply.hasMatchingUsage(in: cached))
        var mismatched = cached
        mismatched.claudeFableWeekly = nil
        XCTAssertFalse(reply.hasMatchingUsage(in: mismatched))
    }

    func testFableSelectionRequiresAValidUnambiguousModelWindow() throws {
        let result = try UsageParser.claudeCLI(data("""
        {"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":30},"model_scoped":[
          {"display_name":"Fable 5.2","utilization":42},
          {"display_name":"Fable","utilization":55},
          {"display_name":"Opus","utilization":0}
        ]}}
        """), now: now)
        XCTAssertEqual(result.claudeFableWeekly?.title, "Fable")
        XCTAssertEqual(result.claudeFableWeekly?.window.remaining, 45)
        let invalid = try UsageParser.claudeCLI(data("""
        {"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":30},"model_scoped":[
          {"display_name":"Fable 5.2","utilization":true},
          {"display_name":"Fable","utilization":5},
          {"display_name":"Fable","utilization":12},
          {"display_name":"Not Fable","utilization":17}
        ]}}
        """), now: now)
        XCTAssertNil(invalid.claudeFableWeekly)
    }

    func testFableResetGrantKeepsExpiryAndHandsOffToClaude() throws {
        let result = try UsageParser.claudeCLI(data("""
        {"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":25},
          "cedar_ember":{"eligible":true,"grants":[{"id":"sample-grant","resets_left":1,
            "paused":false,"type":"session","gives_back_weekly":true,"clears":["five_hour","seven_day_overage_included"],
            "ends_at":1792761243}]}}}
        """), now: now)
        let offer = try XCTUnwrap(result.offers.first)
        let expiry = Date(timeIntervalSince1970: 1792761243)
        XCTAssertEqual(offer.title, "Fable limit reset")
        XCTAssertEqual(offer.kind, "fable")
        XCTAssertEqual(offer.remainingCount, 1)
        XCTAssertFalse(offer.supportsDirectRedemption)
        XCTAssertEqual(result.nextResetExpiry(at: now), expiry)
        XCTAssertTrue(result.hasReviewableClaudeReset(at: now))
        XCTAssertFalse(result.hasReviewableClaudeReset(at: expiry))
    }

    func testUnusedResetHintIsAccountMatchedAndTimeLimitedWithoutAnInventory() throws {
        let checked = now.addingTimeInterval(-60)
        let cutoff = now.addingTimeInterval(1800)
        let hint: [String: Any] = ["accountUuid": "sample-account", "holdsUnusedReset": true,
            "checkedAt": checked.timeIntervalSince1970 * 1000, "validUntil": cutoff.timeIntervalSince1970 * 1000]
        let validity = UsageParser.claudeResetHintValidity(hint, accountID: "sample-account", now: now)
        XCTAssertEqual(validity, cutoff)
        XCTAssertNil(UsageParser.claudeResetHintValidity(hint, accountID: "different-account", now: now))
        XCTAssertNil(UsageParser.claudeResetHintValidity(hint, accountID: "sample-account", now: cutoff))
        XCTAssertNil(UsageParser.claudeResetHintValidity(hint, accountID: "sample-account", now: checked.addingTimeInterval(-1)))

        var malformed = hint
        malformed["holdsUnusedReset"] = 1
        XCTAssertNil(UsageParser.claudeResetHintValidity(malformed, accountID: "sample-account", now: now))
        malformed["holdsUnusedReset"] = false
        XCTAssertNil(UsageParser.claudeResetHintValidity(malformed, accountID: "sample-account", now: now))
        var longLived = hint
        longLived["validUntil"] = checked.addingTimeInterval(4 * 86400).timeIntervalSince1970 * 1000
        XCTAssertEqual(UsageParser.claudeResetHintValidity(longLived, accountID: "sample-account", now: now),
                       checked.addingTimeInterval(3 * 86400))

        var snapshot = try UsageParser.claudeOAuth(data("{\"seven_day\":{\"utilization\":25}}"), now: now)
        snapshot.claudeResetHintValidUntil = validity
        XCTAssertTrue(snapshot.showsClaudeResetHint(at: now))
        XCTAssertTrue(snapshot.hasReviewableClaudeReset(at: now))
        XCTAssertFalse(snapshot.showsClaudeResetHint(at: cutoff))
        XCTAssertNil(snapshot.resetCount)
        XCTAssertNil(snapshot.nextResetExpiry(at: now))
        snapshot.showsResetCredits = true
        snapshot.resetCount = 0
        XCTAssertFalse(snapshot.hasReviewableClaudeReset(at: now))
    }

    func testCLINoEligibleAccountOrMissingDataNeverMeansFullQuota() {
        XCTAssertThrowsError(try UsageParser.claudeCLI(data("{\"rate_limits_available\":false,\"rate_limits\":null}")))
        XCTAssertThrowsError(try UsageParser.claudeCLI(data("{\"rate_limits_available\":true,\"rate_limits\":null}")))
        XCTAssertThrowsError(try UsageParser.claudeCLI(data("{\"rate_limits_available\":true,\"rate_limits\":{}}")))
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
