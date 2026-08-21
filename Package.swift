// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fs9kit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NineP", targets: ["NineP"]),
        .library(name: "NinePClient", targets: ["NinePClient"]),
    ],
    targets: [
        .target(name: "NineP"),
        .target(name: "NinePClient", dependencies: ["NineP"]),
        .testTarget(name: "NinePTests", dependencies: ["NineP"]),
        .testTarget(name: "NinePClientTests", dependencies: ["NinePClient"]),
    ]
)
