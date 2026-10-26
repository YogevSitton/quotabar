import XCTest
@testable import QuotaCore

/// Synthetic feeds and HTTP answers only; nothing here contacts GitHub.
final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)
    private let key = UpdateManifestTests.testKey

    private func stable(_ build: UInt64) throws -> UpdateManifest {
        try UpdateManifestTests.preview(build: build).promotedToStable(releaseNotes: "Notes")
    }

    func testClassifiesHTTPAnswersWithoutAskingForAuthentication() {
        XCTAssertNil(UpdateFetchFailure.classify(status: 200, headers: [:], now: now))
        XCTAssertEqual(UpdateFetchFailure.classify(status: 404, headers: [:], now: now), .unavailable)
        XCTAssertEqual(UpdateFetchFailure.classify(status: 401, headers: [:], now: now), .unavailable)
        XCTAssertEqual(UpdateFetchFailure.classify(status: 503, headers: [:], now: now), .transient)
        XCTAssertEqual(UpdateFetchFailure.classify(status: 301, headers: [:], now: now), .invalid)
        XCTAssertEqual(UpdateFetchFailure.classify(status: 429, headers: ["Retry-After": "120"], now: now),
                       .rateLimited(until: now.addingTimeInterval(120)))
        XCTAssertEqual(UpdateFetchFailure.classify(status: 403, headers: ["x-ratelimit-remaining": "0",
                       "X-RateLimit-Reset": String(Int(now.timeIntervalSince1970) + 900)], now: now),
                       .rateLimited(until: now.addingTimeInterval(900)))
        XCTAssertEqual(UpdateFetchFailure.classify(status: 429, headers: ["Retry-After": "5"], now: now),
                       .rateLimited(until: now.addingTimeInterval(60)))
        XCTAssertEqual(UpdateFetchFailure.classify(status: 429, headers: ["Retry-After": "999999"], now: now),
                       .rateLimited(until: now.addingTimeInterval(86_400)))
    }

    func testScheduleCadenceAndBackoff() {
        XCTAssertEqual(UpdateSchedule.firstCheckDelay(random: 0), 120)
        XCTAssertEqual(UpdateSchedule.firstCheckDelay(random: 1), 600)
        XCTAssertEqual(UpdateSchedule.regularDelay(random: 0), 3_300)
        XCTAssertEqual(UpdateSchedule.regularDelay(random: 1), 3_900)
        XCTAssertEqual(UpdateSchedule.transientDelay(attempt: 0, random: 0), 300)
        XCTAssertEqual(UpdateSchedule.transientDelay(attempt: 2, random: 0), 1_800)
        XCTAssertEqual(UpdateSchedule.transientDelay(attempt: 9, random: 0), 3_600)
        XCTAssertEqual(UpdateSchedule.delay(after: .rateLimited(until: now.addingTimeInterval(7_200)), attempt: 0, now: now, random: 0), 7_200)
        XCTAssertTrue(UpdateSchedule.shouldCheckAfterWake(lastAttempt: nil, now: now))
        XCTAssertFalse(UpdateSchedule.shouldCheckAfterWake(lastAttempt: now.addingTimeInterval(-1_800), now: now))
        XCTAssertTrue(UpdateSchedule.shouldCheckAfterWake(lastAttempt: now.addingTimeInterval(-3_700), now: now))
    }

    func testStableAbsentWithPreviewValid() throws {
        let preview = try UpdateManifestTests.preview(build: 42)
        XCTAssertEqual(UpdateSelection.select(channel: .preview, stable: .absent, preview: .verified(preview)),
                       .candidate(preview, invalidFeeds: []))
        XCTAssertEqual(UpdateSelection.select(channel: .stable, stable: .absent, preview: .verified(preview)),
                       .unavailable(invalidFeeds: []))
    }

    func testPreviewAbsentWithStableValid() throws {
        let stable = try stable(40)
        XCTAssertEqual(UpdateSelection.select(channel: .preview, stable: .verified(stable), preview: .absent),
                       .candidate(stable, invalidFeeds: []))
        XCTAssertEqual(UpdateSelection.select(channel: .stable, stable: .verified(stable), preview: .absent),
                       .candidate(stable, invalidFeeds: []))
    }

    func testBothAbsentAndInvalidFeeds() throws {
        XCTAssertEqual(UpdateSelection.select(channel: .preview, stable: .absent, preview: .absent), .unavailable(invalidFeeds: []))
        XCTAssertEqual(UpdateSelection.select(channel: .preview, stable: .invalid, preview: .absent), .unavailable(invalidFeeds: [.stable]))
        let preview = try UpdateManifestTests.preview(build: 43)
        // An invalid feed is reported and ignored; the other signed feed still counts.
        XCTAssertEqual(UpdateSelection.select(channel: .preview, stable: .invalid, preview: .verified(preview)),
                       .candidate(preview, invalidFeeds: [.stable]))
        XCTAssertEqual(UpdateSelection.select(channel: .stable, stable: .invalid, preview: .verified(preview)),
                       .unavailable(invalidFeeds: [.stable]))
    }

    func testPreviewChoosesTheHigherBuildAndRejectsConflicts() throws {
        let preview = try UpdateManifestTests.preview(build: 45), stable = try stable(44)
        XCTAssertEqual(UpdateSelection.select(channel: .preview, stable: .verified(stable), preview: .verified(preview)),
                       .candidate(preview, invalidFeeds: []))
        let conflicting = try UpdateManifestTests.preview(build: 44, sha256: String(repeating: "e", count: 64))
        XCTAssertEqual(UpdateSelection.select(channel: .preview, stable: .verified(stable), preview: .verified(conflicting)),
                       .conflictingIdentity)
        // A manifest served from the wrong feed is ignored.
        XCTAssertEqual(UpdateSelection.select(channel: .stable, stable: .verified(preview), preview: .absent),
                       .unavailable(invalidFeeds: []))
    }

    func testDecisionNeverDowngradesAfterSwitchingFromPreviewToStable() throws {
        // Installed Preview build 50; Stable is still at 44.
        XCTAssertEqual(UpdateDecision.evaluate(try stable(44), publicKey: key, installedBuild: 50, highWater: UpdateHighWater()), .upToDate)
        XCTAssertEqual(UpdateDecision.evaluate(try stable(51), publicKey: key, installedBuild: 50, highWater: UpdateHighWater()),
                       .newer(try stable(51)))
        let seen = UpdateHighWater().recording(try stable(52))
        XCTAssertEqual(seen.stable?.build, 52)
        XCTAssertEqual(seen.recording(try stable(51)), seen)
        XCTAssertEqual(UpdateDecision.evaluate(try stable(51), publicKey: key, installedBuild: 50, highWater: seen), .upToDate)
        let conflicting = try UpdateManifestTests.preview(build: 52, sha256: String(repeating: "f", count: 64)).promotedToStable(releaseNotes: "")
        XCTAssertEqual(UpdateDecision.evaluate(conflicting, publicKey: key, installedBuild: 50, highWater: seen), .conflictingIdentity)
    }
}
