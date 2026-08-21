// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fs9kit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NineP", targets: ["NineP"]),
    ],
    targets: [
        .target(name: "NineP"),
        .testTarget(name: "NinePTests", dependencies: ["NineP"]),
    ]
)
