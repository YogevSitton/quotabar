import AppKit

struct ProviderInstallation {
    let codex: Bool
    let claude: Bool
    var antigravity: Bool = false

    var count: Int { [codex, claude, antigravity].filter { $0 }.count }

    static func detect() -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func app(_ name: String, identifiers: [String]) -> Bool {
            identifiers.contains {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
                || [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
                    .contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(name).app").path) }
        }
        let claudePaths = [home.appendingPathComponent(".local/bin/claude").path,
                           "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return Self(
            codex: CodexProvider.executable() != nil || app("Codex", identifiers: ["com.openai.codex"]),
            claude: app("Claude", identifiers: ["com.anthropic.claudefordesktop"])
                || claudePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
                || ClaudeHelper.managedExecutable() != nil,
            antigravity: app("Antigravity", identifiers: ["com.google.antigravity"])
                || FileManager.default.fileExists(atPath: AntigravityHelper.executable.path)
                || AntigravityHelper.installedCandidates.contains { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}
