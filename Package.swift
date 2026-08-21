// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fs9kit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NineP", targets: ["NineP"]),
        .library(name: "NinePClient", targets: ["NinePClient"]),
        .library(name: "NinePServer", targets: ["NinePServer"]),
        .library(name: "FS9Core", targets: ["FS9Core"]),
        .library(name: "FS9KitAdapter", targets: ["FS9KitAdapter"]),
        .library(name: "FS9NFS", targets: ["FS9NFS"]),
    ],
    targets: [
        .target(name: "NineP"),
        .target(name: "NinePClient", dependencies: ["NineP"]),
        .target(name: "NinePServer", dependencies: ["NineP"]),
        .target(name: "FS9Core", dependencies: ["NinePClient"]),
        .target(name: "FS9KitAdapter", dependencies: ["FS9Core", "NinePClient", "NineP"]),
        .target(name: "FS9NFS", dependencies: ["FS9Core", "NinePClient", "NineP"]),
        .testTarget(name: "NinePTests", dependencies: ["NineP"]),
        .testTarget(name: "NinePServerTests", dependencies: ["NinePServer", "NineP"]),
        .testTarget(name: "NinePClientTests", dependencies: ["NinePClient"]),
        .testTarget(name: "FS9KitAdapterTests", dependencies: ["FS9KitAdapter"]),
        .testTarget(name: "InteropTests", dependencies: ["NinePClient", "FS9Core"]),
        .testTarget(name: "FS9NFSTests",
                    dependencies: ["FS9NFS", "FS9Core", "NinePClient", "NinePServer"]),
    ]
)
