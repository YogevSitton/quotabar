import XCTest
@testable import QuotaCore

final class ClaudeSignInTests: XCTestCase {
    private let checksum = String(repeating: "a", count: 64)
    private func manifest(checksum: String, size: Any = 275923296) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["platforms": ["darwin-arm64": ["binary": "claude", "checksum": checksum, "size": size]]])
    }
    func testDownloadIsPinnedToOfficialVersionPlatformSizeAndChecksum() throws {
        let release = try ClaudeHelperRelease.parse(version: "2.1.309", platform: "darwin-arm64", manifest: manifest(checksum: checksum))
        XCTAssertEqual(release.downloadURL.absoluteString, "https://downloads.claude.ai/claude-code-releases/2.1.309/darwin-arm64/claude")
        XCTAssertEqual(release.size, 275923296)
        XCTAssertEqual(release.checksum, checksum)
    }
    func testRejectsPathInjectionUnknownPlatformsAndInvalidChecksums() throws {
        let valid = try manifest(checksum: checksum)
        XCTAssertThrowsError(try ClaudeHelperRelease.parse(version: "../../other", platform: "darwin-arm64", manifest: valid))
        XCTAssertThrowsError(try ClaudeHelperRelease.parse(version: "2.1.309", platform: "../../other", manifest: valid))
        XCTAssertThrowsError(try ClaudeHelperRelease.parse(version: "2.1.309", platform: "darwin-arm64", manifest: manifest(checksum: "bad")))
        XCTAssertThrowsError(try ClaudeHelperRelease.parse(version: "2.1.309", platform: "darwin-arm64", manifest: manifest(checksum: checksum, size: true)))
    }
    func testRecoversOnlyOfficialSignInLinkFromHelperOutput() {
        let raw = "Starting…\nhttps://unrelated.example/oauth/authorize\nOpen https://claude.ai/oauth/authorize?client_id=test&state=test-state\n"
        XCTAssertEqual(ClaudeSignInLink.first(in: raw)?.host, "claude.ai")
        XCTAssertEqual(ClaudeSignInLink.first(in: raw)?.path, "/oauth/authorize")
        XCTAssertNil(ClaudeSignInLink.first(in: "https://claude.ai.evil.example/oauth/authorize"))
        XCTAssertNil(ClaudeSignInLink.first(in: "https://user@claude.ai/oauth/authorize"))
        XCTAssertNil(ClaudeSignInLink.first(in: "https://claude.ai/api/anything"))
        XCTAssertNil(ClaudeSignInLink.first(in: "http://claude.ai/oauth/authorize"))
    }
}
