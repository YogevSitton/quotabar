import AppKit
import SwiftUI
import QuotaCore
import QuotaUpdateSupport

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
    private var updates: UpdateCoordinator!
    private var updateWindow: UpdateWindow!
    private var timer: Timer?
    private var outsideClickMonitor: Any?
    private var renderedMenuDescription: String?
    private var renderedMenuAppearance: NSAppearance.Name?
    private var renderedMenuChips: [MenuBarResetChip?]?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance prevents duplicate menu items and unnecessary polling.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.applicationIconImage = AppArtwork.icon
        // Confirms a just-finished update for this exact app and build. It
        // only records the acknowledgment; startup never installs anything.
        if let build = UInt64(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") {
            UpdateInstallation.acknowledgeLaunch(bundle: Bundle.main.bundleURL, build: build)
        }
        state = AppState()
        updates = UpdateCoordinator()
        updateWindow = UpdateWindow(coordinator: updates)
        state.showUpdates = { [weak self] in
            self?.popover.performClose(nil)
            self?.updateWindow.show()
        }
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
        updateLabel(); state.start(); updates.start()
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
        let now = Date()
        let description = entries.map { $0.description(at: now) }.joined(separator: "; ")
        let segments = entries.map { $0.menuSegments(at: now) }
        let chips = entries.map { $0.resetChip(at: now) }
        let renderKey = description + "|" + entries.map { $0.menuLabel(at: now) }.joined(separator: "|")
        let appearance = button.effectiveAppearance
        // The expiry tint can advance while the rounded countdown stays the same.
        if renderedMenuDescription != renderKey || renderedMenuAppearance != appearance.name || renderedMenuChips != chips {
            let image: NSImage
            if entries.isEmpty {
                image = AppArtwork.icon.copy() as! NSImage
                image.size = NSSize(width: 20, height: 20)
            } else {
                image = MenuBarArtwork.image(entries: entries, segments: segments, chips: chips, appearance: appearance)
            }
            // The item fits its content, so a width change must not move the
            // anchor while the popup is open. Apply it when the popup closes.
            if !popover.isShown || button.image?.size.width == image.size.width {
                button.attributedTitle = NSAttributedString(string: "")
                button.image = image
                renderedMenuDescription = renderKey
                renderedMenuAppearance = appearance.name
                renderedMenuChips = chips
            }
        }
        button.toolTip = entries.isEmpty
            ? "QuotaBar\nConnect an installed provider"
            : (["QuotaBar - usage remaining"] + entries.map { $0.tooltipSection(at: now) }).joined(separator: "\n\n")
        let expiring = zip(entries, chips).compactMap { entry, chip in chip.map { " \(entry.name) reset expires in \($0.spoken)." } }
        button.setAccessibilityLabel("QuotaBar. \(description). Percent remaining." + expiring.joined())
    }
    @objc private func woke() { state.refresh(); updates.didWake() }
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
        var dashboard = Dashboard(state: state, maximumSize: available)
        // Measure the laid-out content once, then fix that height so AppKit
        // places the popup from a precomputed size.
        let natural = NSHostingController(rootView: dashboard.fixedSize(horizontal: false, vertical: true))
            .sizeThatFits(in: NSSize(width: dashboard.contentWidth, height: available.height)).height
        let size = NSSize(width: dashboard.contentWidth, height: min(available.height, ceil(natural)))
        dashboard.fixedHeight = size.height
        if let hostingController {
            guard maximumPopoverSize != available || popover.contentSize != size else { return }
            hostingController.rootView = dashboard
            hostingController.preferredContentSize = size
            // While open, NSPopover resizes its own content view; setting the
            // frame directly leaves its chrome at the old height.
            if !popover.isShown { hostingController.view.setFrameSize(size) }
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
