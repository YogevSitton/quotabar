import XCTest
@testable import QuotaCore

final class DiagnosticEventTests: XCTestCase {
    func testVersionsCannotCarryArbitraryTextOrExtraLines() {
        for version in ["2.1.310", "0.4.0", "51"] { XCTAssertTrue(DiagnosticEvent.isVersion(version)) }
        for version in ["", "1..2", "1.2.3\n", "1.2.3\nprivate-value", "private-value", "1.2.3-beta", "１.２"] {
            XCTAssertFalse(DiagnosticEvent.isVersion(version))
            XCTAssertFalse(DiagnosticEvent(area: .claude, kind: .helperReady, version: version).isValid)
        }
    }

    func testClosedSchemaDropsUnknownFieldsFromExport() throws {
        let event = DiagnosticEvent(area: .claude, kind: .sampleRejected, reason: .reusedSampleExpired,
            date: Date(timeIntervalSince1970: 1_792_800_000), sampleAgeSeconds: 61)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        object["rawReply"] = "private-value"
        object["accountID"] = "private-value"
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, event)
        XCTAssertFalse(decoded.line.contains("private-value"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("private-value"))
        object["reason"] = "private-value"
        XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testDurationIsClampedToTheValidRange() {
        let start = Date(timeIntervalSince1970: 1_792_800_000)
        XCTAssertEqual(DiagnosticEvent.durationMS(from: start, to: start.addingTimeInterval(1.5)), 1_500)
        XCTAssertEqual(DiagnosticEvent.durationMS(from: start, to: start.addingTimeInterval(-1)), 0)
        XCTAssertEqual(DiagnosticEvent.durationMS(from: start, to: start.addingTimeInterval(7_200)), 3_600_000)
    }

    func testInvalidNumericFieldsAndDatesAreRejected() {
        XCTAssertFalse(DiagnosticEvent(area: .claude, kind: .readFailed, durationMS: -1).isValid)
        XCTAssertTrue(DiagnosticEvent(area: .antigravity, kind: .readFailed, failureCount: 10).isValid)
        XCTAssertFalse(DiagnosticEvent(area: .antigravity, kind: .readFailed, failureCount: 11).isValid)
        XCTAssertTrue(DiagnosticEvent(area: .antigravity, kind: .readFailed, exitStatus: 255).isValid)
        for status in [-1, 256] {
            XCTAssertFalse(DiagnosticEvent(area: .antigravity, kind: .readFailed, exitStatus: status).isValid)
        }
        XCTAssertFalse(DiagnosticEvent(area: .app, kind: .started, build: -1).isValid)
        XCTAssertFalse(DiagnosticEvent(area: .claude, kind: .readFailed,
            nextAttemptAt: Date(timeIntervalSince1970: .infinity)).isValid)
    }

    func testAntigravityFieldsUseFixedCategories() throws {
        let event = DiagnosticEvent(area: .antigravity, kind: .readFailed, reason: .exitedWithError, phase: .usage,
            date: Date(timeIntervalSince1970: 1_792_800_000), durationMS: 1_200, failureCount: 1,
            signInAllowed: true, exitStatus: 1, authenticationNotice: true, report: .missing)
        XCTAssertEqual(event.line, "2026-10-24T00:00:00Z antigravity readFailed reason=exitedWithError phase=usage "
            + "durationMs=1200 failureCount=1 signInAllowed=true exitStatus=1 authenticationNotice=true report=missing")
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)), event)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        object["report"] = "private-value"
        XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
