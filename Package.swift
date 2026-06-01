// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Skinner",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SkinnerCore", targets: ["SkinnerCore"]),
        .executable(name: "Skinner",  targets: ["Skinner"]),
    ],
    targets: [
        .target(
            name: "SkinnerCore",
            path: "Sources/SkinnerCore"
        ),
        .executableTarget(
            name: "Skinner",
            dependencies: ["SkinnerCore"],
            path: "Sources/Skinner"
        ),
        .testTarget(
            name: "SkinnerCoreTests",
            dependencies: ["SkinnerCore"],
            path: "Tests/SkinnerCoreTests"
        ),
    ]
)
