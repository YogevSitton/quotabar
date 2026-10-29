import AppKit
import SwiftUI

// Long descriptions and arbitrary inventories belong in a resizable window;
// the menu popup itself never scrolls or expands its disclosure sections.
@MainActor final class ProviderDetailsWindow {
    private let state: AppState
    private var window: NSWindow?
    init(state: AppState) { self.state = state }
    func show(provider: Provider) {
        let view = ProviderDetailsView(state: state, provider: provider)
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let height = min(700, (NSScreen.main?.visibleFrame.height ?? 800) - 100)
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 380, height: 260)
            panel.contentViewController = NSHostingController(rootView: view)
            panel.center(); window = panel
        }
        window?.title = "\(provider.rawValue) usage details"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ProviderDetailsView: View {
    @ObservedObject var state: AppState
    let provider: Provider
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch provider {
                    case .antigravity:
                        AntigravityDetailsView(state: state, now: context.date)
                    case .claude:
                        ProviderCard(provider: .claude, color: .orange, snapshot: state.claude,
                            error: state.claudeError, now: context.date, staleAfter: state.claudeMaximumAge, open: state.openClaude)
                    case .codex:
                        ProviderCard(provider: .codex, color: .teal, snapshot: state.codex,
                            error: state.codexError, now: context.date, staleAfter: max(600, state.interval * 120), open: state.openCodex,
                            canReset: state.canUseCodexReset, useReset: state.confirmCodexReset)
                        CodexResetStatus(state: state)
                    }
                }.padding(16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
