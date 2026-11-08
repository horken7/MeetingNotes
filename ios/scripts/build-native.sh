#!/usr/bin/env bash
# Builds ios/Native/MeetingNative.xcframework: whisper.cpp (speech) and llama.cpp (notes) as one static library
# for iPhone and the iOS Simulator, sharing a single copy of ggml (from llama.cpp) with Metal and its shaders
# embedded. The xcframework isn't checked in; Xcode needs it before the first build:
#
#   bash ios/scripts/build-native.sh
#
# Needs CMake (`brew install cmake`). Takes about 5 minutes; reruns are skipped while the versions match.
set -euo pipefail

LLAMA_TAG=b12189
WHISPER_COMMIT=727d3e7666485e12450746b523bfb4e7f057cc5e
DEPLOYMENT_TARGET=26.0

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/Native/MeetingNative.xcframework"
STAMP="$HERE/Native/.version"
VERSION="llama-$LLAMA_TAG whisper-$WHISPER_COMMIT ios-$DEPLOYMENT_TARGET"
if [[ -d "$OUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" ]]; then
  echo "MeetingNative.xcframework is up to date ($VERSION)."
  exit 0
fi

WORK="${MEETINGNATIVE_WORK:-${TMPDIR:-/tmp}/meetingnative-build}"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching llama.cpp $LLAMA_TAG and whisper.cpp ${WHISPER_COMMIT:0:10}"
git clone -q --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp.git "$WORK/llama.cpp"
git init -q "$WORK/whisper.cpp"
git -C "$WORK/whisper.cpp" fetch -q --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WHISPER_COMMIT"
git -C "$WORK/whisper.cpp" checkout -q FETCH_HEAD

JOBS="$(sysctl -n hw.ncpu)"
FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"

build() {  # build <name> <sdk>
  local name="$1" sdk="$2" prefix="$WORK/install-$1"
  local common=(
    -G "Unix Makefiles"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)"
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCMAKE_C_FLAGS="$FLAGS"
    -DCMAKE_CXX_FLAGS="$FLAGS"
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_PREFIX_PATH="$prefix"
    -DCMAKE_FIND_ROOT_PATH="$prefix"
    -DBUILD_SHARED_LIBS=OFF
  )
  echo "Building llama.cpp + ggml for $name"
  cmake -S "$WORK/llama.cpp" -B "$WORK/build-llama-$name" "${common[@]}" \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_MTMD=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF > "$WORK/llama-$name.log"
  cmake --build "$WORK/build-llama-$name" -j "$JOBS" >> "$WORK/llama-$name.log"
  cmake --install "$WORK/build-llama-$name" >> "$WORK/llama-$name.log"

  echo "Building whisper.cpp for $name (with llama.cpp's ggml)"
  cmake -S "$WORK/whisper.cpp" -B "$WORK/build-whisper-$name" "${common[@]}" \
    -DWHISPER_USE_SYSTEM_GGML=ON -Dggml_DIR="$prefix/lib/cmake/ggml" \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF \
    -DWHISPER_CURL=OFF > "$WORK/whisper-$name.log"
  cmake --build "$WORK/build-whisper-$name" -j "$JOBS" --target whisper >> "$WORK/whisper-$name.log"
  cmake --install "$WORK/build-whisper-$name" >> "$WORK/whisper-$name.log" 2>&1 || true
  cp "$WORK/whisper.cpp/include/whisper.h" "$prefix/include/"
  find "$WORK/build-whisper-$name" -name 'libwhisper*.a' -exec cp {} "$prefix/lib/" \;

  # One static library and a Clang module for Swift.
  libtool -static -o "$WORK/libmeetingnative-$name.a" "$prefix"/lib/*.a 2> /dev/null
  mkdir -p "$WORK/headers-$name"
  cp "$prefix"/include/*.h "$WORK/headers-$name/"
  cat > "$WORK/headers-$name/MeetingNative.h" << 'EOF'
#include "ggml.h"
#include "ggml-backend.h"
#include "gguf.h"
#include "llama.h"
#include "whisper.h"
EOF
  cat > "$WORK/headers-$name/module.modulemap" << 'EOF'
module MeetingNative {
    header "MeetingNative.h"
    link "c++"
    link framework "Accelerate"
    link framework "Foundation"
    link framework "Metal"
    link framework "MetalKit"
    export *
}
EOF
}

build ios-device iphoneos
build ios-simulator iphonesimulator

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/libmeetingnative-ios-device.a" -headers "$WORK/headers-ios-device" \
  -library "$WORK/libmeetingnative-ios-simulator.a" -headers "$WORK/headers-ios-simulator" \
  -output "$OUT" > /dev/null
echo "$VERSION" > "$STAMP"
du -sh "$OUT"
