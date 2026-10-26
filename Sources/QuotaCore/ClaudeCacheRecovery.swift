import Foundation

public enum ClaudeCacheRecovery {
    // Claude Code's inspected usage-cache TTL is 60 seconds. Only recheck a
    // sample still inside that TTL, after our normal request interval. The
    // provider must match its account and validate the CLI response separately.
    public static func shouldRecheck(observedAt: Date, lastRequestStartedAt: Date,
                                     now: Date, minimumInterval: TimeInterval = 60) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        let elapsed = now.timeIntervalSince(lastRequestStartedAt)
        guard age.isFinite, elapsed.isFinite, minimumInterval.isFinite else { return false }
        return observedAt > lastRequestStartedAt && age >= 0 && age < 60
            && elapsed >= max(60, minimumInterval) + 0.5
    }
}
