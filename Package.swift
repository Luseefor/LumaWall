// swift-tools-version: 6.2
import PackageDescription

// New warnings fail the build so they get fixed when they appear.
let strictWarnings: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "LumaWall",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LumaWallCore", targets: ["LumaWallCore"]),
        .executable(name: "LumaWall", targets: ["LumaWallApp"]),
    ],
    targets: [
        .target(name: "LumaWallCore", swiftSettings: strictWarnings),
        .executableTarget(
            name: "LumaWallApp",
            dependencies: ["LumaWallCore"],
            resources: [.process("Resources")],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "LumaWallCoreTests",
            dependencies: ["LumaWallCore"],
            swiftSettings: strictWarnings
        ),
    ]
)
