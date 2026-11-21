#!/bin/bash
# Build FFmpeg for one Apple platform/architecture the way FFmpegKit 9.0.2 was built:
#   - FFmpeg source = the given tree with Vendor/FFmpegKit/ffmpeg-build/patches applied (strictly)
#   - configure arguments = configure-args.txt (the line embedded in the 9.0.2 binaries)
#   - compiler/linker flags passed through the environment, as FFmpegKit's last public
#     plugin (tag 6.1.4, Plugins/BuildFFmpeg/main.swift) did: -arch/-isysroot/-target,
#     the -m<os>-version-min flag, -fno-common, and -lc++ for the linker
#   - external libraries = the stock FFmpegKit 9.0.2 dependency xcframeworks, found by
#     pkg-config through .pc files synthesized here (upstream's own .pc files are not
#     published; versions come from the frameworks' headers)
#   - Vulkan headers = KhronosGroup/Vulkan-Headers at the revision of the MoltenVK FFmpegKit
#     ships (header only; FFmpegKit points pkg-config "vulkan" at MoltenVK's include directory).
#     Their version decides whether configure enables vulkan_1_4 and with it the Vulkan VP9
#     hwaccel, which the 9.0.2 binaries have.
# Output (in <out dir>): the seven shared libraries renamed/re-identified as frameworks
# binaries (Libavcodec, ...), stripped like upstream's, dSYMs for device slices, the installed
# public headers plus the private headers upstream also ships, and config.h for the record.
#
# usage: build_slice.sh <platform> <arch> <patched ffmpeg src> <deps dir> <vulkan include dir> <out dir>
#   platform: xros | xrsimulator | tvos | tvsimulator      arch: arm64 | x86_64
#   deps dir: holds <name>.xcframework for every dependency (unzipped 9.0.2 release assets)
set -euo pipefail

platform="$1"; arch="$2"; src="$(cd "$3" && pwd)"; deps="$(cd "$4" && pwd)"
vulkan_inc="$(cd "$5" && pwd)"
mkdir -p "$6"; out="$(cd "$6" && pwd)"          # absolute: the build runs in another directory
here="$(cd "$(dirname "$0")" && pwd)"

case "$platform" in
  xros)        sdk=xros;             triple="$arch-apple-xros1.0";             minflag="";                                   slice="xros-arm64";                  debug=1 ;;
  xrsimulator) sdk=xrsimulator;      triple="$arch-apple-xros1.0-simulator";   minflag="";                                   slice="xros-arm64-simulator";        debug=0 ;;
  tvos)        sdk=appletvos;        triple="$arch-apple-tvos13.0";            minflag="-mtvos-version-min=13.0";            slice="tvos-arm64";                  debug=1 ;;
  tvsimulator) sdk=appletvsimulator; triple="$arch-apple-tvos13.0-simulator";  minflag="-mtvos-simulator-version-min=13.0";  slice="tvos-arm64_x86_64-simulator"; debug=0 ;;
  *) echo "unknown platform $platform" >&2; exit 2 ;;
esac
case "$arch" in
  arm64)  ffarch=aarch64 ;;
  x86_64) ffarch=x86_64 ;;
  *) echo "unknown arch $arch" >&2; exit 2 ;;
esac

sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
work="$PWD/ffwork/$platform-$arch"
prefix="$work/thin"
scratch="$work/scratch"
pcdir="$work/pkgconfig"
toolbin="$work/toolbin"
rm -rf "$work" "$out"
mkdir -p "$prefix" "$scratch" "$pcdir" "$toolbin" "$out"

# --- tools: a PATH with only the system directories plus pkg-config and nasm, so nothing
# else on the runner (a SPIR-V compiler, Homebrew libraries) changes what configure detects.
for tool in pkg-config nasm; do
  p="$(command -v "$tool")" || { echo "::error::$tool not found (brew install pkgconf nasm)" >&2; exit 1; }
  ln -sf "$p" "$toolbin/$tool"
done
export PATH="$toolbin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- pkg-config files for the 9.0.2 dependency frameworks -------------------------------
fwdir() { echo "$deps/$1.xcframework/$slice"; }
hdr()   { echo "$deps/$1.xcframework/$slice/$1.framework/Headers"; }
fw()    { echo "-F$(fwdir "$1") -framework $1"; }
for n in lcms2 libass libcrypto libdav1d libfontconfig libfreetype libfribidi libharfbuzz libopus libplacebo libsrt libssl libzvbi; do
  test -d "$(hdr "$n")" || { echo "::error::dependency $n has no $slice slice in $deps" >&2; exit 1; }
