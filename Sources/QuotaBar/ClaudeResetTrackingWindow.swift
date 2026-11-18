import AppKit
import SwiftUI
import QuotaCore

@MainActor final class ClaudeResetTrackingWindow {
    private var window: NSWindow?

    func show(reset: TrackedClaudeReset?, save: @escaping (TrackedClaudeReset?) async throws -> Void) {
        if window?.isVisible != true {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.title = "Track a Claude reset"
            panel.contentViewController = NSHostingController(rootView: ClaudeResetTrackingEditor(
                reset: reset, save: save, close: { [weak panel] in panel?.close() }))
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ClaudeResetTrackingEditor: View {
    @State private var kind: TrackedClaudeReset.Kind
    @State private var expiry: Date
    @State private var saving = false
    @State private var error: String?
    let isEditing: Bool
    let save: (TrackedClaudeReset?) async throws -> Void
    let close: () -> Void

    init(reset: TrackedClaudeReset?, save: @escaping (TrackedClaudeReset?) async throws -> Void, close: @escaping () -> Void) {
        _kind = State(initialValue: reset?.kind ?? .full)
        _expiry = State(initialValue: reset?.expiresAt ?? Date().addingTimeInterval(86400))
        isEditing = reset != nil
        self.save = save
        self.close = close
    }

    private var expiryMinute: Date { Calendar.current.dateInterval(of: .minute, for: expiry)?.start ?? expiry }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the type and expiry shown in Claude Usage. Stop tracking the reset here if you use it on Claude.")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Reset type", selection: $kind) {
                ForEach(TrackedClaudeReset.Kind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }.disabled(saving)
            DatePicker("Expiry", selection: $expiry, displayedComponents: [.date, .hourAndMinute])
                .disabled(saving)
            Text("Time zone \(TimeZone.current.abbreviation(for: expiry) ?? TimeZone.current.identifier)")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isEditing { Button("Stop tracking") { update(nil) }.disabled(saving) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") { update(TrackedClaudeReset(kind: kind, expiresAt: expiryMinute)) }
                    .keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(16).frame(width: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }

    private func update(_ reset: TrackedClaudeReset?) {
        saving = true
        error = nil
        Task { @MainActor in
            do {
                try await save(reset)
                close()
            } catch {
                self.error = (error as? UsageError)?.localizedDescription ?? "The reset reminder could not be saved."
                saving = false
            }
        }
    }
}
