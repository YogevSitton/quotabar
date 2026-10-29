import XCTest
@testable import QuotaCore

final class ClaudeRefreshPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_800_000)

    private func classification(before: TimeInterval?, after: TimeInterval?,
                                completed: TimeInterval = 1) -> ClaudeRefreshClassification {
        ClaudeRefreshPolicy.classify(before: before.map { start.addingTimeInterval($0) },
            after: after.map { start.addingTimeInterval($0) }, requestStartedAt: start,
            completedAt: start.addingTimeInterval(completed))
    }

    func testNewSampleDuringReadIsAcceptedEvenWhenUsageValuesAreUnchanged() {
        // Matching of usage values is a caller precondition. Timestamp advance
        // is still required when an endpoint returns the same percentages.
        XCTAssertEqual(classification(before: -90, after: 0.5), .newSample)
        XCTAssertTrue(classification(before: -90, after: 0.5).isAccepted)
        XCTAssertEqual(classification(before: -90, after: 0), .newSample)
    }

    func testExpiredCacheFallbackIsRejectedBeforeTheDisplayAgeLimit() {
        for age in [60.0, 61, 90.5, 118] {
            XCTAssertEqual(classification(before: -age, after: -age), .unverified)
            XCTAssertFalse(classification(before: -age, after: -age).isAccepted)
        }
    }

    func testLegitimateCacheShortcutRemainsInsideTTLAtCompletion() {
        XCTAssertEqual(classification(before: -58, after: -58), .recentCache)
        XCTAssertTrue(classification(before: -58, after: -58).isAccepted)
        XCTAssertEqual(classification(before: 0, after: 0), .recentCache)
    }

    func testHelperStartupCrossingCacheTTLDoesNotHideFailedRefresh() {
        XCTAssertEqual(classification(before: -59.99, after: -59.99, completed: 2), .unverified)
        XCTAssertEqual(classification(before: -59, after: -59, completed: 1), .unverified)
        XCTAssertEqual(classification(before: -59, after: -59, completed: 0.99), .recentCache)
    }

    func testAdvancedTimestampMustAlsoBeRecentAtRequestStart() {
        XCTAssertEqual(classification(before: -100, after: -65), .unverified)
        XCTAssertEqual(classification(before: -100, after: -60), .unverified)
        XCTAssertEqual(classification(before: -100, after: -58), .recentCache)
    }

    func testMissingBeforeAllowsOnlyNewOrRecentMatchingSamples() {
        XCTAssertEqual(classification(before: nil, after: 0.5), .newSample)
        XCTAssertEqual(classification(before: nil, after: 0), .newSample)
        XCTAssertEqual(classification(before: nil, after: -58), .recentCache)
        XCTAssertEqual(classification(before: nil, after: -60), .unverified)
        XCTAssertEqual(classification(before: -1, after: nil), .unverified)
    }

    func testOlderConcurrentCacheCannotReplaceKnownNewerSample() {
        XCTAssertEqual(classification(before: -5, after: -10), .unverified)
        XCTAssertEqual(classification(before: -5, after: -65), .unverified)
    }

    func testCompletionAgeLimitRemainsStrictlyTwoMinutes() {
        XCTAssertEqual(classification(before: -90, after: 0.5, completed: 120.49), .newSample)
        XCTAssertEqual(classification(before: -90, after: 0.5, completed: 120.5), .unverified)
    }

    func testFutureSamplesAndClockRollbackAreRejected() {
        XCTAssertEqual(classification(before: -5, after: 1.01), .unverified)
        XCTAssertEqual(classification(before: 0.1, after: 0.5), .unverified)
        XCTAssertEqual(classification(before: -5, after: -1, completed: -0.5), .unverified)
    }

    func testNonfiniteDatesCannotEstablishProvenance() {
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            let date = Date(timeIntervalSince1970: invalid)
            XCTAssertEqual(ClaudeRefreshPolicy.classify(before: date, after: start,
                requestStartedAt: start, completedAt: start), .unverified)
            XCTAssertEqual(ClaudeRefreshPolicy.classify(before: nil, after: date,
                requestStartedAt: start, completedAt: start), .unverified)
            XCTAssertEqual(ClaudeRefreshPolicy.classify(before: nil, after: start,
                requestStartedAt: date, completedAt: start), .unverified)
            XCTAssertEqual(ClaudeRefreshPolicy.classify(before: nil, after: start,
                requestStartedAt: start, completedAt: date), .unverified)
        }
    }

    func testRejectionReportsWhyAReadingWasNotAccepted() {
        func rejection(before: TimeInterval?, after: TimeInterval?, completed: TimeInterval = 1) -> ClaudeRefreshRejection? {
            ClaudeRefreshPolicy.rejection(before: before.map { start.addingTimeInterval($0) },
                after: after.map { start.addingTimeInterval($0) }, requestStartedAt: start,
                completedAt: start.addingTimeInterval(completed))
        }
        XCTAssertNil(rejection(before: -90, after: 0.5))
        XCTAssertNil(rejection(before: -58, after: -58))
        XCTAssertEqual(rejection(before: -1, after: nil), .missingSample)
        XCTAssertEqual(rejection(before: -90, after: 0.5, completed: 120.5), .sampleTooOld)
        XCTAssertEqual(rejection(before: -100, after: -60), .reusedSampleExpired)
        XCTAssertEqual(rejection(before: -59, after: -59, completed: 1), .reusedSampleExpired)
        XCTAssertEqual(rejection(before: -5, after: -10), .inconsistentTiming)
        XCTAssertEqual(rejection(before: -5, after: -1, completed: -0.5), .inconsistentTiming)
    }
}
