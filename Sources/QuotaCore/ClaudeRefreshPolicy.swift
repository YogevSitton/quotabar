import Foundation

public enum ClaudeRefreshClassification: Equatable {
    /// A matching sample was recorded during this request. This does not
    /// establish which official Claude process fetched it or its HTTP status.
    case newSample
    /// The CLI may legitimately reuse a sample within its 60-second cache TTL.
    case recentCache
    /// No acceptable sample time can be established for the response.
    case unverified

    public var isAccepted: Bool { self != .unverified }
}

public enum ClaudeRefreshPolicy {
    /// The caller must verify the active account and match all displayed usage
    /// against the after-cache before passing its timestamp here. This only
    /// classifies provenance; it never makes a disk-only reading current.
    public static func classify(before: Date?, after: Date?, requestStartedAt: Date,
                                completedAt: Date) -> ClaudeRefreshClassification {
        guard let after, requestStartedAt.timeIntervalSince1970.isFinite,
              completedAt.timeIntervalSince1970.isFinite,
              after.timeIntervalSince1970.isFinite,
              completedAt >= requestStartedAt else { return .unverified }
        if let before {
            guard before.timeIntervalSince1970.isFinite, before <= requestStartedAt,
                  after >= before else { return .unverified }
        }
        let completionAge = completedAt.timeIntervalSince(after)
        guard completionAge >= 0, completionAge < 120 else { return .unverified }

        if after >= requestStartedAt, before.map({ after > $0 }) ?? true {
            return .newSample
        }
        // A timestamp advance alone is insufficient: a concurrent writer may
        // have restored a sample that was already old before this request.
        // Also require it to remain inside the TTL at completion: initialize
        // and version checks happen before get_usage, so a sample crossing the
        // TTL during startup could already have been a failed-fetch fallback.
        let startAge = requestStartedAt.timeIntervalSince(after)
        return startAge >= 0 && startAge < 60 && completionAge < 60 ? .recentCache : .unverified
    }
}
