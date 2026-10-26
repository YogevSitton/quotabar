import XCTest
@testable import QuotaCore

final class ClaudeCacheRecoveryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_800_000)

    func testNewOfficialCacheCanTriggerRecheckDuringLongFailureBackoff() {
        XCTAssertTrue(ClaudeCacheRecovery.shouldRecheck(observedAt: start.addingTimeInterval(179),
            lastRequestStartedAt: start, now: start.addingTimeInterval(180)))
    }

    func testUnchangedPreFailureCacheCannotBypassBackoff() {
        for offset in [-600.0, -1, 0] {
            XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: start.addingTimeInterval(offset),
                lastRequestStartedAt: start, now: start.addingTimeInterval(180)))
        }
    }

    func testRecoveryRespectsNormalCadenceAndTimerMargin() {
        let observed = start.addingTimeInterval(60)
        XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: observed,
            lastRequestStartedAt: start, now: start.addingTimeInterval(60)))
        XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: observed,
            lastRequestStartedAt: start, now: start.addingTimeInterval(60.49)))
        XCTAssertTrue(ClaudeCacheRecovery.shouldRecheck(observedAt: observed,
            lastRequestStartedAt: start, now: start.addingTimeInterval(60.5)))
        XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: observed,
            lastRequestStartedAt: start, now: start.addingTimeInterval(60.5), minimumInterval: 120))
    }

    func testExpiredOfficialCacheCannotTriggerAnotherNetworkFetch() {
        let now = start.addingTimeInterval(180)
        XCTAssertTrue(ClaudeCacheRecovery.shouldRecheck(observedAt: now.addingTimeInterval(-59.99),
            lastRequestStartedAt: start, now: now))
        XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: now.addingTimeInterval(-60),
            lastRequestStartedAt: start, now: now))
        XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: now.addingTimeInterval(-120),
            lastRequestStartedAt: start, now: now))
    }

    func testFutureSampleAndClockRollbackCannotTriggerRecovery() {
        XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: start.addingTimeInterval(181),
            lastRequestStartedAt: start, now: start.addingTimeInterval(180)))
        XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: start.addingTimeInterval(-1),
            lastRequestStartedAt: start, now: start.addingTimeInterval(-2)))
    }

    func testOneRecoveredSampleCannotRepeatedlyBypassBackoff() {
        let observed = start.addingTimeInterval(179), recheck = start.addingTimeInterval(180)
        XCTAssertTrue(ClaudeCacheRecovery.shouldRecheck(observedAt: observed,
            lastRequestStartedAt: start, now: recheck))
        XCTAssertFalse(ClaudeCacheRecovery.shouldRecheck(observedAt: observed,
            lastRequestStartedAt: recheck, now: recheck.addingTimeInterval(61)))
    }

    func testRecoverySignalDoesNotMakeCachedOrExpiredUsageCurrent() {
        let now = start.addingTimeInterval(180)
        var cached = UsageSnapshot(session: UsageWindow(used: 100, resetsAt: now.addingTimeInterval(-1)),
            observedAt: now.addingTimeInterval(-1))
        cached.source = .cached
        XCTAssertTrue(ClaudeCacheRecovery.shouldRecheck(observedAt: cached.observedAt,
            lastRequestStartedAt: start, now: now))
        XCTAssertFalse(cached.isCurrent(at: now, maximumAge: 120, hasConnectionError: false))
        XCTAssertNil(cached.session?.currentRemaining(at: now))
    }
}
