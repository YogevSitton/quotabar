import Foundation
import QuotaCore

/// `connectionIncomplete` offers Connect again without declaring the user
/// signed out: monitoring keeps its own retry on the same deadline.
enum AntigravityConnectionIssue: Equatable { case helperMissing, signInRequired, connectionIncomplete, usageUnavailable, profileUnavailable }

enum AntigravityReadResult {
    case success(AntigravitySnapshot, nextRequestAt: Date)
    case deferred(nextRequestAt: Date)
    case failure(String, AntigravityConnectionIssue, nextRequestAt: Date?)

    var nextRequestAt: Date? {
        switch self {
        case .success(_, let next), .deferred(let next): return next
        case .failure(_, _, let next): return next
        }
    }
}

enum AntigravityProvider {
    static let maximumAge: TimeInterval = 390
    static let interval: TimeInterval = 300

    struct Budget: Codable {
        var version = 1
        var nextRequestAt: Date
        var failures: Int
        var needsSignIn: Bool

        /// Needing Connect is not evidence that the last attempt avoided /usage.
        /// In particular, old saved needsSignIn flags must retain their deadline.
        func preflight(explicit: Bool, at now: Date) -> AntigravityReadResult? {
            if needsSignIn, !explicit || nextRequestAt > now {
                let next = nextRequestAt > now ? nextRequestAt : nil
                let message = next.map { "Connect Antigravity to try again after \($0.formatted(date: .omitted, time: .shortened))." }
                    ?? "Connect Antigravity to sign in through the official CLI."
                return .failure(message, .signInRequired, nextRequestAt: next)
            }
            if nextRequestAt > now { return .deferred(nextRequestAt: nextRequestAt) }
            return nil
        }

        mutating func reserve(at now: Date) {
            failures = min(10, failures + 1)
            nextRequestAt = now.addingTimeInterval(min(3600, interval * pow(2, Double(failures - 1))))
            needsSignIn = false
        }

        /// The helper provably never started, so nothing was spent: report the
        /// cancellation against this unchanged schedule.
        func cancelledBeforeLaunch(at now: Date) -> AntigravityReadResult {
            .failure("Antigravity connection was cancelled before the official CLI started.",
                     needsSignIn ? .signInRequired : .connectionIncomplete,
                     nextRequestAt: nextRequestAt > now ? nextRequestAt : nil)
        }

        /// `previous` is the schedule before `reserve`, so an attempt that made
        /// no quota request can keep the earlier failure count.
        mutating func recordFailure(_ error: Error, explicit: Bool, reservedFrom previous: Budget,
                                    at now: Date) -> AntigravityReadResult {
            let wait = min(3600, interval * pow(2, Double(failures - 1)))
            nextRequestAt = now.addingTimeInterval(wait)
            needsSignIn = false
            let message: String
            switch error {
            case SignInIncomplete.authenticationRequired where !explicit:
                // Only the monitored, non-interactive auth failure proves that
                // /usage was not reached. Connect can resolve it immediately,
                // and it is not a quota failure, so earlier failures still count
                // but this attempt does not.
                needsSignIn = true
                nextRequestAt = now
                failures = previous.failures
                return .failure("Connect Antigravity to sign in through the official CLI.", .signInRequired, nextRequestAt: nil)
            case AntigravityProcess.ProcessError.cancelled where explicit:
                needsSignIn = true
                message = "Antigravity connection was cancelled. Connect again after the waiting period."
            case AntigravityProcess.ProcessError.timedOut where explicit:
                needsSignIn = true
                message = "Antigravity connection did not finish in time. Connect again after the waiting period."
            case _ where explicit:
                // Sign-in may have succeeded before /usage failed, and its output
                // cannot tell a preamble from the final error. Neither declare the
                // user signed out nor drop monitoring: offer Connect at the deadline.
                message = "Antigravity's connection did not complete. Connect again after the waiting period; QuotaBar also retries automatically."
            case AntigravityProcess.ProcessError.timedOut:
                message = "Antigravity did not finish in time. It will retry automatically without starting sign-in."
            case is UsageError:
                message = error.localizedDescription
            default:
                message = "Antigravity's usage read failed. It will retry automatically."
            }
            // An explicit Connect also performs /usage. Cancellation, timeout and
            // failed exits cannot prove which phase stopped, so keep the backoff.
            let issue: AntigravityConnectionIssue = needsSignIn ? .signInRequired
                : explicit ? .connectionIncomplete : .usageUnavailable
            return .failure(message, issue, nextRequestAt: nextRequestAt)
        }
    }

