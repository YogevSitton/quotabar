import Foundation

/// A closed schema: callers cannot put provider replies, arbitrary error text,
/// paths, URLs, account identifiers or credentials into the diagnostic history.
public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public enum Area: String, Codable, Sendable { case app, codex, claude, updates }
    public enum Kind: String, Codable, Sendable {
        case started, woke, installationChanged, readStarted, readSucceeded, readFailed
        case readDeferred, retryRequested, helperReady, sampleRejected
        case accountChanged, authenticationChecked, scheduleSaveFailed, connectionRequested
        case loginSettingFailed, updateState
    }
    public enum Reason: String, Codable, Sendable {
        case freshSample, recentCache, missingProvenance, valuesMismatch, sampleTooOld
        case reusedSampleExpired, inconsistentTiming, helperMissing, launchFailed
        case unsupportedVersion, protocolFailure, helperEnded, helperTimeout, oversizedReply
        case readerIO, helperCheckFailed, invalidUsage, signedIn, signedOut, otherAuthentication, unknownAuthentication
        case pollStoreBusy, pollStoreInvalid, pollStoreUnavailable, cooldown, scheduled, pendingRequest
        case idle, notConfigured, checking, upToDate, unavailable, available, downloading, ready, installing, failed
    }
    public enum Phase: String, Codable, Sendable { case launch, initialize, version, usage, parsing, savingSchedule }

    public let date: Date
    public let area: Area
    public let kind: Kind
    public var reason: Reason?
    public var phase: Phase?
    public var durationMS: Int?
    public var sampleAgeSeconds: Int?
    public var cacheAdvanced: Bool?
    public var failureCount: Int?
    public var nextAttemptAt: Date?
    public var version: String?
    public var build: Int?

    public init(area: Area, kind: Kind, reason: Reason? = nil, phase: Phase? = nil, date: Date = Date(),
                durationMS: Int? = nil, sampleAgeSeconds: Int? = nil, cacheAdvanced: Bool? = nil,
                failureCount: Int? = nil, nextAttemptAt: Date? = nil, version: String? = nil, build: Int? = nil) {
        self.date = date; self.area = area; self.kind = kind; self.reason = reason
        self.phase = phase
        self.durationMS = durationMS; self.sampleAgeSeconds = sampleAgeSeconds; self.cacheAdvanced = cacheAdvanced
        self.failureCount = failureCount; self.nextAttemptAt = nextAttemptAt; self.version = version; self.build = build
    }

    public var isValid: Bool {
        func validDate(_ value: Date) -> Bool {
            value.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains(value.timeIntervalSince1970)
        }
        return validDate(date) && (nextAttemptAt.map(validDate) ?? true)
            && (durationMS.map { (0...3_600_000).contains($0) } ?? true)
            && (sampleAgeSeconds.map { (-1_000_000_000...1_000_000_000).contains($0) } ?? true)
            && (failureCount.map { (0...5).contains($0) } ?? true)
            && (version.map(Self.isVersion) ?? true)
            && (build.map { (0...1_000_000_000).contains($0) } ?? true)
    }

    /// Elapsed milliseconds, clamped to the range `isValid` accepts.
    public static func durationMS(from start: Date, to end: Date = Date()) -> Int {
        min(3_600_000, max(0, Int(end.timeIntervalSince(start) * 1_000)))
    }

    /// Healthy, repetitive outcomes. When the history is full they are
    /// evicted before failures, rejections and state changes.
    public var isRoutine: Bool {
        switch kind {
        case .readStarted, .readSucceeded, .helperReady: return true
        case .readDeferred: return reason == .scheduled || reason == .pendingRequest
        case .authenticationChecked: return reason == .signedIn
        case .updateState: return reason == .checking || reason == .upToDate || reason == .idle
        default: return false
        }
    }

    public static func isVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 40 && (1...4).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }

    public var line: String {
        var fields = [date.ISO8601Format(), area.rawValue, kind.rawValue]
        if let reason { fields.append("reason=\(reason.rawValue)") }
        if let phase { fields.append("phase=\(phase.rawValue)") }
        if let durationMS { fields.append("durationMs=\(durationMS)") }
        if let sampleAgeSeconds { fields.append("sampleAgeSeconds=\(sampleAgeSeconds)") }
        if let cacheAdvanced { fields.append("cacheAdvanced=\(cacheAdvanced)") }
        if let failureCount { fields.append("failureCount=\(failureCount)") }
        if let nextAttemptAt { fields.append("nextAttempt=\(nextAttemptAt.ISO8601Format())") }
        if let version { fields.append("version=\(version)") }
        if let build { fields.append("build=\(build)") }
        return fields.joined(separator: " ")
    }
}
