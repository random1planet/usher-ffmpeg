#!/bin/bash
# FFmpeg for Usher's Live TV engine, SD channels (Freeview SD: MPEG-2 video, MPEG-1 Layer II sound).
#
# Builds libavutil and libavcodec, with only the MPEG-2 video and MP2 sound decoders and their two parsers, as
# DYNAMIC frameworks (LGPL 2.1 or later: the app links them, never copies them in, so anyone can swap in their own
# build), for four slices: tvOS device, tvOS simulator, iOS device (iPhone and iPad), iOS simulator. Then one
# .xcframework per library.
#
#   scripts/ffmpeg/build-xcframework.sh
#
#   OUT=<dir>    where everything goes (default: Usher's build disk if it is there, else ./out beside this script)
#   TARBALL_DIR=<dir>  take the tarball and its .asc from here instead of downloading them (default: ./source beside
#                this script, if it holds them, as in the public repository); they are checked just the same
#   JOBS=<n>     make -j (default 4: the Mac is shared)
#   NICE=<n>     nice level for configure and make (default 15)
#   SLICES="…"   a subset of: tvos tvos-sim ios ios-sim (default all four)
#
# Output: $OUT/dist/UsherFFmpeg/{libavutil,libavcodec}.xcframework, include/ (the C headers, for Swift's module
# map), LICENSE (FFmpeg's LGPL text), BUILDINFO.txt (version, checksums, the exact configure flags, toolchain).
#
# The source is FFmpeg's release tarball from ffmpeg.org, untrusted until two checks pass:
#   1. its PGP signature (.asc) is good and made by FFmpeg's release signing key, whose fingerprint KEY_FPR is the one
#      published on https://ffmpeg.org/download.html ("All FFmpeg releases are cryptographically signed ...");
#   2. its SHA-256 is TARBALL_SHA256. FFmpeg publishes no checksum files for current releases (only .asc and
#      .pq.asc signatures; the .md5/.sha1 files stop at 0.6), so this value is the hash of the tarball whose signature
#      checked good: first on 2 Nov 2026 (the spike's download, recorded in commit 543b3db) and again, from a
#      separate download, on 5 Nov 2026. Both downloads hashed the same.
# The download goes into a new, empty directory of its own and is only unpacked once both checks pass.
# After configure, the build stops unless CONFIG_GPL, CONFIG_NONFREE and CONFIG_VERSION3 are all 0 and exactly the
# expected decoders and parsers are enabled.
set -euo pipefail

VERSION=8.1.3
TARBALL="ffmpeg-$VERSION.tar.xz"
TARBALL_SHA256="7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"   # 11,732,036 bytes; see above
KEY_FPR="FCF986EA15E6E293A5644F10B4322F04D67658D8"   # FFmpeg release signing key <ffmpeg-devel@ffmpeg.org>, rsa2048 2011-04-26
MIN_OS=18.0                                           # (project.yml: tvOS 18.0, iOS 18.0)
DECODERS="mpeg2video,mp2,mp2float"                    # (mp2: the fixed-point one, kept for the bit-exact cross-check)
PARSERS="mpegvideo,mpegaudio"

here="$(cd "$(dirname "$0")" && pwd)"
USHER_DISK="/Volumes/Mini SSD/Developer/usher-build"
if [ -d "$USHER_DISK" ]; then OUT="${OUT:-$USHER_DISK/ffmpeg}"; else OUT="${OUT:-$here/out}"; fi
JOBS="${JOBS:-4}"
NICE="${NICE:-15}"
SLICES="${SLICES:-tvos tvos-sim ios ios-sim}"
if [ -z "${TARBALL_DIR:-}" ] && [ -f "$here/source/ffmpeg-$VERSION.tar.xz" ]; then TARBALL_DIR="$here/source"; fi

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "STOP: $*"; exit 1; }

mkdir -p "$OUT"
# FFmpeg's configure and its Makefiles can't take a path with a space ("Mini SSD"): everything is built through a
# space-free link to $OUT. (The link is only a pointer; every byte lands on $OUT.)
LINK="${LINK:-$HOME/.usher-sd-ffmpeg}"
if [ -L "$LINK" ] || [ ! -e "$LINK" ]; then ln -sfn "$OUT" "$LINK"; else die "$LINK exists and is not a link"; fi
W="$LINK"
SRC="$W/src"; BUILD="$W/build"; DIST="$W/dist/UsherFFmpeg"
mkdir -p "$SRC" "$BUILD"

