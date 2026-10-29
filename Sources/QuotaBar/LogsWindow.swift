import AppKit
import SwiftUI
import Combine
import QuotaCore

@MainActor final class LogsWindow {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 520, height: 300)
            panel.title = "QuotaBar logs"
            panel.contentViewController = NSHostingController(rootView: LogsView())
            panel.center(); window = panel
            // Release the view on close so its refresh timer stops reading the
            // log file; the next show() builds a fresh one.
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let closeObserver = self.closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                    self.closeObserver = nil
                    self.window = nil
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct LogsView: View {
    @State private var events: [DiagnosticEvent] = []
    @State private var problem: String?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var header: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "QuotaBar \(DiagnosticEvent.isVersion(version) ? version : "-") (build \(DiagnosticEvent.isVersion(build) ? build : "-"))\nmacOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\nTimes are UTC. Newest events first.\nClaude's CLI may hide HTTP failures; cache rejection alone does not confirm rate limiting."
    }
    private var report: String { header + "\n\n" + events.reversed().map(\.line).joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local diagnostic history").font(.headline)
            Text("Keeps up to 400 events for 7 days across restarts, dropping routine successful checks before failures. No account identifiers, credentials, usage percentages or raw provider replies. Opening logs does not run a usage check.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy logs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }.disabled(problem != nil)
                Button("Clear logs") {
                    do { try DiagnosticLog.shared.clear(); problem = nil; events = [] }
                    catch { problem = "Logs could not be cleared. Try again." }
                }
                Spacer()
                Text("\(events.count) events").font(.caption).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            ScrollView([.horizontal, .vertical]) {
                Text(events.isEmpty ? header + "\n\nNo events recorded yet." : report)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
            }.background(.background, in: RoundedRectangle(cornerRadius: 6))
        }.padding(16)
            .onAppear(perform: reload)
            .onReceive(timer) { _ in reload() }
    }

    private func reload() {
        do { events = try DiagnosticLog.shared.events(); problem = nil }
        catch { problem = "Local logs are unavailable. They may be busy or unreadable. Try again shortly." }
    }
}
