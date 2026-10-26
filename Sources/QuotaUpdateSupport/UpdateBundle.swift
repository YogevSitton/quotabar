import Foundation
import Darwin
import QuotaCore

/// Info.plist keys written by scripts/build.sh from release-version.json.
public enum UpdateBundleKey {
    public static let mode = "QuotaBarUpdateMode"
    public static let publicKey = "QuotaBarUpdatePublicKey"
    public static let commit = "QuotaBarUpdateCommit"
    public static let releaseMode = "release"
    public static let sourceMode = "source"
}

public enum UpdateBundle {
    public static let helperPath = "Contents/Helpers/QuotaUpdater.app"
    public static let helperExecutable = "Contents/MacOS/QuotaUpdater"
    public static let appExecutable = "Contents/MacOS/QuotaBar"

    public static func info(_ bundle: URL) throws -> [String: Any] {
        let bytes = try UpdateFiles.read(bundle.appendingPathComponent("Contents/Info.plist"), maximumBytes: 65_536)
        guard let result = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
            throw UpdateValidationError.invalidArchive
        }
        return result
    }

    /// Regular files and directories owned by this user only: no links, hard
    /// links, set-id bits or special files, within entry and size bounds.
    public static func validateTree(_ root: URL) throws {
        try UpdateFiles.safeComponents(root)
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_uid == getuid() else {
            throw UpdateValidationError.invalidArchive
        }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in failed = true; return false }) else { throw UpdateValidationError.invalidArchive }
        var count = 0; var size: Int64 = 0
        for case let file as URL in enumerator {
            count += 1
            var info = stat()
            guard count <= UpdateZIP.maximumEntries, lstat(file.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & 0o6000 == 0,
                  info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else {
                throw UpdateValidationError.invalidArchive
            }
            if info.st_mode & S_IFMT == S_IFREG {
                guard info.st_nlink == 1, info.st_size >= 0 else { throw UpdateValidationError.invalidArchive }
                size += info.st_size
                guard size <= Int64(UpdateZIP.maximumExpandedBytes) else { throw UpdateValidationError.invalidArchive }
            }
        }
        guard !failed else { throw UpdateValidationError.invalidArchive }
    }

    /// Checks that an extracted release bundle and its helper are exactly the
    /// build the signed manifest describes, then verifies the code signature.
    public static func validate(_ bundle: URL, manifest: UpdateManifest, publicKey: String) throws {
        try manifest.validate(); try validateTree(bundle)
        let value = try info(bundle)
        guard value["CFBundleIdentifier"] as? String == manifest.bundleIdentifier,
              value["CFBundleVersion"] as? String == String(manifest.build),
              value["CFBundleShortVersionString"] as? String == manifest.displayVersion,
              value["LSMinimumSystemVersion"] as? String == manifest.minimumOS,
              value["CFBundleExecutable"] as? String == "QuotaBar",
              value[UpdateBundleKey.mode] as? String == UpdateBundleKey.releaseMode,
              value[UpdateBundleKey.commit] as? String == manifest.commit,
              value[UpdateBundleKey.publicKey] as? String == publicKey else {
            throw UpdateValidationError.invalidArchive
        }
        let helper = bundle.appendingPathComponent(helperPath)
        let helperInfo = try info(helper)
        guard helperInfo["CFBundleIdentifier"] as? String == manifest.helperIdentifier,
              helperInfo["CFBundleVersion"] as? String == String(manifest.build),
              helperInfo["CFBundleShortVersionString"] as? String == manifest.displayVersion,
              helperInfo["CFBundleExecutable"] as? String == "QuotaUpdater",
              helperInfo[UpdateBundleKey.mode] as? String == UpdateBundleKey.releaseMode,
              helperInfo[UpdateBundleKey.commit] as? String == manifest.commit,
              helperInfo[UpdateBundleKey.publicKey] as? String == publicKey else {
            throw UpdateValidationError.invalidArchive
        }
        try arm64(bundle.appendingPathComponent(appExecutable))
        try arm64(helper.appendingPathComponent(helperExecutable))
        try UpdateSystemCommand.run(.codesign, ["--verify", "--deep", "--strict", bundle.path])
    }

    private static func arm64(_ file: URL) throws {
        let input = try UpdateFiles.openRegular(file, maximumBytes: 134_217_728); defer { try? input.close() }
        guard let data = try input.read(upToCount: 8), data.count == 8,
              Array(data.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe],
              Array(data.suffix(4)) == [0x0c, 0, 0, 1], FileManager.default.isExecutableFile(atPath: file.path) else {
            throw UpdateValidationError.invalidArchive
        }
    }
}

public enum UpdateSystemCommand {
    public enum Tool { case ditto, codesign, open }
    /// Fixed system executables, no shell, no output logging or inherited overrides.
    public static func run(_ tool: Tool, _ arguments: [String], timeout: TimeInterval = 60) throws {
        let executable: String
        switch tool { case .ditto: executable = "/usr/bin/ditto"; case .codesign: executable = "/usr/bin/codesign"; case .open: executable = "/usr/bin/open" }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UpdateValidationError.invalidArchive }
            usleep(20_000)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateValidationError.invalidArchive }
    }
}
