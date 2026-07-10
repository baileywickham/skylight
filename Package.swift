// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Skylight",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SkylightCore"),
        .executableTarget(name: "SkylightService", dependencies: ["SkylightCore"]),
        .executableTarget(name: "skylight", dependencies: ["SkylightCore"]),
        .testTarget(name: "SkylightCoreTests", dependencies: ["SkylightCore"]),
    ]
)
