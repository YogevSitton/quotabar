import XCTest
@testable import QuotaCore

/// Synthetic manifests only. The public key is a fixed 32-byte test value, not
/// a real signing key, and nothing here contacts GitHub.
final class UpdateManifestTests: XCTestCase {
    static let testKey = Data(repeating: 7, count: 32).base64EncodedString()
    static let commit = String(repeating: "a", count: 40)
    static let sha = String(repeating: "b", count: 64)

    static func preview(build: UInt64 = 40, display: String = "0.2.0", sha256: String = sha) throws -> UpdateManifest {
        try UpdateManifest(channel: .preview, build: build, displayVersion: display, commit: commit,
                           archiveBytes: 1_003_448, sha256: sha256, publicKey: testKey, releaseNotes: "Preview build.\n")
    }

    func testPreviewAndStableFollowTagAndAssetConventions() throws {
        let preview = try Self.preview()
        XCTAssertEqual(preview.releaseTag, "preview-40")
        XCTAssertEqual(preview.archiveName, "QuotaBar-preview-40.zip")
        XCTAssertEqual(preview.archiveURL.absoluteString,
                       "https://github.com/YogevSitton/quotabar/releases/download/preview-40/QuotaBar-preview-40.zip")
        let stable = try preview.promotedToStable(releaseNotes: "### Added\n\n- Updates.")
        XCTAssertEqual(stable.channel, .stable)
        XCTAssertEqual(stable.releaseTag, "v0.2.0")
        XCTAssertEqual(stable.archiveName, "QuotaBar-0.2.0.zip")
        XCTAssertEqual(UpdateIdentity(stable), UpdateIdentity(preview))
        XCTAssertThrowsError(try stable.promotedToStable(releaseNotes: ""))
        XCTAssertEqual(UpdateChannel.preview.feedURL.absoluteString, "https://yogevsitton.github.io/quotabar/updates/v1/preview.json")
    }

    func testEncodedManifestRoundTripsThroughStrictDecoder() throws {
        let value = try Self.preview()
        XCTAssertEqual(try UpdateManifest.decode(value.encoded()), value)
    }

    func testRejectsBuildsNotNewerThanTheFirstPublicRelease() {
        XCTAssertThrowsError(try Self.preview(build: 28))
        XCTAssertNoThrow(try Self.preview(build: 29))
    }

    func testRejectsMismatchedTagsAssetsAndFields() throws {
        var value = try Self.preview()
        value.releaseTag = "v0.2.0"
        XCTAssertThrowsError(try value.validate())
        value = try Self.preview(); value.archiveName = "QuotaBar-0.2.0.zip"
        XCTAssertThrowsError(try value.validate())
        value = try Self.preview(); value.repository = "someone/else"
        XCTAssertThrowsError(try value.validate())
        value = try Self.preview(); value.architecture = "x86_64"
        XCTAssertThrowsError(try value.validate())
        value = try Self.preview(); value.commit = "abc"
        XCTAssertThrowsError(try value.validate())
        value = try Self.preview(); value.publicKey = "not-a-key"
        XCTAssertThrowsError(try value.validate())
        value = try Self.preview(); value.archiveBytes = 0
        XCTAssertThrowsError(try value.validate())
        value = try Self.preview(); value.releaseNotes = "bell\u{07}"
        XCTAssertThrowsError(try value.validate())
        XCTAssertThrowsError(try Self.preview(display: "0.2"))
        XCTAssertThrowsError(try Self.preview(sha256: "B" + String(repeating: "b", count: 63)))
    }

    func testStrictJSONRejectsDuplicatesUnknownNestedAndNoncanonicalValues() throws {
        let valid = try XCTUnwrap(String(data: Self.preview().encoded(), encoding: .utf8))
        XCTAssertNoThrow(try UpdateManifest.decode(Data(valid.utf8)))
        let mutations = [
            valid.replacingOccurrences(of: "{", with: "{\"build\":41,", options: [], range: valid.range(of: "{")),
            valid.replacingOccurrences(of: "{", with: "{\"bu\\u0069ld\":41,", options: [], range: valid.range(of: "{")),
            valid.replacingOccurrences(of: "{", with: "{\"extra\":\"x\",", options: [], range: valid.range(of: "{")),
            valid.replacingOccurrences(of: "\"build\":40", with: "\"build\":040"),
            valid.replacingOccurrences(of: "\"build\":40", with: "\"build\":40.0"),
            valid.replacingOccurrences(of: "\"build\":40", with: "\"build\":-40"),
            valid.replacingOccurrences(of: "\"build\":40", with: "\"build\":{\"n\":40}"),
            valid.replacingOccurrences(of: "\"build\":40", with: "\"build\":true"),
            valid.replacingOccurrences(of: "\"build\":40,", with: ""),
            valid + " x",
            "[" + valid + "]"
        ]
        for text in mutations {
            XCTAssertThrowsError(try UpdateManifest.decode(Data(text.utf8)), text)
        }
    }

    func testEnvelopeRequiresCanonicalBase64AndKeyIdentifier() throws {
        let payload = try Self.preview().encoded()
        let envelope = UpdateEnvelope(payload: payload, signature: Data(repeating: 1, count: 64))
        let decoded = try UpdateEnvelope.decode(envelope.encoded())
        XCTAssertEqual(decoded.payload, envelope.payload)
        let text = try XCTUnwrap(String(data: envelope.encoded(), encoding: .utf8))
        XCTAssertThrowsError(try UpdateEnvelope.decode(Data(text.replacingOccurrences(of: "quotabar-ed25519-v1", with: "other").utf8)))
        let short = UpdateEnvelope(payload: payload, signature: Data(repeating: 1, count: 63))
        XCTAssertThrowsError(try UpdateEnvelope.decode(short.encoded()))
    }
}
