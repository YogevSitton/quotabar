import AppKit
import SwiftUI

// Rarely changed preferences live here so the popup header stays to
// Refresh, Settings and Quit.
@MainActor final class SettingsWindow {
    private let state: AppState
    private var window: NSWindow?
    init(state: AppState) { self.state = state }
    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "QuotaBar Settings"; panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: SettingsView(state: state))
            panel.center(); window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: state.setLogin))
            if let error = state.settingsError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }.formStyle(.grouped).frame(width: 360).fixedSize(horizontal: false, vertical: true)
    }
}
