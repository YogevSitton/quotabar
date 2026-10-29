import XCTest
@testable import QuotaBar

final class ClaudeHelperDiscoveryTests: XCTestCase {
    private let version = "2.1.310"

    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writeRecord(in directory: URL, version: String = "2.1.310", binary: String = "claude") throws {
        let row: [String: Any] = ["binary": binary, "checksum": String(repeating: "a", count: 64), "size": 1_000_000]
        let record: [String: Any] = ["version": version, "manifest": ["platforms": ["darwin-arm64": row, "darwin-x64": row]]]
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("release.json"))
    }

    private func writeHelper(in directory: URL) throws -> URL {
        let parent = directory.appendingPathComponent(version)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let executable = parent.appendingPathComponent("claude")
        // Synthetic bytes, never launched. Discovery must not hash or authenticate a helper.
        try Data("synthetic helper fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testManagedHelperIsDiscoveredWithoutDesktopOrExternalCLI() throws {
        try fixture { directory in
            let executable = try writeHelper(in: directory)
            try writeRecord(in: directory)
            XCTAssertEqual(ClaudeHelper.managedExecutable(in: directory), executable)
        }
    }

    func testEmptyStaleAndNonExecutableInstallationsStayAbsent() throws {
        try fixture { directory in
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
            try writeRecord(in: directory)
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
            let executable = try writeHelper(in: directory)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: false)
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
        }
    }

    func testMissingMalformedAndUnsafeRecordsStayAbsent() throws {
        try fixture { directory in
            _ = try writeHelper(in: directory)
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
            try Data("{broken".utf8).write(to: directory.appendingPathComponent("release.json"))
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
            try writeRecord(in: directory, version: "../2.1.310")
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
            try writeRecord(in: directory, binary: "other")
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
            try writeRecord(in: directory)
            let recordURL = directory.appendingPathComponent("release.json")
            var oversized = try Data(contentsOf: recordURL)
            oversized.append(Data(repeating: 0x20, count: 1_000_000))
            try oversized.write(to: recordURL)
            XCTAssertNil(ClaudeHelper.managedExecutable(in: directory))
        }
    }
}