# --- 1. the source, verified ------------------------------------------------------------------------------------------
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
if [ -f "$SRC/$TARBALL" ] && [ "$(sha_of "$SRC/$TARBALL")" = "$TARBALL_SHA256" ] && [ -f "$SRC/gpg-verify.txt" ]; then
  log "source: $SRC/$TARBALL already verified (SHA-256 matches)"
else
  rm -f "$SRC/$TARBALL"
  DL="$(mktemp -d "$W/download.XXXXXX")"   # a new, empty directory for the untrusted download
  if [ -n "${TARBALL_DIR:-}" ]; then
    log "source: $TARBALL and its signature from $TARBALL_DIR, FFmpeg's public key from ffmpeg.org, into $DL"
    cp "$TARBALL_DIR/$TARBALL" "$TARBALL_DIR/$TARBALL.asc" "$DL/"
  else
    log "source: downloading $TARBALL, its signature and FFmpeg's public key from ffmpeg.org into $DL"
    ( cd "$DL"
      curl -fsS --proto '=https' --tlsv1.2 -o "$TARBALL"      "https://ffmpeg.org/releases/$TARBALL"
      curl -fsS --proto '=https' --tlsv1.2 -o "$TARBALL.asc"  "https://ffmpeg.org/releases/$TARBALL.asc" )
  fi
  ( cd "$DL" && curl -fsS --proto '=https' --tlsv1.2 -o ffmpeg-devel.asc "https://ffmpeg.org/ffmpeg-devel.asc" )
  # (a keyring of its own: nothing touches the user's)
  export GNUPGHOME="$DL/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  gpg --batch --quiet --import "$DL/ffmpeg-devel.asc" 2>/dev/null
  got=$(gpg --batch --with-colons --fingerprint | awk -F: '/^fpr/ {print $10; exit}')
  [ "$got" = "$KEY_FPR" ] || die "the key from ffmpeg.org has fingerprint $got, not FFmpeg's published $KEY_FPR"
  gpg --batch --status-fd 1 --verify "$DL/$TARBALL.asc" "$DL/$TARBALL" > "$DL/gpg-verify.txt" 2>&1 || true
  grep -q "^\[GNUPG:\] VALIDSIG $KEY_FPR " "$DL/gpg-verify.txt" || { cat "$DL/gpg-verify.txt"; die "BAD SIGNATURE on $TARBALL"; }
  sha=$(sha_of "$DL/$TARBALL")
  [ "$sha" = "$TARBALL_SHA256" ] || die "SHA-256 of the download is $sha, not the pinned $TARBALL_SHA256"
  log "source: signature good (key $KEY_FPR), SHA-256 $sha matches"
  mv "$DL/$TARBALL" "$DL/$TARBALL.asc" "$DL/gpg-verify.txt" "$SRC/"
  rm -rf "$DL"
fi
rm -rf "$SRC/ffmpeg-$VERSION"
( cd "$SRC" && tar xf "$TARBALL" )
FF="$SRC/ffmpeg-$VERSION"
[ -x "$FF/configure" ] || die "no configure in $FF"

# --- 2. one build per slice -----------------------------------------------------------------------------------------
# slice name -> SDK, clang target, Xcode's platform name (for Info.plist)
slice_sdk()      { case $1 in tvos) echo appletvos;; tvos-sim) echo appletvsimulator;; ios) echo iphoneos;; ios-sim) echo iphonesimulator;; esac; }
slice_target()   { case $1 in tvos) echo "arm64-apple-tvos$MIN_OS";; tvos-sim) echo "arm64-apple-tvos$MIN_OS-simulator";;
                              ios) echo "arm64-apple-ios$MIN_OS";; ios-sim) echo "arm64-apple-ios$MIN_OS-simulator";; esac; }
slice_platform() { case $1 in tvos) echo AppleTVOS;; tvos-sim) echo AppleTVSimulator;; ios) echo iPhoneOS;; ios-sim) echo iPhoneSimulator;; esac; }

