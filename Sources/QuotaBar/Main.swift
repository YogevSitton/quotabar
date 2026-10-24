import AppKit
import SwiftUI
import QuotaCore

@main enum Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-claude") {
            Task.detached {
                let result = await ClaudeProvider().read()
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
    private var hostingController: NSHostingController<Dashboard>?
    private var maximumPopoverSize = NSSize.zero
    private var state: AppState!
    private var timer: Timer?
    private var outsideClickMonitor: Any?
    private var renderedMenuDescription: String?
    private var renderedMenuAppearance: NSAppearance.Name?
    private var renderedMenuProviderCount = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance prevents duplicate menu items and unnecessary polling.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.applicationIconImage = AppArtwork.icon
        state = AppState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "QuotaBar"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusItem.button?.target = self; statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        state.onChange = { [weak self] in
            self?.updateLabel()
            if self?.popover.isShown == true { self?.fitPopoverToDisplay() }
        }
        updateLabel(); state.start()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--show") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.state.updateInstallation(); self?.updateLabel()
                if self?.popover.isShown == true { self?.fitPopoverToDisplay() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let entries = state.menuEntries
        let description = entries.map(\.description).joined(separator: "; ")
        let now = Date()
        let segments = entries.map { $0.menuSegments(at: now) }
        let renderKey = description + "|" + entries.map { $0.menuLabel(at: now) }.joined(separator: "|")
        let appearance = button.effectiveAppearance
        // A provider connecting/disconnecting must not move the anchor while
        // its popup is open. Apply that width change when the popup closes.
        let canChangeImage = !popover.isShown || renderedMenuProviderCount == entries.count
        if canChangeImage && (renderedMenuDescription != renderKey || renderedMenuAppearance != appearance.name) {
            button.attributedTitle = NSAttributedString(string: "")
            if entries.isEmpty {
                let image = AppArtwork.icon.copy() as! NSImage
                image.size = NSSize(width: 20, height: 20)
                button.image = image
            } else {
                button.image = MenuBarArtwork.image(entries: entries, segments: segments, appearance: appearance)
            }
            renderedMenuDescription = renderKey
            renderedMenuAppearance = appearance.name
            renderedMenuProviderCount = entries.count
        }
        button.toolTip = entries.isEmpty
            ? "QuotaBar\nConnect an installed provider"
            : (["QuotaBar - usage remaining"] + entries.map(\.tooltipSection)).joined(separator: "\n\n")
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
        fitPopoverToDisplay()
        hostingController?.view.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
    }
    private var anchorScreen: NSScreen? {
        statusItem.button?.window?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
    }
    private func fitPopoverToDisplay() {
        guard let screen = anchorScreen else { return }
        // Reserve space for the popover arrow, border and a clear screen margin.
        let available = NSSize(width: max(1, screen.visibleFrame.width - 64),
                               height: max(1, screen.visibleFrame.height - 64))
        let dashboard = Dashboard(state: state, maximumSize: available)
        let size = dashboard.preferredSize
        if let hostingController {
            guard maximumPopoverSize != available || popover.contentSize != size else { return }
            hostingController.rootView = dashboard
            hostingController.preferredContentSize = size
            hostingController.view.setFrameSize(size)
        } else {
            let controller = NSHostingController(rootView: dashboard)
            // The dashboard owns its screen-constrained size. Do not let a
            // later intrinsic-size report trigger a second popover placement.
            controller.sizingOptions = []
            controller.preferredContentSize = size
            controller.view.setFrameSize(size)
            hostingController = controller; popover.contentViewController = controller
        }
        maximumPopoverSize = available
        popover.contentSize = size
        hostingController?.view.layoutSubtreeIfNeeded()
        // AppKit alone positions the popover within the display. Moving its
        // window manually after show fights its anchor and causes a side-step.
    }
    @objc private func displayChanged() {
        if popover.isShown { fitPopoverToDisplay() }
    }
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        updateLabel()
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }
}
