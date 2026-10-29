import Foundation
import CryptoKit
import Security
import QuotaCore

private final class ClaudeDownloadRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "downloads.claude.ai" ? request : nil)
    }
}

enum ClaudeHelper {
    private static let base = "https://downloads.claude.ai/claude-code-releases"
    static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaBar/ClaudeCode")
    private static var platform: String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x64"
        #endif
    }
    private static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func trustedInstalledCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\"" as CFString,
            SecCSFlags(), &requirement) == errSecSuccess else { return nil }
        return paths.first { url in
            guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url.resolvingSymlinksInPath() as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return false }
            return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        }
    }
    private static func managedCandidate(in directory: URL) -> (executable: URL, release: ClaudeHelperRelease)? {
        let recordURL = directory.appendingPathComponent("release.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: recordURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: recordURL) else { return nil }
        defer { try? handle.close() }
        // Bound the non-secret metadata read used by periodic installation discovery.
        if let saved = try? handle.read(upToCount: 1_000_000), saved.count < 1_000_000,
           let record = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
           let version = record["version"] as? String, let manifest = record["manifest"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: manifest),
           let release = try? ClaudeHelperRelease.parse(version: version, platform: platform, manifest: data) {
            let executable = directory.appendingPathComponent(release.version).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: executable.path),
               let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
               attributes[.type] as? FileAttributeType == .typeRegular {
                return (executable, release)
            }
        }
        return nil
    }
    // Visibility discovery only: no hashing, process launch, download or authentication.
    // existing() still verifies the helper's bytes before any caller may run it.
    static func managedExecutable(in directory: URL = support) -> URL? {
        managedCandidate(in: directory)?.executable
    }
    // Read-only discovery never downloads or starts sign-in.
    static func existing() throws -> URL? {
        if let installed = trustedInstalledCLI() { return installed.resolvingSymlinksInPath() }
        if let candidate = managedCandidate(in: support),
           try checksum(candidate.executable) == candidate.release.checksum { return candidate.executable }
        return nil
    }
    static func prepare(status: @escaping @MainActor @Sendable (String) -> Void) async throws -> URL {
        if let existing = try existing() { return existing }
        await status("Checking the official Claude Code download…")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: ClaudeDownloadRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func get(_ url: URL) async throws -> Data {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UsageError.message("Claude Code's download service is unavailable. Try again later.") }
            return data
        }
        let versionData = try await get(URL(string: "\(base)/latest")!)
        guard versionData.count < 100, let version = String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[A-Za-z0-9.-]+)?$", options: .regularExpression) != nil else {
            throw UsageError.message("Claude Code's download version could not be verified.")
        }
        let manifest = try await get(URL(string: "\(base)/\(version)/manifest.json")!)
        let release = try ClaudeHelperRelease.parse(version: version, platform: platform, manifest: manifest)
        await status("Downloading the official Claude Code helper (\(ByteCountFormatter.string(fromByteCount: Int64(release.size), countStyle: .file)))…")
        let (temporary, response) = try await session.download(from: release.downloadURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == release.size,
              try checksum(temporary) == release.checksum else {
            throw UsageError.message("Claude Code's download failed verification. Nothing was installed. Try again.")
        }
        try Task.checkCancellation()
        let directory = support.appendingPathComponent(version)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = directory.appendingPathComponent("claude")
        // Replace only QuotaBar's own helper. No global launcher or shell settings.
        if FileManager.default.fileExists(atPath: executable.path) { try FileManager.default.removeItem(at: executable) }
        try FileManager.default.copyItem(at: temporary, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let record: [String: Any] = ["version": version, "manifest": try JSONSerialization.jsonObject(with: manifest)]
        try JSONSerialization.data(withJSONObject: record).write(to: support.appendingPathComponent("release.json"), options: [.atomic])
        return executable
    }
}
