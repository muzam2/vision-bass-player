// swift-tools-version:5.9
// ChiakiCore: chiaki-ng's PlayStation Remote Play protocol core (AGPL-3.0 with the OpenSSL
// exception, see vendor/chiaki/COPYING) plus a small C API for Swift (bridge/). Vendored by
// tools/vendor_chiaki.sh at the commits in UPSTREAM; nothing under vendor/ is edited by hand.
// PSN-only parts (holepunch, AIA/curl) are left out and stubbed in stubs/, so the app needs no
// curl, json-c, miniupnpc or libevent: Remote Play is local-network only.
//
// OpenSSL (libcrypto) and Opus come from FFmpegKit's xcframeworks, which the app links anyway.
// Their headers live inside the framework slices (Headers/openssl, Headers/opus), which a
// framework search path can't reach as <openssl/...>, so they are passed with -I. The device
// slice's headers serve the simulator too (same OpenSSL configuration on arm64).
import Foundation
import PackageDescription

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ffmpegKitSources = "\(here)/../FFmpegKit/Sources"
func frameworkHeaders(_ name: String, _ slice: String) -> String {
    "\(ffmpegKitSources)/\(name).xcframework/\(slice)/\(name).framework/Headers"
}

let package = Package(
    name: "ChiakiCore",
    platforms: [.tvOS(.v13), .visionOS(.v1), .iOS(.v13)],
    products: [
        .library(name: "ChiakiCore", targets: ["ChiakiCore"]),
    ],
    dependencies: [
        .package(path: "../FFmpegKit"),
    ],
    targets: [
        .target(
            name: "ChiakiCore",
            dependencies: [.product(name: "FFmpegKit", package: "FFmpegKit")],
            path: ".",
            exclude: ["vendor/nanopb/LICENSE.txt"],
            sources: [
                "vendor/chiaki/src",
                "vendor/proto",
                "vendor/nanopb",
                "vendor/jerasure/src",
                "vendor/gf-complete/src",
                "stubs",
                "bridge/rpbridge.c",
            ],
            publicHeadersPath: "bridge/include",
            cSettings: [
                .headerSearchPath("vendor/chiaki/include"),
                .headerSearchPath("vendor/chiaki/src"),
                .headerSearchPath("vendor/proto"),
                .headerSearchPath("vendor/nanopb"),
                .headerSearchPath("vendor/jerasure/include"),
                .headerSearchPath("vendor/gf-complete/include"),
                .define("PB_C99_STATIC_ASSERT"),
                .unsafeFlags([
                    "-I", frameworkHeaders("libcrypto", "xros-arm64"),
                    "-I", frameworkHeaders("libopus", "xros-arm64"),
                ], .when(platforms: [.visionOS])),
                .unsafeFlags([
                    "-I", frameworkHeaders("libcrypto", "tvos-arm64"),
                    "-I", frameworkHeaders("libopus", "tvos-arm64"),
                ], .when(platforms: [.tvOS])),
                // Vendored code: upstream's warnings (OpenSSL 3 deprecations, gf-complete) are
                // not ours to fix.
                .unsafeFlags(["-w"]),
            ]
        ),
    ],
    cLanguageStandard: .gnu11
)
