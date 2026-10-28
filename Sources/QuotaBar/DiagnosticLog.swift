import Foundation
import Darwin
import QuotaCore

/// Best-effort diagnostics never change provider polling or its saved budget.
/// The separate lock coordinates copies; reads/clears never touch polling state.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()
    static let maximumEvents = 400
    static let maximumBytes = 262_144
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    private let directory: URL
    private let mutex = NSLock()
    private let stateName = "diagnostic-events.json"

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QuotaBar", isDirectory: true)) {
        self.directory = directory
    }

    func record(_ event: DiagnosticEvent) {
        guard event.isValid else { return }
        try? locked { fd in
            // Recover a damaged diagnostic file on the next event. It is not
            // operational state and must never prevent normal monitoring.
            let previous = (try? load(fd)) ?? []
            let events = Array((retained(previous, at: event.date) + [event]).suffix(Self.maximumEvents))
            try save(events, fd)
        }
    }

    func events(at now: Date = Date()) throws -> [DiagnosticEvent] {
        try locked { fd in
            let saved = try load(fd)
            let events = retained(saved, at: now)
            if events != saved { try save(events, fd) }
            return events
        }
    }

    func clear() throws { try locked { try save([], $0) } }

    private func retained(_ events: [DiagnosticEvent], at now: Date) -> [DiagnosticEvent] {
        // A concurrent caller may have captured an earlier timestamp before
        // acquiring the lock. Keep newer entries, also across clock rollback.
        Array(events.filter { $0.isValid && now.timeIntervalSince($0.date) < Self.retention }
            .suffix(Self.maximumEvents))
    }

    enum StoreError: Error { case unavailable, busy, invalidFile }

    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw StoreError.unavailable }
        let lock = openat(fd, "diagnostic-events.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw StoreError.unavailable }
        defer { Darwin.close(lock) }
        try validate(lock)
        guard fchmod(lock, 0o600) == 0 else { throw StoreError.unavailable }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }
        defer { flock(lock, LOCK_UN) }
        return try body(fd)
    }

    private func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & S_IFMT) == S_IFREG else { throw StoreError.invalidFile }
    }

    private func load(_ directoryFD: Int32) throws -> [DiagnosticEvent] {
        let fd = openat(directoryFD, stateName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw StoreError.unavailable
        }
        defer { Darwin.close(fd) }
        try validate(fd)
        guard fchmod(fd, 0o600) == 0 else { throw StoreError.unavailable }
        var bytes = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: total), $0.count - total) }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw StoreError.unavailable }
            total += count
        }
        guard total <= Self.maximumBytes,
              let events = try? JSONDecoder().decode([DiagnosticEvent].self, from: Data(bytes.prefix(total))),
              events.count <= Self.maximumEvents, events.allSatisfy(\.isValid) else { throw StoreError.invalidFile }
        return events
    }

    private func save(_ events: [DiagnosticEvent], _ directoryFD: Int32) throws {
        let data = try JSONEncoder().encode(events)
        guard data.count <= Self.maximumBytes else { throw StoreError.invalidFile }
        let name = ".diagnostic-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { Darwin.close(fd); unlinkat(directoryFD, name, 0) }
        try data.withUnsafeBytes { bytes in
            var total = 0
            while total < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: total), bytes.count - total)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StoreError.unavailable }
                total += count
            }
        }
        guard renameat(directoryFD, name, directoryFD, stateName) == 0 else { throw StoreError.unavailable }
    }
}
