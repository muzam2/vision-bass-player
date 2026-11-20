#!/usr/bin/env python3
"""Turn the per-architecture FFmpeg builds (build_slice.sh) into the seven Lib*.xcframeworks,
check them against the FFmpegKit base release they replace, and write everything a release
needs (zips, checksums.json, MANIFEST.txt, Package.swift).

Each new framework starts as a copy of the base release's framework (Info.plist, module map,
xcframework Info.plist) and gets the new binary, the new headers, a new ad-hoc signature and,
for device slices, a new dSYM. The other xcframeworks (dependencies) and FFmpegKit-sources.zip
are passed through byte for byte.

Hard failures (exit 1):
  - the configure line embedded in a new library differs from the one in the base library of
    the same slice/architecture (apart from --prefix)
  - a library does not carry the expected "FFmpeg version <tag>" string, or its Mach-O version
    is not the one in its headers, or its major version differs from the base
  - platform / minimum OS of a library differ from the base
  - the set of @rpath libraries a library loads differs from the base (a missing or extra
    embedded framework is a dyld crash at launch)
  - a header the base ships is gone (except the ones listed in REMOVED_HEADERS)
Reported in MANIFEST.txt without failing: system load commands, exported symbols, sizes and a
string-based comparison of the enabled components.

usage: assemble_frameworks.py <built dir> <base xcframeworks dir> <base zips dir> <out dir>
                              <Package.swift path> <ffmpeg tag, e.g. n9.1>
"""
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "tools"))
from repack_release import SOURCES_NAME, write_package_swift, zip_and_checksum  # noqa: E402

BASE = json.loads((HERE / "base-release.json").read_text())
FF_LIBS = ["Libavutil", "Libswresample", "Libswscale", "Libavcodec", "Libavformat", "Libavfilter", "Libavdevice"]
# Headers of the base release that the new FFmpeg version no longer has.
REMOVED_HEADERS = {"Libavutil": {"libm.h"}}   # FFmpeg 9.1 removed libavutil/libm.h

errors: list[str] = []
report: list[str] = []


def run(*cmd: str) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def fail(msg: str) -> None:
    errors.append(msg)
    print(f"::error::{msg}")


def note(msg: str = "") -> None:
    report.append(msg)
    print(msg)


def archs_of(binary: Path) -> list[str]:
    return run("lipo", "-archs", str(binary)).split()


def thin(binary: Path, arch: str, dst: Path) -> Path:
    if "Non-fat" in run("lipo", "-info", str(binary)):
        shutil.copyfile(binary, dst)
    else:
        run("lipo", str(binary), "-thin", arch, "-output", str(dst))
    return dst


def configure_line(binary: Path) -> list[str]:
    found = set(re.findall(rb"--prefix=[\x20-\x7e]+", binary.read_bytes()))
    if len(found) != 1:
        raise SystemExit(f"{binary}: expected one embedded configure line, found {len(found)}")
    return found.pop().decode().split(" ")[1:]          # drop --prefix=...


def loads(binary: Path) -> tuple[str, list[str]]:
    """(id line incl. versions, [dependent library names])"""
    lines = [ln.strip() for ln in run("otool", "-L", str(binary)).splitlines()[1:] if ln.strip()]
    return lines[0], [ln.split(" (")[0] for ln in lines[1:]]


def build_version(binary: Path) -> tuple[str, str, str]:
    out = run("vtool", "-show-build", str(binary))

    def get(*keys: str) -> str:
        for key in keys:
            m = re.search(rf"\b{key}\s+(\S+)", out)
            if m:
                return m.group(1)
        return "?"
    # LC_BUILD_VERSION has platform/minos; the older LC_VERSION_MIN_* has cmd/version
    return get("platform", "cmd"), get("minos", "version"), get("sdk")


def exported(binary: Path) -> set[str]:
    out = run("nm", "-gU", str(binary))
    return {ln.split()[-1] for ln in out.splitlines() if ln.strip()}


def header_version(include: Path, lib: str) -> str:
    text = (include / lib / "version_major.h").read_text() + (include / lib / "version.h").read_text()
    up = lib.upper()
    return ".".join(re.search(rf"#define\s+{up}_VERSION_{part}\s+(\d+)", text).group(1)
                    for part in ("MAJOR", "MINOR", "MICRO"))


