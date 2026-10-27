import AppKit
import Foundation
import QuotaCore
import QuotaUpdateSupport

/// Checks the signed public feeds about hourly, stages a verified update, and
/// installs only when the user clicks Install and Relaunch for that exact build
/// (docs/UPDATES.md). Launch, wake, channel changes, permission changes and saved
/// journals never install anything.
@MainActor final class UpdateCoordinator: ObservableObject {
    enum Status: Equatable {
        case notConfigured
        case idle
        case checking
        case upToDate
        case unavailable(String)
        case available(UpdateManifest)
        case downloading(UpdateManifest)
        case ready(UpdateManifest)
        case installing(UpdateManifest)
        case failed(String)
    }

    struct Installed: Sendable {
        let displayVersion: String
        let build: UInt64
        let releaseMode: Bool
        let publicKey: String
        let bundle: URL

        static var current: Installed {
            let info = Bundle.main.infoDictionary ?? [:]
            return Installed(displayVersion: info["CFBundleShortVersionString"] as? String ?? "-",
                             build: UInt64(info["CFBundleVersion"] as? String ?? "") ?? 0,
                             releaseMode: info[UpdateBundleKey.mode] as? String == UpdateBundleKey.releaseMode,
                             publicKey: info[UpdateBundleKey.publicKey] as? String ?? "",
                             bundle: Bundle.main.bundleURL.standardizedFileURL)
        }
    }

    static let releasesPage = URL(string: "https://github.com/YogevSitton/quotabar/releases")!
    private enum Key {
        static let channel = "updateChannel", checks = "updateAutomaticChecks", downloads = "updateAutomaticDownloads"
    }

