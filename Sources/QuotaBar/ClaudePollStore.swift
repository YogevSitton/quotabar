import Foundation
import Darwin
import QuotaCore

/// Coordinates app copies and survives helper/app restarts. Reserve before
/// launching a helper; an interrupted attempt keeps its conservative cooldown.
public struct ClaudePollStore: Sendable {
    private let directory: URL
    private let stateName = "claude-poll-state.json"
    // This inode is never replaced: locking the state file itself would race
    // with the atomic rename used to save it.
    private let lockName = "claude-poll-state.lock"

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = home.appendingPathComponent("Library/Application Support/QuotaBar", isDirectory: true)
    }

    public init(directory: URL) { self.directory = directory }

    public func reserve(at now: Date = Date()) throws -> ClaudePollAcquisition {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0 else { throw StoreError.invalidState }
        return try locked { directoryFD in
            var previous = try load(directoryFD)
            if let saved = previous {
                let updated = saved.respectingNormalInterval()
                if updated != saved { try save(updated, directoryFD) }
                previous = updated
            }
            if let previous, now < previous.nextRequestAt { return .deferred(previous) }
            let state = ClaudePollState.reservation(after: previous, at: now)
            try save(state, directoryFD)
            return .ready(ClaudePollLease(state: state))
        }
    }

    @discardableResult
    public func complete(_ lease: ClaudePollLease, outcome: ClaudePollOutcome,
                         at now: Date = Date()) throws -> ClaudePollState {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0,
              now >= lease.startedAt else { throw StoreError.invalidState }
        if case .success(let observedAt) = outcome {
            guard observedAt.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970 > 0,
                  observedAt <= now else { throw StoreError.invalidState }
        }
        return try locked { directoryFD in
            guard let current = try load(directoryFD) else { throw StoreError.invalidState }
            // A delayed or duplicate completion must never shorten another
            // process's reservation, or turn an already failed read successful.
            guard current.requestID == lease.state.requestID, current.pending else { return current }
            let completed = current.completing(outcome, at: now)
            try save(completed, directoryFD)
            return completed
        }
    }

    public enum StoreError: Error {
        case unavailable
        case busy
        case invalidState
    }

    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw StoreError.unavailable }
        defer { Darwin.close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == getuid(),
              fchmod(directoryFD, 0o700) == 0 else { throw StoreError.unavailable }
        let lockFD = openat(directoryFD, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw StoreError.unavailable }
        defer { Darwin.close(lockFD) }
        try validateFile(lockFD)
        guard fchmod(lockFD, 0o600) == 0 else { throw StoreError.unavailable }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? StoreError.busy : StoreError.unavailable
        }
        defer { flock(lockFD, LOCK_UN) }
        return try body(directoryFD)
    }

    private func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw StoreError.unavailable }
    }

    private func load(_ directoryFD: Int32) throws -> ClaudePollState? {
        let fd = openat(directoryFD, stateName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw StoreError.unavailable
        }
        defer { Darwin.close(fd) }
        try validateFile(fd)
        guard let data = try PrivateFileIO.read(fd, limit: 4_096, failure: StoreError.unavailable),
              let state = try? JSONDecoder().decode(ClaudePollState.self, from: data),
              state.isValid else { throw StoreError.invalidState }
        return state
    }

    private func save(_ state: ClaudePollState, _ directoryFD: Int32) throws {
        guard state.isValid else { throw StoreError.invalidState }
        try PrivateFileIO.replace(stateName, in: directoryFD, with: JSONEncoder().encode(state),
                                  temporaryPrefix: ".claude-poll-", failure: StoreError.unavailable)
    }
}
