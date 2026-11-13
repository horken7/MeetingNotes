#!/bin/bash
# Meeting Notes installer
# Builds and installs a Mac app that records calls, transcribes them on your Mac
# with whisper.cpp and writes notes with the built-in local model (Gemma 3 4B with llama.cpp),
# Claude Code, Codex (OpenAI) or a local model in Ollama.
# Run from the MeetingNotes folder:  bash install.sh
# Optional: SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" bash install.sh
#   signs with a code-signing certificate from your keychain instead of ad hoc (see README).

set -euo pipefail

APP_NAME="Meeting Notes"
EXEC="MeetingNotes"
BUNDLE_ID="se.frinkle.meetingnotes"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"
DATA="$HOME/.meetnotes"
BUILD="$DATA/build"
MODEL="$DATA/ggml-large-v3-turbo.bin"
OLLAMA_MODEL="gemma3:12b"   # keep in sync with Ollama.defaultModel in src/Pipeline.swift
OLLAMA_URL="http://localhost:11434"
VAD="$DATA/ggml-silero-v5.1.2.bin"
# The built-in notes model; keep in sync with BuiltIn in src/BuiltIn.swift and packaging/fetch-models.sh.
NOTES_MODEL="$DATA/gemma-3-4b-it-Q4_K_M.gguf"
NOTES_MODEL_URL="https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/d0976223747697cb51e056d85c532013931fe52e/gemma-3-4b-it-Q4_K_M.gguf"
NOTES_MODEL_SHA="882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

