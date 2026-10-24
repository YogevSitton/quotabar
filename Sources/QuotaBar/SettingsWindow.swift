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
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
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
    private var customCodexPath: String? {
        UserDefaults.standard.string(forKey: "codexPath").flatMap { $0.isEmpty ? nil : $0 }
    }
    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: state.setLogin))
            }
            if state.installation.claude {
                Section("Claude") {
                    LabeledContent("Account") {
                        Button("Switch Claude account…", action: state.switchClaudeAccount)
                    }
                }
            }
            Section("Codex") {
                LabeledContent("Codex CLI") {
                    Text(CodexProvider.executable() ?? "Not found")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(CodexProvider.executable() ?? "QuotaBar could not find the Codex CLI automatically.")
                }
                HStack {
                    Spacer()
                    if customCodexPath != nil {
                        Button("Use automatic", action: state.useAutomaticCodexPath)
                    }
                    Button("Choose…", action: state.chooseCodex)
                }
            }
            if let error = state.settingsError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }.formStyle(.grouped).frame(width: 440).fixedSize(horizontal: false, vertical: true)
    }
}
