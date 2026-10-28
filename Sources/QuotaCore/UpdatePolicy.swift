import Foundation

/// The identity a signed build number stands for. One build number must always
/// describe the same commit and bytes, on every channel.
public struct UpdateIdentity: Codable, Equatable, Sendable {
    public let build: UInt64
    public let commit: String
    public let sha256: String
    public init(build: UInt64, commit: String, sha256: String) {
        self.build = build; self.commit = commit; self.sha256 = sha256
    }
    public init(_ manifest: UpdateManifest) {
        build = manifest.build; commit = manifest.commit; sha256 = manifest.sha256
    }
}

public enum UpdatePolicy {
    /// Accepts a verified manifest only as a newer candidate for this app.
    /// - `invalidMetadata`: wrong channel, key or identifiers for this app.
    /// - `conflictingIdentity`: the same build number seen before with other bytes.
    /// - `rollback`: not newer than the installed build or the channel high water.
    public static func validate(_ manifest: UpdateManifest, channel: UpdateChannel, publicKey: String,
                                installedBuild: UInt64, highWater: UpdateIdentity?) throws {
        try manifest.validate()
        guard manifest.channel == channel, manifest.publicKey == publicKey else {
            throw UpdateValidationError.invalidMetadata
        }
        if let highWater {
            if manifest.build == highWater.build && UpdateIdentity(manifest) != highWater {
                throw UpdateValidationError.conflictingIdentity
            }
            guard manifest.build >= highWater.build else { throw UpdateValidationError.rollback }
        }
        guard manifest.build > installedBuild else { throw UpdateValidationError.rollback }
    }

    /// Two verified manifests (for example the Preview and Stable feeds) must agree
    /// on commit and bytes whenever they name the same build.
    public static func consistent(_ first: UpdateManifest, _ second: UpdateManifest) throws {
        if first.build == second.build && UpdateIdentity(first) != UpdateIdentity(second) {
            throw UpdateValidationError.conflictingIdentity
        }
    }
}
