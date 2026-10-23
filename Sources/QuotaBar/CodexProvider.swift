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
    // Runs on a worker queue. Only account/rateLimits/read is sent; no model calls or threads.
    static func read() throws -> UsageSnapshot {
        guard let binary = executable() else { throw UsageError.message("Locate the Codex CLI using Options → Locate Codex CLI.") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "quota_bar", "title": "QuotaBar", "version": "1.0.0"]]])
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw UsageError.message("Codex usage unavailable. Check your Codex sign-in, connection, and CLI version.") }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                if message["error"] != nil { throw UsageError.message("Codex could not read usage. Open Codex to check your sign-in, then refresh.") }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                } else if id == 2, let result = message["result"] {
                    return try UsageParser.codex(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
    }
}
