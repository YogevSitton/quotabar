import Foundation
import Combine
import QuotaCore

/// The official CLI launches OAuth and stores its own authentication. QuotaBar
/// forwards an optional one-time code through stdin and never sees token files.
@MainActor final class AntigravityConnection: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var needsCode = false
    /// True while the official CLI may save a new sign-in, which is when
    /// macOS can ask about the private profile's missing keychain.
    @Published private(set) var signingIn = false
    @Published var code = ""
    private var task: Task<Void, Never>?
    private var input: AntigravityProcess.LoginInput?
    private var cancellation: AntigravityProcess.Cancellation?
    private let finished: (AntigravityReadResult) -> Void

    init(finished: @escaping (AntigravityReadResult) -> Void) { self.finished = finished }

    func connect() {
        guard !busy else { return }
        busy = true; error = nil; code = ""; needsCode = false
        status = "Preparing Antigravity..."
        let cancellation = AntigravityProcess.Cancellation()
        self.cancellation = cancellation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                input?.close(); input = nil; self.cancellation = nil
                code = ""; needsCode = false; signingIn = false; busy = false; task = nil
            }
            do {
                _ = try await AntigravityHelper.prepare { [weak self] value in self?.status = value }
                DiagnosticLog.shared.record(DiagnosticEvent(area: .antigravity, kind: .helperReady,
                    version: AntigravityHelper.version))
                try Task.checkCancellation()
                let input = try AntigravityProcess.LoginInput()
                self.input = input
                status = "Finish sign-in in your browser. If Antigravity gives you a code, paste it below."
                needsCode = true; signingIn = true
                let result = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AntigravityProvider.read(loginInput: input, cancellation: cancellation))
                    }
                }
                var outcome = result
                switch result {
                case .success: status = "Antigravity is connected."
                case .deferred(let next):
                    // This summary hides once the flow ends, so hand the reason to
                    // the card with the same schedule rather than dropping it.
                    let message = "Waiting until \(next.formatted(date: .omitted, time: .shortened)) before checking Antigravity again."
                    error = message; status = ""
                    outcome = .failure(message, .connectionIncomplete, nextRequestAt: next)
                case .failure(let message, _, _): error = message; status = ""
                }
                finished(outcome)
            } catch {
                // Nothing launched yet: preparation, cancellation or the sign-in terminal failed.
                DiagnosticLog.shared.record(DiagnosticEvent(area: .antigravity, kind: .readFailed,
                    reason: Task.isCancelled ? .cancelledBeforeLaunch
                        : error as? AntigravityProcess.ProcessError == .inputUnavailable ? .terminalUnavailable : .helperCheckFailed,
                    phase: .launch, signInAllowed: true))
                status = ""
                self.error = Task.isCancelled ? "Antigravity connection cancelled." : "The official Antigravity helper could not be prepared. Try Connect Antigravity again."
                finished(.failure(self.error!, .helperMissing, nextRequestAt: nil))
            }
        }
    }

    func submitCode() {
        guard busy, needsCode, let input else { return }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        code = ""
        do {
            try input.sendCode(value)
            needsCode = false
            status = "Completing official sign-in and reading quota..."
        } catch { self.error = "The code could not be submitted. Check it or cancel and connect again." }
    }

    func cancel() {
        cancellation?.cancel(); task?.cancel()
        input?.close(); code = ""; needsCode = false
        status = "Cancelling Antigravity connection..."
    }
}
