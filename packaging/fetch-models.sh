#!/bin/bash
# Downloads the speech models that are bundled in the app, from pinned Hugging Face revisions, and
# checks their SHA-256. Files already in <dir> with the right checksum are kept (CI caches them).
#   bash packaging/fetch-models.sh <dir>
# Keep the names in sync with Tools.modelName / Tools.vadModelName in src/Pipeline.swift.
set -euo pipefail
DIR="$1"
mkdir -p "$DIR"

# name | url | sha256
MODELS=(
  "ggml-large-v3-turbo.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin|1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
  "ggml-silero-v5.1.2.bin|https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin|29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
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
