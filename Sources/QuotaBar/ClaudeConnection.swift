import AppKit
import SwiftUI
import QuotaCore

@MainActor final class ClaudeConnectionModel: ObservableObject {
    @Published var busy = false
    @Published var message = "Sign in with your Claude subscription to connect live usage."
    @Published var error: String?
    @Published var waitingForBrowser = false
    @Published var loginURL: URL?
    @Published var manualCode = ""
    @Published var connected = false
    private var operation: Task<Void, Never>?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var outputBuffer = ""
    private var timeout: Task<Void, Never>?
    private let verify: () async -> String?
    init(verify: @escaping () async -> String?) { self.verify = verify }

    func prepareForPresentation() {
        guard !busy else { return }
        connected = false; error = nil
        message = "Claude Code manages your sign-in. QuotaBar asks its CLI for usage without reading your credentials."
    }
    func checkExisting() {
        guard !busy else { return }
        busy = true; error = nil; message = "Checking your existing Claude Code sign-in…"
        operation = Task {
            let problem = await verify()
            guard !Task.isCancelled else { return }
            finishVerification(problem)
        }
    }
    func signIn() {
        guard !busy else { return }
        busy = true; connected = false; error = nil; loginURL = nil
        outputBuffer = ""; manualCode = ""
        operation = Task {
            do {
                let binary = try await ClaudeHelper.prepare { [self] text in self.message = text }
                try Task.checkCancellation()
                try startLogin(binary)
            } catch {
                guard !Task.isCancelled else { return }
                busy = false; waitingForBrowser = false
                self.error = (error as? UsageError)?.localizedDescription ?? "Claude sign-in could not start. Check your connection and try again."
                message = "Ready to try again."
            }
        }
    }
    private func startLogin(_ binary: URL) throws {
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = binary; child.arguments = ["auth", "login", "--claudeai"]
        child.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        // Use the default subscription login, without inherited API keys, debug
        // output, or custom Claude configuration directories.
        let inherited = ProcessInfo.processInfo.environment
        let names = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR", "SHELL"]
        child.environment = Dictionary(uniqueKeysWithValues: names.compactMap { key in inherited[key].map { (key, $0) } })
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in self?.loginFinished(child) }
        }
        process = child; input = stdin; output = stdout
        do { try child.run() } catch { cleanupProcess(); throw error }
        waitingForBrowser = true
        message = "Finish signing in to Claude in your browser. This window will update automatically."
        timeout = Task {
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, process === child else { return }
            cancel(); error = "Sign-in timed out. Choose Sign in with Claude to try again."
        }
    }
    private func receive(_ data: Data) {
        // Hold only a bounded in-memory buffer to recover an authorization link.
        // Never show or persist raw CLI output, which may contain auth data.
        outputBuffer += String(decoding: data, as: UTF8.self)
        if outputBuffer.utf8.count > 65_536 { outputBuffer = String(outputBuffer.suffix(32_768)) }
        if loginURL == nil { loginURL = ClaudeSignInLink.first(in: outputBuffer) }
    }
    private func loginFinished(_ child: Process) {
        guard process === child else { return }
        let succeeded = child.terminationReason == .exit && child.terminationStatus == 0
        cleanupProcess(); waitingForBrowser = false; outputBuffer = ""; loginURL = nil
        guard succeeded else {
            busy = false; message = "Sign-in did not finish."
            error = "Try signing in again. Complete the Claude authorization page in your browser."
            return
        }
        message = "Signed in. Checking live Claude usage…"
        operation = Task {
            // Credential handling stays in the official CLI after login too.
            let problem = await verify()
            guard !Task.isCancelled else { return }
            finishVerification(problem)
        }
    }
    private func finishVerification(_ problem: String?) {
        busy = false; error = problem; connected = problem == nil
        message = connected ? "Claude is connected. Live usage has been refreshed." : "The connection needs attention."
    }
    func openLogin() { if let loginURL { NSWorkspace.shared.open(loginURL) } }
    func submitCode() {
        let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !code.contains("\n"), let input else { return }
        do { try input.fileHandleForWriting.write(contentsOf: Data((code + "\n").utf8)); manualCode = "" }
        catch { self.error = "The sign-in helper is no longer waiting. Start sign-in again." }
    }
    func cancel() {
        operation?.cancel(); timeout?.cancel()
        let child = process; cleanupProcess()
        if child?.isRunning == true { child?.terminate() }
        outputBuffer = ""; manualCode = ""; loginURL = nil; waitingForBrowser = false
        busy = false; message = "Sign-in cancelled. You can try again whenever you are ready."
    }
    private func cleanupProcess() {
        timeout?.cancel(); timeout = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close(); try? input?.fileHandleForWriting.close()
        process = nil; input = nil; output = nil
    }
}

private struct ClaudeConnectionView: View {
    @ObservedObject var model: ClaudeConnectionModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: model.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 30)).foregroundStyle(model.connected ? .green : .orange)
                Text("Connect Claude").font(.title2.weight(.semibold))
            }
            Text("Use your Claude Pro or Max subscription. Sign-in opens in your browser; QuotaBar checks usage when you finish.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !model.busy && !model.connected {
                Text("If needed, this downloads the official Claude Code helper into QuotaBar’s support folder (about 276 MB). No Terminal setup is required.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Sign in with Claude", action: model.signIn).buttonStyle(.borderedProminent)
                    Button("Use existing sign-in", action: model.checkExisting)
                }
            }
            if model.waitingForBrowser {
                if model.loginURL != nil { Button("Open sign-in page", action: model.openLogin) }
                DisclosureGroup("Browser gave you a code?") {
                    HStack {
                        SecureField("Authorization code", text: $model.manualCode)
                        Button("Continue", action: model.submitCode).disabled(model.manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.top, 8)
                }.font(.caption)
            }
            Divider()
            HStack {
                Link("Claude sign-in help", destination: URL(string: "https://code.claude.com/docs/en/authentication")!)
                Spacer()
                if model.busy { Button("Cancel", action: model.cancel) }
                else { Button(model.connected ? "Done" : "Close", action: close) }
            }.font(.caption)
        }.padding(26).frame(width: 510).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor final class ClaudeConnectionWindow {
    private let model: ClaudeConnectionModel
    private var window: NSWindow?
    init(verify: @escaping () async -> String?) { model = ClaudeConnectionModel(verify: verify) }
    func show() {
        model.prepareForPresentation()
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 390),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Connect Claude"; panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: ClaudeConnectionView(model: model, close: { [weak self] in self?.window?.close() }))
            panel.center(); window = panel
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
}
