import Foundation

public enum UpdateValidationError: Error, LocalizedError, Equatable {
    case invalidMetadata, invalidSignature, invalidArchive, rollback, conflictingIdentity
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "The update metadata is invalid or unsupported."
        case .invalidSignature: return "The update signature could not be verified."
        case .invalidArchive: return "The downloaded update does not match its signed description."
        case .rollback: return "No newer update is available on this channel."
        case .conflictingIdentity: return "The update conflicts with an earlier signed build of the same number."
        }
    }
}

public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable, preview

    /// Signed channel feed on GitHub Pages: one envelope for the channel head.
    public var feedURL: URL {
        URL(string: "https://yogevsitton.github.io/quotabar/updates/v1/\(rawValue).json")!
    }
}

/// A deliberately flat, closed schema. Signatures cover the exact encoded bytes.
/// Tag and asset names follow docs/UPDATES.md: Preview `preview-<build>` with
/// `QuotaBar-preview-<build>.zip`, Stable `v<version>` with `QuotaBar-<version>.zip`.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public static let repository = "YogevSitton/quotabar"
    public static let bundleIdentifier = "com.yogev.quotabar"
    public static let helperIdentifier = "com.yogev.quotabar.updater"
    /// v0.1.0 shipped as build 28 without an updater; every update is newer.
    public static let firstUpdatableBuild: UInt64 = 29
    public static let maximumArchiveBytes = 268_435_456
    public static let maximumPayloadBytes = 32_768
    public static let maximumReleaseNotesBytes = 8_192
    public static let keys: Set<String> = ["schema", "repository", "channel", "build", "displayVersion",
        "commit", "minimumOS", "architecture", "releaseTag", "archiveName", "archiveBytes", "sha256",
        "bundleIdentifier", "helperIdentifier", "publicKey", "releaseNotes"]

    public var schema: Int
    public var repository: String
    public var channel: UpdateChannel
    public var build: UInt64
    public var displayVersion: String
    public var commit: String
    public var minimumOS: String
    public var architecture: String
    public var releaseTag: String
    public var archiveName: String
    public var archiveBytes: Int
    public var sha256: String
    public var bundleIdentifier: String
    public var helperIdentifier: String
    public var publicKey: String
    public var releaseNotes: String

    /// Builds a manifest that follows the channel's tag and asset conventions.
    public init(channel: UpdateChannel, build: UInt64, displayVersion: String, commit: String,
                archiveBytes: Int, sha256: String, publicKey: String, releaseNotes: String) throws {
        schema = 1; repository = Self.repository; self.channel = channel; self.build = build
        self.displayVersion = displayVersion; self.commit = commit
        minimumOS = "14.0"; architecture = "arm64"
        releaseTag = Self.releaseTag(channel: channel, build: build, displayVersion: displayVersion)
        archiveName = Self.archiveName(channel: channel, build: build, displayVersion: displayVersion)
        self.archiveBytes = archiveBytes; self.sha256 = sha256
        bundleIdentifier = Self.bundleIdentifier; helperIdentifier = Self.helperIdentifier
        self.publicKey = publicKey; self.releaseNotes = releaseNotes
        try validate()
    }

    public static func releaseTag(channel: UpdateChannel, build: UInt64, displayVersion: String) -> String {
        channel == .preview ? "preview-\(build)" : "v\(displayVersion)"
    }

    public static func archiveName(channel: UpdateChannel, build: UInt64, displayVersion: String) -> String {
        channel == .preview ? "QuotaBar-preview-\(build).zip" : "QuotaBar-\(displayVersion).zip"
    }

    /// The anonymous release download URL, derived only from validated fields.
    public var archiveURL: URL {
        URL(string: "https://github.com/\(Self.repository)/releases/download/\(releaseTag)/\(archiveName)")!
    }

    /// The same build, commit and bytes described for the Stable channel.
    /// Promotion never rebuilds: only the channel, tag, asset name and notes change.
    public func promotedToStable(releaseNotes notes: String) throws -> UpdateManifest {
        try validate()
        guard channel == .preview else { throw UpdateValidationError.invalidMetadata }
        return try UpdateManifest(channel: .stable, build: build, displayVersion: displayVersion, commit: commit,
                                  archiveBytes: archiveBytes, sha256: sha256, publicKey: publicKey, releaseNotes: notes)
    }

    public static func decode(_ bytes: Data) throws -> Self {
        try StrictUpdateJSON.validate(bytes, keys: keys, maximumBytes: maximumPayloadBytes)
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        return value
    }

    public func validate() throws {
        guard schema == 1, repository == Self.repository,
              build >= Self.firstUpdatableBuild, build <= UInt64(Int64.max),
              displayVersion.range(of: "^[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$", options: .regularExpression) != nil,
              commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              minimumOS == "14.0", architecture == "arm64",
              releaseTag == Self.releaseTag(channel: channel, build: build, displayVersion: displayVersion),
              archiveName == Self.archiveName(channel: channel, build: build, displayVersion: displayVersion),
              archiveBytes > 0, archiveBytes <= Self.maximumArchiveBytes,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              bundleIdentifier == Self.bundleIdentifier, helperIdentifier == Self.helperIdentifier,
              let key = Data(base64Encoded: publicKey), key.count == 32,
              key.base64EncodedString() == publicKey,
              releaseNotes.utf8.count <= Self.maximumReleaseNotesBytes,
              !releaseNotes.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }) else {
            throw UpdateValidationError.invalidMetadata
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumPayloadBytes else { throw UpdateValidationError.invalidMetadata }
        return data
    }
}

