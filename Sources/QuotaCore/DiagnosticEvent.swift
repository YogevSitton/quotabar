import Foundation

/// A closed schema: callers cannot put provider replies, arbitrary error text,
/// paths, URLs, account identifiers or credentials into the diagnostic history.
public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public enum Area: String, Codable, Sendable { case app, codex, claude, antigravity, updates }
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
        case cancelled, cancelledBeforeLaunch, terminalUnavailable, exitedWithError, missingReport
        case connectRequired, profileUnavailable, administratorPolicy
    }
    public enum Phase: String, Codable, Sendable { case launch, initialize, version, usage, parsing, savingSchedule }
    /// The category of a CLI's final top-level JSON object, never its values.
    public enum Report: String, Codable, Sendable { case missing, usage, noGroups, failedStatus, modelTurn, unexpectedShape }

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
    /// Whether the attempt could start the CLI's own sign-in (an explicit Connect).
    public var signInAllowed: Bool?
    public var exitStatus: Int?
    /// Whether stderr contained the reviewed fixed authentication error text.
    public var authenticationNotice: Bool?
    public var report: Report?

    public init(area: Area, kind: Kind, reason: Reason? = nil, phase: Phase? = nil, date: Date = Date(),
                durationMS: Int? = nil, sampleAgeSeconds: Int? = nil, cacheAdvanced: Bool? = nil,
                failureCount: Int? = nil, nextAttemptAt: Date? = nil, version: String? = nil, build: Int? = nil,
                signInAllowed: Bool? = nil, exitStatus: Int? = nil, authenticationNotice: Bool? = nil, report: Report? = nil) {
        self.date = date; self.area = area; self.kind = kind; self.reason = reason
        self.phase = phase
        self.durationMS = durationMS; self.sampleAgeSeconds = sampleAgeSeconds; self.cacheAdvanced = cacheAdvanced
        self.failureCount = failureCount; self.nextAttemptAt = nextAttemptAt; self.version = version; self.build = build
        self.signInAllowed = signInAllowed; self.exitStatus = exitStatus
        self.authenticationNotice = authenticationNotice; self.report = report
    }

    public var isValid: Bool {
        func validDate(_ value: Date) -> Bool {
            value.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains(value.timeIntervalSince1970)
        }
        return validDate(date) && (nextAttemptAt.map(validDate) ?? true)
            && (durationMS.map { (0...3_600_000).contains($0) } ?? true)
            && (sampleAgeSeconds.map { (-1_000_000_000...1_000_000_000).contains($0) } ?? true)
            && (failureCount.map { (0...10).contains($0) } ?? true)
            && (version.map(Self.isVersion) ?? true)
            && (build.map { (0...1_000_000_000).contains($0) } ?? true)
            && (exitStatus.map { (0...255).contains($0) } ?? true)
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
        if let signInAllowed { fields.append("signInAllowed=\(signInAllowed)") }
        if let exitStatus { fields.append("exitStatus=\(exitStatus)") }
        if let authenticationNotice { fields.append("authenticationNotice=\(authenticationNotice)") }
        if let report { fields.append("report=\(report.rawValue)") }
        return fields.joined(separator: " ")
    }
}
