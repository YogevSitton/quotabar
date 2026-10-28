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
                     cancellation: AntigravityProcess.Cancellation? = nil,
                     onOutput: ((Data, AntigravityProcess.OutputStream) -> Void)? = nil) -> AntigravityReadResult {
        do {
            guard let binary = try AntigravityHelper.existing() else {
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
                    cancel: cancellation, onOutput: onOutput)
                guard response.exitCode == 0 else {
                    // Match only the reviewed fixed error. Never expose raw CLI
                    // output, emails, authorization links or server responses.
                    let errorText = String(decoding: response.stderr, as: UTF8.self).lowercased()
                    if loginInput == nil, errorText.contains("authentication required") {
                        budget.needsSignIn = true
                        try profile.writeState(JSONEncoder().encode(budget))
                        return .failure("Connect Antigravity to sign in through the official CLI.", .signInRequired, nextRequestAt: nil)
                    }
                    throw UsageError.message("Antigravity could not retrieve subscription quota. It will retry automatically.")
                }
                let data: Data
                if loginInput != nil {
                    // Explicit auth can print a preamble. Only its final JSON
                    // object is eligible; the strict parser still requires the
                    // usage command and zero turns. Monitoring accepts no preamble.
                    guard let line = response.stdout.split(separator: 10).last(where: { !$0.allSatisfy { $0 == 13 || $0 == 32 } }) else {
                        throw UsageError.message("Antigravity did not return subscription quota after sign-in.")
                    }
                    data = Data(line)
                } else { data = response.stdout }
                let snapshot = try UsageParser.antigravity(data, observedAt: now)
                budget.failures = 0
                budget.nextRequestAt = max(Date().addingTimeInterval(1), now.addingTimeInterval(interval))
                try profile.writeState(JSONEncoder().encode(budget))
                return .success(snapshot, nextRequestAt: budget.nextRequestAt)
            } catch {
                let wait = min(3600, interval * pow(2, Double(budget.failures - 1)))
                budget.nextRequestAt = Date().addingTimeInterval(wait)
                try profile.writeState(JSONEncoder().encode(budget))
                let message: String
                switch error {
                case AntigravityProcess.ProcessError.cancelled: message = "Antigravity connection was cancelled. No automatic sign-in will follow."
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
}
