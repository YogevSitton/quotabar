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

    func testDownloadRateLimitBlocksManualAndAutomaticRequestsUntilItsDeadline() {
        var retry = UpdateRetryState()
        XCTAssertTrue(retry.allowsRequest(at: now))
        // An archive answered 429 with Retry-After 7200.
        let failure = UpdateFetchFailure.classify(status: 429, headers: ["Retry-After": "7200"], now: now)!
        XCTAssertEqual(retry.record(failure, now: now, random: 0), 7_200)
        XCTAssertFalse(retry.allowsRequest(at: now.addingTimeInterval(3_600)))
        XCTAssertFalse(retry.allowsRequest(at: now.addingTimeInterval(7_199)))
        XCTAssertTrue(retry.allowsRequest(at: now.addingTimeInterval(7_200)))
        // A shorter later wait never shortens an existing deadline.
        _ = retry.record(.rateLimited(until: now.addingTimeInterval(60)), now: now, random: 0)
        XCTAssertEqual(retry.rateLimitedUntil, now.addingTimeInterval(7_200))
        retry.recordSuccess()
        XCTAssertNil(retry.rateLimitedUntil)
        XCTAssertTrue(retry.allowsRequest(at: now))
    }

    func testTransientDownloadFailuresKeepTheBackoffProgressionUntilACycleSucceeds() {
        var retry = UpdateRetryState()
        let delays = (0..<5).map { _ in retry.record(.transient, now: now, random: 0) }
        XCTAssertEqual(delays, [300, 900, 1_800, 3_600, 3_600])
        XCTAssertEqual(retry.transientAttempts, 5)
        XCTAssertEqual(retry.record(.unavailable, now: now, random: 0), 3_300)
        XCTAssertEqual(retry.transientAttempts, 5)
        retry.recordSuccess()
        XCTAssertEqual(retry.record(.transient, now: now, random: 0), 300)
    }

    func testSameBuildConflictIsRejectedAcrossChannelsAfterSwitching() throws {
        // Preview build 50 (commit A, hash A) was seen; the Mac then switched to Stable.
        let seenPreview = try UpdateManifestTests.preview(build: 50)
        let saved = UpdateHighWater().recording(seenPreview)
        XCTAssertNil(saved.stable)
        // Stable alone is fetched and offers build 50 with different contents.
        let other = try UpdateManifest(channel: .stable, build: 50, displayVersion: "0.2.0", commit: String(repeating: "b", count: 40),
                                       archiveBytes: 1_003_448, sha256: String(repeating: "c", count: 64),
                                       publicKey: key, releaseNotes: "Notes")
        XCTAssertEqual(UpdateSelection.select(channel: .stable, stable: .verified(other), preview: .absent),
                       .candidate(other, invalidFeeds: []))
        XCTAssertTrue(saved.conflicts(with: other))
        XCTAssertEqual(UpdateDecision.evaluate(other, publicKey: key, installedBuild: 30, highWater: saved), .conflictingIdentity)
        // Promoting the same bytes to Stable is not a conflict.
        let promoted = try seenPreview.promotedToStable(releaseNotes: "Notes")
        XCTAssertFalse(saved.conflicts(with: promoted))
        XCTAssertEqual(UpdateDecision.evaluate(promoted, publicKey: key, installedBuild: 30, highWater: saved), .newer(promoted))
        // The reverse direction: a saved Stable identity also guards Preview.
        let stableSaved = UpdateHighWater().recording(promoted)
        let previewOther = try UpdateManifestTests.preview(build: 50, sha256: String(repeating: "d", count: 64))
        XCTAssertEqual(UpdateDecision.evaluate(previewOther, publicKey: key, installedBuild: 30, highWater: stableSaved), .conflictingIdentity)
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
