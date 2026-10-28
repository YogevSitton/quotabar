import XCTest
import Darwin
import QuotaCore
@testable import QuotaBar

final class DiagnosticLogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)
    private func withLog(_ body: (DiagnosticLog, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(DiagnosticLog(directory: directory), directory)
    }

    func testHistorySurvivesRestartWithPrivatePermissionsAndClearLeavesPollingUntouched() throws {
        try withLog { log, directory in
            let event = DiagnosticEvent(area: .claude, kind: .readFailed, reason: .helperTimeout, date: now)
            log.record(event)
            let file = directory.appendingPathComponent("diagnostic-events.json")
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
            let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(folderMode?.intValue, 0o700)
            let restarted = DiagnosticLog(directory: directory)
            XCTAssertEqual(try restarted.events(at: now), [event])
            let poll = directory.appendingPathComponent("claude-poll-state.json")
            let marker = Data("synthetic-poll-state".utf8)
            try marker.write(to: poll)
            try restarted.clear()
            XCTAssertEqual(try log.events(at: now), [])
            XCTAssertEqual(try Data(contentsOf: poll), marker)
        }
    }

    func testCountAgeAndFileSizeStayBounded() throws {
        try withLog { log, directory in
            log.record(DiagnosticEvent(area: .app, kind: .started, date: now.addingTimeInterval(-DiagnosticLog.retention)))
            for index in 0..<(DiagnosticLog.maximumEvents + 5) {
                log.record(DiagnosticEvent(area: .claude, kind: .readStarted,
                    date: now.addingTimeInterval(Double(index))))
            }
            let events = try log.events(at: now.addingTimeInterval(1_000))
            XCTAssertEqual(events.count, DiagnosticLog.maximumEvents)
            XCTAssertEqual(events.first?.date, now.addingTimeInterval(5))
            let data = try Data(contentsOf: directory.appendingPathComponent("diagnostic-events.json"))
            XCTAssertLessThanOrEqual(data.count, DiagnosticLog.maximumBytes)
            XCTAssertEqual(try log.events(at: now.addingTimeInterval(DiagnosticLog.retention + 1_000)), [])
        }
    }

    func testInvalidEventsAndCorruptFileCannotEnterExport() throws {
        try withLog { log, directory in
            log.record(DiagnosticEvent(area: .claude, kind: .helperReady, date: now, version: "private-value"))
            XCTAssertEqual(try log.events(at: now), [])
            let file = directory.appendingPathComponent("diagnostic-events.json")
            try Data(repeating: 65, count: DiagnosticLog.maximumBytes + 1).write(to: file)
            XCTAssertThrowsError(try log.events(at: now))
            let event = DiagnosticEvent(area: .app, kind: .started, date: now)
            log.record(event)
            XCTAssertEqual(try log.events(at: now), [event])
        }
    }

    func testDelayedEventOrClockRollbackDoesNotEraseNewerHistory() throws {
        try withLog { log, _ in
            let newer = DiagnosticEvent(area: .app, kind: .started, date: now.addingTimeInterval(1))
            let delayed = DiagnosticEvent(area: .app, kind: .woke, date: now)
            log.record(newer)
            log.record(delayed)
            XCTAssertEqual(try log.events(at: now), [newer, delayed])
        }
    }

    func testSymbolicLinkCannotExposeOrModifyItsTarget() throws {
        try withLog { log, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("synthetic-private-file")
            let marker = Data("synthetic-private-content".utf8)
            try marker.write(to: target)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("diagnostic-events.json"),
                                                       withDestinationURL: target)
            XCTAssertThrowsError(try log.events(at: now))
            log.record(DiagnosticEvent(area: .app, kind: .started, date: now))
            XCTAssertEqual(try Data(contentsOf: target), marker)
        }
    }

    func testBusyLogNeverBlocksProviderAndRetainsEarlierEvents() throws {
        try withLog { log, directory in
            let event = DiagnosticEvent(area: .app, kind: .started, date: now)
            log.record(event)
            let fd = Darwin.open(directory.appendingPathComponent("diagnostic-events.lock").path, O_RDWR)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { Darwin.close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            log.record(DiagnosticEvent(area: .app, kind: .woke, date: now))
            XCTAssertThrowsError(try log.events(at: now))
            XCTAssertEqual(flock(fd, LOCK_UN), 0)
            XCTAssertEqual(try log.events(at: now), [event])
        }
    }
}