done
pc() { # name version cflags libs
  printf 'Name: %s\nDescription: FFmpegKit 9.0.2 %s (synthesized by build_slice.sh)\nVersion: %s\nCflags: %s\nLibs: %s\n' \
    "$1" "$1" "$2" "$3" "$4" > "$pcdir/$1.pc"
}
iokit=""
case "$platform" in xros|xrsimulator) iokit="-framework IOKit" ;; esac   # as in the 9.0.2 load commands
freetype_libs="$(fw libfreetype) -lbz2 -lz"
harfbuzz_libs="$(fw libharfbuzz) $freetype_libs -framework CoreText -framework CoreGraphics -framework CoreFoundation -lc++"
fontconfig_libs="$(fw libfontconfig) $freetype_libs -lexpat"
openssl_libs="$(fw libssl) $(fw libcrypto)"
vk_core="$vulkan_inc/vulkan/vulkan_core.h"
vk_minor="$(sed -n 's/^#define VK_HEADER_VERSION_COMPLETE VK_MAKE_API_VERSION(0, 1, \([0-9]*\), VK_HEADER_VERSION)$/\1/p' "$vk_core")"
vk_patch="$(sed -n 's/^#define VK_HEADER_VERSION \([0-9]*\)$/\1/p' "$vk_core")"
test -n "$vk_minor" && test -n "$vk_patch" || { echo "::error::cannot read the Vulkan header version from $vk_core" >&2; exit 1; }
pc vulkan      "1.$vk_minor.$vk_patch" "-I$vulkan_inc" ""
pc lcms2       2.19    "-I$(hdr lcms2)" "$(fw lcms2)"
pc dav1d       1.5.0   "-I$(hdr libdav1d)" "$(fw libdav1d)"
pc libplacebo  7.360.0 "-F$(fwdir libplacebo) -I$vulkan_inc" \
   "$(fw libplacebo) -framework CoreFoundation -framework CoreGraphics -framework Foundation -framework IOSurface -framework Metal -framework QuartzCore -framework UIKit $iokit -lc++ -lobjc"
pc freetype2   26.4.20 "-I$(hdr libfreetype)/freetype2" "$freetype_libs"
pc harfbuzz    14.5.0  "-I$(hdr libharfbuzz)/harfbuzz" "$harfbuzz_libs"
pc fribidi     1.0.17  "-I$(hdr libfribidi)/fribidi" "$(fw libfribidi)"
pc fontconfig  2.18.1  "-I$(hdr libfontconfig)" "$fontconfig_libs"
pc libass      0.17.5  "-I$(hdr libass)" "$(fw libass) -liconv -framework CoreText $(fw libfribidi) $harfbuzz_libs $fontconfig_libs"
pc srt         1.5.6   "-I$(hdr libsrt)" "$(fw libsrt) $openssl_libs -lc++"
pc zvbi-0.2    0.2.45  "-I$(hdr libzvbi)" "$(fw libzvbi) -liconv"
pc opus        1.6     "-I$(hdr libopus)/opus" "$(fw libopus)"
pc openssl     4.0.3   "-I$(hdr libssl)" "$openssl_libs"
pc libxml-2.0  2.9.13  "-I$sysroot/usr/include/libxml2" "-lxml2 -lz -lpthread -licucore -lm"

# --- environment, as FFmpegKit's plugin set it --------------------------------------------
cflags="-arch $arch -isysroot $sysroot -target $triple $minflag -fno-common"
ldflags="-arch $arch -isysroot $sysroot -target $triple -lc++"
export LC_CTYPE=C
export CC=/usr/bin/clang CXX=/usr/bin/clang++
export CURRENT_ARCH="$arch"
export CFLAGS="$cflags" CPPFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="$ldflags"
export PKG_CONFIG_LIBDIR="$pcdir"
unset PKG_CONFIG_PATH || true

# --- configure ------------------------------------------------------------------------------
args=("--prefix=$prefix")
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  line="${line//@ARCH@/$ffarch}"
  line="${line//@DEBUG@/$debug}"
  args+=("$line")
done < "$here/configure-args.txt"

cd "$scratch"
echo "== configure ($platform $arch): ${#args[@]} arguments"
if ! "$src/configure" "${args[@]}" > "$work/configure.out" 2>&1; then
  tail -40 "$work/configure.out"
  echo "---- config.log (tail)"; tail -60 ffbuild/config.log || true
  mkdir -p "$out/logs"; cp ffbuild/config.log "$work/configure.out" "$out/logs/" 2>/dev/null || true
  echo "::error::configure failed for $platform $arch" >&2
  exit 1
fi
grep -E "^(License|install prefix|ARCH|C compiler)" "$work/configure.out" || true

# What FFmpegKit 9.0.2 was built without, although configure would pick it up if present:
# a SPIR-V compiler (its Libavfilter has none of the *_vulkan filters named on the configure
# line) — so this must stay off here too.
if grep -q '_VULKAN_FILTER 1$' config_components.h; then
  echo "::error::a SPIR-V compiler was detected (Vulkan filters enabled); FFmpegKit 9.0.2 was built without one" >&2; exit 1
fi
for want in VULKAN VULKAN_1_4 LCMS2 LIBDAV1D LIBPLACEBO LIBFREETYPE LIBHARFBUZZ LIBFRIBIDI LIBASS LIBSRT LIBZVBI LIBFONTCONFIG LIBOPUS OPENSSL LIBXML2 VIDEOTOOLBOX AUDIOTOOLBOX SHARED; do
  grep -q "^#define CONFIG_$want 1" config.h || { echo "::error::CONFIG_$want is not enabled" >&2; exit 1; }