def component_report(new_bins: dict[str, Path], base_bins: dict[str, Path], components_h: Path) -> None:
    """String-based sanity check of what is compiled in, against the base binaries.

    The base release has no config_components.h, so presence of a component is judged by its
    name appearing as a NUL-delimited string in the library. The method is only trusted for
    names where it gives the right answer on the new library (whose configuration is known)."""
    where = {"DECODER": "Libavcodec", "ENCODER": "Libavcodec", "BSF": "Libavcodec", "HWACCEL": "Libavcodec",
             "DEMUXER": "Libavformat", "MUXER": "Libavformat", "PROTOCOL": "Libavformat", "FILTER": "Libavfilter"}
    blobs = {k: v.read_bytes() for k, v in new_bins.items()}
    base_blobs = {k: v.read_bytes() for k, v in base_bins.items()}
    stats: dict[str, list[int]] = {}
    only_new: dict[str, list[str]] = {}
    only_base: dict[str, list[str]] = {}
    for m in re.finditer(r"^#define CONFIG_(\w+)_(DECODER|ENCODER|BSF|HWACCEL|DEMUXER|MUXER|PROTOCOL|FILTER) ([01])$",
                         components_h.read_text(), re.M):
        name, kind, on = m.group(1).lower(), m.group(2), m.group(3) == "1"
        lib = where[kind]
        needle = b"\0" + name.encode() + b"\0"
        in_new, in_base = needle in blobs[lib], needle in base_blobs[lib]
        st = stats.setdefault(kind, [0, 0, 0])      # enabled, judged, total
        st[2] += 1
        st[0] += on
        if in_new != on:
            continue                                  # method unreliable for this name
        st[1] += 1
        if on and not in_base:
            only_new.setdefault(kind, []).append(name)
        if not on and in_base:
            only_base.setdefault(kind, []).append(name)
    note("Components (xros-arm64; string check against the base binaries, see assemble_frameworks.py):")
    for kind, (on, judged, total) in sorted(stats.items()):
        note(f"  {kind.lower():9s} enabled {on:4d} of {total:4d}; comparable by name {judged:4d}; "
             f"enabled here but not found in base: {', '.join(only_new.get(kind, [])) or '-'}; "
             f"found in base but disabled here: {', '.join(only_base.get(kind, [])) or '-'}")


