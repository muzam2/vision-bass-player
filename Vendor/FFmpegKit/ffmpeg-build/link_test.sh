#!/bin/bash
# Compile and link a small Objective-C program against the assembled xcframeworks for every
# slice, through the same shim headers and clang modules the FFmpegKit SwiftPM target uses.
# Catches a broken module map, a missing header or an unresolvable library before a release
# is published (a published release tag is never overwritten).
#
# usage: link_test.sh <dir with the new Lib*.xcframework> <dir with the base xcframeworks> <shim include dir>
set -euo pipefail
stage="$(cd "$1" && pwd)"; base="$(cd "$2" && pwd)"; shim="$(cd "$3" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/test.m" <<'EOF'
// The whole module of each framework (umbrella + excludes of its module map), as Swift's
// `import Libavcodec` builds it, then the shim headers of the FFmpegKit target.
@import Libavutil;
@import Libswresample;
@import Libswscale;
@import Libavcodec;
@import Libavformat;
@import Libavfilter;
@import Libavdevice;
#import "avutil_shim.h"
#import "avcodec_shim.h"
#import "avformat_shim.h"
#import "avfilter_shim.h"
#import "avdevice_shim.h"
#import "swresample_shim.h"
#import "swscale_shim.h"
#include <stdio.h>
int main(void) {
    AVFormatContext *ctx = avformat_alloc_context();
    int (*io_open)(struct AVFormatContext *, AVIOContext **, const char *, int, AVDictionary **) = ctx->io_open;
    printf("%s %u %u %u %u %u %u %u %p %lld\n", av_version_info(), avutil_version(), avcodec_version(),
           avformat_version(), avfilter_version(), avdevice_version(), swresample_version(), swscale_version(),
           (void *)io_open, (long long)swift_AV_NOPTS_VALUE);
    avformat_free_context(ctx);
    return 0;
}
EOF

ffmpeg="Libavutil Libswresample Libswscale Libavcodec Libavformat Libavfilter Libavdevice"
dynamic_deps="libzvbi libplacebo libfribidi"      # loaded by the FFmpeg libraries via @rpath
check() { # sdk triple slice
  local sdk="$1" triple="$2" slice="$3" flags=() n
  for n in $ffmpeg; do flags+=("-F$stage/$n.xcframework/$slice" -framework "$n"); done
  for n in $dynamic_deps; do flags+=("-F$base/$n.xcframework/$slice"); done
  xcrun --sdk "$sdk" clang -target "$triple" -fmodules -fobjc-arc -Wall -Werror=implicit-function-declaration \
    -I"$shim" "${flags[@]}" "$tmp/test.m" -o "$tmp/test-$triple"
  echo "ok  $slice ($triple): $(otool -L "$tmp/test-$triple" | grep -c '@rpath/Lib') FFmpeg frameworks linked"
}
check xros             arm64-apple-xros1.0             xros-arm64
check xrsimulator      arm64-apple-xros1.0-simulator   xros-arm64-simulator
check appletvos        arm64-apple-tvos13.0            tvos-arm64
check appletvsimulator arm64-apple-tvos14.0-simulator  tvos-arm64_x86_64-simulator
check appletvsimulator x86_64-apple-tvos13.0-simulator tvos-arm64_x86_64-simulator
