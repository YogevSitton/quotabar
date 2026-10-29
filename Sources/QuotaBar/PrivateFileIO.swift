import Foundation
import Darwin

/// Descriptor-relative reads and atomic replacements for QuotaBar's small
/// private state files. Callers validate inodes and choose their own errors.
enum PrivateFileIO {
    /// Reads to end of file. Returns nil when the file is longer than `limit`.
    static func read(_ fd: Int32, limit: Int, failure: Error) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure
            }
            total += count
        }
        return total <= limit ? Data(bytes.prefix(total)) : nil
    }

    /// Writes a new 0600 temporary entry, syncs it, renames it over `name` and
    /// syncs the directory. The temporary entry never outlives this call.
    static func replace(_ name: String, in directoryFD: Int32, with data: Data, temporaryPrefix: String,
                        failure: Error, validate: (Int32) throws -> Void = { _ in }) throws {
        let temporaryName = "\(temporaryPrefix)\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure }
        defer {
            Darwin.close(fd)
            unlinkat(directoryFD, temporaryName, 0)
        }
        try validate(fd)
        try data.withUnsafeBytes { bytes in
            var total = 0
            while total < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: total), bytes.count - total)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure }
                total += count
            }
        }
        guard fsync(fd) == 0,
              renameat(directoryFD, temporaryName, directoryFD, name) == 0,
              fsync(directoryFD) == 0 else { throw failure }
    }
}
