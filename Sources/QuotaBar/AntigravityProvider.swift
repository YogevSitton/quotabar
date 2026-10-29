import Foundation
import QuotaCore

enum AntigravityConnectionIssue: Equatable { case helperMissing, signInRequired, usageUnavailable, profileUnavailable }

enum AntigravityReadResult {
    case success(AntigravitySnapshot, nextRequestAt: Date)
    case deferred(nextRequestAt: Date)
    case failure(String, AntigravityConnectionIssue, nextRequestAt: Date?)
}

enum AntigravityProvider {
    static let maximumAge: TimeInterval = 390
    static let interval: TimeInterval = 300

    private struct Budget: Codable {
        var version = 1
        var nextRequestAt: Date
        var failures: Int
        var needsSignIn: Bool
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
            if budget.needsSignIn, loginInput == nil {
                return .failure("Connect Antigravity to sign in through the official CLI.", .signInRequired, nextRequestAt: nil)
            }
            let now = Date()
            // An unauthenticated read never reached /usage. Explicit Connect may
            // resolve that boundary immediately; other failures keep their budget.
            if budget.nextRequestAt > now, !(budget.needsSignIn && loginInput != nil) {
                return .deferred(nextRequestAt: budget.nextRequestAt)
            }
            guard let binary = try AntigravityHelper.existing() else {
                return .failure("Connect Antigravity to prepare its official CLI.", .helperMissing, nextRequestAt: nil)
            }
            // Reserve the attempt as a failure until it completes. Crashes
            // must not repeatedly reset the failure count or request deadline.
            budget.failures = min(10, budget.failures + 1)
            budget.nextRequestAt = now.addingTimeInterval(min(3600, interval * pow(2, Double(budget.failures - 1))))
            budget.needsSignIn = false
            try profile.writeState(JSONEncoder().encode(budget))

            do {
                let response = try AntigravityProcess.run(binary: binary,
                    arguments: ["-p", "/usage", "--output-format", "json"], profile: profile,
                    timeout: loginInput == nil ? 45 : 180, loginInput: loginInput,
                    cancel: cancellation)
                guard response.exitCode == 0 else {
                    // Match only the reviewed fixed error. Never expose raw CLI
                    // output, emails, authorization links or server responses.
                    let errorText = String(decoding: response.stderr, as: UTF8.self).lowercased()
                    if errorText.contains("authentication required") {
                        throw SignInIncomplete.authenticationRequired
                    }
                    throw UsageError.message("Antigravity could not retrieve subscription quota. It will retry automatically.")
                }
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
            } catch {
                let wait = min(3600, interval * pow(2, Double(budget.failures - 1)))
                budget.nextRequestAt = Date().addingTimeInterval(wait)
                // A missing sign-in, or an explicit Connect that was cancelled or
                // ran out of time, ended before a usage report. Keep Connect
                // available; background polling cannot start sign-in itself.
                if let incomplete = signInIncomplete(error, explicit: loginInput != nil) {
                    budget.needsSignIn = true
                    try profile.writeState(JSONEncoder().encode(budget))
                    return .failure(incomplete, .signInRequired, nextRequestAt: nil)
                }
                try profile.writeState(JSONEncoder().encode(budget))
                let message: String
                switch error {
                case AntigravityProcess.ProcessError.timedOut: message = "Antigravity did not finish in time. It will retry automatically without starting sign-in."
                case is UsageError: message = error.localizedDescription
                default: message = "Antigravity's usage read failed. It will retry automatically."
                }
                return .failure(message, .usageUnavailable, nextRequestAt: budget.nextRequestAt)
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

    private static func signInIncomplete(_ error: Error, explicit: Bool) -> String? {
        switch error {
        case SignInIncomplete.authenticationRequired:
            return explicit ? "Antigravity sign-in did not complete. Connect Antigravity to try again."
                : "Connect Antigravity to sign in through the official CLI."
        case AntigravityProcess.ProcessError.cancelled where explicit:
            return "Antigravity sign-in was cancelled. Connect Antigravity to try again."
        case AntigravityProcess.ProcessError.timedOut where explicit:
            return "Antigravity sign-in did not finish in time. Connect Antigravity to try again."
        default:
            return nil
        }
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
