import Foundation
import Darwin
import QuotaCore

/// A process identified by PID and start time, so a reused PID never matches.
public struct UpdateProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let seconds: UInt64
    public let microseconds: UInt64

    public static func read(_ pid: Int32) throws -> Self {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            throw UpdateValidationError.invalidMetadata
        }
        return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    public static func executable(_ pid: Int32) throws -> String {
        var path = [UInt8](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { throw UpdateValidationError.invalidMetadata }
        return String(decoding: path.prefix(Int(length)).prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// True while this exact process runs. Unknown is never treated as exited.
    public func isRunning() throws -> Bool {
        do { return try Self.read(pid) == self }
        catch {
            if kill(pid, 0) == -1 && errno == ESRCH { return false }
            throw UpdateValidationError.invalidMetadata
        }
    }
}

/// Written by the app for one fresh Install click; consumed once by the helper.
public struct UpdateInstallRequest: Codable, Equatable, Sendable {
    public let schema: Int
    public let nonce: UUID
    public let destination: String
    public let installedBuild: UInt64
    public let channel: UpdateChannel
    public let expectedBuild: UInt64
    public let expectedSHA256: String
    public let parent: UpdateProcessIdentity

    public init(nonce: UUID, destination: URL, installedBuild: UInt64, channel: UpdateChannel,
                manifest: UpdateManifest, parent: UpdateProcessIdentity) {
        schema = 1; self.nonce = nonce; self.destination = destination.path; self.installedBuild = installedBuild
        self.channel = channel; expectedBuild = manifest.build; expectedSHA256 = manifest.sha256; self.parent = parent
    }
}

/// The non-secret transaction record. Reading it never authorizes anything.
public struct UpdateJournal: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Helper started and is verifying; the installed app is unchanged.
        case preparing
        /// Verified and waiting for the app to quit; the installed app is unchanged.
        case waitingForExit
        /// Ended before any protected change; the installed app is unchanged.
        case refused, cancelled
        /// macOS denied the first protected rename; the installed app is unchanged.
        case permissionDenied
        /// The new app is in place and was asked to launch.
        case replaced
        /// The new app launched and acknowledged this transaction.
        case completed
        /// The new app is in place but did not acknowledge launch; both copies kept.
        case launchUnconfirmed
        /// The new app could not launch and the previous app was restored.
        case rolledBack
        /// State is uncertain; every copy is kept for manual recovery.
        case recoveryRequired

        /// Phases in which the installed app was never touched.
        public var leftOriginalUnchanged: Bool { [.preparing, .waitingForExit, .refused, .cancelled, .permissionDenied].contains(self) }
    }

    public let nonce: UUID
    public let phase: Phase
    public let build: UInt64
    public let previousBuild: UInt64
    public let destination: String

    public init(nonce: UUID, phase: Phase, build: UInt64, previousBuild: UInt64, destination: String) {
        self.nonce = nonce; self.phase = phase; self.build = build; self.previousBuild = previousBuild; self.destination = destination
    }

    public func moving(to phase: Phase) -> UpdateJournal {
        UpdateJournal(nonce: nonce, phase: phase, build: build, previousBuild: previousBuild, destination: destination)
    }
}

/// Private update storage under ~/Library/Application Support/QuotaBar/Updates
/// (directories 0700, files 0600) and the filesystem rules for replacement.
public enum UpdateInstallation {
    public static let requestName = "request.json", consumedRequestName = "request-consumed.json"
    public static let handoffName = "handoff.json", consumedHandoffName = "handoff-consumed.json"
    public static let journalName = "state.json", cancelName = "cancel.json"
    public static let envelopeName = "update.json", installerName = "Installer.app", extractedName = "Extracted"
    /// Non-`.app` names keep LaunchServices from registering recovery copies.
    public static let previousName = "Previous.quotabar-backup", failedName = "Failed.quotabar-backup"

    public static func privateDirectory(_ url: URL, create: Bool = false) throws {
        if create && !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try UpdateFiles.safeComponents(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw UpdateValidationError.invalidArchive }
    }

    /// Directories are created only when something is written (`create: true`);
    /// reading at startup never creates anything.
    public static func root(create: Bool = false) throws -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().appendingPathComponent("Library/Application Support")
        try UpdateFiles.safeComponents(base)
        let app = base.appendingPathComponent("QuotaBar", isDirectory: true)
        if create && !FileManager.default.fileExists(atPath: app.path) {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try UpdateFiles.safeComponents(app)
        let root = app.appendingPathComponent("Updates", isDirectory: true)
        try privateDirectory(root, create: create)
        return root
    }

    public static func staged(create: Bool = false) throws -> URL {
        let url = try root(create: create).appendingPathComponent("Staged", isDirectory: true)
        try privateDirectory(url, create: create); return url
    }

    public static func jobs(create: Bool = false) throws -> URL {
        let url = try root(create: create).appendingPathComponent("Jobs", isDirectory: true)
        try privateDirectory(url, create: create); return url
    }

    public static func job(_ nonce: UUID, create: Bool = false) throws -> URL {
        let url = try jobs(create: create).appendingPathComponent(nonce.uuidString, isDirectory: true)
        try privateDirectory(url, create: create); return url
    }

    public static func stateFile(create: Bool = false) throws -> URL {
        try root(create: create).appendingPathComponent("state.json")
    }

