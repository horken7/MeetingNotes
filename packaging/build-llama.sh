#!/bin/bash
# Builds a self-contained llama-completion (llama.cpp; static libraries, Metal shaders embedded) for the
# app bundle. It runs the built-in notes model (Gemma 3 4B) on the Mac, one call per process.
#   bash packaging/build-llama.sh <output llama-completion> [arch ...]
# Default archs: arm64 x86_64, combined into one universal binary. Needs cmake and the Xcode command line tools.
# LLAMA_SRC=<checkout> uses an existing llama.cpp checkout instead of downloading the pinned release.
set -euo pipefail
LLAMA_VERSION="b12189"   # https://github.com/ggml-org/llama.cpp/releases (the same as the iPhone app)
OUT="$1"; shift
ARCHS=("$@"); [[ ${#ARCHS[@]} -gt 0 ]] || ARCHS=(arm64 x86_64)
WORK="${LLAMA_WORK:-$(mktemp -d)}"
mkdir -p "$WORK" "$(dirname "$OUT")"

SRC="${LLAMA_SRC:-$WORK/llama.cpp-$LLAMA_VERSION}"
if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "==> Downloading llama.cpp $LLAMA_VERSION"
  curl -fsSL "https://github.com/ggml-org/llama.cpp/archive/refs/tags/$LLAMA_VERSION.tar.gz" | tar -xz -C "$WORK"
fi

SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "==> Building llama-completion for $arch"
  B="$WORK/build-$arch"
  FLAGS=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
         -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
         -DGGML_BLAS=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_TOOLS=ON
         -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF
         -DLLAMA_BUILD_UI=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF)
  # Every Intel Mac that runs macOS 15 has AVX2.
  [[ "$arch" == x86_64 ]] && FLAGS+=(-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON)
  cmake -S "$SRC" -B "$B" "${FLAGS[@]}" >/dev/null
  cmake --build "$B" --config Release --target llama-completion -j "$(sysctl -n hw.ncpu)" >/dev/null
  SLICES+=("$B/bin/llama-completion")
done
lipo -create "${SLICES[@]}" -output "$OUT"
strip -x "$OUT" 2>/dev/null || true

# Self-contained: only system libraries and frameworks.
otool -L "$OUT"
if otool -L "$OUT" | grep -E '^\s' | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
  echo "llama-completion links non-system libraries (listed above)" >&2; exit 1
fi
echo "==> $OUT ($(lipo -archs "$OUT"))"
