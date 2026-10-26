import Foundation
import Darwin
import QuotaCore
import QuotaUpdateSupport

/// One-shot installer for one fresh Install click (docs/UPDATES.md). It has no
/// network, provider or credential code, and it cannot start from saved state:
/// it acts only on a new request from its live parent app, consumed once.
///
/// The first protected change is an exclusive rename of the intact installed app
/// to a backup. If macOS denies it, nothing changed: the old app is relaunched
/// and the user must click Install again. It never retries, watches for a
/// permission change, requests Full Disk Access, or touches ACLs, Gatekeeper or
/// quarantine.
@main enum Installer {
    static func main() {
        do { try install() }
        catch { exit(1) } // The non-secret journal is the only output.
    }

    static func install() throws {
        guard CommandLine.arguments.count == 2 else { throw UpdateValidationError.invalidMetadata }
        let requestPath = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let request = try JSONDecoder().decode(UpdateInstallRequest.self, from: UpdateFiles.read(requestPath, maximumBytes: 16_384))
        guard request.schema == 1 else { throw UpdateValidationError.invalidMetadata }
        let job = try UpdateInstallation.job(request.nonce)
        let destination = URL(fileURLWithPath: request.destination).standardizedFileURL
        guard requestPath == job.appendingPathComponent(UpdateInstallation.requestName),
              request.parent.pid == getppid(), try UpdateProcessIdentity.read(getppid()) == request.parent,
              try UpdateProcessIdentity.executable(getppid()) == destination.appendingPathComponent(UpdateBundle.appExecutable).path else {
            throw UpdateValidationError.invalidMetadata
        }
        // Consume the request once; a replayed or copied request cannot pass.
        try UpdateInstallation.renameExclusive(requestPath, job.appendingPathComponent(UpdateInstallation.consumedRequestName))

        var journal = UpdateJournal(nonce: request.nonce, phase: .preparing, build: request.expectedBuild,
                                    previousBuild: request.installedBuild, destination: destination.path)
        let journalFile = job.appendingPathComponent(UpdateInstallation.journalName)
        func record(_ phase: UpdateJournal.Phase) throws {
            journal = journal.moving(to: phase)
            try UpdateInstallation.write(journal, to: journalFile)
        }
        func cancelled() -> Bool { FileManager.default.fileExists(atPath: job.appendingPathComponent(UpdateInstallation.cancelName).path) }
        func relaunch() { try? UpdateSystemCommand.run(.open, ["-n", destination.path], timeout: 15) }
        try record(.preparing)

        // Verify everything while the app still runs; any failure leaves it unchanged.
        let manifest: UpdateManifest, publicKey: String, candidate: URL, original: (device: dev_t, inode: ino_t)
        do {
            let ownBundle = Bundle.main.bundleURL.standardizedFileURL
            guard ownBundle.path == job.appendingPathComponent(UpdateInstallation.installerName).path else {
                throw UpdateValidationError.invalidMetadata
            }
            let ownInfo = try UpdateBundle.info(ownBundle)
            guard let key = ownInfo[UpdateBundleKey.publicKey] as? String, !key.isEmpty,
                  ownInfo["CFBundleIdentifier"] as? String == UpdateManifest.helperIdentifier,
                  ownInfo[UpdateBundleKey.mode] as? String == UpdateBundleKey.releaseMode,
                  ownInfo["CFBundleVersion"] as? String == String(request.installedBuild) else {
                throw UpdateValidationError.invalidMetadata
            }
            publicKey = key
            try UpdateInstallation.destination(destination)
            try UpdateSystemCommand.run(.codesign, ["--verify", "--deep", "--strict", destination.path])
            try UpdateSystemCommand.run(.codesign, ["--verify", "--strict", ownBundle.path])
            let installed = try UpdateBundle.info(destination)
            guard installed["CFBundleIdentifier"] as? String == UpdateManifest.bundleIdentifier,
                  installed["CFBundleVersion"] as? String == String(request.installedBuild),
                  installed[UpdateBundleKey.mode] as? String == UpdateBundleKey.releaseMode,
                  installed[UpdateBundleKey.publicKey] as? String == key,
                  installed[UpdateBundleKey.commit] as? String == ownInfo[UpdateBundleKey.commit] as? String else {
                throw UpdateValidationError.invalidArchive
            }
            let envelope = try UpdateFiles.read(job.appendingPathComponent(UpdateInstallation.envelopeName), maximumBytes: UpdateEnvelope.maximumBytes)
            manifest = try UpdateSignature.verify(envelope, publicKey: key)
            guard manifest.build == request.expectedBuild, manifest.sha256 == request.expectedSHA256,
                  request.channel == .preview || manifest.channel == .stable else { throw UpdateValidationError.invalidMetadata }
            try UpdatePolicy.validate(manifest, channel: manifest.channel, publicKey: key,
                                      installedBuild: request.installedBuild, highWater: nil)
            let archive = job.appendingPathComponent(manifest.archiveName)
            try UpdateSignature.verifyArchive(archive, manifest: manifest)
            try UpdateZIP.inspect(archive)
            let extracted = job.appendingPathComponent(UpdateInstallation.extractedName, isDirectory: true)
            try UpdateInstallation.privateDirectory(extracted, create: true)
            // Plain extraction: no quarantine is added and none is removed.
            try UpdateSystemCommand.run(.ditto, ["-x", "-k", archive.path, extracted.path])
            guard try FileManager.default.contentsOfDirectory(atPath: extracted.path) == ["QuotaBar.app"] else {
                throw UpdateValidationError.invalidArchive
            }
            candidate = extracted.appendingPathComponent("QuotaBar.app")
            try UpdateBundle.validate(candidate, manifest: manifest, publicKey: key)
            guard UpdateInstallation.sameVolume(job, destination.deletingLastPathComponent()) else { throw UpdateValidationError.invalidArchive }
            original = try UpdateInstallation.fileIdentity(destination)
        } catch {
            try? record(.refused)
            throw error
        }

        if cancelled() { try record(.cancelled); return }
        try record(.waitingForExit)
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while try request.parent.isRunning() {
            if cancelled() { try record(.cancelled); return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { try record(.refused); return }
            usleep(50_000)
        }
        // The app hands off only after this helper reported waitingForExit. An app
        // that quit or crashed without the handoff did not authorize replacement.
        let handoff = job.appendingPathComponent(UpdateInstallation.handoffName)
        guard !cancelled(), (try? JSONDecoder().decode(UUID.self, from: UpdateFiles.read(handoff, maximumBytes: 128))) == request.nonce else {
            try record(.cancelled); return
        }
        try UpdateInstallation.renameExclusive(handoff, job.appendingPathComponent(UpdateInstallation.consumedHandoffName))

        // Fresh checks immediately before the first protected change.
        do {
            try UpdateInstallation.destination(destination)
            let current = try UpdateInstallation.fileIdentity(destination)
            guard current.device == original.device, current.inode == original.inode,
                  UpdateInstallation.sameVolume(job, destination.deletingLastPathComponent()) else { throw UpdateValidationError.invalidArchive }
        } catch {
            try? record(.refused); relaunch(); return
        }
        let previous = job.appendingPathComponent(UpdateInstallation.previousName)
        do { try UpdateInstallation.renameExclusive(destination, previous) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code) {
            // App Management or another protection refused: the original is intact.
            try? record(.permissionDenied); relaunch(); return
        } catch {
            try? record(.refused); relaunch(); return
        }

        // From here the installed location has changed. Restore only known
        // bundles into a vacant path and keep every copy when uncertain.
        do { try UpdateInstallation.renameExclusive(candidate, destination) }
        catch {
            do { try UpdateInstallation.renameExclusive(previous, destination); try record(.rolledBack); relaunch() }
            catch { try? record(.recoveryRequired) }
            return
        }
        do { try record(.replaced) } catch { try? record(.recoveryRequired); return }
        do { try UpdateSystemCommand.run(.open, ["-n", destination.path], timeout: 15) }
        catch {
            do {
                try UpdateBundle.validate(destination, manifest: manifest, publicKey: publicKey)
                try UpdateInstallation.renameExclusive(destination, job.appendingPathComponent(UpdateInstallation.failedName))
                try UpdateInstallation.renameExclusive(previous, destination)
                try record(.rolledBack)
                relaunch()
            } catch { try? record(.recoveryRequired) }
            return
        }
        let launchDeadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < launchDeadline {
            if let value = try? UpdateInstallation.readJournal(job), value.nonce == request.nonce,
               value.phase == .completed, value.build == manifest.build {
                return // The new app acknowledged launch; the backup stays for manual rollback.
            }
            usleep(100_000)
        }
        // Launch requested but not confirmed; both copies kept. A late
        // acknowledgment is never overwritten.
        if let value = try? UpdateInstallation.readJournal(job), value.phase == .completed { return }
        try? record(.launchUnconfirmed)
    }
}
