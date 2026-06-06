// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Skinner",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SkinnerCore",   targets: ["SkinnerCore"]),
        .library(name: "SkinnerPlayer", targets: ["SkinnerPlayer"]),
        .library(name: "SkinnerViz",    targets: ["SkinnerViz"]),
        .executable(name: "Skinner",    targets: ["Skinner"]),
    ],
    targets: [
        .binaryTarget(
            name: "projectM",
            path: "vendor/projectM.xcframework"
        ),
        .target(
            name: "SkinnerCore",
            path: "Sources/SkinnerCore",
            resources: [.copy("Resources")]
        ),
        .target(
            name: "SkinnerPlayer",
            dependencies: ["SkinnerCore"],
            path: "Sources/SkinnerPlayer"
        ),
        .target(
            name: "SkinnerViz",
            dependencies: ["SkinnerCore", "projectM"],
            path: "Sources/SkinnerViz",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .executableTarget(
            name: "Skinner",
            dependencies: ["SkinnerCore", "SkinnerPlayer", "SkinnerViz"],
            path: "Sources/Skinner"
        ),
        .testTarget(
            name: "SkinnerCoreTests",
            dependencies: ["SkinnerCore"],
            path: "Tests/SkinnerCoreTests"
        ),
    ]
)
