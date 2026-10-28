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

    func testInvalidNumericFieldsAndDatesAreRejected() {
        XCTAssertFalse(DiagnosticEvent(area: .claude, kind: .readFailed, durationMS: -1).isValid)
        XCTAssertFalse(DiagnosticEvent(area: .claude, kind: .readFailed, failureCount: 6).isValid)
        XCTAssertFalse(DiagnosticEvent(area: .app, kind: .started, build: -1).isValid)
        XCTAssertFalse(DiagnosticEvent(area: .claude, kind: .readFailed,
            nextAttemptAt: Date(timeIntervalSince1970: .infinity)).isValid)
    }
}
