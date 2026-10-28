import Foundation
import Darwin

/// Only non-secret configuration is managed here. The official CLI owns every
/// authentication operation, including any access to its shared Keychain entry.
struct AntigravityProfile {
    enum ProfileError: Error {
        case unavailable
        case busy
        case changedConfiguration
        case administratorPolicy
    }

    private static let administratorSettings = URL(fileURLWithPath: "/Library/Application Support/Antigravity/admin_settings.json")
    private static let settings = Data("{\"disableSlashCommands\":false}\n".utf8)
    private static let emptyMCP = Data("{\"mcpServers\":{}}\n".utf8)
    private static let emptyObject = Data("{}\n".utf8)

    final class Lease: @unchecked Sendable {
        let home: URL
        let geminiDirectory: URL
        let workingDirectory: URL
        let temporaryDirectory: URL
        private let rootFD: Int32
        private let lockFD: Int32
        private let administratorSettings: URL

        fileprivate init(home: URL, rootFD: Int32, lockFD: Int32, administratorSettings: URL) {
            self.home = home
            self.rootFD = rootFD
            self.lockFD = lockFD
            self.administratorSettings = administratorSettings
            geminiDirectory = home.appendingPathComponent(".gemini", isDirectory: true)
            workingDirectory = home.appendingPathComponent("work", isDirectory: true)
            temporaryDirectory = home.appendingPathComponent("tmp", isDirectory: true)
        }

        deinit {
            flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            Darwin.close(rootFD)
        }

        var arguments: [String] {
            ["--gemini_dir=\(geminiDirectory.path)", "--app_data_dir=quotabar",
             "--include-default-customizations=false", "--disable-slash-commands=false"]
        }

        var environment: [String: String] {
            // No inherited API keys, routing overrides, proxies, SSH/CDE auth
            // hints, shell configuration, or provider feature flags.
            ["HOME": home.path, "TMPDIR": temporaryDirectory.path + "/",
             "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
             "LC_ALL": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
             "AGY_CLI_DISABLE_AUTO_UPDATE": "true"]
        }

