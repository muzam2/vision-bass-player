// swift-tools-version:5.9
// edge264-mvc (https://github.com/jens-duttke/edge264-mvc, BSD-3-Clause, see LICENSE_BSD.txt),
// vendored at commit 515a7ba (2026-11-04) for Bass Player's 3D Blu-ray (H.264 MVC) playback.
// The whole decoder is one translation unit (src/edge264mvc.c includes the other .c files),
// built with the flags its Makefile uses for iOS; NEON comes from the arm64 target itself.
// include/edge264mvc.h is a copy of ./edge264mvc.h so SwiftPM can expose it as a module.
import PackageDescription

let package = Package(
    name: "edge264mvc",
    platforms: [.iOS(.v13), .tvOS(.v13), .visionOS(.v1), .macOS(.v10_15)],
    products: [
        .library(name: "edge264mvc", targets: ["edge264mvc"]),
    ],
    targets: [
        .target(
            name: "edge264mvc",
            path: ".",
            exclude: ["Makefile", "README.md", "DESIGN.md", "LICENSE_BSD.txt", "edge264mvc.h", "Package.swift"],
            sources: ["src/edge264mvc.c"],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3", "-fwrapv", "-flax-vector-conversions", "-Wno-override-init"]),
            ]
        ),
    ],
    cLanguageStandard: .gnu11
)
