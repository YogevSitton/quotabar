import XCTest
import Darwin
@testable import QuotaBar

/// Synthetic filesystem fixtures only. These tests do not launch a helper,
/// inspect real credentials, or call a provider. Qualification compiles them.
final class AntigravityProfileTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("antigravity-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("user", isDirectory: true), root.appendingPathComponent("admin.json"))
    }

    func testManagedSettingsAreSeparateFromPersonalSettings() throws {
        try fixture { user, policy in
            let personal = user.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
            try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
            let original = Data("{\"disableSlashCommands\":true,\"synthetic\":true}".utf8)
            let file = personal.appendingPathComponent("settings.json")
            try original.write(to: file)
            let lease = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            XCTAssertNotEqual(lease.home, user)
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(lease.environment["HOME"], lease.home.path)
            XCTAssertEqual(lease.environment["AGY_CLI_DISABLE_AUTO_UPDATE"], "true")
            XCTAssertNil(lease.environment["GEMINI_API_KEY"])
            XCTAssertNil(lease.environment["SSH_CONNECTION"])
            XCTAssertNil(lease.environment["AGY_CDE_SEAMLESS_AUTH"])
            XCTAssertTrue(lease.arguments.contains("--gemini_dir=\(lease.geminiDirectory.path)"))
            // 1.4.9 exits with status 2 on this undefined flag before doing anything.
            XCTAssertFalse(lease.arguments.contains { $0.hasPrefix("--include-default-customizations") })
            try lease.validateForLaunch()
        }
    }

    func testLeaseExcludesAnotherCopyAndBudgetSurvivesReacquisition() throws {
        try fixture { user, policy in
            var first: AntigravityProfile.Lease? = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            let saved = Data("{\"version\":1,\"nextRequestAt\":12345,\"failures\":2}".utf8)
            try first!.writeState(saved)
            XCTAssertThrowsError(try AntigravityProfile.acquire(home: user, administratorSettings: policy)) {
                guard case AntigravityProfile.ProfileError.busy = $0 else { return XCTFail("Expected an active lease") }
            }
            first = nil
            let second = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            XCTAssertEqual(try second.readState(), saved)
            let attributes = try FileManager.default.attributesOfItem(atPath: second.home.appendingPathComponent("request-budget.json").path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testCLIRewriteIsNormalizedOnlyAtNextAcquisition() throws {
        try fixture { user, policy in
            var first: AntigravityProfile.Lease? = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            let settings = first!.geminiDirectory.appendingPathComponent("quotabar/settings.json")
            let syntheticToken = first!.geminiDirectory.appendingPathComponent("synthetic-token-placeholder")
            let tokenData = Data("synthetic fixture - not a credential".utf8)
            try tokenData.write(to: syntheticToken)
            try Data("{\"disableSlashCommands\":true,\"statusLine\":{\"command\":\"synthetic\"}}".utf8).write(to: settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
            XCTAssertThrowsError(try first!.validateForLaunch())
            first = nil
            let second = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            XCTAssertEqual(try Data(contentsOf: settings), Data("{\"disableSlashCommands\":false}\n".utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try Data(contentsOf: syntheticToken), tokenData)
            try second.validateForLaunch()
        }
    }

    func testSettingsSymlinkAndHardLinkAreRefusedWithoutChangingTarget() throws {
        for symlink in [true, false] {
            try fixture { user, policy in
                var lease: AntigravityProfile.Lease? = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
                let settings = lease!.geminiDirectory.appendingPathComponent("quotabar/settings.json")
                lease = nil
                let target = user.appendingPathComponent("synthetic-personal.json")
                let original = Data("do not replace this synthetic file".utf8)
                try original.write(to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                try FileManager.default.removeItem(at: settings)
                if symlink {
                    try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
                } else {
                    try FileManager.default.linkItem(at: target, to: settings)
                }
                XCTAssertThrowsError(try AntigravityProfile.acquire(home: user, administratorSettings: policy))
                XCTAssertEqual(try Data(contentsOf: target), original)
            }
        }
    }

    /// Mirrors the layout 1.4.9 leaves after its first full run.
    func testCLIHooksLinkIsAcceptedOnlyForTheControlledConfigCopy() throws {
        try fixture { user, policy in
            var lease: AntigravityProfile.Lease? = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            let hooks = lease!.geminiDirectory.appendingPathComponent("quotabar/hooks.json")
            let shared = lease!.geminiDirectory.appendingPathComponent("config/hooks.json")
            lease = nil
            try FileManager.default.removeItem(at: hooks)
            try FileManager.default.createSymbolicLink(at: hooks, withDestinationURL: shared)
            lease = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            try lease!.validateForLaunch()
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: hooks.path), shared.path)
            lease = nil

            let target = user.appendingPathComponent("synthetic-hooks.json")
            let original = try Data(contentsOf: shared)
            try original.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try FileManager.default.removeItem(at: hooks)
            try FileManager.default.createSymbolicLink(at: hooks, withDestinationURL: target)
            XCTAssertThrowsError(try AntigravityProfile.acquire(home: user, administratorSettings: policy))
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    /// The synthetic home has no real keychain; only the link itself is checked.
    func testKeychainFolderLinksOnlyToTheUsersOwnKeychains() throws {
        try fixture { user, policy in
            let expected = user.appendingPathComponent("Library/Keychains", isDirectory: true).path
            var lease: AntigravityProfile.Lease? = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            let link = lease!.home.appendingPathComponent("Library/Keychains")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), expected)
            try lease!.validateForLaunch()

            // A link elsewhere refuses the launch and is replaced at the next acquisition.
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/synthetic/elsewhere")
            XCTAssertThrowsError(try lease!.validateForLaunch())
            lease = nil
            lease = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), expected)
            lease = nil

            // A real folder there might hold a keychain, so it is refused and kept.
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
            let kept = link.appendingPathComponent("synthetic-placeholder")
            try Data("synthetic fixture - not a keychain".utf8).write(to: kept)
            XCTAssertThrowsError(try AntigravityProfile.acquire(home: user, administratorSettings: policy))
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        }
    }

    func testSymlinkedAncestorIsRefused() throws {
        try fixture { user, policy in
            let realHome = user.deletingLastPathComponent().appendingPathComponent("real-user", isDirectory: true)
            try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: user, withDestinationURL: realHome)
            XCTAssertThrowsError(try AntigravityProfile.acquire(home: user, administratorSettings: policy))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: realHome.path).isEmpty)
        }
    }

    func testAdministratorPolicyIsRefusedWithoutReadingOrChangingIt() throws {
        try fixture { user, policy in
            let original = Data("synthetic policy".utf8)
            try original.write(to: policy)
            XCTAssertThrowsError(try AntigravityProfile.acquire(home: user, administratorSettings: policy)) {
                guard case AntigravityProfile.ProfileError.administratorPolicy = $0 else { return XCTFail("Expected administrator policy refusal") }
            }
            XCTAssertEqual(try Data(contentsOf: policy), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: user.path))
        }
    }

    func testDirtyWorkingDirectoryAndUnsafeBudgetStopLaunch() throws {
        try fixture { user, policy in
            let lease = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            try Data("synthetic".utf8).write(to: lease.workingDirectory.appendingPathComponent("project-config"))
            XCTAssertThrowsError(try lease.validateForLaunch())
            XCTAssertThrowsError(try lease.writeState(Data(repeating: 0, count: 4_097)))
            let target = user.appendingPathComponent("synthetic-budget-target")
            try Data("unchanged".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: lease.home.appendingPathComponent("request-budget.json"), withDestinationURL: target)
            XCTAssertThrowsError(try lease.readState())
            XCTAssertThrowsError(try lease.writeState(Data("{}".utf8)))
            XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
        }
    }

    func testNextAcquisitionClearsLeftoversWithoutFollowingLinks() throws {
        try fixture { user, policy in
            var lease: AntigravityProfile.Lease? = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            let fm = FileManager.default
            let gemini = lease!.geminiDirectory, work = lease!.workingDirectory, home = lease!.home
            lease = nil
            let outside = user.appendingPathComponent("synthetic-outside", isDirectory: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let kept = outside.appendingPathComponent("kept.txt")
            try Data("synthetic outside file".utf8).write(to: kept)
            let token = gemini.appendingPathComponent("synthetic-token-placeholder")
            try Data("synthetic fixture - not a credential".utf8).write(to: token)
            try fm.createDirectory(at: work.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: work.appendingPathComponent("nested/deeper/file"))
            try fm.createSymbolicLink(at: work.appendingPathComponent("link"), withDestinationURL: outside)
            try fm.createDirectory(at: gemini.appendingPathComponent("skills"), withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            try Data("synthetic skill".utf8).write(to: gemini.appendingPathComponent("skills/example.md"))
            try fm.createSymbolicLink(at: gemini.appendingPathComponent("config/plugins"), withDestinationURL: outside)
            try Data("[]".utf8).write(to: gemini.appendingPathComponent("quotabar/plugins.json"))
            try fm.createDirectory(at: home.appendingPathComponent(".agents/rules"), withIntermediateDirectories: true)

            let second = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
            XCTAssertTrue(try fm.contentsOfDirectory(atPath: work.path).isEmpty)
            for removed in ["skills", "config/plugins", "quotabar/plugins.json"] {
                XCTAssertFalse(fm.fileExists(atPath: gemini.appendingPathComponent(removed).path), removed)
            }
            XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".agents").path))
            XCTAssertEqual(try Data(contentsOf: kept), Data("synthetic outside file".utf8))
            XCTAssertEqual(try Data(contentsOf: token), Data("synthetic fixture - not a credential".utf8))
            try second.validateForLaunch()
        }
    }

    func testGlobalPluginRegistrationsCannotBecomeActiveAfterCLIStartup() throws {
        for root in ["", "config/", "quotabar/"] {
            try fixture { user, policy in
                let lease = try AntigravityProfile.acquire(home: user, administratorSettings: policy)
                let plugins = lease.geminiDirectory.appendingPathComponent(root + "plugins", isDirectory: true)
                try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try lease.validateForLaunch()
                try Data("synthetic registration".utf8).write(to: plugins.appendingPathComponent("example.json"))
                XCTAssertThrowsError(try lease.validateForLaunch())
                try FileManager.default.removeItem(at: plugins)
                try Data("[]".utf8).write(to: lease.geminiDirectory.appendingPathComponent(root + "plugins.json"))
                XCTAssertThrowsError(try lease.validateForLaunch())
            }
        }
    }
}
