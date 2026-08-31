// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mobile-spike",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MobileSpikeFraming", targets: ["MobileSpikeFraming"]),
    ],
    targets: [
        .target(name: "MobileSpikeFraming"),
        .testTarget(
            name: "MobileSpikeFramingTests",
            dependencies: ["MobileSpikeFraming"]
        ),
    ]
)