        /// The caller stores only versioned request timing and retry counters.
        /// The profile lock covers reservation, launch and completion together.
        func readState() throws -> Data? {
            let fd = openat(rootFD, "request-budget.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT { return nil }
                throw ProfileError.unavailable
            }
            defer { Darwin.close(fd) }
            try AntigravityProfile.validateFile(fd)
            var bytes = [UInt8](repeating: 0, count: 4_097)
            var total = 0
            while total < bytes.count {
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress!.advanced(by: total), $0.count - total)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw ProfileError.unavailable }
                if count == 0 { break }
                total += count
            }
            guard total <= 4_096 else { throw ProfileError.changedConfiguration }
            return Data(bytes.prefix(total))
        }

        func writeState(_ data: Data) throws {
            guard !data.isEmpty, data.count <= 4_096 else { throw ProfileError.changedConfiguration }
            // Refuse an unexpected existing inode before replacing the entry.
            _ = try readState()
            let name = ".request-budget-\(UUID().uuidString).tmp"
            let fd = openat(rootFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ProfileError.unavailable }
            defer { Darwin.close(fd); unlinkat(rootFD, name, 0) }
            try AntigravityProfile.validateFile(fd)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ProfileError.unavailable }
                    offset += count
                }
            }
            guard fsync(fd) == 0,
                  renameat(rootFD, name, rootFD, "request-budget.json") == 0,
                  fsync(rootFD) == 0 else { throw ProfileError.unavailable }
        }

        /// Recheck under the lease immediately before each child launch.
        func validateForLaunch() throws {
            try AntigravityProfile.checkAdministratorPolicy(at: administratorSettings)
            let current = try AntigravityProfile.openPath(home, create: false)
            defer { Darwin.close(current) }
            var held = stat(), actual = stat()
            guard fstat(rootFD, &held) == 0, fstat(current, &actual) == 0,
                  held.st_dev == actual.st_dev, held.st_ino == actual.st_ino else {
                throw ProfileError.changedConfiguration
            }
            try AntigravityProfile.validateDirectory(current)
            try AntigravityProfile.configure(rootFD: current, create: false)
            guard try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path).isEmpty else {
                throw ProfileError.changedConfiguration
            }
        }
    }

    static func acquire(home userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Lease {
        try acquire(home: userHome, administratorSettings: administratorSettings)
    }

    // A synthetic policy location lets offline tests avoid machine policy state.
    static func acquire(home userHome: URL, administratorSettings: URL) throws -> Lease {
        try checkAdministratorPolicy(at: administratorSettings)
        let home = userHome.appendingPathComponent("Library/Application Support/QuotaBar/Antigravity", isDirectory: true)
        let rootFD = try openPath(home, create: true)
        var retained = false
        defer { if !retained { Darwin.close(rootFD) } }
        try validateDirectory(rootFD)
        let lockFD = openat(rootFD, "profile.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw ProfileError.unavailable }
        defer { if !retained { Darwin.close(lockFD) } }
        try validateFile(lockFD)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? ProfileError.busy : ProfileError.unavailable
        }
        try configure(rootFD: rootFD, create: true)
        let lease = Lease(home: home, rootFD: rootFD, lockFD: lockFD, administratorSettings: administratorSettings)
        retained = true
        try lease.validateForLaunch()
        return lease
    }

    private static func checkAdministratorPolicy(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 { throw ProfileError.administratorPolicy }
        guard errno == ENOENT else { throw ProfileError.unavailable }
    }

    /// Walk every component with openat/O_NOFOLLOW; checking only the final
    /// component would still permit a symlinked ancestor to select user config.
    private static func openPath(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw ProfileError.unavailable
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ProfileError.unavailable }
        do {
            for component in url.path.split(separator: "/").map(String.init) {
                guard component != ".", component != ".." else { throw ProfileError.unavailable }
                if create, mkdirat(fd, component, 0o700) != 0, errno != EEXIST {
                    throw ProfileError.unavailable
                }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ProfileError.unavailable }
                Darwin.close(fd)
                fd = next
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o7777) == 0o700 else {
            throw ProfileError.unavailable
        }
    }

    private static func validateFile(_ fd: Int32, requirePrivateMode: Bool = true) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              !requirePrivateMode || (info.st_mode & 0o7777) == 0o600 else {
            throw ProfileError.unavailable
        }
    }

    private static func directory(_ name: String, under parent: Int32, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw ProfileError.unavailable }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProfileError.unavailable }
        do { try validateDirectory(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }

    private static func configure(rootFD: Int32, create: Bool) throws {
        let gemini = try directory(".gemini", under: rootFD, create: create)
        defer { Darwin.close(gemini) }
        let cli = try directory("quotabar", under: gemini, create: create)
        defer { Darwin.close(cli) }
        let config = try directory("config", under: gemini, create: create)
        defer { Darwin.close(config) }
        let work = try directory("work", under: rootFD, create: create)
        defer { Darwin.close(work) }
        let temporary = try directory("tmp", under: rootFD, create: create)
        defer { Darwin.close(temporary) }
        try controlledFile("settings.json", under: cli, data: settings, create: create)
        try controlledFile("mcp_config.json", under: gemini, data: emptyMCP, create: create)
        try controlledFile("mcp_config.json", under: config, data: emptyMCP, create: create)
        try controlledFile("config.json", under: config, data: emptyObject, create: create)
        try controlledFile("hooks.json", under: gemini, data: emptyObject, create: create)
        try controlledFile("hooks.json", under: config, data: emptyObject, create: create)
        try controlledFile("hooks.json", under: cli, data: emptyObject, create: create)
        // A server-level plugin watcher starts before the CLI's default-
        // customization override. Its registries must remain empty on every
        // launch, including after the official CLI has populated this profile.
        for parent in [gemini, config, cli] {
            for name in ["plugins", "skills", "workflows", "rules"] {
                try requireEmptyDirectoryIfPresent(name, under: parent)
            }
            for name in ["plugins.txt", "plugins.json", "skills.txt", "skills.json",
                         "workflows.json", "rules.json", "AGENTS.md", "GEMINI.md"] {
                try requireAbsent(name, under: parent)
            }
        }
        for name in [".agents", "AGENTS.md", "GEMINI.md"] {
            try requireAbsent(name, under: rootFD)
        }
    }

    private static func requireAbsent(_ name: String, under directory: Int32) throws {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw ProfileError.changedConfiguration }
        guard errno == ENOENT else { throw ProfileError.unavailable }
    }

    private static func requireEmptyDirectoryIfPresent(_ name: String, under directory: Int32) throws {
        let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return }
            throw ProfileError.unavailable
        }
        do { try validateDirectory(fd) }
        catch { Darwin.close(fd); throw error }
        guard let stream = fdopendir(fd) else {
            Darwin.close(fd)
            throw ProfileError.unavailable
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ProfileError.unavailable }
                return
            }
            let entryName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard entryName == "." || entryName == ".." else { throw ProfileError.changedConfiguration }
        }
    }

    private static func controlledFile(_ name: String, under directory: Int32, data: Data, create: Bool) throws {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT, create else { throw ProfileError.unavailable }
            try replaceControlledFile(name, under: directory, data: data)
            return
        }
        defer { Darwin.close(fd) }
        try validateFile(fd, requirePrivateMode: !create)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ProfileError.unavailable }
        var bytes = [UInt8](repeating: 0, count: data.count + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: total), $0.count - total)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ProfileError.unavailable }
            if count == 0 { break }
            total += count
        }
        if Data(bytes.prefix(total)) == data, (info.st_mode & 0o7777) == 0o600 { return }
        // The official CLI may persist defaults while authenticating. Restore
        // only this closed set of QuotaBar-owned, non-secret configuration files
        // under the cross-copy lock. Personal settings and policy are untouched.
        guard create else { throw ProfileError.changedConfiguration }
        try replaceControlledFile(name, under: directory, data: data)
    }

    private static func replaceControlledFile(_ name: String, under directory: Int32, data: Data) throws {
        let temporary = ".config-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProfileError.unavailable }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        try validateFile(fd)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProfileError.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0,
              fsync(directory) == 0 else { throw ProfileError.unavailable }
    }
}
