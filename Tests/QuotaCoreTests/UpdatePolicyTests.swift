import XCTest
@testable import QuotaCore

final class UpdatePolicyTests: XCTestCase {
    private let key = UpdateManifestTests.testKey

    func testAcceptsOnlyNewerBuildsOnTheExpectedChannelAndKey() throws {
        let candidate = try UpdateManifestTests.preview(build: 40)
        XCTAssertNoThrow(try UpdatePolicy.validate(candidate, channel: .preview, publicKey: key, installedBuild: 39, highWater: nil))
        XCTAssertThrowsError(try UpdatePolicy.validate(candidate, channel: .preview, publicKey: key, installedBuild: 40, highWater: nil)) {
            XCTAssertEqual($0 as? UpdateValidationError, .rollback)
        }
        XCTAssertThrowsError(try UpdatePolicy.validate(candidate, channel: .stable, publicKey: key, installedBuild: 30, highWater: nil)) {
            XCTAssertEqual($0 as? UpdateValidationError, .invalidMetadata)
        }
        let otherKey = Data(repeating: 9, count: 32).base64EncodedString()
        XCTAssertThrowsError(try UpdatePolicy.validate(candidate, channel: .preview, publicKey: otherKey, installedBuild: 30, highWater: nil)) {
            XCTAssertEqual($0 as? UpdateValidationError, .invalidMetadata)
        }
    }

    func testHighWaterRejectsDowngradesAndConflictingIdentities() throws {
        let seen = UpdateIdentity(try UpdateManifestTests.preview(build: 45))
        let older = try UpdateManifestTests.preview(build: 44)
        XCTAssertThrowsError(try UpdatePolicy.validate(older, channel: .preview, publicKey: key, installedBuild: 30, highWater: seen)) {
            XCTAssertEqual($0 as? UpdateValidationError, .rollback)
        }
        let conflicting = try UpdateManifestTests.preview(build: 45, sha256: String(repeating: "c", count: 64))
        XCTAssertThrowsError(try UpdatePolicy.validate(conflicting, channel: .preview, publicKey: key, installedBuild: 30, highWater: seen)) {
            XCTAssertEqual($0 as? UpdateValidationError, .conflictingIdentity)
        }
        let same = try UpdateManifestTests.preview(build: 45)
        XCTAssertNoThrow(try UpdatePolicy.validate(same, channel: .preview, publicKey: key, installedBuild: 30, highWater: seen))
    }

    func testFeedsMustAgreeOnTheSameBuild() throws {
        let preview = try UpdateManifestTests.preview(build: 50)
        let stable = try preview.promotedToStable(releaseNotes: "Notes")
        XCTAssertNoThrow(try UpdatePolicy.consistent(preview, stable))
        let other = try UpdateManifestTests.preview(build: 50, sha256: String(repeating: "d", count: 64))
        XCTAssertThrowsError(try UpdatePolicy.consistent(other, stable)) {
            XCTAssertEqual($0 as? UpdateValidationError, .conflictingIdentity)
        }
        XCTAssertNoThrow(try UpdatePolicy.consistent(try UpdateManifestTests.preview(build: 51), stable))
    }
}
