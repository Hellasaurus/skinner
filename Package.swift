// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Skinner",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SkinnerCore", targets: ["SkinnerCore"]),
    ],
    targets: [
        .target(
            name: "SkinnerCore",
            path: "Sources/SkinnerCore"
        ),
        .testTarget(
            name: "SkinnerCoreTests",
            dependencies: ["SkinnerCore"],
            path: "Tests/SkinnerCoreTests"
        ),
    ]
)
