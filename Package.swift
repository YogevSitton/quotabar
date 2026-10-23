// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuotaBar", targets: ["QuotaBar"])],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "QuotaBar", dependencies: ["QuotaCore"], resources: [.process("Resources")]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"])
    ]
)
