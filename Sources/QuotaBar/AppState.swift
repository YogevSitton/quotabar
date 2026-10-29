import AppKit
import SwiftUI
import ServiceManagement
import QuotaCore
import Combine

@MainActor final class AppState: ObservableObject {
    @Published var installation: ProviderInstallation
    @Published var codex: UsageSnapshot?
    @Published var claude: UsageSnapshot?
    @Published var codexError: String?
    @Published var claudeError: String?
    @Published var claudeIssue: ClaudeConnectionIssue?
    @Published var antigravity: AntigravitySnapshot?
    @Published var antigravityError: String?
    @Published var antigravityIssue: AntigravityConnectionIssue?
    @Published private(set) var antigravityNextRequestAt: Date?
    @Published private(set) var refreshingAntigravity = false
    @Published var selectedAntigravityGroupName: String? {
        didSet {
            if storesPreferences { UserDefaults.standard.set(selectedAntigravityGroupName, forKey: "antigravityQuotaGroup") }
            onChange?()
        }
    }
    private let storesPreferences: Bool
    @Published private(set) var antigravityConnection: AntigravityConnection?
    private var antigravityConnectionUpdates: AnyCancellable?
    private var antigravityRetryTimer: Timer?
    @Published private(set) var redeemingCodex = false
    @Published private(set) var pendingCodexReset: CodexResetAttempt?
    @Published private(set) var codexResetMessage: String?
    @Published private(set) var codexResetError: String?
    @Published private(set) var resetRecoveryError: String?
    private let resetStore = CodexResetStore()
    @Published var refreshingCodex = false
    @Published var refreshingClaude = false
    // Codex and installation checks run every minute. Claude enforces its
    // separate, durable polling budget and schedules its exact next deadline.
    let interval: Double = 1
    @Published var launchAtLogin: Bool
    @Published var settingsError: String?
    /// Opens the separate Updates window; set by the app delegate.
    var showUpdates: () -> Void = {}
    var showLogs: () -> Void = {}
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

    // Offline documentation renders opt out of local recovery/preferences and
    // never call start(), connection methods or any provider controls.
    init(loadLocalState: Bool = true) {
        storesPreferences = loadLocalState
        installation = loadLocalState ? ProviderInstallation.detect() : ProviderInstallation(codex: false, claude: false)
        launchAtLogin = loadLocalState && SMAppService.mainApp.status == .enabled
        guard loadLocalState else { return }
        selectedAntigravityGroupName = UserDefaults.standard.string(forKey: "antigravityQuotaGroup")
        do { pendingCodexReset = try resetStore.load() }
        catch { resetRecoveryError = "A saved Codex reset request could not be read. Reset actions are disabled to prevent a duplicate. Check ChatGPT Usage before repairing the recovery file." }
    }

