#!/bin/bash
# Download the assets of the FFmpegKit base release named in base-release.json (the stock
# FFmpegKit 9.0.2 repack), verify each against the checksums recorded there and unzip the
# xcframeworks.
#
# usage: fetch_base.sh <xcframeworks dir> <zips dir> deps|all
#   deps: only the dependency xcframeworks (what an FFmpeg build links against)
#   all:  also the base FFmpeg xcframeworks (templates and reference for the package step)
#         and FFmpegKit-sources.zip
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$1"; zips="$2"; what="$3"
repo="${GITHUB_REPOSITORY:-muzam2/vision-bass-player}"
mkdir -p "$dest" "$zips"
tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$here/base-release.json")"

python3 - "$here/base-release.json" "$what" <<'EOF' |
import json, sys
base = json.load(open(sys.argv[1]))
for name, checksum in base["checksums"].items():
    is_ffmpeg = name in base["ffmpeg_frameworks"]
    is_sources = name == "FFmpegKit-sources"
    if sys.argv[2] == "deps" and (is_ffmpeg or is_sources):
        continue
    print(name, checksum, "sources" if is_sources else "xcframework")
EOF
while read -r name sum kind; do
  if [ "$kind" = sources ]; then asset="$name.zip"; else asset="$name.xcframework.zip"; fi
  if ! gh release download "$tag" -R "$repo" -p "$asset" -D "$zips" --clobber 2>/dev/null; then
    curl -fsSL --retry 4 --retry-all-errors --retry-delay 5 -o "$zips/$asset" \
      "https://github.com/$repo/releases/download/$tag/$asset"
  fi
  echo "$sum  $zips/$asset" | shasum -a 256 -c --status || { echo "::error::checksum mismatch: $asset" >&2; exit 1; }
  if [ "$kind" = xcframework ]; then
    rm -rf "$dest/$name.xcframework"
    ditto -x -k "$zips/$asset" "$dest"
    test -f "$dest/$name.xcframework/Info.plist" || { echo "::error::bad archive layout: $asset" >&2; exit 1; }
  fi
  echo "ok  $asset"
done