done
grep -q '^#define CONFIG_STATIC 0' config.h
# In the 9.0.2 binaries and not on the configure line: depends on the Vulkan header version.
grep -q '^#define CONFIG_VP9_VULKAN_HWACCEL 1' config_components.h || { echo "::error::CONFIG_VP9_VULKAN_HWACCEL is not enabled" >&2; exit 1; }
grep -E '^#define CONFIG_(SECURETRANSPORT|ZLIB|BZLIB|LZMA|ICONV|LIBCURL|APPKIT|AVFOUNDATION|COREIMAGE|METAL|GPL|VERSION3|NONFREE) ' config.h | sed 's/^#define /  /' || true

# --- build ----------------------------------------------------------------------------------
jobs="$(sysctl -n hw.ncpu)"
echo "== make -j$jobs"
if ! make -j"$jobs" > "$work/make.out" 2>&1; then
  grep -nE "error:|Error [0-9]|Undefined symbols|ld: " "$work/make.out" | head -60
  mkdir -p "$out/logs"; cp "$work/make.out" ffbuild/config.log "$out/logs/" 2>/dev/null || true
  echo "::error::make failed for $platform $arch" >&2
  exit 1
fi
make install > "$work/install.out" 2>&1 || { tail -30 "$work/install.out"; exit 1; }

# --- collect ----------------------------------------------------------------------------------
libs="avutil swresample swscale avcodec avformat avfilter avdevice"
mkdir -p "$out/bin" "$out/include" "$out/config"
if [ "$debug" = 1 ]; then mkdir -p "$out/dSYMs"; fi
for l in $libs; do
  L="Lib$l"                                    # avcodec -> Libavcodec
  real="$(cd "$prefix/lib" && ls lib$l.*.*.*.dylib | head -1)"
  test -n "$real" || { echo "::error::lib$l dylib missing" >&2; exit 1; }
  bin="$out/bin/$L"
  cp "$prefix/lib/$real" "$bin"
  chmod u+w "$bin"
  install_name_tool -id "@rpath/$L.framework/$L" "$bin"
  # FFmpeg links its own libraries by <prefix>/lib/lib<name>.<major>.dylib
  for dep in $(otool -L "$bin" | awk 'NR>1 {print $1}' | grep "^$prefix/lib/" || true); do
    base="$(basename "$dep")"; name="${base%%.*}"; name="${name#lib}"
    install_name_tool -change "$dep" "@rpath/Lib$name.framework/Lib$name" "$bin"
  done
  if otool -L "$bin" | grep -q "$work"; then echo "::error::$L still refers to the build directory" >&2; otool -L "$bin"; exit 1; fi
  if [ "$debug" = 1 ]; then
    dsymutil "$bin" -o "$out/dSYMs/$L.framework.dSYM" 2> "$work/dsymutil-$L.out" || { tail -5 "$work/dsymutil-$L.out"; exit 1; }
  fi
  strip -S -x "$bin" 2>&1 | grep -v "invalidate the code signature" || true
  codesign --force --sign - "$bin"
  mkdir -p "$out/include/lib$l"
  cp -R "$prefix/include/lib$l/." "$out/include/lib$l/"
done
# Private headers FFmpegKit 9.0.2 also puts in its frameworks (copied from the source tree,
# unmodified; libavutil/libm.h no longer exists in FFmpeg 9.1).
extra() { # lib relpath
  if [ -f "$src/lib$1/$2" ]; then
    mkdir -p "$(dirname "$out/include/lib$1/$2")"; cp "$src/lib$1/$2" "$out/include/lib$1/$2"
  else
    echo "note: lib$1/$2 is not in this FFmpeg version"
  fi
}
for h in arm/intmath.h attributes_internal.h getenv_utf8.h internal.h intmath.h libm.h mem_internal.h thread.h x86/asm.h x86/intmath.h; do extra avutil "$h"; done
for h in dovi_rpu.h mathops.h sei.h x86/mathops.h; do extra avcodec "$h"; done
extra avformat os_support.h
cp config.h config_components.h "$out/config/"
cp "$work/configure.out" "$out/config/configure.out"
{
  echo "platform=$platform arch=$arch slice=$slice triple=$triple debug=$debug"
  echo "sdk=$(xcrun --sdk "$sdk" --show-sdk-version) xcode=$(xcodebuild -version | tr '\n' ' ')"
  echo "clang=$(/usr/bin/clang --version | head -1)"
  echo "CFLAGS=$cflags"
  echo "LDFLAGS=$ldflags"
  echo "ffmpeg_version=$(cat libavutil/ffversion.h | grep FFMPEG_VERSION | cut -d'"' -f2)"
  echo "vulkan_headers=1.$vk_minor.$vk_patch"
} | tee "$out/build-info.txt"
echo "$slice" > "$out/SLICE"
echo "$arch" > "$out/ARCH"
ls -l "$out/bin"
