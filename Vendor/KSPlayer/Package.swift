// swift-tools-version:5.9
// Vendored from https://github.com/kingslay/KSPlayer (branch GPLv3, Oct 2026) with local
// modifications for Dolby Vision profile 5 rendering. GPLv3 — see LICENSE.
import PackageDescription

let package = Package(
    name: "KSPlayer",
    defaultLocalization: "en",
    platforms: [.macOS(.v10_15), .macCatalyst(.v14), .iOS(.v13), .tvOS(.v13), .visionOS(.v1)],
    products: [
        .library(name: "KSPlayer", targets: ["KSPlayer"]),
    ],
    dependencies: [
        // Local FFmpegKit 9.0.2 (stock, visionOS + tvOS slices; binaries in this repo's release
        // ffmpegkit-9.0.2-vt1); see Vendor/FFmpegKit and docs/HANDOFF.md §3.
        .package(path: "../FFmpegKit"),
    ],
    targets: [
        .target(
            name: "KSPlayer",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                "DisplayCriteria",
            ],
            resources: [.process("Metal/Shaders.metal")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(name: "DisplayCriteria"),
    ]
)
