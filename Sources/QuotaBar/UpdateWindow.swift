import AppKit
import SwiftUI
import QuotaCore

// Updates live in their own small window opened from More > Updates...; the
// compact popup stays unchanged and there is no Settings window.
@MainActor final class UpdateWindow {
    private let coordinator: UpdateCoordinator
    private var window: NSWindow?
    init(coordinator: UpdateCoordinator) { self.coordinator = coordinator }

    func show() {
        coordinator.refreshRecovery()
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 400, height: 320)
            panel.title = "QuotaBar updates"
            panel.contentViewController = NSHostingController(rootView: UpdatesView(coordinator: coordinator))
            panel.center(); window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct UpdatesView: View {
    @ObservedObject var coordinator: UpdateCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("QuotaBar \(coordinator.installed.displayVersion) (build \(coordinator.installed.build))")
                        .font(.headline)
                    Text(coordinator.installed.releaseMode ? "Downloaded release" : "Built from source")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if coordinator.status == .notConfigured {
                    Text("This build has no update key, so it cannot check for updates. Download a release to receive updates.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Releases") { coordinator.openReleases() }
                } else {
                    Picker("Channel", selection: $coordinator.channel) {
                        Text("Stable").tag(UpdateChannel.stable)
                        Text("Preview").tag(UpdateChannel.preview)
                    }.pickerStyle(.segmented).frame(maxWidth: 260).disabled(isBusy)
                    Text(coordinator.channel == .stable
                         ? "Stable gets builds the maintainer selects. It is the default."
                         : "Preview follows changes merged into main. Builds are public but less tested.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Check for updates automatically", isOn: $coordinator.automaticChecks)
                    Toggle("Download updates automatically", isOn: $coordinator.automaticDownloads)
                        .disabled(!coordinator.canDownloadAndInstall)
                    statusSection
                    if let note = coordinator.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = coordinator.locationProblem {
                        Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Check for Updates") { coordinator.checkNow() }
                            .disabled(isBusy)
                        if let last = coordinator.lastCheck {
                            Text("Last checked \(last.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let notice = coordinator.transactionNotice {
                    Divider()
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                }
                if !coordinator.recovery.isEmpty {
                    Divider()
                    recoverySection
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isBusy: Bool {
        switch coordinator.status {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch coordinator.status {
        case .notConfigured, .idle:
            Text("No check has run yet.").foregroundStyle(.secondary)
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking...") }
        case .upToDate:
            Text("QuotaBar is up to date.")
        case .unavailable(let message):
            Text(message)
        case .available(let manifest):
            Text("\(describe(manifest)) is available.")
            if coordinator.canDownloadAndInstall {
                Button("Download") { coordinator.downloadNow() }
            } else {
                Text("Builds made from source do not install updates. Download the release instead.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Releases") { coordinator.openReleases() }
            }
        case .downloading(let manifest):
            HStack { ProgressView().controlSize(.small); Text("Downloading and verifying \(describe(manifest))...") }
        case .ready(let manifest):
            Text("\(describe(manifest)) is downloaded and verified.")
            Text("Installing quits QuotaBar, replaces it and opens the new version. macOS may ask you to allow QuotaBar to manage apps.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Install and Relaunch") { coordinator.install(manifest) }
                .disabled(!coordinator.canInstall)
                .keyboardShortcut(.defaultAction)
        case .installing(let manifest):
            HStack { ProgressView().controlSize(.small); Text("Preparing \(describe(manifest))...") }
        case .failed(let message):
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recovery copies").font(.subheadline.weight(.semibold))
            let total = coordinator.recovery.reduce(Int64(0)) { $0 + $1.bytes }
            Text("\(coordinator.recovery.count) saved update \(coordinator.recovery.count == 1 ? "folder" : "folders"), \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Show in Finder") { coordinator.revealRecovery() }
                Button("Remove recovery copies") { coordinator.removeRecoveryCopies() }
                    .disabled(!coordinator.removableRecovery)
                    .help("Removes only finished updates. Copies from an uncertain update are always kept.")
            }
        }
    }

    private func describe(_ manifest: UpdateManifest) -> String {
        manifest.channel == .stable
            ? "QuotaBar \(manifest.displayVersion) (build \(manifest.build))"
            : "Preview build \(manifest.build) (\(manifest.displayVersion))"
    }
}
