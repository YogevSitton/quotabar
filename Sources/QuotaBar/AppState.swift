import AppKit
import SwiftUI
import ServiceManagement
import QuotaCore
import Combine

@MainActor final class AppState: ObservableObject {
    @Published var installation = ProviderInstallation.detect()
    @Published var codex: UsageSnapshot?
    @Published var claude: UsageSnapshot?
    @Published var codexError: String?
    @Published var claudeError: String?
    @Published var claudeIssue: ClaudeConnectionIssue?
    @Published private(set) var redeemingCodex = false
    @Published private(set) var pendingCodexReset: CodexResetAttempt?
    @Published private(set) var codexResetMessage: String?
    @Published private(set) var codexResetError: String?
    @Published private(set) var resetRecoveryError: String?
    private let resetStore = CodexResetStore()
    @Published var refreshingCodex = false
    @Published var refreshingClaude = false
    @Published var interval: Double = UserDefaults.standard.object(forKey: "refreshMinutes") as? Double ?? 1
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settingsError: String?
    private let claudeProvider = ClaudeProvider()
    @Published private(set) var claudeConnection: ClaudeConnectionWindow?
    private var claudeConnectionUpdates: AnyCancellable?
    private var providerDetails: ProviderDetailsWindow?
    private var timer: Timer?
    private var localTimer: Timer?
    private var claudeRetryTimer: Timer?
    @Published private(set) var claudeNextRequestAt: Date?
    private var statusLineModified: Date?
    var onChange: (() -> Void)?

    init() {
        do { pendingCodexReset = try resetStore.load() }
        catch { resetRecoveryError = "A saved Codex reset request could not be read. Reset actions are disabled to prevent a duplicate. Check ChatGPT Usage before repairing the recovery file." }
    }

