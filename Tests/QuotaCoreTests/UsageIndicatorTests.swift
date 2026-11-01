import XCTest
@testable import QuotaCore

final class UsageIndicatorTests: XCTestCase {
    private let sampleTime = Date(timeIntervalSince1970: 1_792_800_000)

    func testPaceComparesBothWindowLengthsAgainstElapsedTime() throws {
        for duration: TimeInterval in [5 * 3600, 7 * 86400] {
            let reset = sampleTime.addingTimeInterval(duration / 2)
            let fast = try XCTUnwrap(UsageWindow(used: 65, resetsAt: reset).pace(over: duration, at: sampleTime))
            XCTAssertEqual(fast.expectedUsed, 50, accuracy: 0.001)
            XCTAssertEqual(fast.expectedRemaining, 50, accuracy: 0.001)
            XCTAssertEqual(fast.percentagePointsOverBudget, 15, accuracy: 0.001)
            XCTAssertTrue(fast.overBudget)
            XCTAssertFalse(fast.underBudget)
            let slow = try XCTUnwrap(UsageWindow(used: 30, resetsAt: reset).pace(over: duration, at: sampleTime))
            XCTAssertTrue(slow.underBudget)
            XCTAssertFalse(slow.overBudget)
            for used in [48.0, 50, 52] {
                let onBudget = try XCTUnwrap(UsageWindow(used: used, resetsAt: reset).pace(over: duration, at: sampleTime))
                XCTAssertFalse(onBudget.overBudget)
                XCTAssertFalse(onBudget.underBudget)
            }
        }
    }

