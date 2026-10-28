import XCTest
@testable import QuotaCore

final class ReadingFreshnessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_800_000)

    func testUsersTwelveHourOldDiskReadingCannotBePresentedAsCurrent() {
        let now = Date(timeIntervalSince1970: 1_792_800_000)
        var saved = UsageSnapshot(session: UsageWindow(used: 0, resetsAt: nil),
            weekly: UsageWindow(used: 25, resetsAt: nil), observedAt: now.addingTimeInterval(-12 * 3600))
        saved.source = .cached
        XCTAssertFalse(saved.isCurrent(at: now, maximumAge: 600, hasConnectionError: false))
        saved.observedAt = now
        XCTAssertFalse(saved.isCurrent(at: now, maximumAge: 600, hasConnectionError: false))
    }
    func testLiveReadingMustBeRecentAndConnected() {
        let now = Date(timeIntervalSince1970: 1_792_800_000)
        var reading = UsageSnapshot(observedAt: now.addingTimeInterval(-300))
        XCTAssertTrue(reading.isCurrent(at: now, maximumAge: 600, hasConnectionError: false))
        XCTAssertFalse(reading.isCurrent(at: now, maximumAge: 600, hasConnectionError: true))
        reading.observedAt = now.addingTimeInterval(-600)
        XCTAssertFalse(reading.isCurrent(at: now, maximumAge: 600, hasConnectionError: false))
        reading.observedAt = now.addingTimeInterval(3600)
        XCTAssertFalse(reading.isCurrent(at: now, maximumAge: 600, hasConnectionError: false))
    }
    func testResetDeadlineRemovesCurrentPercentageWithoutInventingReplenishment() {
        let reset = Date(timeIntervalSince1970: 1_792_800_000)
        let window = UsageWindow(used: 34, resetsAt: reset)
        XCTAssertEqual(window.currentRemaining(at: reset.addingTimeInterval(-1)), 66)
        XCTAssertNil(window.currentRemaining(at: reset))
        XCTAssertNil(window.currentRemaining(at: reset.addingTimeInterval(60)))
        XCTAssertEqual(window.remaining, 66)
    }

    func testAcceptedRecentClaudeCacheCoversNextPollAndReaderTimeout() {
        let observed = start.addingTimeInterval(-59.5)
        XCTAssertEqual(ClaudeRefreshPolicy.classify(before: observed, after: observed,
            requestStartedAt: start, completedAt: start.addingTimeInterval(0.25)), .recentCache)
        let reading = UsageSnapshot(session: UsageWindow(used: 34, resetsAt: start.addingTimeInterval(3_600)),
            observedAt: observed)
        let nextRequest = start.addingTimeInterval(ClaudePollState.normalInterval)
        XCTAssertEqual(nextRequest, start.addingTimeInterval(130))
        let nextReadTimeout = nextRequest.addingTimeInterval(45)
        XCTAssertTrue(reading.isCurrent(at: nextRequest,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        XCTAssertTrue(reading.isCurrent(at: nextReadTimeout,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        XCTAssertTrue(reading.isCurrent(at: nextReadTimeout.addingTimeInterval(5),
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        XCTAssertEqual(reading.currentSessionLimit(at: nextReadTimeout,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false), reading.sessionLimit)
    }

    func testClaudeDisplayExpiresAtExactlyFourMinutes() {
        let reading = UsageSnapshot(session: UsageWindow(used: 34, resetsAt: start.addingTimeInterval(3_600)),
            observedAt: start)
        XCTAssertTrue(reading.isCurrent(at: start.addingTimeInterval(239.99),
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        XCTAssertFalse(reading.isCurrent(at: start.addingTimeInterval(240),
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        XCTAssertEqual(reading.currentSessionLimit(at: start.addingTimeInterval(240),
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false), .unavailable)
    }

    func testClaudeErrorOrHistoricalSourceInvalidatesDisplayImmediately() {
        var reading = UsageSnapshot(session: UsageWindow(used: 34, resetsAt: start.addingTimeInterval(3_600)),
            observedAt: start)
        let nextPoll = start.addingTimeInterval(130)
        XCTAssertTrue(reading.isCurrent(at: nextPoll,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        XCTAssertFalse(reading.isCurrent(at: nextPoll,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: true))
        XCTAssertEqual(reading.currentSessionLimit(at: nextPoll,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: true), .unavailable)
        reading.source = .cached
        XCTAssertFalse(reading.isCurrent(at: nextPoll,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        XCTAssertEqual(reading.currentSessionLimit(at: nextPoll,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false), .unavailable)
    }

    func testClaudeWindowExpiryStillOverridesExtendedDisplayLifetime() {
        let reset = start.addingTimeInterval(130)
        let reading = UsageSnapshot(session: UsageWindow(used: 34, resetsAt: reset),
            weekly: UsageWindow(used: 25, resetsAt: start.addingTimeInterval(86_400)), observedAt: start)
        XCTAssertTrue(reading.isCurrent(at: reset,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        XCTAssertEqual(reading.currentSessionLimit(at: reset.addingTimeInterval(-0.01),
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false), reading.sessionLimit)
        XCTAssertEqual(reading.currentSessionLimit(at: reset,
            maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false), .unavailable)
        XCTAssertEqual(reading.weekly?.currentRemaining(at: reset), 75)
    }

    func testExtendedDisplayLifetimeDoesNotAcceptExpiredClaudeCacheFallback() {
        for age in [60.0, 90.5, 130, 239] {
            let observed = start.addingTimeInterval(-age)
            var reading = UsageSnapshot(session: UsageWindow(used: 34, resetsAt: start.addingTimeInterval(3_600)),
                observedAt: observed)
            // A previously accepted reading may still be displayed, but a new
            // refresh returning this expired cache must still be rejected.
            XCTAssertTrue(reading.isCurrent(at: start,
                maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
            XCTAssertEqual(ClaudeRefreshPolicy.classify(before: observed, after: observed,
                requestStartedAt: start, completedAt: start.addingTimeInterval(0.25)), .unverified)
            reading.source = .cached
            XCTAssertFalse(reading.isCurrent(at: start,
                maximumAge: ClaudeRefreshPolicy.maximumDisplayAge, hasConnectionError: false))
        }
    }
}
