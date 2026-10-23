import Foundation

enum ClaudeConnectionIssue: Equatable {
    case helperMissing, signInRequired, subscriptionRequired, usageUnavailable
    var needsSignIn: Bool { self == .signInRequired || self == .subscriptionRequired }
    var needsConnection: Bool { self == .helperMissing || needsSignIn }
}

// Ask the official CLI about its own authentication. Never inspect credentials,
// print raw output, or start login from a status/usage check.
enum ClaudeAuthStatus {
    case signedIn, signedOut, otherAuthentication, unknown

    static func read(binary: URL) -> Self {
        let child = Process(), output = Pipe()
        child.executableURL = binary
        child.arguments = ["--safe-mode", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}", "auth", "status"]
        child.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let inherited = ProcessInfo.processInfo.environment
        let names = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR", "SHELL"]
        var environment = Dictionary(uniqueKeysWithValues: names.compactMap { key in inherited[key].map { (key, $0) } })
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return .unknown }
        let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer {
            deadline.cancel()
            if child.isRunning { child.terminate() }
            try? output.fileHandleForReading.close()
        }
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            guard data.count + chunk.count <= 65_536 else { return .unknown }
            data.append(chunk)
        }
        child.waitUntilExit()
        guard child.terminationReason == .exit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = root["authMethod"] as? String else { return .unknown }
        switch (child.terminationStatus, method) {
        case (0, "claude.ai"): return .signedIn
        case (1, "none"): return .signedOut
        case (0, "api_key"), (0, "api_key_helper"), (0, "third_party"), (0, "oauth_token"): return .otherAuthentication
        default: return .unknown
        }
    }
}
