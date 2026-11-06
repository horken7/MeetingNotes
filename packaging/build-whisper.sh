#!/bin/bash
# Builds a self-contained whisper-cli (static libraries, Metal shaders embedded) for the app bundle.
#   bash packaging/build-whisper.sh <output whisper-cli> [arch ...]
# Default archs: arm64 x86_64, combined into one universal binary. Needs cmake and the Xcode command line tools.
# WHISPER_SRC=<checkout> uses an existing whisper.cpp checkout instead of downloading the pinned release.
set -euo pipefail
WHISPER_VERSION="v1.9.5"   # https://github.com/ggml-org/whisper.cpp/releases
OUT="$1"; shift
ARCHS=("$@"); [[ ${#ARCHS[@]} -gt 0 ]] || ARCHS=(arm64 x86_64)
WORK="${WHISPER_WORK:-$(mktemp -d)}"
mkdir -p "$WORK" "$(dirname "$OUT")"

SRC="${WHISPER_SRC:-$WORK/whisper.cpp-$WHISPER_VERSION}"
if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "==> Downloading whisper.cpp $WHISPER_VERSION"
  curl -fsSL "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/$WHISPER_VERSION.tar.gz" | tar -xz -C "$WORK"
  [[ -d "$WORK/whisper.cpp-${WHISPER_VERSION#v}" ]] && mv "$WORK/whisper.cpp-${WHISPER_VERSION#v}" "$SRC"
fi

SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "==> Building whisper-cli for $arch"
  B="$WORK/build-$arch"
  FLAGS=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
         -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
         -DGGML_BLAS=ON -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
         -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF)
  # Every Intel Mac that runs macOS 15 has AVX2.
  [[ "$arch" == x86_64 ]] && FLAGS+=(-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON)
  cmake -S "$SRC" -B "$B" "${FLAGS[@]}" >/dev/null
  cmake --build "$B" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)" >/dev/null
  SLICES+=("$B/bin/whisper-cli")
done
lipo -create "${SLICES[@]}" -output "$OUT"
strip -x "$OUT" 2>/dev/null || true

# Self-contained: only system libraries and frameworks.
if otool -L "$OUT" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
  echo "whisper-cli links non-system libraries (listed above)" >&2; exit 1
fi
echo "==> $OUT ($(lipo -archs "$OUT"))"
