import Foundation
import QuotaCore

/// `connectionIncomplete` offers Connect again without declaring the user
/// signed out: monitoring keeps its own retry on the same deadline.
enum AntigravityConnectionIssue: Equatable { case helperMissing, signInRequired, connectionIncomplete, usageUnavailable, profileUnavailable }

enum AntigravityReadResult {
    case success(AntigravitySnapshot, nextRequestAt: Date)
    case deferred(nextRequestAt: Date)
    case failure(String, AntigravityConnectionIssue, nextRequestAt: Date?)
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
        do {
            // A presence check keeps polling from creating the private profile
            // before Connect. The full hash and signature check runs below,
            // only for an attempt that will actually launch the helper.
            guard FileManager.default.fileExists(atPath: AntigravityHelper.executable.path) else {
                return .failure("Connect Antigravity to prepare its official CLI.", .helperMissing, nextRequestAt: nil)
            }
            let profile = try AntigravityProfile.acquire()
            var budget = Budget(nextRequestAt: .distantPast, failures: 0, needsSignIn: false)
            if let saved = try profile.readState() {
                guard let decoded = try? JSONDecoder().decode(Budget.self, from: saved) else {
                    return .failure("Antigravity's saved request schedule could not be read. Usage monitoring is stopped.", .profileUnavailable, nextRequestAt: nil)
                }
                budget = decoded
                guard budget.version == 1, (0...10).contains(budget.failures),
                      budget.nextRequestAt.timeIntervalSince1970.isFinite else {
                    return .failure("Antigravity's saved request schedule could not be verified.", .profileUnavailable, nextRequestAt: nil)
                }
            }
            let now = Date()
            if let result = budget.preflight(explicit: loginInput != nil, at: now) { return result }
            guard let binary = try AntigravityHelper.existing() else {
                return .failure("Connect Antigravity to prepare its official CLI.", .helperMissing, nextRequestAt: nil)
            }
            // Verification takes a moment; a Connect cancelled meanwhile never launched.
            if cancellation?.isCancelled == true { return budget.cancelledBeforeLaunch(at: Date()) }
            // Reserve the attempt as a failure until it completes. Crashes
            // must not repeatedly reset the failure count or request deadline.
            let previous = budget
            budget.reserve(at: now)
            try profile.writeState(JSONEncoder().encode(budget))

            do {
                let response = try AntigravityProcess.run(binary: binary,
                    arguments: ["-p", "/usage", "--output-format", "json"], profile: profile,
                    timeout: loginInput == nil ? 45 : 180, loginInput: loginInput,
                    cancel: cancellation)
                try validateExit(response, explicit: loginInput != nil)
                let data: Data
                if loginInput != nil {
                    guard let report = finalJSONObject(in: response.stdout) else {
                        throw UsageError.message("Antigravity did not return subscription quota after sign-in.")
                    }
                    data = report
                } else { data = response.stdout }
                let snapshot = try UsageParser.antigravity(data, observedAt: now)
                budget.failures = 0
                budget.nextRequestAt = max(Date().addingTimeInterval(1), now.addingTimeInterval(interval))
                try profile.writeState(JSONEncoder().encode(budget))
                return .success(snapshot, nextRequestAt: budget.nextRequestAt)
            } catch AntigravityProcess.ProcessError.cancelledBeforeLaunch {
                // The lease is still held, so restoring the earlier schedule
                // cannot overwrite another copy's reservation.
                try profile.writeState(JSONEncoder().encode(previous))
                return previous.cancelledBeforeLaunch(at: Date())
            } catch {
                let result = budget.recordFailure(error, explicit: loginInput != nil, reservedFrom: previous, at: Date())
                try profile.writeState(JSONEncoder().encode(budget))
                return result
            }
        } catch AntigravityProfile.ProfileError.busy {
            return .deferred(nextRequestAt: Date().addingTimeInterval(30))
        } catch AntigravityProfile.ProfileError.administratorPolicy {
            return .failure("Antigravity's administrator policy is not supported by this integration yet. Check usage in Antigravity.", .profileUnavailable, nextRequestAt: nil)
        } catch is AntigravityProfile.ProfileError {
            return .failure("Antigravity's isolated settings could not be verified. Usage monitoring is stopped.", .profileUnavailable, nextRequestAt: nil)
        } catch {
            return .failure("The reviewed Antigravity helper or its saved schedule could not be verified. Use Connect Antigravity to check setup.", .helperMissing, nextRequestAt: nil)
        }
    }

    private enum SignInIncomplete: Error { case authenticationRequired }

    static func validateExit(_ response: AntigravityProcess.Result, explicit: Bool) throws {
        guard response.exitCode != 0 else { return }
        // Explicit login prints this preamble before successful authentication,
        // so it says nothing about a later quota failure. Only monitoring can
        // classify this reviewed error as a confirmed authentication boundary.
        if !explicit, String(decoding: response.stderr, as: UTF8.self).lowercased().contains("authentication required") {
            throw SignInIncomplete.authenticationRequired
        }
        throw UsageError.message("Antigravity could not retrieve subscription quota. It will retry automatically.")
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
