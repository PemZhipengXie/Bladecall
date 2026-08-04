// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompletionBell",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "JianlingShared", targets: ["JianlingShared"]),
        .library(name: "JianlingSync", targets: ["JianlingSync"]),
        .library(name: "JianlingCloudSync", targets: ["JianlingCloudSync"]),
        .library(name: "CompletionBellCore", targets: ["CompletionBellCore"]),
        .executable(name: "CompletionBell", targets: ["CompletionBell"]),
        .executable(name: "completion-bell-cli", targets: ["CompletionBellCLI"]),
        .executable(name: "completion-bell-tests", targets: ["CompletionBellTests"])
    ],
    targets: [
        .target(name: "JianlingShared"),
        .target(name: "JianlingSync", dependencies: ["JianlingShared"]),
        .target(name: "JianlingCloudSync", dependencies: ["JianlingShared"]),
        .target(name: "CompletionBellCore"),
        .executableTarget(
            name: "CompletionBell",
            dependencies: ["CompletionBellCore", "JianlingShared", "JianlingSync", "JianlingCloudSync"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CompletionBellCLI",
            dependencies: ["CompletionBellCore"]
        ),
        .executableTarget(
            name: "CompletionBellTests",
            dependencies: ["CompletionBellCore", "JianlingShared", "JianlingSync", "JianlingCloudSync"]
        )
    ],
    swiftLanguageModes: [.v5]
)
