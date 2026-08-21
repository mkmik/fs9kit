// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fs9kit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NineP", targets: ["NineP"]),
        .library(name: "NinePClient", targets: ["NinePClient"]),
        .library(name: "FS9Core", targets: ["FS9Core"]),
    ],
    targets: [
        .target(name: "NineP"),
        .target(name: "NinePClient", dependencies: ["NineP"]),
        .target(name: "FS9Core", dependencies: ["NinePClient"]),
        .testTarget(name: "NinePTests", dependencies: ["NineP"]),
        .testTarget(name: "NinePClientTests", dependencies: ["NinePClient"]),
    ]
)