CONFIGURE_FLAGS=(
  --disable-everything
  --enable-decoder="$DECODERS" --enable-parser="$PARSERS"
  --disable-gpl --disable-nonfree --disable-version3
  --enable-shared --disable-static --enable-pic
  --disable-programs --disable-doc --disable-network --disable-autodetect --disable-debug
  --disable-avformat --disable-avfilter --disable-avdevice --disable-swscale --disable-swresample
)

build_slice() {
  local s=$1 sdk target dir sysroot cc
  sdk=$(slice_sdk "$s"); target=$(slice_target "$s"); dir="$BUILD/$s"
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir"
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path); cc=$(xcrun --sdk "$sdk" -f clang)
  log "$s: configure ($sdk, $target)"
  nice -n "$NICE" "$FF/configure" \
    --prefix="$dir/install" --enable-cross-compile --target-os=darwin --arch=aarch64 \
    --cc="$cc" --sysroot="$sysroot" \
    --extra-cflags="-target $target" --extra-ldflags="-target $target" \
    --install-name-dir='@rpath' \
    "${CONFIGURE_FLAGS[@]}" > configure.log 2>&1 || { tail -30 configure.log; die "$s: configure failed"; }
  for k in CONFIG_GPL CONFIG_NONFREE CONFIG_VERSION3; do
    grep -q "^#define $k 0$" config.h || die "$s: $k is not 0 (licence)"
  done
  # Exactly these decoders and parsers, nothing else (encoders, demuxers, protocols: none).
  local dec par
  dec=$(grep -E '^#define CONFIG_[A-Z0-9_]+_DECODER 1$' config_components.h | sed -E 's/#define CONFIG_(.*)_DECODER 1/\1/' | tr 'A-Z' 'a-z' | sort | tr '\n' ,)
  par=$(grep -E '^#define CONFIG_[A-Z0-9_]+_PARSER 1$' config_components.h | sed -E 's/#define CONFIG_(.*)_PARSER 1/\1/' | tr 'A-Z' 'a-z' | sort | tr '\n' ,)
  [ "$dec" = "mp2,mp2float,mpeg2video," ] || die "$s: decoders enabled are '$dec'"
  [ "$par" = "mpegaudio,mpegvideo," ] || die "$s: parsers enabled are '$par'"
  for kind in ENCODER DEMUXER MUXER PROTOCOL FILTER; do
    ! grep -qE "^#define CONFIG_[A-Z0-9_]+_$kind 1$" config_components.h || die "$s: an $kind is enabled"
  done
  log "$s: make -j$JOBS (nice $NICE)"
  nice -n "$NICE" make -j"$JOBS" > make.log 2>&1 || { tail -30 make.log; die "$s: make failed"; }
  make install > install.log 2>&1 || { tail -30 install.log; die "$s: make install failed"; }
}

# --- 3. frameworks and the xcframeworks -------------------------------------------------------------------------------
framework() {   # $1 slice, $2 lib (avutil | avcodec) -> $BUILD/fw/$1/lib$2.framework
  local s=$1 lib=$2 inst="$BUILD/$1/install" fw="$BUILD/fw/$1/lib$2.framework" dylib old
  rm -rf "$fw"; mkdir -p "$fw/Headers"
  dylib=$(ls "$inst/lib/lib$lib".[0-9]*.dylib | grep -E "lib$lib\.[0-9]+\.dylib$" | head -1)
  [ -n "$dylib" ] || die "$s: no lib$lib dylib"
  cp "$dylib" "$fw/lib$lib"
  install_name_tool -id "@rpath/lib$lib.framework/lib$lib" "$fw/lib$lib" 2>/dev/null
  if [ "$lib" = avcodec ]; then   # (libavcodec loads libavutil: point it at the framework)
    old=$(otool -L "$fw/lib$lib" | awk '$1 ~ /libavutil/ {print $1}' | head -1)
    [ -n "$old" ] && install_name_tool -change "$old" "@rpath/libavutil.framework/libavutil" "$fw/lib$lib" 2>/dev/null
  fi
  xcrun strip -x -S "$fw/lib$lib" 2>/dev/null   # (local and debug symbols out; FFmpeg's API stays exported)
  codesign -f -s - "$fw/lib$lib" 2>/dev/null     # (ad hoc again after the edits; Xcode signs it properly when it embeds it)
  cp -R "$inst/include/lib$lib/." "$fw/Headers/"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>lib$lib</string>
  <key>CFBundleIdentifier</key><string>com.custardcat.usher.ffmpeg.lib$lib</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>lib$lib</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$(slice_platform "$s")</string></array>
  <key>MinimumOSVersion</key><string>$MIN_OS</string>
</dict></plist>
PLIST
  # Checks: arm64, the right platform, the right install name, and nothing it loads but the system and libavutil.
  lipo -archs "$fw/lib$lib" | grep -qx arm64 || die "$s lib$lib: not arm64"
  otool -D "$fw/lib$lib" | tail -1 | grep -qx "@rpath/lib$lib.framework/lib$lib" || die "$s lib$lib: install name"
  if otool -L "$fw/lib$lib" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/|@rpath/libavutil\.framework/libavutil$|@rpath/lib'"$lib"'\.framework/lib'"$lib"'$)'; then
    die "$s lib$lib: loads something unexpected (above)"
  fi
}

