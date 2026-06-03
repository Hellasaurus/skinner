// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Skinner",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SkinnerCore",   targets: ["SkinnerCore"]),
        .library(name: "SkinnerPlayer", targets: ["SkinnerPlayer"]),
        .executable(name: "Skinner",    targets: ["Skinner"]),
    ],
    targets: [
        .target(
            name: "SkinnerCore",
            path: "Sources/SkinnerCore"
        ),
        .target(
            name: "SkinnerPlayer",
            dependencies: ["SkinnerCore"],
            path: "Sources/SkinnerPlayer"
        ),
        .executableTarget(
            name: "Skinner",
            dependencies: ["SkinnerCore", "SkinnerPlayer"],
            path: "Sources/Skinner"
        ),
        .testTarget(
            name: "SkinnerCoreTests",
            dependencies: ["SkinnerCore"],
            path: "Tests/SkinnerCoreTests"
        ),
    ]
)
