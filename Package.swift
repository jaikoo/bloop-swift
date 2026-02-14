// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "BloopClient",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(
            name: "BloopClient",
            targets: ["BloopClient"]
        ),
    ],
    targets: [
        .target(
            name: "BloopClient",
            path: "Sources/BloopClient"
        ),
        .testTarget(
            name: "BloopClientTests",
            dependencies: ["BloopClient"],
            path: "Tests/BloopClientTests"
        ),
    ]
)
