import XCTest
import Darwin
import QuotaCore
@testable import QuotaBar

final class ClaudePollStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_800_000)

    private func withStore(_ body: (ClaudePollStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ClaudePollStore(directory: directory), directory)
    }

    private func lease(_ acquisition: ClaudePollAcquisition, file: StaticString = #filePath,
                       line: UInt = #line) throws -> ClaudePollLease {
        guard case .ready(let lease) = acquisition else {
            XCTFail("Expected a request reservation", file: file, line: line)
            throw ClaudePollStore.StoreError.invalidState
        }
        return lease
    }

    func testReservationSurvivesAppRestartAndBlocksAnotherCopy() throws {
        try withStore { store, directory in
            let first = try lease(store.reserve(at: start))
            XCTAssertEqual(first.failureCount, 1)
            XCTAssertEqual(first.nextRequestAt, start.addingTimeInterval(300))
            let restarted = ClaudePollStore(directory: directory)
            guard case .deferred(let state) = try restarted.reserve(at: start.addingTimeInterval(90.5)) else {
                return XCTFail("A restart must not bypass an unfinished request's cooldown")
            }
            XCTAssertEqual(state, first.state)
        }
    }

    func testFailuresBackOffImmediatelyAndPersistTheEscalation() throws {
        try withStore { store, directory in
            var now = start
            for delay in [300.0, 600, 1_200, 2_400, 3_600, 3_600] {
                let reserved = try lease(store.reserve(at: now))
                XCTAssertEqual(reserved.nextRequestAt, now.addingTimeInterval(delay))
                let finished = now.addingTimeInterval(2)
                let failed = try store.complete(reserved, outcome: .failure, at: finished)
                XCTAssertEqual(failed.nextRequestAt, finished.addingTimeInterval(delay))
                let restarted = ClaudePollStore(directory: directory)
                guard case .deferred(let saved) = try restarted.reserve(at: failed.nextRequestAt.addingTimeInterval(-0.01)) else {
                    return XCTFail("No request may run before the persisted deadline")
                }
                XCTAssertEqual(saved, failed)
                now = failed.nextRequestAt
            }
        }
    }

    func testSuccessRestoresNormalCadenceAndResetsFailureStreak() throws {
        try withStore { store, _ in
            let first = try lease(store.reserve(at: start))
            let failure = try store.complete(first, outcome: .failure, at: start.addingTimeInterval(1))
            let second = try lease(store.reserve(at: failure.nextRequestAt))
            let observed = second.startedAt.addingTimeInterval(1)
            let success = try store.complete(second, outcome: .success(observedAt: observed), at: observed)
            XCTAssertEqual(success.failureCount, 0)
            XCTAssertFalse(success.pending)
            XCTAssertEqual(success.nextRequestAt, observed.addingTimeInterval(90.5))
            guard case .deferred = try store.reserve(at: success.nextRequestAt.addingTimeInterval(-0.01)) else {
                return XCTFail("An early timer must not start another helper")
            }
            let next = try lease(store.reserve(at: success.nextRequestAt))
            XCTAssertEqual(next.failureCount, 1)
            XCTAssertEqual(next.nextRequestAt, next.startedAt.addingTimeInterval(300))
        }
    }

    func testCacheShortcutDoesNotShortenSpacingBetweenRequests() throws {
        try withStore { store, _ in
            let request = try lease(store.reserve(at: start))
            let success = try store.complete(request,
                outcome: .success(observedAt: start.addingTimeInterval(-10)), at: start.addingTimeInterval(1))
            XCTAssertEqual(success.nextRequestAt, start.addingTimeInterval(90.5))
        }
    }

    func testDelayedCompletionCannotOverwriteNewerReservation() throws {
        try withStore { store, _ in
            let abandoned = try lease(store.reserve(at: start))
            let newer = try lease(store.reserve(at: abandoned.nextRequestAt))
            let result = try store.complete(abandoned, outcome: .success(observedAt: start),
                                            at: newer.startedAt.addingTimeInterval(1))
            XCTAssertEqual(result, newer.state)
        }
    }

    func testDuplicateCompletionCannotTurnFailureIntoSuccess() throws {
        try withStore { store, _ in
            let request = try lease(store.reserve(at: start))
            let failed = try store.complete(request, outcome: .failure, at: start.addingTimeInterval(1))
            let duplicate = try store.complete(request, outcome: .success(observedAt: start),
                                               at: start.addingTimeInterval(2))
            XCTAssertEqual(duplicate, failed)
        }
    }

    func testClockRollbackCannotBypassPersistedCooldown() throws {
        try withStore { store, _ in
            let request = try lease(store.reserve(at: start))
            guard case .deferred(let saved) = try store.reserve(at: start.addingTimeInterval(-3_600)) else {
                return XCTFail("A clock rollback must not clear the reservation")
            }
            XCTAssertEqual(saved, request.state)
        }
    }

    func testCompletionBeforeRequestStartCannotReleaseReservation() throws {
        try withStore { store, _ in
            let request = try lease(store.reserve(at: start))
            let rollback = start.addingTimeInterval(-1)
            XCTAssertThrowsError(try store.complete(request, outcome: .success(observedAt: rollback), at: rollback))
            XCTAssertThrowsError(try store.complete(request, outcome: .failure, at: rollback))
            guard case .deferred(let saved) = try store.reserve(at: start.addingTimeInterval(90.5)) else {
                return XCTFail("A clock rollback must leave the reservation intact")
            }
            XCTAssertEqual(saved, request.state)
        }
    }

    func testCorruptStateFailsClosedWithoutReplacingIt() throws {
        try withStore { store, directory in
            _ = try store.reserve(at: start)
            let file = directory.appendingPathComponent("claude-poll-state.json")
            let corrupt = Data("invalid synthetic state".utf8)
            try corrupt.write(to: file)
            XCTAssertThrowsError(try store.reserve(at: start.addingTimeInterval(10_000)))
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
        }
    }

    func testNonblockingLockFailsClosed() throws {
        try withStore { store, directory in
            _ = try store.reserve(at: start)
            let fd = Darwin.open(directory.appendingPathComponent("claude-poll-state.lock").path, O_RDWR)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { Darwin.close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            defer { flock(fd, LOCK_UN) }
            XCTAssertThrowsError(try store.reserve(at: start.addingTimeInterval(1_000))) { error in
                guard case ClaudePollStore.StoreError.busy = error else { return XCTFail("Expected a busy lock") }
            }
        }
    }

    func testStateAndLockArePrivateAndContainOnlySchedulingMetadata() throws {
        try withStore { store, directory in
            _ = try store.reserve(at: start)
            let file = directory.appendingPathComponent("claude-poll-state.json")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["version", "requestID", "startedAt", "nextRequestAt", "failureCount", "pending"]))
            for (url, expected) in [(directory, 0o700), (file, 0o600),
                                    (directory.appendingPathComponent("claude-poll-state.lock"), 0o600)] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected)
            }
        }
    }

    func testStateSymlinkIsRejectedWithoutTouchingTarget() throws {
        try withStore { store, directory in
            _ = try store.reserve(at: start)
            let file = directory.appendingPathComponent("claude-poll-state.json")
            let target = directory.appendingPathComponent("synthetic-target.json")
            let original = try Data(contentsOf: file)
            try original.write(to: target)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            XCTAssertThrowsError(try store.reserve(at: start.addingTimeInterval(1_000)))
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testFutureObservationCannotReleaseReservation() throws {
        try withStore { store, _ in
            let request = try lease(store.reserve(at: start))
            XCTAssertThrowsError(try store.complete(request,
                outcome: .success(observedAt: start.addingTimeInterval(1)), at: start))
            guard case .deferred(let saved) = try store.reserve(at: start.addingTimeInterval(90.5)) else {
                return XCTFail("Invalid success must leave the conservative reservation intact")
            }
            XCTAssertEqual(saved, request.state)
        }
    }
}
