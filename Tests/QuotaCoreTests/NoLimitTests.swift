import XCTest
@testable import QuotaCore

final class NoLimitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)
    private let codexWeek: [String: Any] = ["usedPercent": 39, "windowDurationMins": 10080, "resetsAt": 1_793_000_000]
    private let claudeWeek: [String: Any] = ["utilization": 39, "resets_at": 1_793_000_000]

    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func codex(primary: Any?, secondary: Any?, plan: Any? = "pro", named: Bool = false) throws -> UsageSnapshot {
        var bucket: [String: Any] = [:]
        bucket["primary"] = primary
        bucket["secondary"] = secondary
        bucket["planType"] = plan
        let root: [String: Any] = named ? ["rateLimitsByLimitId": ["codex": bucket]] : ["rateLimits": bucket]
        return try UsageParser.codex(data(root), now: now)
    }

    private func claude(session: Any?, weekly: Any?, available: Bool = true) throws -> UsageSnapshot {
        var limits: [String: Any] = [:]
        limits["five_hour"] = session
        limits["seven_day"] = weekly
        return try UsageParser.claudeCLI(data(["rate_limits_available": available, "rate_limits": limits]), now: now)
    }

    private func noLimitSnapshot() -> UsageSnapshot {
        var snapshot = UsageSnapshot(weekly: UsageWindow(used: 39, resetsAt: now.addingTimeInterval(3600)), observedAt: now)
        snapshot.sessionLimit = .noLimit
        return snapshot
    }

    func testCodexProWeeklyWindowAndExplicitNullWorksInEitherSlotAndBucket() throws {
        for named in [false, true] {
            for swapped in [false, true] {
                let snapshot = try codex(primary: swapped ? NSNull() : codexWeek,
                    secondary: swapped ? codexWeek : NSNull(), named: named)
                XCTAssertEqual(snapshot.sessionLimit, .noLimit)
                XCTAssertNil(snapshot.session)
                XCTAssertNil(snapshot.sessionLimit.remaining)
                XCTAssertEqual(snapshot.weekly?.remaining, 61)
            }
        }
    }

    func testCodexMissingOrMalformedSlotDoesNotClaimNoLimit() throws {
        let unknownSlots: [Any?] = [nil, [String: Any](), [Any](), false, 0, "unavailable", ["usedPercent": NSNull(), "windowDurationMins": 300]]
        for slot in unknownSlots {
            for swapped in [false, true] {
                let snapshot = try codex(primary: swapped ? slot : codexWeek,
                    secondary: swapped ? codexWeek : slot)
                XCTAssertEqual(snapshot.sessionLimit, .unavailable)
                XCTAssertEqual(snapshot.weekly?.remaining, 61)
            }
        }
    }

    func testCodexNoLimitRequiresRecognizedPlanAndValidWeeklyReading() throws {
        let plans: [Any?] = [nil, NSNull(), "plus", "future-plan", false]
        for plan in plans {
            XCTAssertEqual(try codex(primary: codexWeek, secondary: NSNull(), plan: plan).sessionLimit, .unavailable)
        }
        let percentages: [Any] = [NSNull(), true, "39", -1, 101]
        for used in percentages {
            XCTAssertEqual(try codex(primary: ["usedPercent": used, "windowDurationMins": 10080],
                secondary: NSNull()).sessionLimit, .unavailable)
        }
        let invalidWeeks: [Any?] = [nil, NSNull(), [String: Any](), ["usedPercent": 39],
            ["usedPercent": 39, "windowDurationMins": 60], ["usedPercent": 39, "windowDurationMins": "10080"]]
        for week in invalidWeeks {
            XCTAssertEqual(try codex(primary: week, secondary: NSNull()).sessionLimit, .unavailable)
        }
    }

    func testCodexReportedFiveHourWindowTakesPrecedenceForPro() throws {
        for used in [0, 100] {
            let window: [String: Any] = ["usedPercent": used, "windowDurationMins": 300, "resetsAt": 1_792_810_000]
            let snapshot = try codex(primary: codexWeek, secondary: window)
            XCTAssertEqual(snapshot.sessionLimit.remaining, 100 - used)
            XCTAssertEqual(snapshot.sessionLimit, .limited(try XCTUnwrap(snapshot.session)))
        }
        let invalidFiveHour: [String: Any] = ["usedPercent": 101, "windowDurationMins": 300]
        XCTAssertEqual(try codex(primary: codexWeek, secondary: invalidFiveHour).sessionLimit, .unavailable)
    }

    func testNamedCodexBucketDoesNotInheritLegacyNoLimitClaim() throws {
        let snapshot = try UsageParser.codex(data([
            "rateLimits": ["planType": "pro", "primary": codexWeek, "secondary": NSNull()],
            "rateLimitsByLimitId": ["codex": ["planType": "pro", "primary": codexWeek]]
        ]), now: now)
        XCTAssertEqual(snapshot.sessionLimit, .unavailable)
        XCTAssertEqual(snapshot.weekly?.remaining, 61)
    }

    func testClaudeExplicitNullFiveHourWithValidWeeklyIsDistinctFromUnknown() throws {
        let snapshot = try claude(session: NSNull(), weekly: claudeWeek)
        XCTAssertEqual(snapshot.sessionLimit, .noLimit)
        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.weekly?.remaining, 61)
        let cache = try UsageParser.claudeOAuth(data(["five_hour": NSNull(), "seven_day": claudeWeek]), now: now)
        XCTAssertEqual(cache.sessionLimit, .noLimit)
        XCTAssertTrue(snapshot.hasMatchingUsage(in: cache))

        let unknownSlots: [Any?] = [nil, [String: Any](), [Any](), false, 0, "unavailable", ["utilization": NSNull()],
            ["utilization": true], ["utilization": -1], ["utilization": 101]]
        for slot in unknownSlots {
            XCTAssertEqual(try claude(session: slot, weekly: claudeWeek).sessionLimit, .unavailable)
        }
    }

    func testClaudeNullFiveHourNeedsEligibleResponseAndValidWeeklyReading() throws {
        XCTAssertThrowsError(try claude(session: NSNull(), weekly: claudeWeek, available: false))
        let invalidWeeks: [Any?] = [nil, NSNull(), [String: Any](), ["utilization": NSNull()],
            ["utilization": true], ["utilization": "39"], ["utilization": -1], ["utilization": 101]]
        for week in invalidWeeks {
            XCTAssertThrowsError(try claude(session: NSNull(), weekly: week))
        }
        XCTAssertThrowsError(try UsageParser.claudeCLI(data(["rate_limits_available": true, "rate_limits": NSNull()]), now: now))
    }

    func testClaudeZeroUsageAndExhaustionRemainMeasuredLimits() throws {
        for used in [0, 100] {
            let snapshot = try claude(session: ["utilization": used], weekly: claudeWeek)
            XCTAssertEqual(snapshot.sessionLimit, .limited(UsageWindow(used: Double(used), resetsAt: nil)))
            XCTAssertEqual(snapshot.sessionLimit.remaining, 100 - used)
        }
    }

    func testHistoricalClaudeOmissionsAndNullsCannotEstablishNoLimit() throws {
        let missingValues: [Any?] = [nil, NSNull()]
        for absent in missingValues {
            var statusLimits: [String: Any] = ["seven_day": ["used_percentage": 39]]
            statusLimits["five_hour"] = absent
            let status = try UsageParser.claudeStatusLine(data([
                "organizationID": "fixture-org", "capturedAt": now.timeIntervalSince1970,
                "rate_limits": statusLimits
            ]), organizationID: "fixture-org", now: now)
            XCTAssertEqual(status.sessionLimit, .unavailable)
            XCTAssertEqual(status.source, .cached)

            var historyUsage: [String: Any] = ["sd": 39]
            historyUsage["fh"] = absent
            let history = try UsageParser.claudeHistory(data([
                "version": 2, "samples": [["t": now.timeIntervalSince1970, "org": "fixture-org", "u": historyUsage]]
            ]), organizationID: "fixture-org", now: now)
            XCTAssertEqual(history.sessionLimit, .unavailable)
            XCTAssertEqual(history.source, .cached)
        }
    }

    func testNoLimitClaimRequiresCurrentConnectedLiveReading() {
        var snapshot = noLimitSnapshot()
        XCTAssertEqual(snapshot.currentSessionLimit(at: now, maximumAge: 120, hasConnectionError: false), .noLimit)
        XCTAssertEqual(snapshot.currentSessionLimit(at: now, maximumAge: 120, hasConnectionError: true), .unavailable)
        XCTAssertEqual(snapshot.currentSessionLimit(at: now.addingTimeInterval(120), maximumAge: 120, hasConnectionError: false), .unavailable)
        XCTAssertEqual(snapshot.currentSessionLimit(at: now.addingTimeInterval(-61), maximumAge: 120, hasConnectionError: false), .unavailable)
        snapshot.source = .cached
        XCTAssertEqual(snapshot.currentSessionLimit(at: now, maximumAge: 120, hasConnectionError: false), .unavailable)
        XCTAssertEqual(snapshot.sessionLimit, .noLimit) // Preserve the historical claim without presenting it as current.
    }

    func testExpiredMeasuredWindowDoesNotBecomeNoLimitOrReplenished() {
        let window = UsageWindow(used: 100, resetsAt: now)
        let limit = UsageLimit.limited(window)
        XCTAssertEqual(limit.current(at: now.addingTimeInterval(-1)), .limited(window))
        XCTAssertEqual(limit.current(at: now), .unavailable)
        XCTAssertEqual(limit.current(at: now.addingTimeInterval(1)), .unavailable)
        XCTAssertEqual(UsageLimit.unavailable.current(at: now), .unavailable)
        XCTAssertEqual(UsageLimit.noLimit.current(at: now), .noLimit)
    }

    func testNoLimitProvenanceMustMatchExplicitAbsenceAndWeeklyReading() {
        let snapshot = noLimitSnapshot()
        var cache = snapshot
        XCTAssertTrue(snapshot.hasMatchingUsage(in: cache))
        cache.session = UsageWindow(used: 0, resetsAt: nil)
        XCTAssertFalse(snapshot.hasMatchingUsage(in: cache))
        XCTAssertFalse(cache.hasMatchingUsage(in: snapshot))
        cache.session = nil
        XCTAssertFalse(snapshot.hasMatchingUsage(in: cache))
        cache.sessionLimit = .noLimit
        cache.weekly = UsageWindow(used: 40, resetsAt: snapshot.weekly?.resetsAt)
        XCTAssertFalse(snapshot.hasMatchingUsage(in: cache))
        cache.weekly = UsageWindow(used: 39, resetsAt: now.addingTimeInterval(7200))
        XCTAssertFalse(snapshot.hasMatchingUsage(in: cache))
    }

    func testUnavailableResponseStillMatchesOnlyItsDisplayedValues() {
        var response = noLimitSnapshot()
        response.session = nil
        var cache = response
        cache.session = UsageWindow(used: 20, resetsAt: nil)
        XCTAssertTrue(response.hasMatchingUsage(in: cache))
        cache.weekly = UsageWindow(used: 40, resetsAt: response.weekly?.resetsAt)
        XCTAssertFalse(response.hasMatchingUsage(in: cache))
    }

    func testReplacingSessionClearsEarlierNoLimitState() {
        var snapshot = noLimitSnapshot()
        let measured = UsageWindow(used: 0, resetsAt: now.addingTimeInterval(300))
        snapshot.session = measured
        XCTAssertEqual(snapshot.sessionLimit, .limited(measured))
        XCTAssertEqual(snapshot.session?.remaining, 100)
        snapshot.session = nil
        XCTAssertEqual(snapshot.sessionLimit, .unavailable)
    }
}
