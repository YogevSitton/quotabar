import XCTest
@testable import QuotaCore

final class ReadingFreshnessTests: XCTestCase {
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
}