    func start() {
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
        guard interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        updateInstallation()
        if installation.claude { refreshClaude() }
        if installation.antigravity { refreshAntigravity() }
        guard installation.codex, !refreshingCodex, !redeemingCodex else { return }; refreshingCodex = true
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            let result = Result { try CodexProvider.read() }
            DiagnosticLog.shared.record(DiagnosticEvent(area: .codex,
                kind: (try? result.get()) == nil ? .readFailed : .readSucceeded,
                durationMS: DiagnosticEvent.durationMS(from: started)))
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
            let result = await claudeProvider.read(reconnect: reconnect)
            self.claude = result.snapshot; self.claudeError = result.error
            self.claudeIssue = result.issue
            self.scheduleClaudeRead(result)
            self.refreshingClaude = false; self.onChange?()
        }
    }
    func retryClaude() {
        DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .retryRequested))
        refreshClaude(reconnect: true)
    }

    var antigravityMaximumAge: TimeInterval { AntigravityProvider.maximumAge }
    var selectedAntigravityGroup: AntigravityQuotaGroup? {
        antigravity?.selectedGroup(named: selectedAntigravityGroupName)
    }
    /// Polling waits for an explicit action: Connect for setup and sign-in,
    /// Retry for an unverifiable private profile.
    var antigravityStopped: Bool {
        antigravityIssue == .helperMissing || antigravityIssue == .signInRequired || antigravityIssue == .profileUnavailable
    }
    func refreshAntigravity() {
        guard installation.antigravity, !refreshingAntigravity, antigravityConnection?.busy != true,
              antigravityNextRequestAt.map({ $0 <= Date() }) ?? true, !antigravityStopped else { return }
        refreshingAntigravity = true
        DispatchQueue.global(qos: .utility).async {
            let result = AntigravityProvider.read()
            DispatchQueue.main.async {
                self.refreshingAntigravity = false
                self.applyAntigravity(result)
            }
        }
    }
    func retryAntigravity() {
        if antigravityIssue == .profileUnavailable { antigravityIssue = nil }
        refreshAntigravity()
    }
    func applyAntigravity(_ result: AntigravityReadResult) {
        antigravityRetryTimer?.invalidate(); antigravityNextRequestAt = nil
        switch result {
        case .success(let snapshot, let next):
            antigravity = snapshot; antigravityError = nil; antigravityIssue = nil
            antigravityNextRequestAt = next
        case .deferred(let next): antigravityNextRequestAt = next
        case .failure(let message, let issue, let next):
            antigravityError = message; antigravityIssue = issue; antigravityNextRequestAt = next
            if issue == .signInRequired || issue == .helperMissing { antigravity = nil }
            else { antigravity?.source = .cached }
        }
        scheduleAntigravityDeadline()
        onChange?()
    }
    private func scheduleAntigravityDeadline() {
        antigravityRetryTimer?.invalidate()
        guard interval > 0, let next = antigravityNextRequestAt else { return }
        let timer = Timer(timeInterval: max(1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.antigravityDeadlinePassed() }
        }
        antigravityRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func antigravityDeadlinePassed() {
        guard let next = antigravityNextRequestAt else { return }
        guard next <= Date() else { return scheduleAntigravityDeadline() }
        // Publish the passed deadline so Connect re-enables now rather than at
        // the popup's next 30-second tick. This never starts sign-in: refresh
        // reads without login input and stays idle while monitoring is stopped.
        antigravityNextRequestAt = nil
        refreshAntigravity()
        onChange?()
    }
    func connectAntigravity() {
        guard antigravityConnection?.busy != true, !refreshingAntigravity else { return }
        if antigravityConnection == nil {
            let connection = AntigravityConnection { [weak self] result in
                self?.updateInstallation(); self?.applyAntigravity(result)
            }
            antigravityConnection = connection
            antigravityConnectionUpdates = connection.objectWillChange.sink { [weak self] in
                Task { @MainActor in self?.objectWillChange.send(); self?.onChange?() }
            }
        }
        antigravity = nil; antigravityIssue = nil; antigravityError = nil
        antigravityNextRequestAt = nil; antigravityRetryTimer?.invalidate()
        antigravityConnection?.connect()
        onChange?()
    }
    func openAntigravity() {
        NSWorkspace.shared.open(URL(string: "https://antigravity.google/docs/cli/commands/usage")!)
    }
    private func scheduleClaudeRead(_ result: ClaudeReadResult) {
        claudeRetryTimer?.invalidate()
        claudeNextRequestAt = nil
        guard interval > 0, installation.claude, let next = result.nextRequestAt else { return }
        let now = Date()
        let delay = max(1, next.timeIntervalSince(now))
        claudeNextRequestAt = now.addingTimeInterval(delay)
        // The shared periodic timer can fire just before the provider's exact
        // deadline. Schedule that deadline instead of skipping a whole minute.
        let retryTimer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
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
            let session = snapshot.sessionLimit == .noLimit ? "No 5-hour limit"
                : snapshot.session.map { "\($0.remaining)% remaining" } ?? "Unknown"
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
    func connectClaude() {
        DiagnosticLog.shared.record(DiagnosticEvent(area: .claude, kind: .connectionRequested))
        ensureClaudeConnection().connect()
    }
    func showClaudeConnectionHelp() { ensureClaudeConnection().show(recheck: false) }
    var hasClaudeConnectionActivity: Bool {
        guard let model = claudeConnection?.model else { return false }
        return model.busy || (model.error != nil && (claudeError != nil || needsClaudeConnection))
    }
    var hasCodexResetNotice: Bool {
        pendingCodexReset != nil || resetRecoveryError != nil || codexResetError != nil || codexResetMessage != nil
    }
    func showDetails(for provider: Provider) {
        if providerDetails == nil { providerDetails = ProviderDetailsWindow(state: self) }
        providerDetails?.show(provider: provider)
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
        let result = await claudeProvider.read(reconnect: true)
        claude = result.snapshot; claudeError = result.error; claudeIssue = result.issue; onChange?()
        scheduleClaudeRead(result)
        return result
    }
    var claudeMaximumAge: TimeInterval { ClaudeRefreshPolicy.maximumDisplayAge }
    var needsClaudeConnection: Bool {
        claudeIssue?.needsConnection == true
    }
    func openClaude() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { settingsError = "Allow QuotaBar in System Settings → General → Login Items." }
        } catch {
            DiagnosticLog.shared.record(DiagnosticEvent(area: .app, kind: .loginSettingFailed))
            settingsError = "Login item could not be changed: \(error.localizedDescription)"
        }
    }
    func openCodex() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!)
    }
    func updateInstallation() {
        let detected = ProviderInstallation.detect()
        let changed = installation.codex != detected.codex || installation.claude != detected.claude || installation.antigravity != detected.antigravity
        if changed {
            installation = detected; onChange?()
            DiagnosticLog.shared.record(DiagnosticEvent(area: .app, kind: .installationChanged))
        }
    }
    var menuEntries: [MenuBarEntry] {
        func entry(_ provider: Provider, _ snapshot: UsageSnapshot?, error: String?, maximumAge: TimeInterval) -> MenuBarEntry {
            let now = Date()
            let current = snapshot?.isCurrent(at: now, maximumAge: maximumAge, hasConnectionError: error != nil) == true
            func quota(_ limit: UsageLimit) -> MenuBarQuota {
                MenuBarQuota(limit: current ? limit.current(at: now) : .unavailable)
            }
            let session = snapshot?.currentSessionLimit(at: now, maximumAge: maximumAge, hasConnectionError: error != nil) ?? .unavailable
            let expiry = current && snapshot?.showsResetCredits == true ? snapshot?.nextResetExpiry(at: now) : nil
            return MenuBarEntry(provider: provider, session: MenuBarQuota(limit: session),
                                weekly: quota(snapshot?.weekly.map { .limited($0) } ?? .unavailable), nextResetExpiry: expiry)
        }
        var entries: [MenuBarEntry] = []
        if installation.codex { entries.append(entry(.codex, codex, error: codexError, maximumAge: max(600, interval * 120))) }
        if installation.claude && !needsClaudeConnection {
            entries.append(entry(.claude, claude, error: claudeError, maximumAge: claudeMaximumAge))
        }
        if installation.antigravity, !antigravityStopped {
            let now = Date()
            let current = antigravity?.isCurrent(at: now, maximumAge: antigravityMaximumAge, hasConnectionError: antigravityError != nil) == true
            let group = selectedAntigravityGroup
            func quota(_ window: UsageWindow?) -> MenuBarQuota {
                MenuBarQuota(limit: current ? (window.map { .limited($0).current(at: now) } ?? .unavailable) : .unavailable)
            }
            entries.append(MenuBarEntry(provider: .antigravity, session: quota(group?.session), weekly: quota(group?.weekly), quotaGroup: group?.name))
        }
        return entries
    }
}
