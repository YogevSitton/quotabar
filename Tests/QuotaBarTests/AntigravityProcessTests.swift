import XCTest
@testable import QuotaBar

/// No process is launched even if these synthetic rejection tests are run.
/// Process-group and terminal behavior still require separate qualification.
final class AntigravityProcessTests: XCTestCase {
    private func fixture(_ body: (AntigravityProfile.Lease) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("antigravity-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AntigravityProfile.acquire(home: root.appendingPathComponent("user"),
                                            administratorSettings: root.appendingPathComponent("admin.json")))
    }

    func testCancellationBeforeLaunchDoesNotReachExecutableLookup() throws {
        try fixture { lease in
            let cancellation = AntigravityProcess.Cancellation()
            cancellation.cancel()
            XCTAssertThrowsError(try AntigravityProcess.run(binary: URL(fileURLWithPath: "/nonexistent/synthetic-never-launch"),
                arguments: [], profile: lease, cancel: cancellation)) {
                guard case AntigravityProcess.ProcessError.cancelledBeforeLaunch = $0 else { return XCTFail("Expected cancellation before spawn") }
            }
        }
    }

    func testInvalidDeadlineAndEmbeddedNULAreRejectedBeforeSpawn() throws {
        try fixture { lease in
            for timeout in [TimeInterval.nan, .infinity, 0, -1, 181] {
                XCTAssertThrowsError(try AntigravityProcess.run(binary: URL(fileURLWithPath: "/nonexistent/synthetic-never-launch"),
                    arguments: [], profile: lease, timeout: timeout)) {
                    guard case AntigravityProcess.ProcessError.launchFailed = $0 else { return XCTFail("Expected launch policy refusal") }
                }
            }
            XCTAssertThrowsError(try AntigravityProcess.run(binary: URL(fileURLWithPath: "/nonexistent/synthetic-never-launch"),
                arguments: ["/usage\0ignored"], profile: lease))
        }
    }
}
