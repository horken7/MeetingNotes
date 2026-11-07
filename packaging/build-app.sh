#!/bin/bash
# Builds the self-contained "Meeting Notes.app" for the disk image: universal app, the MCP server,
# a bundled whisper-cli and the Claude Desktop extension, ad hoc signed.
#   WHISPER_CLI=<whisper-cli from build-whisper.sh> MODELS_DIR=<folder from fetch-models.sh> \
#     bash packaging/build-app.sh <output folder> [version]
# MODELS_DIR is required, so a release never ships without the speech models; MODELS_DIR=none builds
# without them (the app then downloads them on first run).
# ARCHS="arm64" builds one architecture only (quicker, for local testing).
set -euo pipefail
OUT="$1"
VERSION="${2:-0.0.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHS=(${ARCHS:-arm64 x86_64})
: "${WHISPER_CLI:?Set WHISPER_CLI to the whisper-cli built by packaging/build-whisper.sh}"
: "${MODELS_DIR:?Set MODELS_DIR to the folder filled by packaging/fetch-models.sh (or none)}"
APP="$OUT/Meeting Notes.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

build() {   # build <output> <swiftc args...>: one slice per arch, combined with lipo
  local out="$1"; shift
  local slices=()
  for arch in "${ARCHS[@]}"; do
    xcrun --sdk macosx swiftc -O -swift-version 5 -target "$arch-apple-macos15.0" -o "$WORK/$(basename "$out")-$arch" "$@"
    slices+=("$WORK/$(basename "$out")-$arch")
  done
  lipo -create "${slices[@]}" -output "$out"
}

echo "==> Building the app (${ARCHS[*]})"
build "$APP/Contents/MacOS/MeetingNotes" -parse-as-library "$ROOT"/src/*.swift
echo "==> Building the MCP server"
build "$APP/Contents/MacOS/meetingnotes-mcp" "$ROOT/mcp/main.swift"
echo "==> Adding whisper-cli"
cp "$WHISPER_CLI" "$APP/Contents/MacOS/whisper-cli"
chmod 755 "$APP/Contents/MacOS/whisper-cli"

if [[ "$MODELS_DIR" != none ]]; then
  echo "==> Adding the speech models"
  mkdir -p "$APP/Contents/Resources/models"
  for m in ggml-large-v3-turbo.bin ggml-silero-v5.1.2.bin; do
    [[ -s "$MODELS_DIR/$m" ]] || { echo "Missing $MODELS_DIR/$m (run packaging/fetch-models.sh)" >&2; exit 1; }
    # A clone shares the disk blocks with the source on APFS, so this doesn't take another 1.6 GB.
    cp -c "$MODELS_DIR/$m" "$APP/Contents/Resources/models/$m" 2>/dev/null || cp "$MODELS_DIR/$m" "$APP/Contents/Resources/models/$m"
    chmod 644 "$APP/Contents/Resources/models/$m"
  done
fi

# The build number only has to increase between releases: the commit count does.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
bash "$ROOT/packaging/info-plist.sh" "$VERSION" "$BUILD_NUMBER" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Icon"
xcrun --sdk macosx swift "$ROOT/makeicon.swift" "$WORK/icon.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
sips -z 512 512 "$WORK/icon.png" --out "$WORK/icon-512.png" >/dev/null

echo "==> Claude Desktop extension"
# Its launcher runs the server inside the installed app (it also looks in ~/Applications and asks Spotlight).
MCPB_VERSION="${VERSION}" bash "$ROOT/mcp/pack.sh" "$APP/Contents/Resources/MeetingNotes.mcpb" \
  "/Applications/Meeting Notes.app/Contents/MacOS/meetingnotes-mcp" "$WORK/icon-512.png"

echo "==> Signing (ad hoc)"
# Inner executables first, then the bundle, which seals everything inside it.
for exe in whisper-cli meetingnotes-mcp; do
  codesign --force --sign - --identifier "se.frinkle.meetingnotes.$exe" "$APP/Contents/MacOS/$exe"
done
codesign --force --sign - --identifier se.frinkle.meetingnotes "$APP"
codesign --verify --strict --deep "$APP"
echo "==> $APP ($(lipo -archs "$APP/Contents/MacOS/MeetingNotes"))"
