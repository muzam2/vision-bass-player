#!/bin/bash
# Apply every patch in <patch dir> to the FFmpeg tree at <ffmpeg src>, in name order, with
# `git apply` (context must match exactly: line offsets are accepted, fuzz is not).
# Stops at the first patch that does not apply. FFmpegKit's old build plugin ignored such
# failures, which silently drops whole patch files; that must never happen here.
#
# usage: apply_patches.sh <ffmpeg src> <patch dir>
set -euo pipefail
src="$1"
patches="$(cd "$2" && pwd)"
cd "$src"
count=0
for p in "$patches"/*.patch; do
  name="$(basename "$p")"
  if ! git apply --check "$p"; then
    echo "::error::FFmpeg patch does not apply: $name" >&2
    exit 1
  fi
  git apply "$p"
  echo "applied $name"
  count=$((count + 1))
done
expected="$(ls "$patches"/*.patch | wc -l | tr -d ' ')"
test "$count" = "$expected" || { echo "::error::applied $count of $expected patches" >&2; exit 1; }
echo "all $count patches applied"
