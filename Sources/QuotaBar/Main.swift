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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var state: AppState!
    private var timer: Timer?
    private var outsideClickMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance prevents duplicate menu items and unnecessary polling.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.applicationIconImage = AppArtwork.icon
        state = AppState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusItem.button?.target = self; statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Dashboard(state: state))
        state.onChange = { [weak self] in self?.updateLabel() }
        updateLabel(); state.start()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--show") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.state.updateInstallation(); self?.updateLabel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }
    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString()
        let entries = state.menuEntries
        for (index, entry) in entries.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "   ·   ")) }
            let image = ProviderArtwork.image(for: entry.name)
            let attachment = NSTextAttachment()
            image.size = NSSize(width: 20, height: 20)
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -5, width: 20, height: 20)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " \(entry.text)"))
        }
        let description = entries.map { "\($0.name): \($0.text)" }.joined(separator: "; ")
        if entries.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            let image = AppArtwork.icon.copy() as! NSImage
            image.size = NSSize(width: 20, height: 20)
            button.image = image
        } else {
            button.image = nil
            title.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), range: NSRange(location: 0, length: title.length))
            button.attributedTitle = title
        }
        button.toolTip = description.isEmpty ? "QuotaBar · connect an installed provider" : "QuotaBar · percentages remaining · \(description)"
        button.setAccessibilityLabel("QuotaBar. \(description). Percent remaining.")
    }
    @objc private func woke() { state.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }
    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        state.updateInstallation()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
    }
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }
}
