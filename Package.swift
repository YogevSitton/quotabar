// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"]),
        // Used only by the trusted release workflow and the owner's key setup.
        .executable(name: "QuotaReleaseTool", targets: ["QuotaReleaseTool"])
    ],
    targets: [
        .target(name: "QuotaCore"),
        .target(name: "QuotaUpdateSupport", dependencies: ["QuotaCore"]),
        .executableTarget(name: "QuotaReleaseTool", dependencies: ["QuotaCore", "QuotaUpdateSupport"]),
        .executableTarget(name: "QuotaBar", dependencies: ["QuotaCore"], resources: [.process("Resources")]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaUpdateSupportTests", dependencies: ["QuotaCore", "QuotaUpdateSupport"])
    ]
)
