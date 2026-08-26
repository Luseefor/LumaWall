// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LumaWall",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LumaWallCore", targets: ["LumaWallCore"]),
        .executable(name: "LumaWall", targets: ["LumaWallApp"]),
    ],
    targets: [
        .target(name: "LumaWallCore"),
        .executableTarget(name: "LumaWallApp", dependencies: ["LumaWallCore"]),
        .testTarget(name: "LumaWallCoreTests", dependencies: ["LumaWallCore"]),
    ]
)
