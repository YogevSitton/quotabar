import Foundation
import CryptoKit
import QuotaCore
import QuotaUpdateSupport

/// Release metadata tool for the trusted release workflow and the owner's
/// one-time key setup (docs/UPDATES.md). It never uploads, installs or contacts
/// a network service, and it never prints private key material.
///
///   identity --bundle <app>
///   manifest --channel preview --bundle <app> --archive <zip> --notes <file> --output <file>
///   manifest --promote <preview envelope> --public-key <key> --display-version <x.y.z> --notes <file> --output <file>
///   sign --manifest <unsigned manifest> --output <envelope>    (key: QUOTABAR_UPDATE_SIGNING_KEY)
///   verify --envelope <file> --public-key <key> [--channel <c>] [--tag <t>] [--archive <zip>]
///   generate-key --output <absolute path outside any checkout>
@main enum ReleaseTool {
    struct Failure: Error { let message: String }

    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch let failure as Failure { fail(failure.message) }
        catch let error as UpdateValidationError { fail(error.errorDescription ?? "Update validation failed.") }
        catch { fail("Release preparation failed. Check the inputs and docs/UPDATES.md.") }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("QuotaReleaseTool: \(message)\n".utf8)); exit(1)
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw Failure(message: "missing command") }
        let options = try parse(Array(arguments.dropFirst()))
        switch command {
        case "identity": try identity(options)
        case "manifest": try manifest(options)
        case "sign": try sign(options)
        case "verify": try verify(options)
        case "generate-key": try generateKey(options)
        default: throw Failure(message: "unknown command \(command)")
        }
    }

    static func parse(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]; var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), index + 1 < arguments.count, result[name] == nil else {
                throw Failure(message: "invalid or repeated option \(name)")
            }
            result[name] = arguments[index + 1]; index += 2
        }
        return result
    }

    static func required(_ options: [String: String], _ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else { throw Failure(message: "missing \(name)") }
        return value
    }

    static func file(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL }

    static func emit(_ pairs: [(String, String)]) {
        print(pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "\n"))
    }

    static func notes(_ options: [String: String]) throws -> String {
        let data = try UpdateFiles.read(file(try required(options, "--notes")), maximumBytes: UpdateManifest.maximumReleaseNotesBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure(message: "release notes must be UTF-8") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the identity a release-mode bundle was built with.
    static func releaseIdentity(_ bundle: URL) throws -> (display: String, build: UInt64, commit: String, publicKey: String) {
        let info = try UpdateBundle.info(bundle)
        guard info[UpdateBundleKey.mode] as? String == UpdateBundleKey.releaseMode else {
            throw Failure(message: "the bundle is not a release-mode build")
        }
        guard let display = info["CFBundleShortVersionString"] as? String,
              let buildText = info["CFBundleVersion"] as? String, let build = UInt64(buildText),
              let commit = info[UpdateBundleKey.commit] as? String,
              let publicKey = info[UpdateBundleKey.publicKey] as? String,
              info["CFBundleIdentifier"] as? String == UpdateManifest.bundleIdentifier else {
            throw Failure(message: "the bundle identity is incomplete")
        }
        return (display, build, commit, publicKey)
    }

    static func identity(_ options: [String: String]) throws {
        let value = try releaseIdentity(file(try required(options, "--bundle")))
        emit([("displayVersion", value.display), ("build", String(value.build)),
              ("commit", value.commit), ("publicKey", value.publicKey)])
    }

    static func manifest(_ options: [String: String]) throws {
        let output = file(try required(options, "--output"))
        let value: UpdateManifest
        if let promote = options["--promote"] {
            // Stable promotion: same build, commit and bytes as the verified Preview.
            let preview = try UpdateSignature.verify(UpdateFiles.read(file(promote), maximumBytes: UpdateEnvelope.maximumBytes),
                                                     publicKey: try required(options, "--public-key"))
            guard preview.channel == .preview else { throw Failure(message: "only a Preview can be promoted") }
            let requested = try required(options, "--display-version")
            guard preview.displayVersion == requested else {
                throw Failure(message: "the Preview's display version does not match the requested version")
            }
            value = try preview.promotedToStable(releaseNotes: try notes(options))
        } else {
            guard options["--channel"] == UpdateChannel.preview.rawValue else {
                throw Failure(message: "new builds are published only to the preview channel")
            }
            let bundle = file(try required(options, "--bundle")), archive = file(try required(options, "--archive"))
            let identity = try releaseIdentity(bundle)
            try UpdateZIP.inspect(archive)
            let digest = try UpdateSignature.digest(archive, maximumBytes: UpdateManifest.maximumArchiveBytes)
            value = try UpdateManifest(channel: .preview, build: identity.build, displayVersion: identity.display,
                                       commit: identity.commit, archiveBytes: digest.bytes, sha256: digest.sha256,
                                       publicKey: identity.publicKey, releaseNotes: try notes(options))
            guard archive.lastPathComponent == value.archiveName else {
                throw Failure(message: "the archive must be named \(value.archiveName)")
            }
        }
        try UpdateFiles.write(try value.encoded(), toNew: output)
        emit([("channel", value.channel.rawValue), ("build", String(value.build)), ("releaseTag", value.releaseTag),
              ("archiveName", value.archiveName), ("sha256", value.sha256)])
    }

    static func sign(_ options: [String: String]) throws {
        let input = file(try required(options, "--manifest")), output = file(try required(options, "--output"))
        guard let encoded = ProcessInfo.processInfo.environment["QUOTABAR_UPDATE_SIGNING_KEY"],
              let key = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else {
            throw Failure(message: "QUOTABAR_UPDATE_SIGNING_KEY is missing or malformed")
        }
        let value = try UpdateManifest.decode(UpdateFiles.read(input, maximumBytes: UpdateManifest.maximumPayloadBytes))
        let envelope = try UpdateSignature.signed(value, privateKey: key)
        // Never publish an envelope that does not verify with the manifest's own key.
        guard try UpdateSignature.verify(envelope, publicKey: value.publicKey) == value else {
            throw Failure(message: "the signed metadata did not verify")
        }
        try UpdateFiles.write(envelope, toNew: output)
        emit([("channel", value.channel.rawValue), ("build", String(value.build)), ("releaseTag", value.releaseTag)])
    }

    static func verify(_ options: [String: String]) throws {
        let value = try UpdateSignature.verify(
            UpdateFiles.read(file(try required(options, "--envelope")), maximumBytes: UpdateEnvelope.maximumBytes),
            publicKey: try required(options, "--public-key"))
        if let channel = options["--channel"], value.channel.rawValue != channel {
            throw Failure(message: "the metadata is for the \(value.channel.rawValue) channel")
        }
        if let tag = options["--tag"], value.releaseTag != tag {
            throw Failure(message: "the metadata belongs to release \(value.releaseTag)")
        }
        if let archive = options["--archive"] {
            try UpdateSignature.verifyArchive(file(archive), manifest: value)
            try UpdateZIP.inspect(file(archive))
        }
        emit([("channel", value.channel.rawValue), ("build", String(value.build)), ("displayVersion", value.displayVersion),
              ("commit", value.commit), ("releaseTag", value.releaseTag), ("archiveName", value.archiveName),
              ("archiveBytes", String(value.archiveBytes)), ("sha256", value.sha256)])
    }

    /// Owner setup only. Writes the private key (base64) to a new 0600 file that is
    /// not inside any Git checkout, and prints only the public key.
    static func generateKey(_ options: [String: String]) throws {
        let path = try required(options, "--output")
        let output = file(path)
        guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: output.path) else {
            throw Failure(message: "--output must be a new absolute path")
        }
        var directory = output.deletingLastPathComponent()
        try UpdateFiles.safeComponents(directory)
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                throw Failure(message: "--output must be outside every Git checkout")
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        let key = Curve25519.Signing.PrivateKey()
        try UpdateFiles.write(Data(key.rawRepresentation.base64EncodedString().utf8), toNew: output)
        emit([("publicKey", key.publicKey.rawRepresentation.base64EncodedString())])
    }
}
