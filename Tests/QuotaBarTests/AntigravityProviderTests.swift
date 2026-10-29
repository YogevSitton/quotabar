import XCTest
@testable import QuotaBar

/// Synthetic output only. No helper is launched and no provider is called.
final class AntigravityProviderTests: XCTestCase {
    private let report = #"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini","buckets":[]}]}}}"#

    private func extract(_ text: String) -> String? {
        AntigravityProvider.finalJSONObject(in: Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testSignInPreambleBeforeSingleLineReport() {
        XCTAssertEqual(extract("Synthetic sign-in notice\n{\"synthetic\":true}\n\(report)\n\n"), report)
        XCTAssertEqual(extract(report), report)
    }

    func testSignInPreambleBeforePrettyPrintedReport() throws {
        let object = try JSONSerialization.jsonObject(with: Data(report.utf8))
        let pretty = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]), as: UTF8.self)
        let extracted = try XCTUnwrap(extract("Synthetic sign-in notice\r\n\(pretty)\t\n"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(extracted.utf8)) as? NSDictionary, object as? NSDictionary)
    }

    func testMissingOrTrailingTextIsNotAReport() {
        XCTAssertNil(extract(""))
        XCTAssertNil(extract("Synthetic sign-in notice\n"))
        XCTAssertNil(extract("\(report)\nSynthetic trailing notice\n"))
        XCTAssertNil(extract("  {\"indented\":true}"))
    }
}
