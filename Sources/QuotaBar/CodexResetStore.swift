import Foundation
import QuotaCore

// This is recovery metadata, never a queue. Loading it must not send requests.
struct CodexResetStore {
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QuotaBar")
    private var file: URL { directory.appendingPathComponent("pending-codex-reset.json") }

    func load() throws -> CodexResetAttempt? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        guard data.count < 16_384 else { throw UsageError.message("Invalid saved reset request.") }
        let attempt = try JSONDecoder().decode(CodexResetAttempt.self, from: data)
        guard !attempt.accountID.isEmpty, !attempt.creditID.isEmpty else {
            throw UsageError.message("Invalid saved reset request.")
        }
        return attempt
    }
    func save(_ attempt: CodexResetAttempt) throws {
        if let existing = try load(), existing != attempt {
            throw UsageError.message("Resolve the saved Codex reset request before starting another.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(attempt).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    func clear(_ attempt: CodexResetAttempt) throws {
        guard let saved = try load() else { return }
        guard saved == attempt else { throw UsageError.message("The saved reset request changed. Check ChatGPT Usage before continuing.") }
        try FileManager.default.removeItem(at: file)
    }
}