    /// Only the two Applications locations, owned by this user, on a volume that
    /// supports exclusive renames. Writability is necessary but does not prove
    /// that macOS App Management will allow replacing the app.
    public static func destination(_ url: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let allowed = ["/Applications/QuotaBar.app", home.appendingPathComponent("Applications/QuotaBar.app").path]
        guard allowed.contains(url.path), url.path == url.standardizedFileURL.path else { throw UpdateValidationError.invalidArchive }
        try UpdateFiles.safeComponents(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw UpdateValidationError.invalidArchive
        }
        let values = try url.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
        guard values.volumeSupportsExclusiveRenaming == true else { throw UpdateValidationError.invalidArchive }
    }

    /// Exclusive renames need the job directory and the app on one volume.
    public static func sameVolume(_ first: URL, _ second: URL) -> Bool {
        var a = stat(), b = stat()
        return lstat(first.path, &a) == 0 && lstat(second.path, &b) == 0 && a.st_dev == b.st_dev
    }

    public static func fileIdentity(_ url: URL) throws -> (device: dev_t, inode: ino_t) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw UpdateValidationError.invalidArchive }
        return (info.st_dev, info.st_ino)
    }

    /// Atomically replaces an updater-owned JSON file inside a private directory.
    public static func write<T: Encodable>(_ value: T, to file: URL) throws {
        try privateDirectory(file.deletingLastPathComponent())
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        let output = try UpdateFiles.create(temporary)
        do {
            try output.write(contentsOf: JSONEncoder().encode(value)); try output.synchronize(); try output.close()
            guard rename(temporary.path, file.path) == 0 else { throw UpdateValidationError.invalidArchive }
            let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw UpdateValidationError.invalidArchive }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw UpdateValidationError.invalidArchive }
        } catch { try? output.close(); try? FileManager.default.removeItem(at: temporary); throw error }
    }

    public static func read<T: Decodable>(_ type: T.Type, from file: URL, maximumBytes: Int = 16_384) throws -> T {
        try privateDirectory(file.deletingLastPathComponent())
        return try JSONDecoder().decode(type, from: UpdateFiles.read(file, maximumBytes: maximumBytes))
    }

    public static func readJournal(_ job: URL) throws -> UpdateJournal {
        try read(UpdateJournal.self, from: job.appendingPathComponent(journalName), maximumBytes: 4_096)
    }

    /// Fails instead of replacing anything at the destination name.
    public static func renameExclusive(_ source: URL, _ destination: URL) throws {
        try UpdateFiles.safeComponents(source.deletingLastPathComponent()); try UpdateFiles.safeComponents(destination.deletingLastPathComponent())
        let from = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let to = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { if from >= 0 { close(from) }; if to >= 0 { close(to) } }
        guard from >= 0, to >= 0 else { throw UpdateValidationError.invalidArchive }
        guard renameatx_np(from, source.lastPathComponent, to, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Run once at app launch. If this exact app is the new build of a `replaced`
    /// transaction for its own location, records `completed`. This is the only
    /// file operation startup performs on update state; it installs nothing.
    public static func acknowledgeLaunch(bundle: URL, build: UInt64) {
        guard let jobs = try? jobs(), let names = try? FileManager.default.contentsOfDirectory(atPath: jobs.path) else { return }
        for name in names where UUID(uuidString: name) != nil {
            let job = jobs.appendingPathComponent(name, isDirectory: true)
            guard let journal = try? readJournal(job), journal.nonce.uuidString == name, journal.phase == .replaced,
                  journal.build == build, journal.destination == bundle.standardizedFileURL.path else { continue }
            try? write(journal.moving(to: .completed), to: job.appendingPathComponent(journalName))
        }
    }

    public struct JobSummary: Equatable, Sendable {
        public let nonce: UUID
        public let journal: UpdateJournal?
        public let location: URL
        public let bytes: Int64
    }

    /// Read-only listing for the Updates window.
    public static func jobSummaries() -> [JobSummary] {
        guard let jobs = try? jobs(), let names = try? FileManager.default.contentsOfDirectory(atPath: jobs.path) else { return [] }
        return names.compactMap { name -> JobSummary? in
            guard let nonce = UUID(uuidString: name) else { return nil }
            let job = jobs.appendingPathComponent(name, isDirectory: true)
            let journal = (try? readJournal(job)).flatMap { $0.nonce == nonce ? $0 : nil }
            return JobSummary(nonce: nonce, journal: journal, location: job, bytes: size(job))
        }
    }

    /// Whether the user may remove this job's files from the running build:
    /// a completed update whose backup is older than the running build, or a
    /// settled job that left (or restored) the running build itself. Uncertain,
    /// unknown and in-progress jobs are never removable.
    public static func isRemovable(_ journal: UpdateJournal, runningBuild: UInt64) -> Bool {
        switch journal.phase {
        case .completed: return journal.build <= runningBuild && journal.previousBuild < runningBuild
        case .rolledBack, .permissionDenied, .refused, .cancelled: return journal.previousBuild <= runningBuild
        default: return false
        }
    }

    /// Explicit user action only; never called automatically.
    @discardableResult
    public static func removeRecoveryCopies(runningBuild: UInt64) -> Int {
        var removed = 0
        for summary in jobSummaries() {
            guard let journal = summary.journal, isRemovable(journal, runningBuild: runningBuild) else { continue }
            if (try? FileManager.default.removeItem(at: summary.location)) != nil { removed += 1 }
        }
        return removed
    }

    private static func size(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink != true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
