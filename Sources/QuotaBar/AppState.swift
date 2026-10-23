import AppKit
import SwiftUI
import ServiceManagement
import QuotaCore

@MainActor final class AppState: ObservableObject {
    @Published var codex: UsageSnapshot?
    @Published var claude: UsageSnapshot?
    @Published var codexError: String?
    @Published var claudeError: String?
    @Published var refreshingCodex = false
    @Published var refreshingClaude = false
    @Published var interval: Double = UserDefaults.standard.object(forKey: "refreshMinutes") as? Double ?? 5
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settingsError: String?
    private let claudeProvider = ClaudeProvider()
    private var claudeConnection: ClaudeConnectionWindow?
    private var timer: Timer?
    private var localTimer: Timer?
    private var statusLineModified: Date?
    var onChange: (() -> Void)?

    func start() {
        // Migrate the former one-minute cadence to the provider's five-minute minimum.
        if interval > 0 && interval < 5 { interval = 5 }
        refresh(); schedule()
        localTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStatusLineFile() }
        }
    }
    private func checkStatusLineFile() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaBar/claude-statusline.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date, modified != statusLineModified else { return }
        statusLineModified = modified
        Task {
            guard let reading = await claudeProvider.statusLineSnapshot(), reading.observedAt > (claude?.observedAt ?? .distantPast) else { return }
            claude = reading; onChange?()
        }
    }
    func schedule() {
        timer?.invalidate(); UserDefaults.standard.set(interval, forKey: "refreshMinutes")
        guard interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        refreshClaude()
        guard !refreshingCodex else { return }; refreshingCodex = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try CodexProvider.read() }
            DispatchQueue.main.async {
                self.refreshingCodex = false
                switch result {
                case .success(let snapshot): self.codex = snapshot; self.codexError = nil
                case .failure(let error):
                    self.codexError = error.localizedDescription
                    self.codex?.source = .cached; self.codex?.sourceName = "Last live Codex reading"
                }
                self.onChange?()
            }
        }
    }
    func refreshClaude(allowInteraction: Bool = false) {
        guard !refreshingClaude else { return }; refreshingClaude = true
        Task {
            let result = await claudeProvider.read(allowInteraction: allowInteraction)
            self.claude = result.snapshot; self.claudeError = result.error
            self.refreshingClaude = false; self.onChange?()
        }
    }
    func connectClaude() {
        if claudeConnection == nil {
            claudeConnection = ClaudeConnectionWindow { [weak self] in
                guard let self else { return "The app is no longer running." }
                return await self.verifyClaudeConnection()
            }
        }
        claudeConnection?.show()
    }
    private func verifyClaudeConnection() async -> String? {
        // Opening setup is immediate, even when a background Keychain read is
        // underway. Its explicit verification waits instead of silently dropping.
        while refreshingClaude {
            if Task.isCancelled { return "Connection check cancelled." }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !Task.isCancelled else { return "Connection check cancelled." }
        refreshingClaude = true; defer { refreshingClaude = false }
        let result = await claudeProvider.read(allowInteraction: true)
        claude = result.snapshot; claudeError = result.error; onChange?()
        return result.error
    }
    var needsClaudeConnection: Bool {
        claude?.isCurrent(at: Date(), maximumAge: max(600, interval * 120), hasConnectionError: claudeError != nil) != true
    }
    func openClaude() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    func chooseCodex() {
        let panel = NSOpenPanel(); panel.title = "Locate the Codex executable"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else { settingsError = "Choose an executable Codex CLI file."; return }
            UserDefaults.standard.set(url.path, forKey: "codexPath"); refresh()
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { settingsError = "Allow QuotaBar in System Settings → General → Login Items." }
        } catch { settingsError = "Login item could not be changed: \(error.localizedDescription)" }
    }
    func openCodex() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }
    var menuTitle: String {
        func pair(_ snapshot: UsageSnapshot?, error: String?) -> String {
            guard let snapshot, snapshot.isCurrent(at: Date(), maximumAge: max(600, interval * 120), hasConnectionError: error != nil) else { return "—/—" }
            func text(_ window: UsageWindow?) -> String {
                guard let remaining = window?.currentRemaining(at: Date()) else { return "—" }
                return "\(remaining)"
            }
            return "\(text(snapshot.session))/\(text(snapshot.weekly))"
        }
        return "C \(pair(codex, error: codexError))  ·  A \(pair(claude, error: claudeError))"
    }
}
