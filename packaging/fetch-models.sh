#!/bin/bash
# Downloads the models that are bundled in the app (speech, voice detection and the built-in notes
# model) from pinned Hugging Face revisions, and checks their SHA-256. Files already in <dir> with the
# right checksum are kept (CI caches them).
#   bash packaging/fetch-models.sh <dir>
# Keep the names in sync with Tools.modelName / Tools.vadModelName and BuiltIn.modelName in src/.
set -euo pipefail
DIR="$1"
mkdir -p "$DIR"

# name | url | sha256
MODELS=(
  "ggml-large-v3-turbo.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin|1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
  "ggml-silero-v5.1.2.bin|https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin|29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
  # Gemma 3 4B instruct, Q4_K_M (2.49 GB): the built-in notes model, the same file the iPhone app uses.
  "gemma-3-4b-it-Q4_K_M.gguf|https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/d0976223747697cb51e056d85c532013931fe52e/gemma-3-4b-it-Q4_K_M.gguf|882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863"
)

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

for entry in "${MODELS[@]}"; do
  IFS='|' read -r name url sum <<<"$entry"
  file="$DIR/$name"
  if [[ -f "$file" && "$(sha "$file")" == "$sum" ]]; then
    echo "==> $name: already here"
    continue
  fi
  echo "==> Downloading $name"
  curl -fL --retry 5 --retry-all-errors -C - -o "$file.part" "$url" || curl -fL --retry 5 -o "$file.part" "$url"
  got="$(sha "$file.part")"
  if [[ "$got" != "$sum" ]]; then
    rm -f "$file.part"
    echo "Checksum mismatch for $name: expected $sum, got $got" >&2
    exit 1
  fi
  mv "$file.part" "$file"
done
