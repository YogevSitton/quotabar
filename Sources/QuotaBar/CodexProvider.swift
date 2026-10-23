import Foundation
import QuotaCore

enum CodexProvider {
    static func executable() -> String? {
        let custom = UserDefaults.standard.string(forKey: "codexPath") ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [custom,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
    // Polling uses only read RPCs. Redemption has a separate, explicit entry point.
    static func read() throws -> UsageSnapshot {
        try read(using: CodexSession())
    }
    private static func read(using session: CodexSession) throws -> UsageSnapshot {
        var snapshot = try UsageParser.codex(session.request("account/rateLimits/read"))
        // Account lookup is optional for monitoring, mandatory for redemption.
        if snapshot.accountID == nil,
           let data = try? session.request("account/read", parameters: ["refreshToken": false]) {
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let account = root["account"] as? [String: Any], account["type"] as? String == "chatgpt" {
                snapshot.accountID = account["id"] as? String
            }
        }
        return snapshot
    }
    static func redeem(_ attempt: CodexResetAttempt, retryingSameRequest: Bool) throws -> CodexResetOutcome {
        let session = try CodexSession()
        let current = try read(using: session)
        guard current.accountID == attempt.accountID else {
            throw UsageError.message("The signed-in Codex account changed. Switch back to the original account to resolve this reset request.")
        }
        if !retryingSameRequest {
            try CodexResetAttempt.validate(snapshot: current, creditID: attempt.creditID)
        }
        // Recovery must permit an already-removed credit: the previous request
        // may have succeeded. The same creditId AND idempotencyKey are mandatory.
        let result = try session.request("account/rateLimitResetCredit/consume", parameters: attempt.parameters)
        return try CodexResetOutcome.parse(result)
    }
}

// One initialized process per operation; never automatically replay a mutation.
private final class CodexSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var sequence = 0
    private var timeout: DispatchWorkItem?

    init() throws {
        guard let binary = CodexProvider.executable() else {
            throw UsageError.message("Locate the Codex CLI using Options → Locate Codex CLI.")
        }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        do {
            try process.run()
            let process = self.process
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            timeout = deadline
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: deadline)
            _ = try request("initialize", parameters: ["clientInfo": ["name": "quota_bar", "title": "QuotaBar", "version": "1.6.0"]])
            try send(["method": "initialized", "params": [:]])
        } catch { close(); throw error }
    }
    deinit { close() }
    private func close() {
        timeout?.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }
    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func request(_ method: String, parameters: [String: Any] = [:]) throws -> Data {
        sequence += 1
        let expected = sequence
        try send(["id": expected, "method": method, "params": parameters])
        while true {
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["id"] as? Int == expected else { continue }
                if message["error"] != nil {
                    throw UsageError.message("Codex could not complete this request. Check your sign-in and CLI version. Reset requests remain saved until a definite result is known.")
                }
                if let result = message["result"] {
                    return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
                }
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                throw UsageError.message("Codex did not return a complete response. Check your connection. A pending reset is never retried automatically.")
            }
            buffer.append(chunk)
            guard buffer.count <= 4_000_000 else { throw UsageError.message("Codex returned an oversized response.") }
        }
    }
}
