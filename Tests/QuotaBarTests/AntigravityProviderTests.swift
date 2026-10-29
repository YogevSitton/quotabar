import XCTest
@testable import QuotaBar

/// Synthetic output only. No helper is launched and no provider is called.
final class AntigravityProviderTests: XCTestCase {
    private let report = #"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini","buckets":[]}]}}}"#
    private let start = Date(timeIntervalSince1970: 1_792_800_000)

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

    func testSuccessfulExplicitExitIgnoresSignInPreamble() {
        let response = AntigravityProcess.Result(stdout: Data(report.utf8),
            stderr: Data("Authentication required. Synthetic sign-in notice.\n".utf8), exitCode: 0)
        XCTAssertNoThrow(try AntigravityProvider.validateExit(response, explicit: true))
    }

    func testExplicitPreambleThenQuotaFailureRetainsAutomaticRetry() {
        let response = AntigravityProcess.Result(stdout: Data(),
            stderr: Data("Authentication required. Synthetic sign-in notice.\nQuota fetch failed.\n".utf8), exitCode: 1)
        var budget = AntigravityProvider.Budget(nextRequestAt: .distantPast, failures: 0, needsSignIn: false)
        budget.reserve(at: start)
        let completed = start.addingTimeInterval(20)
        XCTAssertThrowsError(try AntigravityProvider.validateExit(response, explicit: true)) { error in
            guard case .failure(_, .usageUnavailable, let next) = budget.recordFailure(error, explicit: true, at: completed) else {
                return XCTFail("A sign-in preamble must not turn a later quota failure into a sign-in requirement")
            }
            XCTAssertFalse(budget.needsSignIn)
            XCTAssertEqual(next, completed.addingTimeInterval(300))
            guard case .deferred(let deadline) = budget.preflight(explicit: false, at: completed) else {
                return XCTFail("Monitoring must retain the retry deadline")
            }
            XCTAssertEqual(deadline, next)
            XCTAssertNil(budget.preflight(explicit: false, at: budget.nextRequestAt))
        }
    }

    func testAmbiguousConnectInterruptionsPreserveBackoffAcrossRestarts() throws {
        for error in [AntigravityProcess.ProcessError.cancelled, .timedOut] {
            var budget = AntigravityProvider.Budget(nextRequestAt: .distantPast, failures: 0, needsSignIn: false)
            var now = start
            for wait in [300.0, 600, 1_200, 2_400, 3_600, 3_600] {
                XCTAssertNil(budget.preflight(explicit: true, at: now))
                budget.reserve(at: now)
                XCTAssertFalse(budget.needsSignIn)
                let completed = now.addingTimeInterval(20)
                let expected = completed.addingTimeInterval(wait)
                guard case .failure(_, .signInRequired, let next) = budget.recordFailure(error, explicit: true, at: completed) else {
                    return XCTFail("An interrupted Connect must retain its connection action and request deadline")
                }
                XCTAssertEqual(next, expected)
                budget = try JSONDecoder().decode(AntigravityProvider.Budget.self, from: JSONEncoder().encode(budget))
                for explicit in [false, true] {
                    guard case .failure(_, .signInRequired, let saved) = budget.preflight(explicit: explicit, at: expected.addingTimeInterval(-0.01)) else {
                        return XCTFail("Neither monitoring nor Connect may bypass an ambiguous attempt's deadline")
                    }
                    XCTAssertEqual(saved, expected)
                }
                guard case .failure(_, .signInRequired, nil) = budget.preflight(explicit: false, at: expected) else {
                    return XCTFail("Background monitoring must not resume an interrupted sign-in")
                }
                XCTAssertNil(budget.preflight(explicit: true, at: expected))
                now = expected
            }
        }
    }

    func testLegacySignInFlagCannotWaiveSavedDeadline() throws {
        let data = Data(#"{"version":1,"nextRequestAt":800000000,"failures":2,"needsSignIn":true}"#.utf8)
        let budget = try JSONDecoder().decode(AntigravityProvider.Budget.self, from: data)
        let deadline = Date(timeIntervalSinceReferenceDate: 800_000_000)
        guard case .failure(_, .signInRequired, let next) = budget.preflight(explicit: true, at: deadline.addingTimeInterval(-1)) else {
            return XCTFail("Previously saved sign-in flags are not proof that no quota request began")
        }
        XCTAssertEqual(next, deadline)
        XCTAssertNil(budget.preflight(explicit: true, at: deadline))
    }

    func testConfirmedMonitoringAuthFailureAllowsImmediateExplicitConnectOnly() {
        let response = AntigravityProcess.Result(stdout: Data(),
            stderr: Data("Error: authentication required. Run the official login to sign in.\n".utf8), exitCode: 1)
        var budget = AntigravityProvider.Budget(nextRequestAt: .distantPast, failures: 0, needsSignIn: false)
        budget.reserve(at: start)
        XCTAssertThrowsError(try AntigravityProvider.validateExit(response, explicit: false)) { error in
            guard case .failure(_, .signInRequired, nil) = budget.recordFailure(error, explicit: false, at: start) else {
                return XCTFail("The non-interactive auth failure establishes that /usage was not reached")
            }
            XCTAssertEqual(budget.nextRequestAt, start)
            guard case .failure(_, .signInRequired, nil) = budget.preflight(explicit: false, at: start) else {
                return XCTFail("Only an explicit action can start sign-in")
            }
            XCTAssertNil(budget.preflight(explicit: true, at: start))
            budget.reserve(at: start)
            XCTAssertFalse(budget.needsSignIn)
            XCTAssertGreaterThan(budget.nextRequestAt, start)
        }
    }
}
