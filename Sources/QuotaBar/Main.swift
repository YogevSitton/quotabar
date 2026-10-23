import AppKit
import SwiftUI
import QuotaCore

@main enum Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-claude") {
            let allow = CommandLine.arguments.contains("--allow-keychain")
            Task.detached {
                let result = await ClaudeProvider().read(allowInteraction: allow)
                if let value = result.snapshot {
                    print("Claude \(value.source.rawValue): 5h \(value.session?.remaining.description ?? "unavailable")% left; week \(value.weekly?.remaining.description ?? "unavailable")% left; resets \(value.resetCount?.description ?? "not reported"); sampled \(value.observedAt.ISO8601Format())")
                }
                if let error = result.error { print(error) }
                exit(result.error == nil ? 0 : 2)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--check-codex") {
            do {
                let snapshot = try CodexProvider.read()
                print("Codex: 5h \(snapshot.session?.remaining.description ?? "unavailable")% left; week \(snapshot.weekly?.remaining.description ?? "unavailable")% left; resets \(snapshot.resetCount?.description ?? "unavailable"); expiry rows \(snapshot.offers.count)")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var state: AppState!
    private var timer: Timer?
    private var dashboardWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance prevents duplicate menu items and unnecessary polling.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        state = AppState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusItem.button?.target = self; statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Dashboard(state: state))
        state.onChange = { [weak self] in self?.updateLabel() }
        updateLabel(); state.start()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--show") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showDashboard() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLabel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }
    private func updateLabel() {
        statusItem.button?.title = state.menuTitle
        statusItem.button?.toolTip = "QuotaBar · percentages remaining · C: Codex 5h/week · A: Claude 5h/week"
        statusItem.button?.setAccessibilityLabel("QuotaBar. \(state.menuTitle). Percent remaining, five hours then week.")
    }
    @objc private func woke() { state.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }
    private func showDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 690),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "QuotaBar"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: Dashboard(state: state))
            window.center(); dashboardWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); dashboardWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