t0=$(date +%s)
for s in $SLICES; do build_slice "$s"; done
log "frameworks"
rm -rf "$DIST"; mkdir -p "$DIST"
for lib in avutil avcodec; do
  args=()
  for s in $SLICES; do framework "$s" "$lib"; args+=(-framework "$BUILD/fw/$s/lib$lib.framework"); done
  xcodebuild -create-xcframework "${args[@]}" -output "$DIST/lib$lib.xcframework" > "$BUILD/xcframework-$lib.log" 2>&1 \
    || { cat "$BUILD/xcframework-$lib.log"; die "xcframework lib$lib"; }
done
# The C headers (the same for every slice: checked), for the Swift module map (Apps/UsherTV/LiveEngine/SD/CFFmpeg).
first=$(echo $SLICES | awk '{print $1}')
for s in $SLICES; do diff -rq "$BUILD/$first/install/include" "$BUILD/$s/install/include" > /dev/null || die "headers differ between $first and $s"; done
cp -R "$BUILD/$first/install/include" "$DIST/include"
cp "$FF/COPYING.LGPLv2.1" "$DIST/LICENSE"

{ echo "FFmpeg $VERSION for Usher (SD channels), built $(date -u +%Y-%m-%dT%H:%MZ) by scripts/ffmpeg/build-xcframework.sh"
  echo "source: https://ffmpeg.org/releases/$TARBALL"
  echo "tarball sha256: $(sha_of "$SRC/$TARBALL")"
  grep -E '^\[GNUPG:\] (GOODSIG|VALIDSIG)' "$SRC/gpg-verify.txt" | cut -c1-120
  echo "configure (every slice; plus --prefix, --cc, --sysroot and -target for the slice): ${CONFIGURE_FLAGS[*]} --enable-cross-compile --target-os=darwin --arch=aarch64 --install-name-dir=@rpath"
  echo "slices: $SLICES"
  for s in $SLICES; do echo "  $s: $(slice_target "$s") (SDK $(xcrun --sdk "$(slice_sdk "$s")" --show-sdk-version))"; done
  echo "toolchain: $(xcodebuild -version | tr '\n' ' ')"
  grep -E "^#define CONFIG_(GPL|NONFREE|VERSION3) " "$BUILD/$first/config.h"
  echo "licence (configure): $(grep -m1 '^License:' "$BUILD/$first/configure.log" || true)"
  echo "sizes (bytes, stripped binary per slice):"
  for s in $SLICES; do for lib in avutil avcodec; do printf '  %-9s lib%-8s %9d\n' "$s" "$lib" "$(stat -f %z "$BUILD/fw/$s/lib$lib.framework/lib$lib")"; done; done
} > "$DIST/BUILDINFO.txt"
cat "$DIST/BUILDINFO.txt"
du -sh "$DIST"/*.xcframework
log "done in $(( $(date +%s) - t0 )) s: $OUT/dist/UsherFFmpeg"
