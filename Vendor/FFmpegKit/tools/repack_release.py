#!/usr/bin/env python3
"""Repackage a stock kingslay/FFmpegKit tag as SwiftPM binary-target zips for visionOS + tvOS.

FFmpegKit 9.x commits its xcframeworks (all Apple platforms, ~1.5 GB) straight into the git
tag and publishes no release assets. This takes a (sparse) checkout of the tag and, for every
binary target the FFmpegKit target depends on (libmpv excluded — that is for the MPV player):
  - copies Sources/<name>.xcframework
  - keeps only the visionOS and tvOS libraries (device + simulator; iOS / macOS / Catalyst /
    watchOS are dropped) and rewrites Info.plist accordingly
  - zips it with ditto and computes the SwiftPM checksum
It also zips Sources/FFmpegKit (the C shim target: include/*.h, *.c, Resources; the big
private/ Vulkan headers are not needed — renderer.c is entirely commented out) as
FFmpegKit-sources.zip, so Vendor/FFmpegKit carries no copy of upstream's sources either.
Then it writes Vendor/FFmpegKit/Package.swift with path-based binary targets, which
tools/fetch_binaries.sh fills from the release.

usage: repack_release.py <fk checkout> <out dir> <package.swift path> <ffmpegkit tag>
"""
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

KEEP_PLATFORMS = {"xros", "tvos"}
SKIP_TARGETS = {"libmpv"}
SOURCES_NAME = "FFmpegKit-sources"


def binary_targets(package_swift: Path) -> list[str]:
    text = package_swift.read_text()
    names = re.findall(r'\.binaryTarget\(\s*name:\s*"([^"]+)"', text)
    if not names:
        raise SystemExit("no binaryTarget entries found in upstream Package.swift")
    return [n for n in names if n not in SKIP_TARGETS]


def strip_xcframework(path: Path) -> list[str]:
    info_path = path / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    kept, dropped = [], []
    for lib in info["AvailableLibraries"]:
        wanted = lib["SupportedPlatform"] in KEEP_PLATFORMS and (path / lib["LibraryIdentifier"]).is_dir()
        (kept if wanted else dropped).append(lib)
    if not any("SupportedPlatformVariant" not in lib for lib in kept):
        raise SystemExit(f"{path.name}: no visionOS/tvOS device slice")
    for lib in dropped:
        shutil.rmtree(path / lib["LibraryIdentifier"], ignore_errors=True)
    # Anything on disk that is not in the plist (sparse checkout leftovers) goes too.
    keep_ids = {lib["LibraryIdentifier"] for lib in kept}
    for child in path.iterdir():
        if child.is_dir() and child.name not in keep_ids:
            shutil.rmtree(child, ignore_errors=True)
    info["AvailableLibraries"] = kept
    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))
    return [lib["LibraryIdentifier"] for lib in kept]


def zip_and_checksum(src: Path, zip_path: Path) -> str:
    zip_path.unlink(missing_ok=True)
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(src), str(zip_path)], check=True)
    return subprocess.run(["swift", "package", "compute-checksum", str(zip_path)],
                          check=True, capture_output=True, text=True).stdout.strip()


def main() -> None:
    fk, out, package_swift = (Path(a) for a in sys.argv[1:4])
    tag = sys.argv[4]
    targets = binary_targets(fk / "Package.swift")
    stage = out / "stage"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    out.mkdir(parents=True, exist_ok=True)
    checksums: dict[str, str] = {}
    manifest = [f"FFmpegKit {tag} (kingslay/FFmpegKit) repackaged for visionOS + tvOS", ""]

    for name in targets:
        src = fk / "Sources" / f"{name}.xcframework"
        if not src.is_dir():
            raise SystemExit(f"missing {src}")
        dst = stage / src.name
        shutil.copytree(src, dst, symlinks=True)
        slices = strip_xcframework(dst)
        zip_path = out / f"{name}.xcframework.zip"
        checksum = zip_and_checksum(dst, zip_path)
        checksums[name] = checksum
        line = f"{name:16s} {','.join(slices):70s} {zip_path.stat().st_size / 1e6:7.1f} MB  {checksum}"
        print(line)
        manifest.append(line)

    # The C target's sources (shims + dummy .c files + privacy manifest).
    src_dir = stage / "FFmpegKit"
    shutil.copytree(fk / "Sources" / "FFmpegKit", src_dir, ignore=shutil.ignore_patterns("private"))
    zip_path = out / f"{SOURCES_NAME}.zip"
    checksum = zip_and_checksum(src_dir, zip_path)
    checksums[SOURCES_NAME] = checksum
    line = f"{SOURCES_NAME:16s} {'Sources/FFmpegKit (include, *.c, Resources)':70s} {zip_path.stat().st_size / 1e6:7.1f} MB  {checksum}"
    print(line)
    manifest.append(line)

    (out / "checksums.json").write_text(json.dumps(checksums, indent=2) + "\n")
    (out / "MANIFEST.txt").write_text("\n".join(manifest) + "\n")

    deps = ",\n".join(f'                "{n}"' for n in targets)
    binaries = "\n".join(
        f'        .binaryTarget(\n            name: "{n}",\n'
        f'            path: "Sources/{n}.xcframework"\n        ),'
        for n in targets)
    package_swift.parent.mkdir(parents=True, exist_ok=True)
    package_swift.write_text(f'''// swift-tools-version:5.9
// GENERATED by Vendor/FFmpegKit/tools/repack_release.py (workflow "FFmpegKit repack").
// Stock FFmpegKit {tag} (kingslay/FFmpegKit, GPLv3, see LICENSE) — the tag's xcframeworks
// stripped to their visionOS + tvOS slices (device + simulator). The binaries and the
// Sources/FFmpegKit shim files are not in git: tools/fetch_binaries.sh downloads them from
// release RELEASE_TAG and verifies checksums.json (CI does this before resolving packages).
import PackageDescription

let package = Package(
    name: "FFmpegKit",
    platforms: [.tvOS(.v13), .visionOS(.v1)],
    products: [
        .library(name: "FFmpegKit", targets: ["FFmpegKit"]),
    ],
    targets: [
        .target(
            name: "FFmpegKit",
            dependencies: [
{deps},
            ],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("IOKit", .when(platforms: [.visionOS])),
                .linkedFramework("IOSurface"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Security"),
                .linkedFramework("UIKit"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("c++"),
                .linkedLibrary("expat"),
                .linkedLibrary("iconv"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
            ]
        ),
{binaries}
    ]
)
''')
    print(f"wrote {package_swift}")


if __name__ == "__main__":
    main()
