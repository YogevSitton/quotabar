import XCTest
import QuotaCore
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

    func testFailedConnectExitOffersConnectWithoutDeclaringSignedOut() {
        // Either final line is ambiguous: the preamble must never be read as the error.
        for stderr in ["Authentication required. Synthetic sign-in notice.\nQuota fetch failed.\n",
                       "Synthetic notice.\nAuthentication required.\n"] {
            let response = AntigravityProcess.Result(stdout: Data(), stderr: Data(stderr.utf8), exitCode: 1)
            var budget = AntigravityProvider.Budget(nextRequestAt: .distantPast, failures: 0, needsSignIn: false)
            let previous = budget
            budget.reserve(at: start)
            let completed = start.addingTimeInterval(20)
            XCTAssertThrowsError(try AntigravityProvider.validateExit(response, explicit: true)) { error in
                guard case .failure(_, .connectionIncomplete, let next) = budget.recordFailure(error, explicit: true,
                        reservedFrom: previous, at: completed) else {
                    return XCTFail("A failed Connect must offer Connect again without declaring the user signed out")
                }
                XCTAssertFalse(budget.needsSignIn)
                XCTAssertEqual(budget.failures, 1)
                XCTAssertEqual(next, completed.addingTimeInterval(300))
                for explicit in [false, true] {
                    guard case .deferred(let deadline) = budget.preflight(explicit: explicit, at: completed) else {
                        return XCTFail("Neither monitoring nor Connect may bypass the failed attempt's deadline")
                    }
                    XCTAssertEqual(deadline, next)
                    // Monitoring resumes on its own at the deadline, alongside Connect.
                    XCTAssertNil(budget.preflight(explicit: explicit, at: budget.nextRequestAt))
                }
            }
        }
    }

    func testFailedReportAfterSignInOffersConnect() {
        var budget = AntigravityProvider.Budget(nextRequestAt: .distantPast, failures: 1, needsSignIn: false)
        let previous = budget
        budget.reserve(at: start)
        let failure = UsageError.message("Antigravity did not return subscription quota after sign-in.")
        guard case .failure(_, .connectionIncomplete, let next) = budget.recordFailure(failure, explicit: true,
                reservedFrom: previous, at: start) else {
            return XCTFail("A Connect without a usable report must keep its recovery action")
        }
        XCTAssertEqual(next, start.addingTimeInterval(600))
        XCTAssertEqual(budget.failures, 2)
    }

    func testMonitoringExitWithoutAuthenticationErrorKeepsAutomaticRetry() {
        let response = AntigravityProcess.Result(stdout: Data(),
            stderr: Data("Synthetic quota fetch failure.\n".utf8), exitCode: 1)
        var budget = AntigravityProvider.Budget(nextRequestAt: .distantPast, failures: 0, needsSignIn: false)
        let previous = budget
        budget.reserve(at: start)
        let completed = start.addingTimeInterval(20)
        XCTAssertThrowsError(try AntigravityProvider.validateExit(response, explicit: false)) { error in
            guard case .failure(_, .usageUnavailable, let next) = budget.recordFailure(error, explicit: false,
                    reservedFrom: previous, at: completed) else {
                return XCTFail("A monitoring quota failure is not a sign-in requirement")
            }
            XCTAssertFalse(budget.needsSignIn)
            XCTAssertEqual(next, completed.addingTimeInterval(300))
            guard case .deferred(let deadline) = budget.preflight(explicit: false, at: completed) else {
                return XCTFail("Monitoring must retain the retry deadline")
            }
            XCTAssertEqual(deadline, next)
            XCTAssertNil(budget.preflight(explicit: false, at: completed.addingTimeInterval(300)))
        }
    }

    func testConnectDuringNormalBackoffIsDeferred() {
        let deadline = start.addingTimeInterval(600)
        let budget = AntigravityProvider.Budget(nextRequestAt: deadline, failures: 2, needsSignIn: false)
        for explicit in [false, true] {
            guard case .deferred(let next) = budget.preflight(explicit: explicit, at: start) else {
                return XCTFail("Connect must not bypass a normal failure deadline")
            }
            XCTAssertEqual(next, deadline)
        }
    }

    func testCancellationBeforeLaunchKeepsTheUnchangedSchedule() {
        let signedOut = AntigravityProvider.Budget(nextRequestAt: start, failures: 2, needsSignIn: true)
        guard case .failure(_, .signInRequired, nil) = signedOut.cancelledBeforeLaunch(at: start) else {
            return XCTFail("A confirmed sign-in boundary stays in place, with Connect available")
        }
        let waiting = AntigravityProvider.Budget(nextRequestAt: start.addingTimeInterval(60), failures: 1, needsSignIn: false)
        guard case .failure(_, .connectionIncomplete, let next) = waiting.cancelledBeforeLaunch(at: start) else {
            return XCTFail("A pre-launch cancellation offers Connect without declaring the user signed out")
        }
        XCTAssertEqual(next, start.addingTimeInterval(60))
        guard case .failure(_, .connectionIncomplete, nil) = waiting.cancelledBeforeLaunch(at: start.addingTimeInterval(60)) else {
            return XCTFail("A passed deadline leaves Connect available immediately")
        }
    }

    func testAmbiguousConnectInterruptionsPreserveBackoffAcrossRestarts() throws {
        for error in [AntigravityProcess.ProcessError.cancelled, .timedOut] {
            var budget = AntigravityProvider.Budget(nextRequestAt: .distantPast, failures: 0, needsSignIn: false)
            var now = start
            for wait in [300.0, 600, 1_200, 2_400, 3_600, 3_600] {
                XCTAssertNil(budget.preflight(explicit: true, at: now))
                let previous = budget
                budget.reserve(at: now)
                XCTAssertFalse(budget.needsSignIn)
                let completed = now.addingTimeInterval(20)
                let expected = completed.addingTimeInterval(wait)
                guard case .failure(_, .signInRequired, let next) = budget.recordFailure(error, explicit: true,
                        reservedFrom: previous, at: completed) else {
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
        let previous = budget
        budget.reserve(at: start)
        XCTAssertThrowsError(try AntigravityProvider.validateExit(response, explicit: false)) { error in
            guard case .failure(_, .signInRequired, nil) = budget.recordFailure(error, explicit: false,
                    reservedFrom: previous, at: start) else {
                return XCTFail("The non-interactive auth failure establishes that /usage was not reached")
            }
            XCTAssertEqual(budget.nextRequestAt, start)
            XCTAssertEqual(budget.failures, 0)
            guard case .failure(_, .signInRequired, nil) = budget.preflight(explicit: false, at: start) else {
                return XCTFail("Only an explicit action can start sign-in")
            }
            XCTAssertNil(budget.preflight(explicit: true, at: start))
            budget.reserve(at: start)
            XCTAssertFalse(budget.needsSignIn)
            XCTAssertGreaterThan(budget.nextRequestAt, start)
        }
    }

    func testAuthenticationOnlyAttemptKeepsEarlierQuotaFailures() {
        let response = AntigravityProcess.Result(stdout: Data(),
            stderr: Data("Error: authentication required.\n".utf8), exitCode: 1)
        var budget = AntigravityProvider.Budget(nextRequestAt: start, failures: 2, needsSignIn: false)
        let previous = budget
        budget.reserve(at: start)
        XCTAssertEqual(budget.failures, 3)
        XCTAssertThrowsError(try AntigravityProvider.validateExit(response, explicit: false)) { error in
            _ = budget.recordFailure(error, explicit: false, reservedFrom: previous, at: start)
            XCTAssertEqual(budget.failures, 2, "Genuine earlier quota failures still count; this attempt does not")
            // The next interrupted Connect continues from those earlier failures.
            let beforeConnect = budget
            budget.reserve(at: start)
            guard case .failure(_, .signInRequired, let next) = budget.recordFailure(AntigravityProcess.ProcessError.cancelled,
                    explicit: true, reservedFrom: beforeConnect, at: start) else {
                return XCTFail("An interrupted Connect keeps its connection action")
            }
            XCTAssertEqual(next, start.addingTimeInterval(1_200))
        }
    }
}