def main() -> None:
    built, base, base_zips, out, package_swift = (Path(a).resolve() for a in sys.argv[1:6])
    ffmpeg_tag = sys.argv[6]
    stage = out / "stage"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    tmp = out / "tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()

    # slice id -> {arch: build dir}
    builds: dict[str, dict[str, Path]] = {}
    for d in sorted(p for p in built.iterdir() if (p / "SLICE").is_file()):
        builds.setdefault((d / "SLICE").read_text().strip(), {})[(d / "ARCH").read_text().strip()] = d
    note(f"FFmpeg {ffmpeg_tag} built for: " + "; ".join(f"{s} ({'+'.join(sorted(a))})" for s, a in sorted(builds.items())))
    for d in sorted(p for s in builds.values() for p in s.values()):
        note("  " + (d / "build-info.txt").read_text().strip().replace("\n", "\n  "))
    note()

    checksums: dict[str, str] = {}
    manifest_rows: list[str] = []
    xros_new: dict[str, Path] = {}
    xros_base: dict[str, Path] = {}

    for lib in FF_LIBS:
        low = lib.lower()                              # Libavcodec -> libavcodec
        src_xc = base / f"{lib}.xcframework"
        dst_xc = stage / f"{lib}.xcframework"
        shutil.copytree(src_xc, dst_xc, symlinks=True)
        info = plistlib.loads((dst_xc / "Info.plist").read_bytes())
        slices = {e["LibraryIdentifier"]: e for e in info["AvailableLibraries"]}
        if set(slices) != set(builds):
            fail(f"{lib}: base slices {sorted(slices)} != built slices {sorted(builds)}")
            continue
        for slice_id, entry in sorted(slices.items()):
            fw = dst_xc / slice_id / f"{lib}.framework"
            base_bin = src_xc / slice_id / f"{lib}.framework" / lib
            want_archs = sorted(entry["SupportedArchitectures"])
            if sorted(builds[slice_id]) != want_archs or sorted(archs_of(base_bin)) != want_archs:
                fail(f"{lib} {slice_id}: architectures built {sorted(builds[slice_id])}, base {want_archs}")
                continue

            # ---- per-architecture checks against the base binary
            thins = []
            for arch in want_archs:
                bdir = builds[slice_id][arch]
                new_bin = bdir / "bin" / lib
                old_bin = thin(base_bin, arch, tmp / f"base-{lib}-{slice_id}-{arch}")
                thins.append(new_bin)
                tag = f"{lib} {slice_id} {arch}"

                new_cfg, old_cfg = configure_line(new_bin), configure_line(old_bin)
                if new_cfg != old_cfg:
                    fail(f"{tag}: configure line differs from the base: only new {[a for a in new_cfg if a not in old_cfg]}, "
                         f"only base {[a for a in old_cfg if a not in new_cfg]}, same order {new_cfg == old_cfg}")
                if f"FFmpeg version {ffmpeg_tag}\0".encode() not in new_bin.read_bytes():
                    fail(f"{tag}: no 'FFmpeg version {ffmpeg_tag}' string")

                new_id, new_loads = loads(new_bin)
                old_id, old_loads = loads(old_bin)
                want_ver = header_version(bdir / "include", low)
                m = re.match(r"(\S+) \(compatibility version ([\d.]+), current version ([\d.]+)\)", new_id)
                mo = re.match(r"(\S+) \(compatibility version ([\d.]+), current version ([\d.]+)\)", old_id)
                if not m or m.group(1) != f"@rpath/{lib}.framework/{lib}" or m.group(1) != mo.group(1):
                    fail(f"{tag}: install name {new_id}")
                elif m.group(3) != want_ver:
                    fail(f"{tag}: Mach-O version {m.group(3)} but headers say {want_ver}")
                elif m.group(2) != mo.group(2):
                    fail(f"{tag}: compatibility version {m.group(2)}, base {mo.group(2)} (major version changed)")
                rp_new = sorted(x for x in new_loads if x.startswith("@rpath/"))
                rp_old = sorted(x for x in old_loads if x.startswith("@rpath/"))
                if rp_new != rp_old:
                    fail(f"{tag}: @rpath loads {rp_new}, base {rp_old}")
                sys_added = sorted(set(new_loads) - set(old_loads))
                sys_gone = sorted(set(old_loads) - set(new_loads))

                np, nmin, nsdk = build_version(new_bin)
                op, omin, osdk = build_version(old_bin)
                if (np, nmin) != (op, omin):
                    fail(f"{tag}: platform/minos {np} {nmin}, base {op} {omin}")

                new_syms, old_syms = exported(new_bin), exported(old_bin)
                gone = sorted(old_syms - new_syms)
                added = len(new_syms - old_syms)
                note(f"{tag}: version {m.group(3) if m else '?'} (base {mo.group(3)}), {np} minos {nmin} sdk {nsdk} (base sdk {osdk}), "
                     f"size {new_bin.stat().st_size / 1e6:.2f} MB (base {old_bin.stat().st_size / 1e6:.2f}), "
                     f"exports {len(new_syms)} (base {len(old_syms)}, +{added}, -{len(gone)})")
                if gone:
                    note(f"    exported by the base but not here: {' '.join(gone)}")
                    print(f"::warning::{tag}: {len(gone)} symbols exported by the base are gone: {' '.join(gone[:12])}")
                if sys_added or sys_gone:
                    note(f"    system load commands: added {sys_added or '-'}, removed {sys_gone or '-'}")
                if slice_id == "xros-arm64":
                    xros_new[lib], xros_base[lib] = new_bin, old_bin

            # ---- binary
            target = fw / lib
            target.unlink()
            if len(thins) == 1:
                shutil.copyfile(thins[0], target)
            else:
                run("lipo", "-create", *map(str, thins), "-output", str(target))
            target.chmod(0o755)

            # ---- headers (identical for every architecture of a slice except avconfig.h, which
            # FFmpeg generates identically for the architectures built here)
            first = builds[slice_id][want_archs[0]] / "include" / low
            for arch in want_archs[1:]:
                other = builds[slice_id][arch] / "include" / low
                a = {str(p.relative_to(first)): p.read_bytes() for p in first.rglob("*") if p.is_file()}
                b = {str(p.relative_to(other)): p.read_bytes() for p in other.rglob("*") if p.is_file()}
                diff = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
                if diff:
                    fail(f"{lib} {slice_id}: headers differ between architectures: {diff}")
            old_headers = {str(p.relative_to(fw / "Headers")) for p in (fw / "Headers").rglob("*") if p.is_file()}
            shutil.rmtree(fw / "Headers")
            shutil.copytree(first, fw / "Headers")
            new_headers = {str(p.relative_to(fw / "Headers")) for p in (fw / "Headers").rglob("*") if p.is_file()}
            lost = old_headers - new_headers - REMOVED_HEADERS.get(lib, set())
            if lost:
                fail(f"{lib} {slice_id}: headers of the base missing: {sorted(lost)}")
            if slice_id == "xros-arm64" and old_headers != new_headers:
                note(f"    {lib} headers: added {sorted(new_headers - old_headers) or '-'}, removed {sorted(old_headers - new_headers) or '-'}")

            # ---- module map: drop excludes of headers that no longer exist
            mm = fw / "Modules" / "module.modulemap"
            kept = []
            for line in mm.read_text().splitlines():
                m2 = re.match(r'\s*exclude header "([^"]+)"', line)
                if m2 and not (fw / "Headers" / m2.group(1)).is_file():
                    continue
                kept.append(line)
            mm.write_text("\n".join(kept))

            # ---- dSYM (device slices), signature
            dsym_dir = dst_xc / slice_id / "dSYMs"
            if dsym_dir.is_dir():
                shutil.rmtree(dsym_dir)
                new_dsym = builds[slice_id][want_archs[0]] / "dSYMs" / f"{lib}.framework.dSYM"
                if not new_dsym.is_dir():
                    fail(f"{lib} {slice_id}: base has a dSYM, build has none")
                else:
                    dsym_dir.mkdir()
                    shutil.copytree(new_dsym, dsym_dir / new_dsym.name)
            shutil.rmtree(fw / "_CodeSignature", ignore_errors=True)
            run("codesign", "--force", "--sign", "-", str(fw))
            run("codesign", "--verify", "--strict", str(fw))

        zip_path = out / f"{lib}.xcframework.zip"
        checksums[lib] = zip_and_checksum(dst_xc, zip_path)
        manifest_rows.append(f"{lib:16s} FFmpeg {ffmpeg_tag}, built here  {zip_path.stat().st_size / 1e6:7.1f} MB  {checksums[lib]}")

    note()
    if xros_new.keys() >= {"Libavcodec", "Libavformat", "Libavfilter"}:
        comp = builds["xros-arm64"]["arm64"] / "config" / "config_components.h"
        component_report(xros_new, xros_base, comp)
        note()

    # ---- everything else: byte-identical copies of the base release assets
    for name, checksum in BASE["checksums"].items():
        if name in FF_LIBS:
            continue
        asset = f"{name}.zip" if name == SOURCES_NAME else f"{name}.xcframework.zip"
        src = base_zips / asset
        got = run("swift", "package", "compute-checksum", str(src)).strip()
        if got != checksum:
            fail(f"{asset}: checksum {got} is not the base release's {checksum}")
        shutil.copyfile(src, out / asset)
        checksums[name] = checksum
        manifest_rows.append(f"{name:16s} unchanged from {BASE['release']}  {src.stat().st_size / 1e6:7.1f} MB  {checksum}")

    # keep the key order of the base release so diffs of checksums.json stay readable
    ordered = {k: checksums[k] for k in BASE["checksums"] if k in checksums}
    if set(ordered) != set(BASE["checksums"]):
        fail(f"assets missing: {sorted(set(BASE['checksums']) - set(ordered))}")
    (out / "checksums.json").write_text(json.dumps(ordered, indent=2) + "\n")
    (out / "MANIFEST.txt").write_text("\n".join(
        [f"FFmpeg {ffmpeg_tag} + FFmpegKit's patches, built with FFmpegKit {BASE['ffmpegkit_tag']}'s configure line;",
         f"dependencies and shim sources unchanged from {BASE['release']}", ""] + manifest_rows + [""] + report) + "\n")

    targets = [k for k in ordered if k != SOURCES_NAME]
    write_package_swift(package_swift, targets, (
        f"// FFmpeg {ffmpeg_tag} with FFmpegKit's patches (ffmpeg-build/patches), compiled in CI with the\n"
        f"// configure line of FFmpegKit {BASE['ffmpegkit_tag']} (kingslay/FFmpegKit, see LICENSE); every other\n"
        f"// xcframework and the Sources/FFmpegKit shim files are the stock FFmpegKit {BASE['ffmpegkit_tag']} ones.\n"
        "// visionOS + tvOS slices only (device + simulator). Nothing binary is in git:\n"
        "// tools/fetch_binaries.sh downloads the assets of release RELEASE_TAG and verifies\n"
        "// checksums.json (CI does this before resolving packages).\n"),
        'ffmpeg-build/assemble_frameworks.py (workflow "FFmpegKit build")')
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"wrote {package_swift}")
    if errors:
        print(f"\n{len(errors)} check(s) failed:")
        for e in errors:
            print("  - " + e)
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