    let installed = Installed.current
    @Published private(set) var status: Status = .idle
    @Published private(set) var note: String?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var nextCheck: Date?
    @Published private(set) var recovery: [UpdateInstallation.JobSummary] = []
    @Published private(set) var transactionNotice: String?
    @Published var channel: UpdateChannel {
        didSet { UserDefaults.standard.set(channel.rawValue, forKey: Key.channel); if channel != oldValue { channelChanged() } }
    }
    @Published var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: Key.checks); scheduleNext(after: UpdateSchedule.regularDelay(random: .random(in: 0...1))) }
    }
    @Published var automaticDownloads: Bool {
        didSet { UserDefaults.standard.set(automaticDownloads, forKey: Key.downloads) }
    }

    private let client = UpdateFeedClient()
    private var timer: Timer?
    private var lastAttempt: Date?
    /// One wait state for feed checks and archive downloads alike.
    private var retry = UpdateRetryState()
    private var highWater = UpdateHighWater()
    private var highWaterUnreadable = false
    private var envelopes: [UpdateChannel: Data] = [:]

    init() {
        let defaults = UserDefaults.standard
        channel = UpdateChannel(rawValue: defaults.string(forKey: Key.channel) ?? "") ?? .stable
        automaticChecks = defaults.object(forKey: Key.checks) as? Bool ?? true
        automaticDownloads = defaults.object(forKey: Key.downloads) as? Bool ?? true
        if installed.publicKey.isEmpty { status = .notConfigured }
        loadHighWater()
        refreshRecovery()
    }

    // MARK: Capabilities

    var canDownloadAndInstall: Bool { installed.releaseMode && !installed.publicKey.isEmpty }

    /// Install needs the app at exactly /Applications or ~/Applications, not a
    /// translocated or downloaded copy. Returns guidance when it is elsewhere.
    var locationProblem: String? {
        guard canDownloadAndInstall else { return nil }
        do { try UpdateInstallation.destination(installed.bundle); return nil }
        catch {
            return "To install updates, quit QuotaBar, move QuotaBar.app into Applications (or ~/Applications) and open it from there."
        }
    }

    var canInstall: Bool {
        guard case .ready = status, canDownloadAndInstall, locationProblem == nil, !highWaterUnreadable else { return false }
        return true
    }

    // MARK: Scheduling

    func start() {
        guard !installed.publicKey.isEmpty else { return }
        scheduleNext(after: UpdateSchedule.firstCheckDelay(random: .random(in: 0...1)))
    }

    func didWake() {
        guard automaticChecks, !installed.publicKey.isEmpty,
              UpdateSchedule.shouldCheckAfterWake(lastAttempt: lastAttempt, now: Date()) else { return }
        Task { await check(manual: false) }
    }

    private func scheduleNext(after delay: TimeInterval) {
        timer?.invalidate(); timer = nil
        guard automaticChecks, !installed.publicKey.isEmpty else { nextCheck = nil; return }
        let date = Date().addingTimeInterval(delay)
        nextCheck = date
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
    }

    private func channelChanged() {
        // Switching only changes candidate selection; it never installs or downgrades.
        if case .ready = status { status = .idle }
        if case .available = status { status = .idle }
        Task { await check(manual: true) }
    }

    // MARK: Checking

    func checkNow() { Task { await check(manual: true) } }

    func check(manual: Bool) async {
        guard !installed.publicKey.isEmpty else { status = .notConfigured; return }
        switch status { case .checking, .downloading, .installing: return; default: break }
        let now = Date()
        guard retry.allowsRequest(at: now) else {
            noteRateLimit()
            if !manual, let until = retry.rateLimitedUntil { scheduleNext(after: until.timeIntervalSince(now)) }
            return
        }
        let previous = status
        status = .checking; lastAttempt = now
        let selected = channel
        let stableFetch = await client.feed(.stable)
        let previewFetch = selected == .preview ? await client.feed(.preview) : .absent
        lastCheck = Date()

        let failures = [stableFetch, previewFetch].compactMap { fetch -> UpdateFetchFailure? in
            if case .failed(let failure) = fetch { return failure }; return nil
        }
        if let failure = failures.first(where: { if case .rateLimited = $0 { return true }; return false }) ?? failures.first {
            if case .rateLimited = failure { note = "GitHub asked QuotaBar to wait before checking again. Your installed app is unchanged." }
            else { note = "Could not reach the update feed. QuotaBar will retry; your installed app is unchanged." }
            status = previous == .checking ? .idle : previous
            scheduleNext(after: retry.record(failure, now: Date(), random: .random(in: 0...1)))
            return
        }
        note = nil

        let stable = verify(stableFetch, channel: .stable)
        let preview = verify(previewFetch, channel: .preview)
        // A verified manifest that conflicts with an earlier signed reading of the
        // same build, on either channel, stops here.
        for case .verified(let manifest) in [stable, preview] {
            if highWater.conflicts(with: manifest) {
                status = .failed("The \(manifest.channel.rawValue) feed changed the contents of build \(manifest.build). Nothing will be installed.")
                scheduleNext(after: UpdateSchedule.regularDelay(random: .random(in: 0...1)))
                return
            }
        }
        let priorHighWater = highWater
        for case .verified(let manifest) in [stable, preview] { highWater = highWater.recording(manifest) }
        saveHighWater()
        let invalidNote: (([UpdateChannel]) -> String?) = { invalid in
            invalid.isEmpty ? nil : "The \(invalid.map(\.rawValue).joined(separator: " and ")) feed could not be verified and was ignored."
        }

        // The cycle's outcome sets the next check: a download failure keeps its
        // own rate-limit deadline or transient backoff instead of the hourly delay.
        var downloadDelay: TimeInterval?
        switch UpdateSelection.select(channel: selected, stable: stable, preview: preview) {
        case .conflictingIdentity:
            status = .failed("The Stable and Preview feeds disagree about the same build. Nothing will be installed.")
        case .unavailable(let invalid):
            status = .unavailable(selected == .stable ? "No Stable release is published yet." : "No updates are published for this channel yet.")
            note = invalidNote(invalid)
        case .candidate(let manifest, let invalid):
            note = invalidNote(invalid)
            switch UpdateDecision.evaluate(manifest, publicKey: installed.publicKey, installedBuild: installed.build, highWater: priorHighWater) {
            case .newer(let candidate):
                if case .ready(let staged) = previous, staged == candidate { status = previous }
                else {
                    status = .available(candidate)
                    if canDownloadAndInstall && automaticDownloads { downloadDelay = await download(candidate) }
                }
            case .upToDate:
                status = .upToDate
                if selected == .stable && manifest.build < installed.build {
                    note = "This Mac runs Preview build \(installed.build). Stable updates resume once a Stable build newer than that is published."
                }
            case .conflictingIdentity:
                status = .failed("The update feed changed the contents of build \(manifest.build). Nothing will be installed.")
            case .invalid:
                status = .failed("The update metadata does not match this app. Nothing will be installed.")
            }
        }
        if let downloadDelay { scheduleNext(after: downloadDelay); return }
        retry.recordSuccess()
        scheduleNext(after: UpdateSchedule.regularDelay(random: .random(in: 0...1)))
    }

    private func noteRateLimit() {
        guard let until = retry.rateLimitedUntil else { return }
        note = "GitHub asked QuotaBar to wait. The next request is after \(until.formatted(date: .omitted, time: .shortened))."
    }

    private func verify(_ fetch: UpdateFeedClient.FeedFetch, channel: UpdateChannel) -> UpdateFeedResult {
        switch fetch {
        case .absent, .failed: return .absent
        case .bytes(let data):
            guard let manifest = try? UpdateSignature.verify(data, publicKey: installed.publicKey), manifest.channel == channel else {
                return .invalid
            }
            envelopes[channel] = data
            return .verified(manifest)
        }
    }

    // MARK: Download

    func downloadNow() {
        guard case .available(let manifest) = status, canDownloadAndInstall else { return }
        // A manual Download honors the same rate-limit deadline as automatic requests.
        guard retry.allowsRequest(at: Date()) else { noteRateLimit(); return }
        Task {
            if let delay = await download(manifest) { scheduleNext(after: delay) } else { retry.recordSuccess() }
        }
    }

    /// Returns the delay before the next automatic attempt when the download
    /// failed in transport, or nil when it finished or failed verification.
    private func download(_ manifest: UpdateManifest) async -> TimeInterval? {
        guard let envelope = envelopes[manifest.channel] else { return nil }
        status = .downloading(manifest)
        let client = self.client, key = installed.publicKey
        do {
            try await Task.detached(priority: .utility) {
                try await Self.stage(manifest, envelope: envelope, publicKey: key, client: client)
            }.value
            status = .ready(manifest)
            return nil
        } catch let failure as UpdateFeedClient.DownloadFailure {
            status = .available(manifest)
            switch failure.failure {
            case .unavailable: note = "The release download is not available yet."
            case .rateLimited: note = "GitHub asked QuotaBar to wait before downloading. Your installed app is unchanged."
            default: note = "The download did not finish. QuotaBar will try again later."
            }
            return retry.record(failure.failure, now: Date(), random: .random(in: 0...1))
        } catch {
            status = .failed("The downloaded update did not match its signed description and was deleted. Your installed app is unchanged.")
            return nil
        }
    }

    nonisolated private static func stageDirectory(_ manifest: UpdateManifest) throws -> URL {
        try UpdateInstallation.staged(create: true).appendingPathComponent("\(manifest.build)-\(manifest.sha256.prefix(12))", isDirectory: true)
    }

    /// Downloads, verifies, inspects, extracts and validates one candidate. Keeps
    /// only this candidate staged and deletes anything that fails verification.
    nonisolated private static func stage(_ manifest: UpdateManifest, envelope: Data, publicKey: String, client: UpdateFeedClient) async throws {
        let directory = try stageDirectory(manifest)
        let staged = try UpdateInstallation.staged()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: staged.path)) ?? [] where name != directory.lastPathComponent {
            try? FileManager.default.removeItem(at: staged.appendingPathComponent(name))
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try UpdateInstallation.privateDirectory(directory, create: true)
        do {
            let archive = directory.appendingPathComponent(manifest.archiveName)
            try await client.download(manifest, to: archive)
            try UpdateZIP.inspect(archive)
            let extracted = directory.appendingPathComponent(UpdateInstallation.extractedName, isDirectory: true)
            try UpdateInstallation.privateDirectory(extracted, create: true)
            // Plain extraction: no quarantine is added and none is removed.
            try UpdateSystemCommand.run(.ditto, ["-x", "-k", archive.path, extracted.path])
            guard try FileManager.default.contentsOfDirectory(atPath: extracted.path) == ["QuotaBar.app"] else {
                throw UpdateValidationError.invalidArchive
            }
            try UpdateBundle.validate(extracted.appendingPathComponent("QuotaBar.app"), manifest: manifest, publicKey: publicKey)
            try UpdateFiles.write(envelope, toNew: directory.appendingPathComponent(UpdateInstallation.envelopeName))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    // MARK: Install (fresh click only)

    /// Called only by the Install and Relaunch button for the build it shows.
    func install(_ shown: UpdateManifest) {
        guard canInstall, case .ready(let manifest) = status, manifest == shown else { return }
        status = .installing(manifest)
        transactionNotice = nil
        let installed = self.installed, selected = channel
        Task {
            do {
                let job = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareJob(manifest, installed: installed, channel: selected)
                }.value
                try await handOff(job: job.directory, nonce: job.nonce)
            } catch {
                status = .ready(manifest)
                transactionNotice = "The update could not be prepared for installation. QuotaBar is unchanged."
                refreshRecovery()
            }
        }
    }

    nonisolated private static func prepareJob(_ manifest: UpdateManifest, installed: Installed,
                                               channel: UpdateChannel) throws -> (directory: URL, nonce: UUID) {
        let staged = try stageDirectory(manifest)
        let envelope = try UpdateFiles.read(staged.appendingPathComponent(UpdateInstallation.envelopeName), maximumBytes: UpdateEnvelope.maximumBytes)
        guard try UpdateSignature.verify(envelope, publicKey: installed.publicKey) == manifest else { throw UpdateValidationError.invalidMetadata }
        let nonce = UUID()
        let job = try UpdateInstallation.job(nonce, create: true)
        let archive = staged.appendingPathComponent(manifest.archiveName)
        try UpdateSignature.verifyArchive(archive, manifest: manifest)
        try UpdateFiles.write(UpdateFiles.read(archive, maximumBytes: manifest.archiveBytes), toNew: job.appendingPathComponent(manifest.archiveName))
        try UpdateFiles.write(envelope, toNew: job.appendingPathComponent(UpdateInstallation.envelopeName))
        // The helper runs from the job folder so it survives the app's replacement.
        try UpdateSystemCommand.run(.ditto, [installed.bundle.appendingPathComponent(UpdateBundle.helperPath).path,
                                             job.appendingPathComponent(UpdateInstallation.installerName).path])
        let request = UpdateInstallRequest(nonce: nonce, destination: installed.bundle, installedBuild: installed.build,
                                           channel: channel, manifest: manifest, parent: try UpdateProcessIdentity.read(getpid()))
        try UpdateInstallation.write(request, to: job.appendingPathComponent(UpdateInstallation.requestName))
        return (job, nonce)
    }

    /// Starts the helper, waits until it has verified everything and is waiting
    /// for this app to quit, then hands off and quits. The old app is untouched
    /// until the helper's first protected rename.
    private func handOff(job: URL, nonce: UUID) async throws {
        let helper = Process()
        helper.executableURL = job.appendingPathComponent(UpdateInstallation.installerName).appendingPathComponent(UpdateBundle.helperExecutable)
        helper.arguments = [job.appendingPathComponent(UpdateInstallation.requestName).path]
        helper.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            guard let journal = try? UpdateInstallation.readJournal(job), journal.nonce == nonce else {
                if !helper.isRunning { break }
                continue
            }
            switch journal.phase {
            case .waitingForExit:
                try UpdateInstallation.write(nonce, to: job.appendingPathComponent(UpdateInstallation.handoffName))
                NSApp.terminate(nil)
                return
            case .preparing: continue
            default: throw UpdateValidationError.invalidArchive
            }
        }
        try? UpdateInstallation.write(nonce, to: job.appendingPathComponent(UpdateInstallation.cancelName))
        throw UpdateValidationError.invalidArchive
    }

    // MARK: State and recovery

    private func loadHighWater() {
        // No saved state yet (including no Updates folder) is a normal first run.
        guard let file = try? UpdateInstallation.stateFile(), FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            highWater = try UpdateInstallation.read(UpdateHighWater.self, from: file, maximumBytes: 4_096)
        } catch {
            // Unreadable state never authorizes anything; installation waits for
            // the next successful verification to rewrite it.
            highWaterUnreadable = true
        }
    }

    private func saveHighWater() {
        do { try UpdateInstallation.write(highWater, to: try UpdateInstallation.stateFile(create: true)); highWaterUnreadable = false }
        catch { highWaterUnreadable = true }
    }

    func refreshRecovery() {
        recovery = UpdateInstallation.jobSummaries()
        let latest = recovery.compactMap { summary -> (Date, UpdateJournal)? in
            guard let journal = summary.journal else { return nil }
            let modified = (try? summary.location.appendingPathComponent(UpdateInstallation.journalName)
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (modified, journal)
        }.max(by: { $0.0 < $1.0 })?.1
        transactionNotice = latest.flatMap(notice)
    }

    private func notice(for journal: UpdateJournal) -> String? {
        switch journal.phase {
        case .permissionDenied where journal.previousBuild == installed.build:
            return "macOS did not allow QuotaBar to replace itself, so nothing changed. Allow QuotaBar in System Settings > Privacy & Security > App Management, then click Install and Relaunch again."
        case .refused where journal.previousBuild == installed.build, .cancelled where journal.previousBuild == installed.build:
            return "The last update did not start. QuotaBar is unchanged."
        case .completed where journal.build == installed.build:
            return "Updated from build \(journal.previousBuild). A recovery copy of the previous build is kept until you remove it."
        case .rolledBack:
            return "Build \(journal.build) could not be started, so build \(journal.previousBuild) was restored."
        case .replaced, .launchUnconfirmed, .recoveryRequired:
            return "An earlier update did not confirm that it finished. Both copies are kept. See docs/UPDATES.md before removing anything."
        default:
            return nil
        }
    }

    var removableRecovery: Bool {
        recovery.contains { $0.journal.map { UpdateInstallation.isRemovable($0, runningBuild: installed.build) } ?? false }
    }

    func removeRecoveryCopies() {
        UpdateInstallation.removeRecoveryCopies(runningBuild: installed.build)
        refreshRecovery()
    }

    func revealRecovery() {
        if let jobs = try? UpdateInstallation.jobs() { NSWorkspace.shared.activateFileViewerSelecting([jobs]) }
    }

    func openReleases() { NSWorkspace.shared.open(Self.releasesPage) }
}