    /// Runs on a utility queue. The filesystem lease serializes all app copies;
    /// the durable reservation survives termination, wake, retry and relaunch.
    static func read(loginInput: AntigravityProcess.LoginInput? = nil,
                     cancellation: AntigravityProcess.Cancellation? = nil) -> AntigravityReadResult {
        let explicit = loginInput != nil
        var phase: DiagnosticEvent.Phase = .launch
        do {
            // A presence check keeps polling from creating the private profile
            // before Connect. The full hash and signature check runs below,
            // only for an attempt that will actually launch the helper.
            // Not logged: an unconnected install would add an entry every launch.
            guard FileManager.default.fileExists(atPath: AntigravityHelper.executable.path) else {
                return .failure("Connect Antigravity to prepare its official CLI.", .helperMissing, nextRequestAt: nil)
            }
            let profile = try AntigravityProfile.acquire()
            var budget = Budget(nextRequestAt: .distantPast, failures: 0, needsSignIn: false)
            if let saved = try profile.readState() {
                guard let decoded = try? JSONDecoder().decode(Budget.self, from: saved) else {
                    record(.readFailed, .pollStoreInvalid, phase: phase, explicit: explicit)
                    return .failure("Antigravity's saved request schedule could not be read. Usage monitoring is stopped.", .profileUnavailable, nextRequestAt: nil)
                }
                budget = decoded
                guard budget.version == 1, (0...10).contains(budget.failures),
                      budget.nextRequestAt.timeIntervalSince1970.isFinite else {
                    record(.readFailed, .pollStoreInvalid, phase: phase, explicit: explicit)
                    return .failure("Antigravity's saved request schedule could not be verified.", .profileUnavailable, nextRequestAt: nil)
                }
            }
            let now = Date()
            if let result = budget.preflight(explicit: explicit, at: now) {
                DiagnosticLog.shared.record(DiagnosticEvent(area: .antigravity, kind: .readDeferred,
                    reason: budget.needsSignIn ? .connectRequired : budget.failures > 0 ? .cooldown : .scheduled,
                    failureCount: budget.failures, nextAttemptAt: result.nextRequestAt, signInAllowed: explicit))
                return result
            }
            guard let binary = try AntigravityHelper.existing() else {
                record(.readFailed, .helperMissing, phase: phase, explicit: explicit)
                return .failure("Connect Antigravity to prepare its official CLI.", .helperMissing, nextRequestAt: nil)
            }
            // Verification takes a moment; a Connect cancelled meanwhile never launched.
            if cancellation?.isCancelled == true {
                record(.readFailed, .cancelledBeforeLaunch, phase: phase, explicit: explicit)
                return budget.cancelledBeforeLaunch(at: Date())
            }
            // Reserve the attempt as a failure until it completes. Crashes
            // must not repeatedly reset the failure count or request deadline.
            let previous = budget
            budget.reserve(at: now)
            phase = .savingSchedule
            try profile.writeState(JSONEncoder().encode(budget))
            DiagnosticLog.shared.record(DiagnosticEvent(area: .antigravity, kind: .readStarted,
                failureCount: previous.failures, nextAttemptAt: budget.nextRequestAt, signInAllowed: explicit))

            let startedAt = Date()
            var response: AntigravityProcess.Result?
            do {
                phase = .usage
                let completed = try AntigravityProcess.run(binary: binary,
                    arguments: ["-p", "/usage", "--output-format", "json"], profile: profile,
                    timeout: explicit ? 180 : 45, loginInput: loginInput,
                    cancel: cancellation)
                response = completed
                try validateExit(completed, explicit: explicit)
                phase = .parsing
                let data: Data
                if explicit {
                    guard let report = finalJSONObject(in: completed.stdout) else {
                        throw UsageError.message("Antigravity did not return subscription quota after sign-in.")
                    }
                    data = report
                } else { data = completed.stdout }
                let snapshot = try UsageParser.antigravity(data, observedAt: now)
                budget.failures = 0
                budget.nextRequestAt = max(Date().addingTimeInterval(1), now.addingTimeInterval(interval))
                phase = .savingSchedule
                try profile.writeState(JSONEncoder().encode(budget))
                DiagnosticLog.shared.record(DiagnosticEvent(area: .antigravity, kind: .readSucceeded,
                    durationMS: DiagnosticEvent.durationMS(from: startedAt), failureCount: 0,
                    nextAttemptAt: budget.nextRequestAt, signInAllowed: explicit))
                return .success(snapshot, nextRequestAt: budget.nextRequestAt)
            } catch AntigravityProcess.ProcessError.cancelledBeforeLaunch {
                // The lease is still held, so restoring the earlier schedule
                // cannot overwrite another copy's reservation.
                phase = .savingSchedule
                try profile.writeState(JSONEncoder().encode(previous))
                record(.readFailed, .cancelledBeforeLaunch, phase: .launch, explicit: explicit)
                return previous.cancelledBeforeLaunch(at: Date())
            } catch {
                let result = budget.recordFailure(error, explicit: explicit, reservedFrom: previous, at: Date())
                let report = response.map { DiagnosticEvent.Report(antigravity: finalJSONObject(in: $0.stdout)) }
                DiagnosticLog.shared.record(DiagnosticEvent(area: .antigravity, kind: .readFailed,
                    reason: diagnosticReason(error, phase: phase, report: report), phase: phase,
                    durationMS: DiagnosticEvent.durationMS(from: startedAt), failureCount: budget.failures,
                    nextAttemptAt: result.nextRequestAt, signInAllowed: explicit,
                    exitStatus: response.map { Int($0.exitCode) },
                    authenticationNotice: response.map(mentionsAuthenticationRequired), report: report))
                phase = .savingSchedule
                try profile.writeState(JSONEncoder().encode(budget))
                return result
            }
        } catch {
            let reason = diagnosticReason(error, phase: phase, report: nil)
            record(reason == .pollStoreBusy ? .readDeferred : .readFailed, reason,
                   phase: reason == .pollStoreBusy ? nil : phase, explicit: explicit)
            switch error {
            case AntigravityProfile.ProfileError.busy:
                return .deferred(nextRequestAt: Date().addingTimeInterval(30))
            case AntigravityProfile.ProfileError.administratorPolicy:
                return .failure("Antigravity's administrator policy is not supported by this integration yet. Check usage in Antigravity.", .profileUnavailable, nextRequestAt: nil)
            case is AntigravityProfile.ProfileError:
                return .failure("Antigravity's isolated settings could not be verified. Usage monitoring is stopped.", .profileUnavailable, nextRequestAt: nil)
            default:
                return .failure("The reviewed Antigravity helper or its saved schedule could not be verified. Use Connect Antigravity to check setup.", .helperMissing, nextRequestAt: nil)
            }
        }
    }

