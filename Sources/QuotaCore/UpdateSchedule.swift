import Foundation

/// Why a feed or archive request did not produce usable bytes. None of these
/// ever asks for a GitHub account, token or CLI: public feeds are anonymous.
public enum UpdateFetchFailure: Equatable, Sendable {
    /// 404 and other "not there" answers: nothing is published for this channel yet.
    case unavailable
    /// GitHub asked us to wait; never retry before `until`.
    case rateLimited(until: Date)
    /// Timeouts, connection problems and server errors; retried with backoff.
    case transient
    /// Malformed, oversized or unverifiable data; not retried before the next scheduled check.
    case invalid

    public static let minimumRateLimitWait: TimeInterval = 60
    public static let maximumRateLimitWait: TimeInterval = 86_400

    /// Classifies an HTTP status. Returns nil for success.
    public static func classify(status: Int, headers: [String: String], now: Date) -> UpdateFetchFailure? {
        if status == 200 { return nil }
        let header = Dictionary(headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) },
                                uniquingKeysWith: { first, _ in first })
        if status == 429 || (status == 403 && (header["retry-after"] != nil || header["x-ratelimit-remaining"] == "0")) {
            var wait: TimeInterval = 3_600
            if let seconds = header["retry-after"].flatMap(TimeInterval.init) {
                wait = seconds
            } else if let reset = header["x-ratelimit-reset"].flatMap(TimeInterval.init) {
                wait = reset - now.timeIntervalSince1970
            }
            wait = min(maximumRateLimitWait, max(minimumRateLimitWait, wait))
            return .rateLimited(until: now.addingTimeInterval(wait))
        }
        if (500...599).contains(status) || status == 408 { return .transient }
        if (400...499).contains(status) { return .unavailable }
        return .invalid
    }
}

/// The result of fetching and verifying one channel feed. Absence and invalid
/// data are deliberately different: invalid data never counts as "nothing published".
public enum UpdateFeedResult: Equatable, Sendable {
    case absent
    case invalid
    case verified(UpdateManifest)
}

public enum UpdateSelection: Equatable, Sendable {
    case candidate(UpdateManifest, invalidFeeds: [UpdateChannel])
    case unavailable(invalidFeeds: [UpdateChannel])
    case conflictingIdentity

    /// Stable uses only the Stable feed. Preview uses the higher build of the
    /// feeds that are present and verified; either one alone is enough.
    public static func select(channel: UpdateChannel, stable: UpdateFeedResult, preview: UpdateFeedResult) -> UpdateSelection {
        let feeds: [(UpdateChannel, UpdateFeedResult)] = channel == .stable ? [(.stable, stable)] : [(.stable, stable), (.preview, preview)]
        let invalid = feeds.filter { $0.1 == .invalid }.map(\.0)
        let verified = feeds.compactMap { feed -> UpdateManifest? in
            if case .verified(let manifest) = feed.1, manifest.channel == feed.0 { return manifest }
            return nil
        }
        if verified.count == 2 {
            do { try UpdatePolicy.consistent(verified[0], verified[1]) } catch { return .conflictingIdentity }
        }
        guard let best = verified.max(by: { $0.build < $1.build }) else { return .unavailable(invalidFeeds: invalid) }
        return .candidate(best, invalidFeeds: invalid)
    }
}

/// Highest verified identity seen per feed channel, persisted privately.
public struct UpdateHighWater: Codable, Equatable, Sendable {
    public var stable: UpdateIdentity?
    public var preview: UpdateIdentity?
    public init(stable: UpdateIdentity? = nil, preview: UpdateIdentity? = nil) { self.stable = stable; self.preview = preview }

    public func identity(for channel: UpdateChannel) -> UpdateIdentity? { channel == .stable ? stable : preview }

    /// Records a verified manifest when it is newer than what this channel has seen.
    public func recording(_ manifest: UpdateManifest) -> UpdateHighWater {
        var copy = self
        let current = identity(for: manifest.channel)
        guard current == nil || manifest.build > current!.build else { return copy }
        if manifest.channel == .stable { copy.stable = UpdateIdentity(manifest) } else { copy.preview = UpdateIdentity(manifest) }
        return copy
    }
}

public enum UpdateDecision: Equatable, Sendable {
    case newer(UpdateManifest)
    case upToDate
    case conflictingIdentity
    case invalid

    /// Applies downgrade, high-water and identity rules to a selected candidate.
    public static func evaluate(_ manifest: UpdateManifest, publicKey: String, installedBuild: UInt64,
                                highWater: UpdateHighWater) -> UpdateDecision {
        do {
            try UpdatePolicy.validate(manifest, channel: manifest.channel, publicKey: publicKey,
                                      installedBuild: installedBuild, highWater: highWater.identity(for: manifest.channel))
            return .newer(manifest)
        } catch UpdateValidationError.rollback { return .upToDate }
        catch UpdateValidationError.conflictingIdentity { return .conflictingIdentity }
        catch { return .invalid }
    }
}

/// Check timing: shortly after launch, then about hourly while running.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 3_600
    public static let jitter: TimeInterval = 300
    public static let transientDelays: [TimeInterval] = [300, 900, 1_800, 3_600]

    /// 2-10 minutes after launch. `random` is in 0...1.
    public static func firstCheckDelay(random: Double) -> TimeInterval {
        120 + 480 * min(1, max(0, random))
    }

    /// About an hour, plus or minus five minutes.
    public static func regularDelay(random: Double) -> TimeInterval {
        interval - jitter + 2 * jitter * min(1, max(0, random))
    }

    /// 5, 15, 30, then 60 minutes, each with up to 10% extra jitter.
    public static func transientDelay(attempt: Int, random: Double) -> TimeInterval {
        let base = transientDelays[min(max(0, attempt), transientDelays.count - 1)]
        return base * (1 + 0.1 * min(1, max(0, random)))
    }

    /// After wake, check only when the last attempt was more than an hour ago.
    public static func shouldCheckAfterWake(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) > interval
    }

    /// The next automatic check after a failure, honoring any rate-limit wait.
    public static func delay(after failure: UpdateFetchFailure, attempt: Int, now: Date, random: Double) -> TimeInterval {
        switch failure {
        case .rateLimited(let until): return max(UpdateFetchFailure.minimumRateLimitWait, until.timeIntervalSince(now))
        case .transient: return transientDelay(attempt: attempt, random: random)
        case .unavailable, .invalid: return regularDelay(random: random)
        }
    }
}