    func testPaceRejectsMissingExpiredAndImplausibleWindows() {
        let duration: TimeInterval = 5 * 3600
        for reset in [nil, sampleTime, sampleTime.addingTimeInterval(-1), sampleTime.addingTimeInterval(duration + 1)] {
            XCTAssertNil(UsageWindow(used: 20, resetsAt: reset).pace(over: duration, at: sampleTime))
        }
        let reset = sampleTime.addingTimeInterval(duration)
        for used in [-1, 101, Double.nan, .infinity] {
            XCTAssertNil(UsageWindow(used: used, resetsAt: reset).pace(over: duration, at: sampleTime))
        }
        for invalidDuration in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(UsageWindow(used: 20, resetsAt: reset).pace(over: invalidDuration, at: sampleTime))
        }
    }

    func testWeeklyReferenceApproachesZeroOnlyNearReset() throws {
        let duration: TimeInterval = 7 * 86400
        let nearReset = UsageWindow(used: 51, resetsAt: sampleTime.addingTimeInterval(40 * 60))
        let pace = try XCTUnwrap(nearReset.pace(over: duration, at: sampleTime))
        XCTAssertEqual(pace.expectedRemaining, 100 * 40 / (7 * 24 * 60), accuracy: 0.0001)
        XCTAssertGreaterThan(pace.expectedRemaining, 0)
        XCTAssertTrue(pace.underBudget)
        XCTAssertEqual(nearReset.remaining, 49)

        let newWeek = UsageWindow(used: 0, resetsAt: sampleTime.addingTimeInterval(duration))
        XCTAssertEqual(try XCTUnwrap(newWeek.pace(over: duration, at: sampleTime)).expectedRemaining, 100)
        XCTAssertNil(nearReset.pace(over: duration, at: sampleTime.addingTimeInterval(40 * 60)))
    }

    // Synthetic presentation metadata only; no redemption or recovery paths.
    func testExpiryHighlightBoundariesAndUnknownInventory() {
        func offer(_ seconds: TimeInterval?) -> ResetOffer {
            ResetOffer(id: "synthetic", title: "Usage reset", expiresAt: seconds.map { sampleTime.addingTimeInterval($0) })
        }
        XCTAssertEqual(offer(nil).expiryUrgency(at: sampleTime), .normal)
        XCTAssertEqual(offer(-1).expiryUrgency(at: sampleTime), .normal)
        XCTAssertEqual(offer(0).expiryUrgency(at: sampleTime), .normal)
        XCTAssertEqual(offer(1).expiryUrgency(at: sampleTime), .imminent)
        XCTAssertEqual(offer(86400).expiryUrgency(at: sampleTime), .imminent)
        XCTAssertEqual(offer(86401).expiryUrgency(at: sampleTime), .soon)
        XCTAssertEqual(offer(3 * 86400).expiryUrgency(at: sampleTime), .soon)
        XCTAssertEqual(offer(3 * 86400 + 1).expiryUrgency(at: sampleTime), .normal)
        var empty = offer(60)
        empty.remainingCount = 0
        XCTAssertEqual(empty.expiryUrgency(at: sampleTime), .normal)
        var unknownCount = offer(60)
        unknownCount.remainingCount = nil
        XCTAssertEqual(unknownCount.expiryUrgency(at: sampleTime), .imminent)
        for timeLeft in [0, -1, -.infinity, .nan] as [TimeInterval] {
            XCTAssertEqual(ResetExpiryUrgency(timeLeft: timeLeft), .normal)
        }
    }

    func testExpiryColorGraduallyReachesRedAtTwelveHours() {
        let samples: [(TimeInterval, Double)] = [
            (3 * 86400, 0), (86401, 0), (24 * 3600, 0),
            (21 * 3600, 0.25), (18 * 3600, 0.5), (15 * 3600, 0.75),
            (12 * 3600, 1), (3600, 1), (1, 1)
        ]
        for (timeLeft, expected) in samples {
            XCTAssertEqual(ResetExpiryUrgency.redBlendFraction(timeLeft: timeLeft), expected, accuracy: 0.000001)
        }
        for timeLeft in [0, -1, -.infinity, .infinity, .nan] as [TimeInterval] {
            XCTAssertEqual(ResetExpiryUrgency.redBlendFraction(timeLeft: timeLeft), 0)
        }
    }

    func testNextExpiryIgnoresPastUnknownAndUsedOffers() {
        func offer(_ id: String, _ seconds: TimeInterval?, count: Int? = 1) -> ResetOffer {
            var offer = ResetOffer(id: id, title: "Usage reset", expiresAt: seconds.map { sampleTime.addingTimeInterval($0) })
            offer.remainingCount = count
            return offer
        }
        let snapshot = UsageSnapshot(offers: [offer("past", -10), offer("used", 30, count: 0), offer("unknown", nil),
                                              offer("later", 9000), offer("next", 600)])
        XCTAssertEqual(snapshot.nextResetExpiry(at: sampleTime), sampleTime.addingTimeInterval(600))
        XCTAssertNil(UsageSnapshot(offers: [offer("unknown", nil), offer("past", -1)]).nextResetExpiry(at: sampleTime))
    }

    func testUpcomingExpiryIsNotHiddenByExpiredOffer() {
        let expired = ResetOffer(id: "expired", title: "Old", expiresAt: sampleTime.addingTimeInterval(-1))
        let urgent = ResetOffer(id: "urgent", title: "Soon", expiresAt: sampleTime.addingTimeInterval(600))
        let later = ResetOffer(id: "later", title: "Later", expiresAt: sampleTime.addingTimeInterval(100000))
        let unknown = ResetOffer(id: "unknown", title: "Unknown", expiresAt: nil)
        let snapshot = UsageSnapshot(offers: [expired, unknown, later, urgent])
        XCTAssertEqual(snapshot.orderedResetOffers(at: sampleTime).map(\.id), ["urgent", "later", "unknown", "expired"])
    }

    func testLeftoverResetBoundaries() {
        func qualifies(_ window: LeftoverReset.Window, _ remaining: Int?, _ seconds: TimeInterval?) -> Bool {
            LeftoverReset.qualifies(window, remaining: remaining, resetsAt: seconds.map { sampleTime.addingTimeInterval($0) }, at: sampleTime)
        }
        XCTAssertTrue(qualifies(.weekly, 1, 48 * 3600))
        XCTAssertTrue(qualifies(.weekly, 100, 1))
        XCTAssertFalse(qualifies(.weekly, 34, 48 * 3600 + 1))
        XCTAssertFalse(qualifies(.weekly, 0, 3600))
        XCTAssertTrue(qualifies(.fiveHour, 30, 3600))
        XCTAssertFalse(qualifies(.fiveHour, 29, 600))
        XCTAssertFalse(qualifies(.fiveHour, 80, 3601))
        for window in [LeftoverReset.Window.fiveHour, .weekly] {
            XCTAssertFalse(qualifies(window, nil, 600))
            XCTAssertFalse(qualifies(window, 50, nil))
            for seconds in [0, -1, .nan, -.infinity] as [TimeInterval] {
                XCTAssertFalse(qualifies(window, 50, seconds))
            }
        }
    }

    func testLeftoverResetPicksSoonestQualifyingWindow() throws {
        func window(used: Double, _ seconds: TimeInterval) -> UsageWindow {
            UsageWindow(used: used, resetsAt: sampleTime.addingTimeInterval(seconds))
        }
        let weekly = try XCTUnwrap(LeftoverReset.soonest(fiveHour: window(used: 20, 3 * 3600), weekly: window(used: 66, 9 * 3600), at: sampleTime))
        XCTAssertEqual(weekly.window, .weekly)
        XCTAssertEqual(weekly.remaining, 34)
        let fiveHour = try XCTUnwrap(LeftoverReset.soonest(fiveHour: window(used: 45, 2400), weekly: window(used: 66, 9 * 3600), at: sampleTime))
        XCTAssertEqual(fiveHour.window, .fiveHour)
        XCTAssertEqual(fiveHour.resetsAt, sampleTime.addingTimeInterval(2400))
        XCTAssertNil(LeftoverReset.soonest(fiveHour: window(used: 45, 2400), weekly: window(used: 100, 9 * 3600), at: sampleTime))
        XCTAssertNil(LeftoverReset.soonest(fiveHour: nil, weekly: window(used: 10, 3 * 86400), at: sampleTime))
        XCTAssertNil(LeftoverReset.soonest(fiveHour: nil, weekly: UsageWindow(used: 10, resetsAt: nil), at: sampleTime))
        XCTAssertEqual(LeftoverReset.soonest(fiveHour: window(used: 0, 600), weekly: nil, at: sampleTime)?.window, .fiveHour)
    }
}