    private static func record(_ kind: DiagnosticEvent.Kind, _ reason: DiagnosticEvent.Reason,
                               phase: DiagnosticEvent.Phase?, explicit: Bool) {
        DiagnosticLog.shared.record(DiagnosticEvent(area: .antigravity, kind: kind, reason: reason,
            phase: phase, signInAllowed: explicit))
    }

    /// Fixed categories only: stdout, stderr and error text never reach the log.
    /// `phase` is the step that threw, which separates a failed exit from a
    /// rejected report and a schedule write from profile verification.
    static func diagnosticReason(_ error: Error, phase: DiagnosticEvent.Phase,
                                 report: DiagnosticEvent.Report?) -> DiagnosticEvent.Reason {
        switch error {
        case AntigravityProcess.ProcessError.timedOut: return .helperTimeout
        case AntigravityProcess.ProcessError.cancelled: return .cancelled
        case AntigravityProcess.ProcessError.cancelledBeforeLaunch: return .cancelledBeforeLaunch
        case AntigravityProcess.ProcessError.oversizedResponse: return .oversizedReply
        case AntigravityProcess.ProcessError.inputUnavailable: return .terminalUnavailable
        case AntigravityProcess.ProcessError.launchFailed: return .launchFailed
        case SignInIncomplete.authenticationRequired: return .signedOut
        case AntigravityProfile.ProfileError.busy: return .pollStoreBusy
        case AntigravityProfile.ProfileError.administratorPolicy: return .administratorPolicy
        case is AntigravityProfile.ProfileError: return phase == .savingSchedule ? .pollStoreUnavailable : .profileUnavailable
        default:
            switch phase {
            case .usage: return .exitedWithError
            case .parsing: return report == .missing ? .missingReport : .invalidUsage
            case .savingSchedule: return .pollStoreUnavailable
            default: return .helperCheckFailed
            }
        }
    }

    private enum SignInIncomplete: Error { case authenticationRequired }

    static func validateExit(_ response: AntigravityProcess.Result, explicit: Bool) throws {
        guard response.exitCode != 0 else { return }
        // Explicit login prints this preamble before successful authentication,
        // so it says nothing about a later quota failure. Only monitoring can
        // classify this reviewed error as a confirmed authentication boundary.
        if !explicit, mentionsAuthenticationRequired(response) {
            throw SignInIncomplete.authenticationRequired
        }
        throw UsageError.message("Antigravity could not retrieve subscription quota. It will retry automatically.")
    }

    /// Matches the reviewed CLI's fixed error text; only the boolean is kept.
    static func mentionsAuthenticationRequired(_ response: AntigravityProcess.Result) -> Bool {
        String(decoding: response.stderr, as: UTF8.self).lowercased().contains("authentication required")
    }

    /// Explicit sign-in can print a preamble before the report. Accept only the
    /// final top-level JSON object, on one line or pretty-printed: its opening
    /// brace starts a line. The strict parser still requires the usage command
    /// and zero turns. Monitoring accepts no preamble.
    static func finalJSONObject(in output: Data) -> Data? {
        let bytes = [UInt8](output)
        var end = bytes.count
        while end > 0, [9, 10, 13, 32].contains(bytes[end - 1]) { end -= 1 }
        guard end > 0, bytes[end - 1] == UInt8(ascii: "}") else { return nil }
        var attempts = 0
        var index = end - 1
        while index >= 0, attempts < 16 {
            if bytes[index] == UInt8(ascii: "{"), index == 0 || bytes[index - 1] == 10 {
                attempts += 1
                let candidate = Data(bytes[index..<end])
                if (try? JSONSerialization.jsonObject(with: candidate)) is [String: Any] { return candidate }
            }
            index -= 1
        }
        return nil
    }
}
