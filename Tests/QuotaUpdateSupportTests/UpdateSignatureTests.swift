import XCTest
import CryptoKit
import QuotaCore
@testable import QuotaUpdateSupport

/// Signing keys are generated in memory per test; no key material is committed.
final class UpdateSignatureTests: XCTestCase {
    private func manifest(for key: Curve25519.Signing.PrivateKey) throws -> UpdateManifest {
        try UpdateManifest(channel: .preview, build: 40, displayVersion: "0.2.0", commit: String(repeating: "a", count: 40),
                           archiveBytes: 12, sha256: String(repeating: "b", count: 64),
                           publicKey: key.publicKey.rawRepresentation.base64EncodedString(), releaseNotes: "Preview build.")
    }

    func testSignedEnvelopeVerifiesWithItsPublicKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let value = try manifest(for: key)
        let envelope = try UpdateSignature.signed(value, privateKey: key.rawRepresentation)
        XCTAssertEqual(try UpdateSignature.verify(envelope, publicKey: value.publicKey), value)
    }

    func testRejectsAnotherKeyAndAManifestNamingAnotherKey() throws {
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let value = try manifest(for: key)
        let envelope = try UpdateSignature.signed(value, privateKey: key.rawRepresentation)
        let otherPublic = other.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try UpdateSignature.verify(envelope, publicKey: otherPublic)) {
            XCTAssertEqual($0 as? UpdateValidationError, .invalidSignature)
        }
        // The signer must be the key the manifest names.
        XCTAssertThrowsError(try UpdateSignature.signed(value, privateKey: other.rawRepresentation))
    }

    func testRejectsTamperedPayloadAndSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let value = try manifest(for: key)
        let envelope = try UpdateEnvelope.decode(UpdateSignature.signed(value, privateKey: key.rawRepresentation))
        var tampered = value; tampered.archiveBytes = 13
        let swapped = UpdateEnvelope(payload: try tampered.encoded(), signature: Data(base64Encoded: envelope.signature)!)
        XCTAssertThrowsError(try UpdateSignature.verify(swapped.encoded(), publicKey: value.publicKey)) {
            XCTAssertEqual($0 as? UpdateValidationError, .invalidSignature)
        }
        var signature = Data(base64Encoded: envelope.signature)!; signature[0] ^= 1
        let flipped = UpdateEnvelope(payload: Data(base64Encoded: envelope.payload)!, signature: signature)
        XCTAssertThrowsError(try UpdateSignature.verify(flipped.encoded(), publicKey: value.publicKey))
    }

    func testArchiveMustMatchSignedSizeAndHash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("QuotaBar-preview-40.zip")
        let bytes = Data("synthetic zip".utf8)
        try UpdateFiles.write(bytes, toNew: archive)
        let digest = try UpdateSignature.digest(archive, maximumBytes: 1_024)
        XCTAssertEqual(digest.bytes, bytes.count)
        var value = try manifest(for: Curve25519.Signing.PrivateKey())
        value.archiveBytes = digest.bytes; value.sha256 = digest.sha256
        XCTAssertNoThrow(try UpdateSignature.verifyArchive(archive, manifest: value))
        value.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try UpdateSignature.verifyArchive(archive, manifest: value))
        // A new file never replaces an existing one.
        XCTAssertThrowsError(try UpdateFiles.write(bytes, toNew: archive))
        // Arbitrary bytes are not an accepted ZIP.
        XCTAssertThrowsError(try UpdateZIP.inspect(archive))
    }
}
