import Foundation
import CryptoKit
import Security
import QuotaCore
import Darwin

private final class AntigravityDownloadRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "storage.googleapis.com" ? request : nil)
    }
}

/// Only the reviewed executable is eligible for this experimental protocol.
/// Updating this pin requires reviewing dispatch, configuration and auth again.
enum AntigravityHelper {
    static let version = "1.4.9"
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QuotaBar/AntigravityCLI")
    static let executable = support.appendingPathComponent("bin/\(version)/agy")
    private static let binarySize = 193_540_240
    private static let binaryHash = "a66421b7962ffe5642e00cffdd2844dfde440e540502a29d206be5544a065c7b"
    private static let archiveSize = 58_215_151
    private static let archiveHash = "d7d83634b0c236659ee530f448e9aa1c5dc00a010631edd72bf11a920006892b319be7e51c8defae226f204660544e4d915bb5e733f1ceb50c065f4cbe45d3d0"
    private static let archiveURL = URL(string: "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.4.9-4962164969177088/darwin-arm/cli_mac_arm64.tar.gz")!

    static var installedCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".local/bin/agy"), URL(fileURLWithPath: "/opt/homebrew/bin/agy"), URL(fileURLWithPath: "/usr/local/bin/agy")]
    }

    private static func digest<H: HashFunction>(_ url: URL, using initial: H) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = initial
        while let part = try handle.read(upToCount: 1_048_576), !part.isEmpty { hash.update(data: part) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ url: URL) throws {
        #if !arch(arm64)
        throw UsageError.message("Antigravity support currently requires an Apple Silicon Mac.")
        #else
        guard (try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).isRegularFile == true,
              (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == binarySize,
              try digest(url, using: SHA256()) == binaryHash else {
            throw UsageError.message("The Antigravity helper is not the reviewed version. Use Connect Antigravity to prepare it again.")
        }
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\"" as CFString,
                                            SecCSFlags(), &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw UsageError.message("The official Antigravity helper's signature could not be verified.")
        }
        #endif
    }

    /// No downloads or execution. The managed copy cannot be replaced by the
    /// user's ordinary CLI auto-updater between verification and launch.
    static func existing() throws -> URL? {
        guard FileManager.default.fileExists(atPath: executable.path) else { return nil }
        try validatePrivateDirectories()
        var info = stat()
        guard executable.resolvingSymlinksInPath().path == executable.standardizedFileURL.path,
              lstat(executable.path, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UsageError.message("The Antigravity helper location is not a private regular path.")
        }
        try verify(executable)
        return executable
    }

    /// Called only by the user's Connect action, never startup or polling.
    static func prepare(status: @escaping @MainActor @Sendable (String) -> Void) async throws -> URL {
        if let installed = try? existing() { return installed }
        await status("Preparing the official Antigravity CLI \(version)...")
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("quotabar-agy-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent("agy")
        if let candidate = installedCandidates.first(where: { (try? verify($0.resolvingSymlinksInPath())) != nil }) {
            try fm.copyItem(at: candidate.resolvingSymlinksInPath(), to: staged)
        } else {
            await status("Downloading the official Antigravity CLI (58 MB)...")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config, delegate: AntigravityDownloadRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (download, response) = try await session.download(from: archiveURL)
            defer { try? fm.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try download.resourceValues(forKeys: [.fileSizeKey])).fileSize == archiveSize,
                  try digest(download, using: SHA512()) == archiveHash else {
                throw UsageError.message("Antigravity's download failed verification. Nothing was installed.")
            }
            try Task.checkCancellation()
            // Extract one member to stdout, never archive-controlled paths.
            guard fm.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw UsageError.message("The Antigravity helper could not be prepared.")
            }
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            let unpack = Process()
            unpack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            unpack.arguments = ["-xOzf", download.path, "antigravity"]
            unpack.standardInput = FileHandle.nullDevice; unpack.standardOutput = output; unpack.standardError = FileHandle.nullDevice
            try unpack.run()
            let deadline = DispatchWorkItem { if unpack.isRunning { unpack.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
            unpack.waitUntilExit(); deadline.cancel()
            guard unpack.terminationReason == .exit, unpack.terminationStatus == 0 else {
                throw UsageError.message("Antigravity's download could not be unpacked.")
            }
        }
        try Task.checkCancellation()
        try verify(staged)
        let directory = executable.deletingLastPathComponent()
        // Validate each existing ancestor before creating children; a symlink
        // must not redirect even directory creation into another location.
        for path in [support, support.appendingPathComponent("bin"), directory] {
            guard path.resolvingSymlinksInPath().path == path.standardizedFileURL.path else {
                throw UsageError.message("The Antigravity helper location is not a private regular path.")
            }
            if !fm.fileExists(atPath: path.path) {
                try fm.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try validatePrivateDirectory(path)
        }
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
            throw UsageError.message("The Antigravity helper location is not a private regular path.")
        }
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staged.path)
        // Atomic replacement within our helper directory, preserving Google's signature.
        let pending = directory.appendingPathComponent(".agy-\(UUID().uuidString)")
        try fm.copyItem(at: staged, to: pending)
        defer { try? fm.removeItem(at: pending) }
        guard rename(pending.path, executable.path) == 0 else {
            throw UsageError.message("The verified Antigravity helper could not be saved.")
        }
        return executable
    }

    private static func validatePrivateDirectories() throws {
        for directory in [support, support.appendingPathComponent("bin"), executable.deletingLastPathComponent()] {
            try validatePrivateDirectory(directory)
        }
    }
    private static func validatePrivateDirectory(_ directory: URL) throws {
        var info = stat()
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path,
              lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw UsageError.message("The Antigravity helper directory is not private. Nothing was launched.")
        }
    }
}
