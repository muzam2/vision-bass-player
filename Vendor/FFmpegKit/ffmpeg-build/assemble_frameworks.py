#!/usr/bin/env python3
"""Turn the per-architecture FFmpeg builds (build_slice.sh) into the seven Lib*.xcframeworks,
check them against the FFmpegKit base release they replace, and write everything a release
needs (zips, checksums.json, MANIFEST.txt, Package.swift).

Each new framework starts as a copy of the base release's framework (Info.plist, module map,
xcframework Info.plist) and gets the new binary, the new headers, a new ad-hoc signature and,
for device slices, a new dSYM. The other xcframeworks (dependencies) and FFmpegKit-sources.zip
are passed through byte for byte.

Hard failures (exit 1):
  - the configure line embedded in a new library (what avutil_configuration() etc. return)
    differs from the one in the base library of the same slice/architecture (apart from --prefix)
  - a library's Mach-O version or the version in its headers is not the one listed in
    expected-versions.json, or its major version differs from the base
  - a library whose base carries "FFmpeg version <base tag>" (every library but libswscale,
    which has no such string in either version) does not carry the new one, or Libavcodec /
    Libavformat lack their ident string (Lavc/Lavf + version)
  - platform / minimum OS of a library differ from the base
  - the set of @rpath libraries a library loads differs from the base (a missing or extra
    embedded framework is a dyld crash at launch)
  - a header the base ships is gone (except the ones listed in REMOVED_HEADERS)
  - a decoder/demuxer/filter/hwaccel/... that the base library has is not enabled here (string
    based, see component_check; this is what catches a dependency or header that configure
    auto-detects differently although the configure line is the same)
Reported in MANIFEST.txt without failing: system load commands, exported symbols, sizes and
the components this FFmpeg version adds.

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
EXPECTED = json.loads((HERE / "expected-versions.json").read_text())
FF_LIBS = ["Libavutil", "Libswresample", "Libswscale", "Libavcodec", "Libavformat", "Libavfilter", "Libavdevice"]
# Headers of the base release that the new FFmpeg version no longer has.
REMOVED_HEADERS = {"Libavutil": {"libm.h"}}   # FFmpeg 9.1 removed libavutil/libm.h
# Libraries that embed "<prefix><major.minor.micro>" (LIBAVCODEC_IDENT, LIBAVFORMAT_IDENT).
IDENTS = {"Libavcodec": "Lavc", "Libavformat": "Lavf"}
# component_check: names found as a string in a base library although the component is not
# part of the base build. Anything else found in the base but disabled here fails the run.
BASE_STRING_ONLY = {
    ("FILTER", "hqdn3d"),   # n9.0.2's avfilter.c compares filter names with "hqdn3d"; n9.1 does not
}

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


def exported(binary: Path) -> tuple[set[str], set[str]]:
    """(symbols defined and exported, symbols re-exported from another library).

    FFmpeg links with -exported_symbols_list and wildcards (av*, ...), so a library also
    re-exports every matching symbol it imports from another FFmpeg library; nm lists those
    without an address as "I <name> (indirect for <name>)"."""
    defined, reexported = set(), set()
    for ln in run("nm", "-gU", str(binary)).splitlines():
        m = re.match(r"\s*(?:[0-9a-fA-F]+\s+)?([A-Za-z])\s+(\S+)", ln)
        if m:
            (reexported if m.group(1) == "I" else defined).add(m.group(2))
    return defined, reexported


def header_version(include: Path, lib: str) -> str:
    # libavutil keeps all three numbers in version.h; the others split off version_major.h
    text = "".join(p.read_text() for p in (include / lib / "version_major.h", include / lib / "version.h") if p.is_file())
    up = lib.upper()
    return ".".join(re.search(rf"#define\s+{up}_VERSION_{part}\s+(\d+)", text).group(1)
                    for part in ("MAJOR", "MINOR", "MICRO"))


def component_check(tag: str, new: bytes, base: bytes, kinds: tuple[str, ...], components_h: Path) -> dict:
    """String-based check of what is compiled into one library, against the base library.

    The base release has no config_components.h, so presence of a component is judged by its
    name appearing as a NUL-delimited string in the library. The method is only trusted for
    names where it gives the right answer on the new library (whose configuration is known),
    and a name of fewer than six characters found only in the base is reported, not failed
    (short byte patterns such as "f4v" also occur in data tables)."""
    result = {}
    for kind in kinds:
        enabled = judged = total = 0
        only_new, only_base, only_base_short = [], [], []
        for m in re.finditer(rf"^#define CONFIG_(\w+)_{kind} ([01])$", components_h.read_text(), re.M):
            name, on = m.group(1).lower(), m.group(2) == "1"
            needle = b"\0" + name.encode() + b"\0"
            in_new, in_base = needle in new, needle in base
            total += 1
            enabled += on
            if in_new != on:
                continue                                  # method unreliable for this name
            judged += 1
            if on and not in_base:
                only_new.append(name)
            elif not on and in_base and (kind, name) not in BASE_STRING_ONLY:
                (only_base if len(name) >= 6 else only_base_short).append(name)
        if only_base:
            fail(f"{tag}: {kind.lower()}s the base library has but this build does not: {', '.join(only_base)}")
        result[kind] = (f"{kind.lower():9s} enabled {enabled:4d} of {total:4d}; comparable by name {judged:4d}; "
                        f"new here: {', '.join(only_new) or '-'}; in base only: {', '.join(only_base) or '-'}; "
                        f"short name seen in base (not judged): {', '.join(only_base_short) or '-'}")
    return result


COMPONENT_KINDS = {"Libavcodec": ("DECODER", "ENCODER", "BSF", "HWACCEL"),
                   "Libavformat": ("DEMUXER", "MUXER", "PROTOCOL"),
                   "Libavfilter": ("FILTER",)}


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
    n_builds = sum(len(a) for a in builds.values())
    note(f"FFmpeg {ffmpeg_tag} built for: " + "; ".join(f"{s} ({'+'.join(sorted(a))})" for s, a in sorted(builds.items())))
    for d in sorted(p for s in builds.values() for p in s.values()):
        note("  " + (d / "build-info.txt").read_text().strip().replace("\n", "\n  "))
    note()

    if EXPECTED["ffmpeg"] != ffmpeg_tag:
        fail(f"expected-versions.json is for {EXPECTED['ffmpeg']}, this build is {ffmpeg_tag}")
    base_tag = "n" + BASE["ffmpegkit_tag"]                 # FFmpegKit 9.0.2 = FFmpeg n9.0.2
    checksums: dict[str, str] = {}
    manifest_rows: list[str] = []
    components: dict[str, dict[str, list[str]]] = {}       # kind -> {report line: [slice/arch, ...]}
    defined_anywhere = {(s, a): set().union(*(exported(d / "bin" / lib)[0] for lib in FF_LIBS))
                        for s, archs in builds.items() for a, d in archs.items()}

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
                new_bytes, old_bytes = new_bin.read_bytes(), old_bin.read_bytes()
                has_version = f"FFmpeg version {base_tag}\0".encode() in old_bytes
                if has_version and f"FFmpeg version {ffmpeg_tag}\0".encode() not in new_bytes:
                    fail(f"{tag}: no 'FFmpeg version {ffmpeg_tag}' string")
                if base_tag.encode() in new_bytes:
                    fail(f"{tag}: contains the base version string {base_tag}")

                new_id, new_loads = loads(new_bin)
                old_id, old_loads = loads(old_bin)
                want_ver = EXPECTED["libraries"][lib]
                if header_version(bdir / "include", low) != want_ver:
                    fail(f"{tag}: headers say {header_version(bdir / 'include', low)}, expected-versions.json {want_ver}")
                m = re.match(r"(\S+) \(compatibility version ([\d.]+), current version ([\d.]+)\)", new_id)
                mo = re.match(r"(\S+) \(compatibility version ([\d.]+), current version ([\d.]+)\)", old_id)
                if not m or m.group(1) != f"@rpath/{lib}.framework/{lib}" or m.group(1) != mo.group(1):
                    fail(f"{tag}: install name {new_id}")
                elif m.group(3) != want_ver:
                    fail(f"{tag}: Mach-O version {m.group(3)}, expected {want_ver}")
                elif m.group(2) != mo.group(2):
                    fail(f"{tag}: compatibility version {m.group(2)}, base {mo.group(2)} (major version changed)")
                if lib in IDENTS:
                    if f"{IDENTS[lib]}{mo.group(3)}\0".encode() not in old_bytes:
                        fail(f"{tag}: base library has no ident string {IDENTS[lib]}{mo.group(3)}")
                    if f"{IDENTS[lib]}{want_ver}\0".encode() not in new_bytes:
                        fail(f"{tag}: no ident string {IDENTS[lib]}{want_ver}")
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

                (new_def, new_re), (old_def, old_re) = exported(new_bin), exported(old_bin)
                missing = (old_def | old_re) - (new_def | new_re)
                # no longer re-exported here but still defined by one of the new libraries
                moved = sorted(missing & defined_anywhere[(slice_id, arch)])
                gone = sorted(missing - defined_anywhere[(slice_id, arch)])
                note(f"{tag}: version {m.group(3) if m else '?'} (base {mo.group(3)}), {np} minos {nmin} sdk {nsdk} (base sdk {osdk}), "
                     f"size {new_bin.stat().st_size / 1e6:.2f} MB (base {old_bin.stat().st_size / 1e6:.2f}), "
                     f"exports {len(new_def)} + {len(new_re)} re-exported (base {len(old_def)} + {len(old_re)})")
                if moved:
                    note(f"    re-exported by the base, here only in the library that defines them: {' '.join(moved)}")
                if gone:
                    note(f"    exported by the base and by no library here: {' '.join(gone)}")
                    print(f"::warning::{tag}: {len(gone)} symbols exported by the base are gone: {' '.join(gone[:12])}")
                if sys_added or sys_gone:
                    note(f"    system load commands: added {sys_added or '-'}, removed {sys_gone or '-'}")
                if lib in COMPONENT_KINDS:
                    lines = component_check(tag, new_bytes, old_bytes, COMPONENT_KINDS[lib],
                                            bdir / "config" / "config_components.h")
                    for kind, line in lines.items():
                        components.setdefault(kind, {}).setdefault(line, []).append(f"{slice_id} {arch}")

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
    note("Components (string check against the base libraries, see component_check):")
    for kind in sorted(components):
        for line, where in components[kind].items():
            note(f"  {line}" + ("" if len(where) == n_builds else f"   [{'; '.join(where)}]"))
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