    func start() {
        // Upgrade the old default once, preserving explicit manual/15-minute choices.
        if !UserDefaults.standard.bool(forKey: "minutePollingEnabled") {
            if interval == 5 { interval = 1 }
            UserDefaults.standard.set(true, forKey: "minutePollingEnabled")
        }
        if interval > 0 && interval < 1 { interval = 1 }
        refresh(); schedule()
        localTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStatusLineFile() }
        }
    }
    private func checkStatusLineFile() {
        guard installation.claude else { return }
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
        timer?.invalidate(); claudeRetryTimer?.invalidate()
        UserDefaults.standard.set(interval, forKey: "refreshMinutes")
        guard interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        updateInstallation()
        if installation.claude { refreshClaude() }
        guard installation.codex, !refreshingCodex, !redeemingCodex else { return }; refreshingCodex = true
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
    func refreshClaude(reconnect: Bool = false) {
        guard installation.claude, !refreshingClaude else { return }; refreshingClaude = true
        Task {
            let result = await claudeProvider.read(reconnect: reconnect, minimumInterval: max(60, interval * 60))
            self.claude = result.snapshot; self.claudeError = result.error
            self.claudeIssue = result.issue
            self.scheduleClaudeRead(result)
            self.refreshingClaude = false; self.onChange?()
        }
    }
    func retryClaude() { refreshClaude(reconnect: true) }
    private func scheduleClaudeRead(_ result: ClaudeReadResult) {
        claudeRetryTimer?.invalidate()
        claudeNextRequestAt = nil
        guard interval > 0, installation.claude, let next = result.nextRequestAt else { return }
        let delay = next > Date() ? next.timeIntervalSinceNow : max(60, interval * 60)
        claudeNextRequestAt = Date().addingTimeInterval(max(1, delay))
        // The shared periodic timer can fire just before the provider's exact
        // deadline. Schedule that deadline instead of skipping a whole minute.
        let retryTimer = Timer(timeInterval: max(1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshClaude() }
        }
        claudeRetryTimer = retryTimer
        RunLoop.main.add(retryTimer, forMode: .common)
    }
    func canUseCodexReset(_ offer: ResetOffer) -> Bool {
        guard !redeemingCodex, !refreshingCodex, pendingCodexReset == nil, resetRecoveryError == nil,
              codexError == nil, let codex else { return false }
        return (try? CodexResetAttempt.validate(snapshot: codex, creditID: offer.id)) != nil
    }
    func confirmCodexReset(_ offer: ResetOffer) {
        guard canUseCodexReset(offer), let snapshot = codex else { return }
        do {
            let attempt = try CodexResetAttempt(snapshot: snapshot, offer: offer)
            let expiry = offer.expiresAt.map { $0.formatted(.dateTime.day().month().year().hour().minute().timeZone()) } ?? "Not reported"
            let session = snapshot.session.map { "\($0.remaining)% remaining" } ?? "Unknown"
            let weekly = snapshot.weekly.map { "\($0.remaining)% remaining" } ?? "Unknown"
            guard confirmReset(title: "Use 1 saved Codex reset?",
                message: "\(offer.title)\nExpires: \(expiry)\n\n5-hour usage: \(session)\nWeekly usage: \(weekly)\n\nIf accepted by Codex, this permanently consumes one saved reset. It cannot be undone. Only this selected credit will be requested.",
                action: "Use 1 reset") else { return }
            beginCodexReset(attempt, retrying: false)
        } catch { codexResetError = error.localizedDescription }
    }
    func reviewPendingCodexReset() {
        guard !redeemingCodex, !refreshingCodex, resetRecoveryError == nil, let pending = pendingCodexReset else { return }
        guard confirmReset(title: "Resolve the saved Codex reset request?",
            message: "\(pending.title)\nStarted \(pending.createdAt.formatted(.dateTime.day().month().hour().minute()))\n\nThe previous result is uncertain. This may already have consumed one reset. Retrying sends the exact same credit and request ID; it cannot select another credit. Codex will verify the signed-in account first. Nothing is retried automatically.",
            action: "Retry same request") else { return }
        beginCodexReset(pending, retrying: true)
    }
    private func confirmReset(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = message
        // Cancel owns Return and Escape. A reset requires clicking its own button.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action).keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func beginCodexReset(_ attempt: CodexResetAttempt, retrying: Bool) {
        guard !redeemingCodex, !refreshingCodex, resetRecoveryError == nil else {
            codexResetError = "Wait for the current operation, then confirm the reset again. Nothing was sent."
            return
        }
        // The journal must be durable BEFORE the only mutating RPC can run.
        do { try resetStore.save(attempt) }
        catch {
            codexResetError = "The reset request could not be saved safely. Nothing was sent."
            return
        }
        pendingCodexReset = attempt; redeemingCodex = true
        codexResetMessage = nil; codexResetError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CodexProvider.redeem(attempt, retryingSameRequest: retrying) }
            DispatchQueue.main.async {
                self.redeemingCodex = false
                self.codex?.source = .cached
                self.codex?.sourceName = "Codex reading before reset request"
                switch result {
                case .success(let outcome):
                    self.codexResetMessage = outcome.message
                    do {
                        try self.resetStore.clear(attempt)
                        self.pendingCodexReset = nil
                    } catch {
                        self.codexResetError = "Codex returned a definite result, but the recovery record could not be cleared. Review the saved request before starting another reset."
                    }
                case .failure(let error):
                    let reason = (error as? UsageError)?.localizedDescription ?? "The reset result could not be confirmed."
                    self.codexResetError = reason + " The original request is saved. Review it to retry the same request, or check ChatGPT Usage. No automatic retry will occur."
                }
                // Refresh only reads. Never infer new balances or redeem again.
                self.onChange?(); self.refresh()
            }
        }
    }
    private func ensureClaudeConnection() -> ClaudeConnectionWindow {
        if let claudeConnection { return claudeConnection }
        let connection = ClaudeConnectionWindow { [weak self] in
            guard let self else { return ClaudeReadResult(snapshot: nil, error: "The app is no longer running.", issue: .usageUnavailable) }
            return await self.verifyClaudeConnection()
        }
        claudeConnection = connection
        claudeConnectionUpdates = connection.model.objectWillChange.sink { [weak self] in
            // Published values finish changing before the popup's size is read.
            Task { @MainActor in self?.objectWillChange.send(); self?.onChange?() }
        }
        return connection
    }
    func connectClaude() { ensureClaudeConnection().connect() }
    func manageClaudeConnection() { ensureClaudeConnection().show() }
    func showClaudeConnectionHelp() { ensureClaudeConnection().show(recheck: false) }
    var hasClaudeConnectionActivity: Bool {
        guard let model = claudeConnection?.model else { return false }
        return model.busy || (model.error != nil && (claudeError != nil || needsClaudeConnection))
    }
    var hasCodexResetNotice: Bool {
        pendingCodexReset != nil || resetRecoveryError != nil || codexResetError != nil || codexResetMessage != nil
    }
    func showDetails(for provider: String, limitsOnly: Bool = false) {
        if providerDetails == nil { providerDetails = ProviderDetailsWindow(state: self) }
        providerDetails?.show(provider: provider, limitsOnly: limitsOnly)
    }
    private func verifyClaudeConnection() async -> ClaudeReadResult {
        // Opening setup is immediate, even when a background CLI read is
        // underway. Its explicit verification waits instead of silently dropping.
        while refreshingClaude {
            if Task.isCancelled { return ClaudeReadResult(snapshot: nil, error: "Connection check cancelled.", issue: .usageUnavailable) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !Task.isCancelled else { return ClaudeReadResult(snapshot: nil, error: "Connection check cancelled.", issue: .usageUnavailable) }
        refreshingClaude = true; defer { refreshingClaude = false }
        let result = await claudeProvider.read(reconnect: true, minimumInterval: max(60, interval * 60))
        claude = result.snapshot; claudeError = result.error; claudeIssue = result.issue; onChange?()
        scheduleClaudeRead(result)
        return result
    }
    var claudeMaximumAge: TimeInterval { 120 }
    var needsClaudeConnection: Bool {
        claudeIssue?.needsConnection == true
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
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!)
    }
    func updateInstallation() {
        let detected = ProviderInstallation.detect()
        let changed = installation.codex != detected.codex || installation.claude != detected.claude
        if changed { installation = detected; onChange?() }
    }
    var menuEntries: [MenuBarEntry] {
        func entry(_ name: String, _ snapshot: UsageSnapshot?, error: String?, maximumAge: TimeInterval) -> MenuBarEntry {
            let now = Date()
            let current = snapshot?.isCurrent(at: now, maximumAge: maximumAge, hasConnectionError: error != nil) == true
            func quota(_ window: UsageWindow?) -> MenuBarQuota {
                guard current, let window, let remaining = window.currentRemaining(at: now) else {
                    return MenuBarQuota(remaining: nil, resetsAt: nil)
                }
                return MenuBarQuota(remaining: remaining, resetsAt: window.resetsAt)
            }
            return MenuBarEntry(name: name, session: quota(snapshot?.session), weekly: quota(snapshot?.weekly))
        }
        var entries: [MenuBarEntry] = []
        if installation.codex { entries.append(entry("Codex", codex, error: codexError, maximumAge: max(600, interval * 120))) }
        if installation.claude && !needsClaudeConnection {
            entries.append(entry("Claude", claude, error: claudeError, maximumAge: claudeMaximumAge))
        }
        return entries
    }
}
