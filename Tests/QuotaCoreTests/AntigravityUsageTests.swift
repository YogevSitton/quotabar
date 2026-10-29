import XCTest
@testable import QuotaCore

final class AntigravityUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_232_000)

    private func report(_ groups: [[String: Any]], changes: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = ["status": "SUCCESS", "num_turns": 0,
            "command": ["name": "usage", "data": ["groups": groups]]]
        root.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func group(_ name: String = "Gemini", buckets: [[String: Any]]) -> [String: Any] {
        ["name": name, "buckets": buckets]
    }

    func testIndependentGroupsAndExplicitWindowText() throws {
        let groups = [
            group(buckets: [
                ["id": "primary", "name": "Short usage", "window": "5h", "remaining_fraction": 0.29],
                ["id": "long", "name": "Long usage", "window": "weekly", "remaining_fraction": 0.8]
            ]),
            group("Gemini 4 Argon", buckets: [
                ["id": "argon", "name": "Argon usage", "window": "7 days", "remaining_fraction": 0.4]
            ])
        ]
        let snapshot = try UsageParser.antigravity(report(groups), observedAt: now)
        XCTAssertNil(snapshot.selectedGroup(named: nil))
        XCTAssertEqual(snapshot.selectedGroup(named: "Gemini")?.session?.remaining, 29)
        XCTAssertEqual(snapshot.selectedGroup(named: "Gemini")?.weekly?.remaining, 80)
        let argon = try XCTUnwrap(snapshot.selectedGroup(named: "Gemini 4 Argon"))
        XCTAssertNil(argon.session)
        XCTAssertEqual(argon.weekly?.remaining, 40)
        XCTAssertNil(snapshot.selectedGroup(named: "Removed group"))
        XCTAssertEqual(snapshot.observedAt, now)
    }

    func testUnknownWindowAndModelLikeIDsArePreservedWithoutInventedClassification() throws {
        let snapshot = try UsageParser.antigravity(report([group(buckets: [
            ["id": "gemini-4-argon-weekly", "name": "Weekly model", "window": "adaptive",
             "remaining_fraction": 0.5, "reset_time": "2026-11-04T00:00:00Z"]
        ])]), observedAt: now)
        let selected = try XCTUnwrap(snapshot.selectedGroup(named: nil))
        let bucket = try XCTUnwrap(selected.buckets.first)
        XCTAssertEqual(bucket.window, "adaptive")
        XCTAssertEqual(bucket.reportedID, "gemini-4-argon-weekly")
        XCTAssertEqual(bucket.usageWindow?.remaining, 50)
        XCTAssertNil(bucket.windowKind)
        XCTAssertNil(selected.session)
        XCTAssertNil(selected.weekly)
    }

    func testMissingMalformedAndDisabledFractionsNeverBecomeFullQuota() throws {
        let invalid: [Any] = [NSNull(), true, "0.8", -0.1, 1.1]
        var buckets = invalid.enumerated().map { index, value in
            ["name": "Invalid \(index)", "remaining_fraction": value] as [String: Any]
        }
        buckets += [
            ["name": "Missing"],
            ["name": "Count only", "remaining_amount": 7],
            ["name": "Disabled", "disabled": true, "remaining_fraction": 1],
            ["name": "Empty", "remaining_fraction": 0],
            ["name": "Full", "remaining_fraction": 1]
        ]
        let snapshot = try UsageParser.antigravity(report([group(buckets: buckets)]), observedAt: now)
        let parsed = snapshot.groups[0].buckets
        for bucket in parsed.prefix(8) { XCTAssertNil(bucket.usageWindow, bucket.name) }
        XCTAssertEqual(parsed[6].remainingAmount, 7)
        XCTAssertEqual(parsed[8].usageWindow?.remaining, 0)
        XCTAssertEqual(parsed[9].usageWindow?.remaining, 100)
    }

    func testCountValidationPreservesUnknownAndExactIntegerBounds() throws {
        let values: [Any] = [true, -1, 1.5, "2", NSNull(), Int.max, 0]
        let buckets = values.enumerated().map { index, value in
            ["name": "Bucket \(index)", "remaining_amount": value] as [String: Any]
        }
        let snapshot = try UsageParser.antigravity(report([group(buckets: buckets)]), observedAt: now)
        let parsed = snapshot.groups[0].buckets
        for bucket in parsed.prefix(5) { XCTAssertNil(bucket.remainingAmount) }
        XCTAssertEqual(parsed[5].remainingAmount, Int.max)
        XCTAssertEqual(parsed[6].remainingAmount, 0)
        XCTAssertTrue(parsed.allSatisfy { $0.usageWindow == nil })
    }

    func testRejectsOtherCommandsModelTurnsAndFailedEnvelopes() throws {
        let groups = [group(buckets: [["name": "Quota", "remaining_fraction": 0.5]])]
        let changes: [[String: Any]] = [
            ["status": "ERROR"], ["status": "success"],
            ["num_turns": true], ["num_turns": "0"], ["num_turns": 1], ["num_turns": -1], ["num_turns": NSNull()],
            ["command": ["name": "model", "data": ["groups": groups]]],
            ["command": ["name": "/usage", "data": ["groups": groups]]],
            ["error": "Synthetic failure"], ["error": ["message": "Synthetic failure"]]
        ]
        for change in changes {
            XCTAssertThrowsError(try UsageParser.antigravity(report(groups, changes: change), observedAt: now))
        }
        XCTAssertThrowsError(try UsageParser.antigravity(Data("{}".utf8), observedAt: now))
        XCTAssertThrowsError(try UsageParser.antigravity(report([]), observedAt: now))
    }

    func testAbsentEmptyAndNullErrorFieldsAreSuccessfulEnvelopes() throws {
        let groups = [group(buckets: [["name": "Quota", "remaining_fraction": 0.5]])]
        for change in [[:], ["error": ""], ["error": NSNull()]] as [[String: Any]] {
            XCTAssertEqual(try UsageParser.antigravity(report(groups, changes: change), observedAt: now).groups.count, 1)
        }
    }

    func testAmbiguousGroupsAndBucketIDsFailInsteadOfSilentlySelecting() throws {
        let first = group("Same", buckets: [["name": "Quota", "remaining_fraction": 0.5]])
        XCTAssertThrowsError(try UsageParser.antigravity(report([first, first]), observedAt: now))
        let duplicateIDs = group(buckets: [
            ["id": "same", "name": "One", "remaining_fraction": 0.5],
            ["id": "same", "name": "Two", "remaining_fraction": 0.8]
        ])
        XCTAssertThrowsError(try UsageParser.antigravity(report([duplicateIDs]), observedAt: now))
        let duplicateWindows = group(buckets: [
            ["name": "One", "window": "weekly", "remaining_fraction": 0.5],
            ["name": "Two", "window": "7d", "disabled": true]
        ])
        let snapshot = try UsageParser.antigravity(report([duplicateWindows]), observedAt: now)
        XCTAssertNil(snapshot.groups[0].weekly)
        XCTAssertEqual(Set(snapshot.groups[0].buckets.map(\.id)).count, 2)
    }

    func testMalformedDisabledFlagAndMissingBucketNameFailClosed() throws {
        let buckets: [[String: Any]] = [
            ["name": "Quota", "disabled": "false", "remaining_fraction": 1],
            ["name": "Quota", "disabled": NSNull(), "remaining_fraction": 1],
            ["remaining_fraction": 1]
        ]
        for bucket in buckets {
            XCTAssertThrowsError(try UsageParser.antigravity(report([group(buckets: [bucket])]), observedAt: now))
        }
    }

    func testOriginalRequestAgeFailuresAndResetExpirySuppressCurrentValues() throws {
        let resetsAt = now.addingTimeInterval(60)
        let bucket = AntigravityQuotaBucket(id: "quota", name: "Quota", window: "5 hours",
            remainingFraction: 0, resetsAt: resetsAt)
        var snapshot = AntigravitySnapshot(groups: [AntigravityQuotaGroup(name: "Gemini", buckets: [bucket])], observedAt: now)
        XCTAssertTrue(snapshot.isCurrent(at: now, maximumAge: 300, hasConnectionError: false))
        XCTAssertFalse(snapshot.isCurrent(at: now.addingTimeInterval(300), maximumAge: 300, hasConnectionError: false))
        XCTAssertFalse(snapshot.isCurrent(at: now, maximumAge: 300, hasConnectionError: true))
        XCTAssertFalse(snapshot.isCurrent(at: now.addingTimeInterval(-1), maximumAge: 300, hasConnectionError: false))
        let window = try XCTUnwrap(bucket.usageWindow)
        XCTAssertEqual(UsageLimit.limited(window).current(at: resetsAt.addingTimeInterval(-1)), .limited(window))
        XCTAssertEqual(UsageLimit.limited(window).current(at: resetsAt), .unavailable)
        XCTAssertEqual(bucket.usageWindow?.remaining, 0) // Historical values are retained.
        snapshot.source = .cached
        XCTAssertFalse(snapshot.isCurrent(at: now, maximumAge: 300, hasConnectionError: false))
    }

    func testResetDateParsingAndUnknownDates() throws {
        let snapshot = try UsageParser.antigravity(report([group(buckets: [
            ["name": "Valid", "remaining_fraction": 0.5, "reset_time": "2026-11-04T00:00:00.123Z"],
            ["name": "Invalid", "remaining_fraction": 0.5, "reset_time": "later"],
            ["name": "Missing", "remaining_fraction": 0.5]
        ])]), observedAt: now)
        XCTAssertNotNil(snapshot.groups[0].buckets[0].resetsAt)
        XCTAssertNil(snapshot.groups[0].buckets[1].resetsAt)
        XCTAssertNil(snapshot.groups[0].buckets[2].resetsAt)
    }
}
