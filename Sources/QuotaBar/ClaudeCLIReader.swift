import Foundation
import QuotaCore

// Claude Code owns authentication and its usage request. QuotaBar sends control
// messages only: no user turn, prompt, tool execution, or reset request exists here.
final class ClaudeCLIReader {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var sequence = 0
    private var timeout: DispatchWorkItem?

    init(binary: URL) throws {
        process.executableURL = binary
        process.arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--no-session-persistence", "--safe-mode", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true}", "--tools", "", "--strict-mcp-config",
            "--mcp-config", "{\"mcpServers\":{}}"]
        let inherited = ProcessInfo.processInfo.environment
        let names = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR", "SHELL"]
        var environment = Dictionary(uniqueKeysWithValues: names.compactMap { key in inherited[key].map { (key, $0) } })
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        do {
            try process.run()
            let child = process
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            timeout = deadline
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: deadline)
            _ = try request("initialize", fields: ["hooks": [:]])
            let info = try request("get_binary_version")
            guard let version = info["version"] as? String,
                  version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
                  version.compare("2.1.309", options: .numeric) != .orderedAscending else {
                throw UsageError.message("Update Claude Code to 2.1.309 or later to read subscription usage through its CLI.")
            }
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
    // Keep the protocol allowlist closed even if a future caller supplies input.
    private func request(_ subtype: String, fields: [String: Any] = [:]) throws -> [String: Any] {
        guard ["initialize", "get_binary_version", "get_usage"].contains(subtype) else {
            throw UsageError.message("Unsupported Claude quota-reader operation.")
        }
        sequence += 1
        let id = "quotabar-\(sequence)"
        var payload = fields; payload["subtype"] = subtype
        try send(["type": "control_request", "request_id": id, "request": payload])
        var received = 0
        while true {
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if message["type"] as? String == "control_request", let requestID = message["request_id"] as? String {
                    try send(["type": "control_response", "response": ["subtype": "error", "request_id": requestID,
                        "error": "QuotaBar cannot authorize tools or account actions."]])
                }
                guard message["type"] as? String == "control_response",
                      let response = message["response"] as? [String: Any], response["request_id"] as? String == id else { continue }
                guard response["subtype"] as? String == "success", let result = response["response"] as? [String: Any] else {
                    throw UsageError.message("Claude Code could not return usage through its experimental CLI interface. Check your connection or update Claude Code.")
                }
                return result
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                throw UsageError.message("Claude Code ended before returning usage. Retry or update Claude Code.")
            }
            received += chunk.count
            guard received <= 2_000_000 else { throw UsageError.message("Claude Code returned an oversized quota response.") }
            buffer.append(chunk)
        }
    }
    func readUsage() throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: request("get_usage", fields: ["skip_behaviors": true]))
        // EOF lets the official CLI finish its own pending cache/config writes.
        // Killing it immediately can leave our provenance check reading old data.
        try? input.fileHandleForWriting.close()
        let child = process
        let graceDeadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: graceDeadline)
        process.waitUntilExit()
        graceDeadline.cancel()
        return data
    }
}
