import Foundation
import CryptoKit
import Darwin
import QuotaCore

public enum UpdateSignature {
    /// Verifies an envelope against the public key this app or workflow trusts and
    /// returns its manifest. The manifest must name that same key.
    public static func verify(_ data: Data, publicKey: String) throws -> UpdateManifest {
        guard let keyBytes = Data(base64Encoded: publicKey), keyBytes.count == 32,
              keyBytes.base64EncodedString() == publicKey,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw UpdateValidationError.invalidSignature
        }
        let envelope = try UpdateEnvelope.decode(data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              key.isValidSignature(signature, for: payload) else { throw UpdateValidationError.invalidSignature }
        let manifest = try UpdateManifest.decode(payload)
        guard manifest.publicKey == publicKey else { throw UpdateValidationError.invalidSignature }
        return manifest
    }

    /// Signs the exact encoded manifest bytes. The key must match the manifest's key.
    public static func signed(_ manifest: UpdateManifest, privateKey: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        guard manifest.publicKey == key.publicKey.rawRepresentation.base64EncodedString() else {
            throw UpdateValidationError.invalidSignature
        }
        let payload = try manifest.encoded()
        return try UpdateEnvelope(payload: payload, signature: try key.signature(for: payload)).encoded()
    }

    public static func verifyArchive(_ file: URL, manifest: UpdateManifest) throws {
        let result = try digest(file, maximumBytes: UpdateManifest.maximumArchiveBytes)
        guard result.bytes == manifest.archiveBytes, result.sha256 == manifest.sha256 else {
            throw UpdateValidationError.invalidArchive
        }
    }

    public static func digest(_ file: URL, maximumBytes: Int) throws -> (bytes: Int, sha256: String) {
        let handle = try UpdateFiles.openRegular(file, maximumBytes: maximumBytes)
        defer { try? handle.close() }
        var count = 0; var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += chunk.count
            guard count <= maximumBytes else { throw UpdateValidationError.invalidArchive }
            hash.update(data: chunk)
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// Bounded, link-refusing file access for update inputs and outputs.
public enum UpdateFiles {
    public static func openRegular(_ file: URL, maximumBytes: Int) throws -> FileHandle {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UpdateValidationError.invalidArchive }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            close(descriptor); throw UpdateValidationError.invalidArchive
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public static func read(_ file: URL, maximumBytes: Int) throws -> Data {
        let handle = try openRegular(file, maximumBytes: maximumBytes); defer { try? handle.close() }
        let result = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard result.count <= maximumBytes else { throw UpdateValidationError.invalidArchive }
        return result
    }

    /// Creates a new private (0600) file; refuses to replace or follow anything.
    public static func create(_ file: URL) throws -> FileHandle {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UpdateValidationError.invalidArchive }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public static func write(_ data: Data, toNew file: URL) throws {
        let output = try create(file)
        do { try output.write(contentsOf: data); try output.synchronize(); try output.close() }
        catch { try? output.close(); try? FileManager.default.removeItem(at: file); throw error }
    }

    /// Requires an absolute, standardized path whose every component exists and is
    /// not a symbolic link.
    public static func safeComponents(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path else {
            throw UpdateValidationError.invalidArchive
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
                throw UpdateValidationError.invalidArchive
            }
        }
    }
}
