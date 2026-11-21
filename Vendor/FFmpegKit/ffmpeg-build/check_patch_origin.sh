#!/bin/bash
# Compare the patch files in <ours> with FFmpegKit's patch folder <upstream>: same set of file
# names, every file byte-identical except the ones listed in REMADE (re-made by hand for the
# FFmpeg version built here, see patches/README.md), which must differ. Fails otherwise.
#
# usage: check_patch_origin.sh <upstream patch dir> <our patch dir>
set -euo pipefail
REMADE="05-h264_seek.patch 10-http-redirect-cache.patch 14-dashdec-seek.patch"
up="$(cd "$1" && pwd)"; ours="$(cd "$2" && pwd)"
bad=0
if [ "$(cd "$up" && ls *.patch)" != "$(cd "$ours" && ls *.patch)" ]; then
  echo "::error::patch file names differ from FFmpegKit's" >&2
  diff <(cd "$up" && ls *.patch) <(cd "$ours" && ls *.patch) || true
  bad=1
fi
for p in "$ours"/*.patch; do
  n="$(basename "$p")"
  [ -f "$up/$n" ] || continue
  case " $REMADE " in
    *" $n "*)
      if cmp -s "$p" "$up/$n"; then echo "::error::$n is listed as re-made but is identical to FFmpegKit's" >&2; bad=1
      else echo "re-made    $n"; fi ;;
    *)
      if cmp -s "$p" "$up/$n"; then echo "identical  $n"
      else echo "::error::$n differs from FFmpegKit's and is not listed as re-made" >&2; bad=1; fi ;;
  esac
done
exit "$bad"
