#!/bin/bash
# Download FFmpegKit's xcframework zips (and FFmpegKit-sources.zip, the C shim target's files)
# from this repo's release (tag in ../RELEASE_TAG), verify each against checksums.json (SHA-256,
# same value SwiftPM uses) and unzip them into Vendor/FFmpegKit/Sources/, where Package.swift
# references them by path.
#
# SwiftPM's own binary-target download failed in CI ("failed downloading ... already exists in
# file system", seemingly after 504s from the public release URL), so CI fetches them here.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="${GITHUB_REPOSITORY:-muzam2/vision-bass-player}"
tag="$(tr -d '[:space:]' < "$here/RELEASE_TAG")"
dest="$here/Sources"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 -c 'import json,sys; [print(k, v) for k, v in json.load(open(sys.argv[1])).items()]' "$here/checksums.json" |
while read -r name sum; do
  if [ "$name" = "FFmpegKit-sources" ]; then
    asset="FFmpegKit-sources.zip"; folder="$dest/FFmpegKit"; marker="$folder/include/avutil_shim.h"
  else
    asset="$name.xcframework.zip"; folder="$dest/$name.xcframework"; marker="$folder/Info.plist"
  fi
  if [ -f "$folder/.sha256" ] && [ "$(cat "$folder/.sha256")" = "$sum" ]; then
    echo "ok (cached)  $name"
    continue
  fi
  # gh goes through the authenticated API; the public download URL has returned 504s.
  if command -v gh >/dev/null && gh release download "$tag" -R "$repo" -p "$asset" -D "$tmp" --clobber 2>/dev/null; then
    mv "$tmp/$asset" "$tmp/$name.zip"
  else
    curl -fsSL --retry 4 --retry-all-errors --retry-delay 5 -o "$tmp/$name.zip" \
      "https://github.com/$repo/releases/download/$tag/$asset"
  fi
  echo "$sum  $tmp/$name.zip" | shasum -a 256 -c --status || { echo "checksum mismatch: $name"; exit 1; }
  rm -rf "$folder"
  ditto -x -k "$tmp/$name.zip" "$dest"
  test -f "$marker" || { echo "bad archive layout: $name"; exit 1; }
  echo "$sum" > "$folder/.sha256"
  echo "ok           $name"
done
