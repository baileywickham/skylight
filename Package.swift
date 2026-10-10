// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Skylight",
    platforms: [.macOS(.v27)],
    targets: [
        .target(name: "SkylightCore"),
        .executableTarget(name: "SkylightService", dependencies: ["SkylightCore"]),
        .executableTarget(name: "skylight", dependencies: ["SkylightCore"]),
        .testTarget(name: "SkylightCoreTests", dependencies: ["SkylightCore"]),
    ],
    swiftLanguageModes: [.v5]
)