/// The signed wrapper published as `QuotaBar-update.json` and as each channel feed.
public struct UpdateEnvelope: Codable, Sendable {
    public static let keyIdentifier = "quotabar-ed25519-v1"
    public static let maximumBytes = 49_152
    public let schema: Int
    public let keyID: String
    public let payload: String
    public let signature: String

    public init(payload: Data, signature: Data) {
        schema = 1; keyID = Self.keyIdentifier
        self.payload = payload.base64EncodedString(); self.signature = signature.base64EncodedString()
    }

    public static func decode(_ data: Data) throws -> Self {
        try StrictUpdateJSON.validate(data, keys: ["schema", "keyID", "payload", "signature"], maximumBytes: maximumBytes)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.keyID == keyIdentifier,
              let payload = Data(base64Encoded: value.payload), payload.count <= UpdateManifest.maximumPayloadBytes,
              payload.base64EncodedString() == value.payload,
              let signature = Data(base64Encoded: value.signature), signature.count == 64,
              signature.base64EncodedString() == value.signature else { throw UpdateValidationError.invalidMetadata }
        return value
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// JSONDecoder alone accepts repeated keys. This flat-schema scanner rejects them,
/// escaped duplicates, nested values, literals, signs, fractions, noncanonical
/// integers and unknown or missing fields before decoding.
public enum StrictUpdateJSON {
    public static func validate(_ data: Data, keys: Set<String>, maximumBytes: Int) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw UpdateValidationError.invalidMetadata }
        let bytes = Array(data); var i = 0; var seen = Set<String>()
        func space() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
        func string() throws -> String {
            guard i < bytes.count, bytes[i] == 34 else { throw UpdateValidationError.invalidMetadata }
            let start = i; i += 1
            while i < bytes.count {
                if bytes[i] == 34 {
                    i += 1
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<i])) }
                    catch { throw UpdateValidationError.invalidMetadata }
                }
                if bytes[i] < 32 { throw UpdateValidationError.invalidMetadata }
                if bytes[i] == 92 { i += 1 }
                i += 1
            }
            throw UpdateValidationError.invalidMetadata
        }
        space(); guard i < bytes.count, bytes[i] == 123 else { throw UpdateValidationError.invalidMetadata }; i += 1
        while true {
            space(); let key = try string()
            guard keys.contains(key), seen.insert(key).inserted else { throw UpdateValidationError.invalidMetadata }
            space(); guard i < bytes.count, bytes[i] == 58 else { throw UpdateValidationError.invalidMetadata }; i += 1; space()
            guard i < bytes.count else { throw UpdateValidationError.invalidMetadata }
            if bytes[i] == 34 { _ = try string() }
            else {
                let start = i
                while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
                guard i > start, i - start <= 19, i - start == 1 || bytes[start] != 48 else {
                    throw UpdateValidationError.invalidMetadata
                }
            }
            space(); guard i < bytes.count else { throw UpdateValidationError.invalidMetadata }
            if bytes[i] == 125 { i += 1; break }
            guard bytes[i] == 44 else { throw UpdateValidationError.invalidMetadata }; i += 1
        }
        space(); guard i == bytes.count, seen == keys else { throw UpdateValidationError.invalidMetadata }
    }
}