step() { printf '\n\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Preserve the selected provider on reinstall. A first install uses the built-in model; an install from
# before it existed (built, but no provider saved) keeps Claude, which was the default then.
if SAVED="$(defaults read "$BUNDLE_ID" notesProvider 2>/dev/null)"; then
  PROVIDER="$SAVED"
elif [[ -d "$BUILD" ]]; then
  PROVIDER=claude
else
  PROVIDER=builtin
fi
if [[ $# -gt 0 ]]; then
  [[ $# -eq 2 && "$1" == "--provider" ]] || fail "Usage: bash install.sh [--provider builtin|claude|codex|ollama]"
  PROVIDER="$2"
fi
[[ "$PROVIDER" == "local" ]] && PROVIDER="ollama"
[[ "$PROVIDER" == "builtin" || "$PROVIDER" == "claude" || "$PROVIDER" == "codex" || "$PROVIDER" == "ollama" ]] \
  || fail "Provider must be builtin, claude, codex or ollama."

# ---------------------------------------------------------------------------
step "Checking your Mac"
[[ "$(uname)" == "Darwin" ]] || fail "This installer is for macOS."
ls "$SRC"/*.swift >/dev/null 2>&1 || fail "Source files not found in $SRC. Run install.sh from inside the MeetingNotes folder."
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( OS_MAJOR >= 15 )) || fail "macOS 15 (Sequoia) or newer is required."
xcrun --sdk macosx --find swiftc >/dev/null 2>&1 || fail "Xcode command line tools are missing. Run: xcode-select --install"
command -v brew >/dev/null || fail "Homebrew is required. Install it from https://brew.sh and run this again."
note "macOS $(sw_vers -productVersion), $(uname -m)"

# ---------------------------------------------------------------------------
step "Transcription engine (whisper.cpp)"
if command -v whisper-cli >/dev/null; then
  note "Already installed: $(command -v whisper-cli)"
else
  brew install whisper-cpp
fi
command -v whisper-cli >/dev/null || fail "whisper-cli was not found after installing whisper-cpp."

# ---------------------------------------------------------------------------
step "Notes provider: $PROVIDER"
PROVIDER_CMD="$PROVIDER"
[[ "$PROVIDER" == "builtin" ]] && PROVIDER_CMD="llama-completion"
PROVIDER_EXE="$(command -v "$PROVIDER_CMD" || true)"
if [[ -z "$PROVIDER_EXE" ]]; then
  if [[ "$PROVIDER" == "builtin" ]]; then
    brew install llama.cpp
    PROVIDER_EXE="$(command -v llama-completion || true)"
  elif [[ "$PROVIDER" == "claude" ]]; then
    curl -fsSL https://claude.ai/install.sh | bash
    PROVIDER_EXE="$HOME/.local/bin/claude"
  elif [[ "$PROVIDER" == "ollama" ]]; then
    brew install ollama
    PROVIDER_EXE="$(command -v ollama || true)"
  else
    brew install --cask codex
    PROVIDER_EXE="$(command -v codex || true)"
  fi
fi
[[ -x "$PROVIDER_EXE" ]] || fail "$PROVIDER could not be installed."
"$PROVIDER_EXE" --version >/dev/null 2>&1 || fail "$PROVIDER is installed but cannot run. Repair its installation and retry."
note "Using $PROVIDER_EXE"
if [[ "$PROVIDER" == "builtin" ]]; then
  PROVIDER_OK=1
  if [[ "$(shasum -a 256 "$NOTES_MODEL" 2>/dev/null | cut -d' ' -f1)" == "$NOTES_MODEL_SHA" ]]; then
    note "Notes model already downloaded."
  else
    note "Downloading the notes model Gemma 3 4B (about 2.5 GB, once)..."
    curl -fL --progress-bar -C - -o "$NOTES_MODEL.part" "$NOTES_MODEL_URL"
    [[ "$(shasum -a 256 "$NOTES_MODEL.part" | cut -d' ' -f1)" == "$NOTES_MODEL_SHA" ]] \
      || { rm -f "$NOTES_MODEL.part"; fail "The notes model download was damaged. Run install.sh again."; }
    mv "$NOTES_MODEL.part" "$NOTES_MODEL"
  fi
elif [[ "$PROVIDER" == "claude" ]]; then
  note "Checking Claude login (one tiny request)..."
  if env -u ANTHROPIC_API_KEY "$PROVIDER_EXE" -p "Reply with just the word OK" </dev/null >/dev/null 2>&1; then
    PROVIDER_OK=1
  else
    PROVIDER_OK=0
  fi
elif [[ "$PROVIDER" == "ollama" ]]; then
  if ! curl -fsS -m 3 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
    note "Starting Ollama..."
    if [[ -d /Applications/Ollama.app ]]; then
      open -a Ollama
    else
      brew services start ollama >/dev/null || true
    fi
    for _ in $(seq 1 30); do
      curl -fsS -m 2 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 && break
      sleep 1
    done
  fi
  PROVIDER_OK=0
  if curl -fsS -m 3 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
    note "Downloading the local notes model $OLLAMA_MODEL (about 8 GB, once)..."
    "$PROVIDER_EXE" pull "$OLLAMA_MODEL" && PROVIDER_OK=1
  else
    note "Ollama didn't start. Start it with: brew services start ollama"
  fi
else
  if "$PROVIDER_EXE" login status >/dev/null 2>&1; then
    PROVIDER_OK=1
  else
    PROVIDER_OK=0
  fi
fi

# ---------------------------------------------------------------------------
step "Speech models (downloaded once)"
mkdir -p "$DATA"
if [[ -s "$MODEL" ]]; then
  note "Whisper model already downloaded."
else
  note "Downloading Whisper large-v3-turbo (about 1.6 GB)..."
  curl -fL --progress-bar -C - -o "$MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
  mv "$MODEL.part" "$MODEL"
fi
if whisper-cli --help 2>&1 | grep -q -- '--vad'; then
  if [[ ! -s "$VAD" ]]; then
    note "Downloading voice activity model (under 1 MB)..."
    curl -fL --progress-bar -o "$VAD" \
      "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" \
      || { rm -f "$VAD"; note "Skipped (download failed). Transcription still works."; }
  fi
fi


# ---------------------------------------------------------------------------
step "Building the app from $SRC (about a minute)"
ROOT="$HERE"; source "$HERE/packaging/sources.sh"
rm -rf "$BUILD"
mkdir -p "$BUILD"
ARCH="$(uname -m)"
xcrun --sdk macosx swiftc -O -parse-as-library -swift-version 5 \
  -target "$ARCH-apple-macos15.0" \
  -o "$BUILD/$EXEC" "${APP_SOURCES[@]}" \
  || fail "The build failed. See the compiler errors above."

# MCP server so Claude and other MCP clients can read your meetings (see the README).
mkdir -p "$DATA/bin"
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$ARCH-apple-macos15.0" \
  -o "$DATA/bin/meetingnotes-mcp" "$HERE/mcp/main.swift" \
  || fail "The MCP server build failed. See the compiler errors above."

APP="$BUILD/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD/$EXEC" "$APP/Contents/MacOS/$EXEC"

bash "$HERE/packaging/info-plist.sh" "$(cat "$HERE/version.txt" 2>/dev/null || echo 1.0)" 1 > "$APP/Contents/Info.plist"

# App icon (cosmetic, skipped if anything goes wrong)
(
  set +e
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  if xcrun --sdk macosx swift "$HERE/makeicon.swift" "$BUILD/icon.png" >/dev/null 2>&1; then
    for s in 16 32 128 256 512; do
      sips -z $s $s "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
      sips -z $((s * 2)) $((s * 2)) "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1
  fi
) || true

# Claude Desktop extension for the MCP server: open it (or use Settings > Setup) to add it to Claude Desktop.
sips -z 512 512 "$BUILD/icon.png" --out "$BUILD/icon-512.png" >/dev/null 2>&1 || true
bash "$HERE/mcp/pack.sh" "$DATA/MeetingNotes.mcpb" "$DATA/bin/meetingnotes-mcp" "$BUILD/icon-512.png" \
  || fail "Packing the Claude Desktop extension failed."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 \
    || fail "Code signing failed."
else
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP" \
    || fail "Signing with \"$SIGN_IDENTITY\" failed. List your identities with: security find-identity -p codesigning"
  note "Signed with $SIGN_IDENTITY"
fi

# ---------------------------------------------------------------------------
step "Installing"
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
pkill -x "$EXEC" 2>/dev/null || true
sleep 1
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP" "$DEST/"
[[ "$PROVIDER" == "ollama" || "$PROVIDER" == "builtin" ]] || defaults write "$BUNDLE_ID" "${PROVIDER}Path" "$PROVIDER_EXE"
defaults write "$BUNDLE_ID" notesProvider "$PROVIDER"
# Save meetings next to the app's source in a Meetings folder, unless another folder was chosen in Settings.
if ! defaults read "$BUNDLE_ID" outputDir >/dev/null 2>&1; then
  defaults write "$BUNDLE_ID" outputDir "$HERE/Meetings"
fi
# Each ad hoc build has a new signature, so clear stale permission entries for a clean prompt.
# With a signing identity the signature stays the same and the permissions are kept.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset AudioCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
  # Older versions needed Screen Recording; clear that grant too.
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
note "Installed to $DEST/$APP_NAME.app"
open "$DEST/$APP_NAME.app"

# ---------------------------------------------------------------------------
step "Done"
cat <<'MSG'
    Meeting Notes is open. A waveform icon is in your menu bar.

    First time only:
      1. Allow Microphone access when asked.
      2. When your first recording starts, allow System Audio Recording (this is
         how the app hears the other people on the call; the screen is not recorded).

    Then join a call: a notification (or a small popup) offers to start notes. Or press
    "Start meeting" in the window or the menu bar icon.
    Notes are saved in the Meetings folder next to install.sh.
MSG
if [[ "$PROVIDER_OK" == "0" && "$PROVIDER" == "ollama" ]]; then
  note "Still to do: start Ollama (brew services start ollama) and run: ollama pull $OLLAMA_MODEL"
elif [[ "$PROVIDER_OK" == "0" ]]; then
  note "Still to do: run $PROVIDER in Terminal and log in before generating notes."
fi
