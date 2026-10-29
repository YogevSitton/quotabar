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

public enum ClaudeRefreshRejection: Error, Equatable {
    case missingSample, inconsistentTiming, sampleTooOld, reusedSampleExpired
}

public enum ClaudeRefreshPolicy {
    /// Display lifetime after a response has passed the stricter checks below.
    /// Covers the 130-second polling interval, a reused sample under 60 seconds
    /// old, the reader's 45-second timeout and five seconds of scheduling margin.
    /// Errors, cached-only sources and expired windows still invalidate values.
    public static let maximumDisplayAge: TimeInterval = 240

    /// The caller must verify the active account and match all displayed usage
    /// against the after-cache before passing its timestamp here. This only
    /// classifies provenance; it never makes a disk-only reading current.
    public static func classify(before: Date?, after: Date?, requestStartedAt: Date,
                                completedAt: Date) -> ClaudeRefreshClassification {
        switch evaluate(before: before, after: after, requestStartedAt: requestStartedAt, completedAt: completedAt) {
        case .success(let classification): return classification
        case .failure: return .unverified
        }
    }

    /// Why `classify` returned `.unverified`, for diagnostics only. Nil when
    /// the response is accepted.
    public static func rejection(before: Date?, after: Date?, requestStartedAt: Date,
                                 completedAt: Date) -> ClaudeRefreshRejection? {
        if case .failure(let rejection) = evaluate(before: before, after: after,
            requestStartedAt: requestStartedAt, completedAt: completedAt) { return rejection }
        return nil
    }

    private static func evaluate(before: Date?, after: Date?, requestStartedAt: Date,
                                 completedAt: Date) -> Result<ClaudeRefreshClassification, ClaudeRefreshRejection> {
        guard let after else { return .failure(.missingSample) }
        guard requestStartedAt.timeIntervalSince1970.isFinite,
              completedAt.timeIntervalSince1970.isFinite,
              after.timeIntervalSince1970.isFinite,
              completedAt >= requestStartedAt else { return .failure(.inconsistentTiming) }
        if let before {
            guard before.timeIntervalSince1970.isFinite, before <= requestStartedAt,
                  after >= before else { return .failure(.inconsistentTiming) }
        }
        let completionAge = completedAt.timeIntervalSince(after)
        guard completionAge >= 0 else { return .failure(.inconsistentTiming) }
        guard completionAge < 120 else { return .failure(.sampleTooOld) }

        if after >= requestStartedAt, before.map({ after > $0 }) ?? true {
            return .success(.newSample)
        }
        // A timestamp advance alone is insufficient: a concurrent writer may
        // have restored a sample that was already old before this request.
        // Also require it to remain inside the TTL at completion: initialize
        // and version checks happen before get_usage, so a sample crossing the
        // TTL during startup could already have been a failed-fetch fallback.
        let startAge = requestStartedAt.timeIntervalSince(after)
        return startAge >= 0 && startAge < 60 && completionAge < 60 ? .success(.recentCache) : .failure(.reusedSampleExpired)
    }
}
