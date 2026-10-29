import XCTest
@testable import QuotaBar

/// Offline AppState only: no installation is detected, so refresh never reads,
/// launches a helper or starts sign-in.
final class AntigravityDeadlineTests: XCTestCase {
    @MainActor func testPassedDeadlineReenablesConnectWithoutStartingSignIn() {
        let state = AppState(loadLocalState: false)
        state.applyAntigravity(.failure("Synthetic interrupted connection.", .signInRequired,
                                        nextRequestAt: Date().addingTimeInterval(-1)))
        XCTAssertNotNil(state.antigravityNextRequestAt)
        state.antigravityDeadlinePassed()
        XCTAssertNil(state.antigravityNextRequestAt, "Connect must re-enable at its deadline")
        XCTAssertEqual(state.antigravityIssue, .signInRequired)
        XCTAssertNil(state.antigravityConnection, "Reaching a deadline must never start sign-in")
        XCTAssertFalse(state.refreshingAntigravity)
    }

    @MainActor func testFutureDeadlineStaysInPlace() {
        let state = AppState(loadLocalState: false)
        let deadline = Date().addingTimeInterval(3_600)
        state.applyAntigravity(.failure("Synthetic failed connection.", .connectionIncomplete, nextRequestAt: deadline))
        state.antigravityDeadlinePassed()
        XCTAssertEqual(state.antigravityNextRequestAt, deadline)
        XCTAssertEqual(state.antigravityIssue, .connectionIncomplete)
        XCTAssertNil(state.antigravityConnection)
    }
}
