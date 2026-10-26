import Foundation
import QuotaCore

/// Closed ZIP subset produced by `ditto -c -k --keepParent --norsrc --noextattr`.
/// Local and central records are inspected before ditto ever extracts the
/// archive: one `QuotaBar.app/` root, regular files and directories only, no
/// links, special modes, ZIP64, traversal, duplicates, gaps or overlaps.
public enum UpdateZIP {
    public static let maximumEntries = 4_096
    public static let maximumExpandedBytes = 536_870_912

    public static func inspect(_ file: URL) throws {
        let data = try UpdateFiles.read(file, maximumBytes: UpdateManifest.maximumArchiveBytes)
        let bytes = [UInt8](data)
        func value(_ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, count > 0, offset <= bytes.count - count else { throw UpdateValidationError.invalidArchive }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count >= 22 else { throw UpdateValidationError.invalidArchive }
        var end: Int?
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try value(i, 4) == 0x06054b50, i + 22 + Int(try value(i + 20, 2)) == bytes.count { end = i; break }
        }
        guard let end, try value(end + 4, 2) == 0, try value(end + 6, 2) == 0,
              try value(end + 8, 2) == value(end + 10, 2) else { throw UpdateValidationError.invalidArchive }
        let count = Int(try value(end + 10, 2)), size = Int(try value(end + 12, 4)), central = Int(try value(end + 16, 4))
        guard count > 0, count <= maximumEntries, central > 0, size <= 4_194_304, central + size == end else {
            throw UpdateValidationError.invalidArchive
        }
        func extra(_ start: Int, _ length: Int) throws {
            var i = start; let end = start + length
            guard start >= 0, end <= bytes.count else { throw UpdateValidationError.invalidArchive }
            while i < end {
                let kind = try value(i, 2), size = Int(try value(i + 2, 2))
                // No ZIP64 or Unicode path overrides that could rename an entry.
                guard kind != 1, kind != 0x7075, i + 4 + size <= end else { throw UpdateValidationError.invalidArchive }
                i += 4 + size
            }
            guard i == end else { throw UpdateValidationError.invalidArchive }
        }
        var cursor = central, names = Set<String>(), ranges: [(Int, Int)] = [], expanded = 0
        for _ in 0..<count {
            guard try value(cursor, 4) == 0x02014b50 else { throw UpdateValidationError.invalidArchive }
            let flags = try value(cursor + 8, 2), method = try value(cursor + 10, 2), crc = try value(cursor + 16, 4)
            let compressed = Int(try value(cursor + 20, 4)), unpacked = Int(try value(cursor + 24, 4))
            let nameSize = Int(try value(cursor + 28, 2)), extraSize = Int(try value(cursor + 30, 2)), comment = Int(try value(cursor + 32, 2))
            let mode = try value(cursor + 38, 4) >> 16, local = Int(try value(cursor + 42, 4))
            guard try value(cursor + 34, 2) == 0, flags & ~UInt64(0x0808) == 0,
                  method == 0 || method == 8, compressed < Int(UInt32.max), unpacked < Int(UInt32.max),
                  mode & 0o6000 == 0, [UInt64(0), 0o100000, 0o040000].contains(mode & 0o170000),
                  nameSize > 0, nameSize <= 1_024, cursor + 46 + nameSize + extraSize + comment <= end,
                  local < central else { throw UpdateValidationError.invalidArchive }
            let nameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + nameSize)])
            // Bundle names include `_CodeSignature`, so underscores are allowed.
            guard let name = String(bytes: nameBytes, encoding: .utf8),
                  name.range(of: "^[A-Za-z0-9._ /+-]+$", options: .regularExpression) != nil else { throw UpdateValidationError.invalidArchive }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            let clean = name.hasSuffix("/") ? Array(components.dropLast()) : components
            guard clean.first == "QuotaBar.app", !clean.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  names.insert(clean.joined(separator: "/").lowercased()).inserted,
                  mode & 0o170000 != 0o040000 || name.hasSuffix("/") else { throw UpdateValidationError.invalidArchive }
            expanded += unpacked
            guard expanded <= maximumExpandedBytes else { throw UpdateValidationError.invalidArchive }
            try extra(cursor + 46 + nameSize, extraSize)
            guard try value(local, 4) == 0x04034b50, try value(local + 6, 2) == flags,
                  try value(local + 8, 2) == method, Int(try value(local + 26, 2)) == nameSize else {
                throw UpdateValidationError.invalidArchive
            }
            let localExtra = Int(try value(local + 28, 2)), start = local + 30 + nameSize + localExtra
            guard start <= central, start + compressed <= central,
                  Array(bytes[(local + 30)..<(local + 30 + nameSize)]) == nameBytes else { throw UpdateValidationError.invalidArchive }
            try extra(local + 30 + nameSize, localExtra)
            var finish = start + compressed
            if flags & 8 == 0 {
                guard try value(local + 14, 4) == crc, Int(try value(local + 18, 4)) == compressed,
                      Int(try value(local + 22, 4)) == unpacked else { throw UpdateValidationError.invalidArchive }
            } else {
                if try value(finish, 4) == 0x08074b50 { finish += 4 }
                guard try value(finish, 4) == crc, Int(try value(finish + 4, 4)) == compressed,
                      Int(try value(finish + 8, 4)) == unpacked else { throw UpdateValidationError.invalidArchive }
                finish += 12
            }
            guard finish <= central else { throw UpdateValidationError.invalidArchive }
            ranges.append((local, finish)); cursor += 46 + nameSize + extraSize + comment
        }
        guard cursor == end else { throw UpdateValidationError.invalidArchive }
        var previous = 0
        for (start, finish) in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard start == previous else { throw UpdateValidationError.invalidArchive }; previous = finish
        }
        guard previous == central else { throw UpdateValidationError.invalidArchive }
    }
}
