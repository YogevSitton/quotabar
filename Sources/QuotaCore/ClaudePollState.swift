import Foundation

/// A local request budget, with no account identifiers or usage data.
public struct ClaudePollState: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let startedAt: Date
    public let nextRequestAt: Date
    public let failureCount: Int
    public let pending: Bool

    public static let normalInterval: TimeInterval = 130

    public static func failureDelay(for failureCount: Int) -> TimeInterval {
        switch failureCount {
        case ...1: return 300
        case 2: return 600
        case 3: return 1_200
        case 4: return 2_400
        default: return 3_600
        }
    }

    public static func reservation(after previous: ClaudePollState?, at now: Date) -> ClaudePollState {
        let failures = min(5, max(0, min(5, previous?.failureCount ?? 0)) + 1)
        return ClaudePollState(version: 1, requestID: UUID(), startedAt: now,
            nextRequestAt: now.addingTimeInterval(failureDelay(for: failures)),
            failureCount: failures, pending: true)
    }

    public func completing(_ outcome: ClaudePollOutcome, at now: Date) -> ClaudePollState {
        let deadline: Date
        let failures: Int
        switch outcome {
        case .success(let observedAt):
            deadline = max(startedAt, observedAt).addingTimeInterval(Self.normalInterval)
            failures = 0
        case .failure:
            deadline = max(nextRequestAt, now.addingTimeInterval(Self.failureDelay(for: failureCount)))
            failures = failureCount
        }
        return ClaudePollState(version: version, requestID: requestID, startedAt: startedAt,
            nextRequestAt: deadline, failureCount: failures, pending: false)
    }

    /// An older app may have saved a shorter healthy interval. Enforce the
    /// current minimum between request starts without shortening any deadline
    /// or changing an unsuccessful/in-flight request's cooldown.
    public func respectingNormalInterval() -> ClaudePollState {
        guard !pending, failureCount == 0 else { return self }
        let deadline = max(nextRequestAt, startedAt.addingTimeInterval(Self.normalInterval))
        guard deadline > nextRequestAt else { return self }
        return ClaudePollState(version: version, requestID: requestID, startedAt: startedAt,
            nextRequestAt: deadline, failureCount: failureCount, pending: pending)
    }

    public var isValid: Bool {
        version == 1 && (0...5).contains(failureCount) && (!pending || failureCount > 0)
            && startedAt.timeIntervalSince1970.isFinite && startedAt.timeIntervalSince1970 > 0
            && nextRequestAt.timeIntervalSince1970.isFinite && nextRequestAt >= startedAt
    }
}

public struct ClaudePollLease: Sendable {
    public let state: ClaudePollState
    public init(state: ClaudePollState) { self.state = state }
    public var startedAt: Date { state.startedAt }
    public var nextRequestAt: Date { state.nextRequestAt }
    public var failureCount: Int { state.failureCount }
}

public enum ClaudePollAcquisition: Sendable {
    case ready(ClaudePollLease)
    case deferred(ClaudePollState)
}

public enum ClaudePollOutcome: Sendable {
    case success(observedAt: Date)
    case failure
}
