#!/usr/bin/env bash
# Downloads the models that ship inside the app into ios/Models/ (not checked in; about 1 GB), checking each
# file's SHA-256: voice detection, Whisper small (all languages) and Gemma 3 1B (notes). Xcode copies the folder
# into the app, so it works offline right after install; better models are optional downloads in the app. Files that are already
# there and correct are kept, so reruns are quick.
#
#   bash ios/scripts/fetch-models.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/Models"
STAMPS="$(dirname "$DIR")/.models-verified"
mkdir -p "$DIR" "$STAMPS"

# file name | URL | SHA-256 (from Hugging Face's LFS metadata)
MODELS="
ggml-silero-v5.1.2.bin|https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin|29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf
ggml-small-q5_1.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin|ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb
gemma-3-1b-it-Q4_K_M.gguf|https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf|8ccc5cd1f1b3602548715ae25a66ed73fd5dc68a210412eea643eb20eb75a135
"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

for line in $MODELS; do
  IFS='|' read -r name url sum <<< "$line"
  file="$DIR/$name"
  # A stamp records the checksum of a verified file, so it isn't rehashed on every build.
  if [[ -f "$file" && -f "$STAMPS/$name" && "$(cat "$STAMPS/$name")" == "$sum $(stat -f %z "$file")" ]]; then
    continue
  fi
  if [[ ! -f "$file" ]] || [[ "$(sha "$file")" != "$sum" ]]; then
    echo "Downloading $name"
    curl -fL --retry 3 -o "$file.part" "$url"
    if [[ "$(sha "$file.part")" != "$sum" ]]; then
      rm -f "$file.part"
      echo "error: $name doesn't match its checksum" >&2
      exit 1
    fi
    mv "$file.part" "$file"
  fi
  echo "$sum $(stat -f %z "$file")" > "$STAMPS/$name"
done
du -sh "$DIR"
