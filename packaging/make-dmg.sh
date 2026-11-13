#!/bin/bash
# Makes MeetingNotes.dmg: the app next to an Applications shortcut, on a background that says to drag
# it across and how to open an unsigned app the first time.
#   bash packaging/make-dmg.sh <Meeting Notes.app> <output.dmg>
# Uses dmgbuild (pip install dmgbuild) for the window layout; without it, a plain disk image with the
# same contents.
set -euo pipefail
APP="$1"
OUT="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOLUME="Meeting Notes"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -f "$OUT"

if command -v dmgbuild >/dev/null; then
  xcrun --sdk macosx swift "$ROOT/packaging/dmg-background.swift" "$WORK/bg.png" 1
  xcrun --sdk macosx swift "$ROOT/packaging/dmg-background.swift" "$WORK/bg@2x.png" 2
  # Both sizes in one TIFF, so the background is sharp on Retina screens.
  tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" >/dev/null
  # dmgbuild sizes the volume a few percent too small for 4 GB of models (it divides bytes by 1000 but
  # hdiutil reads K as 1024), and ditto running out of space doesn't fail it: give the size, with room.
  SIZE_MB=$(( $(du -sk "$APP" | cut -f1) * 105 / 100 / 1024 + 256 ))
  dmgbuild -s "$ROOT/packaging/dmg-settings.py" -D app="$APP" -D background="$WORK/background.tiff" -D size="${SIZE_MB}m" "$VOLUME" "$OUT"
else
  echo "dmgbuild not found; making a plain disk image"
  mkdir -p "$WORK/stage"
  cp -Rc "$APP" "$WORK/stage/" 2>/dev/null || cp -R "$APP" "$WORK/stage/"   # a clone: no second copy of the 4 GB of models
  ln -s /Applications "$WORK/stage/Applications"
  hdiutil create -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
fi
hdiutil verify "$OUT" >/dev/null
# Everything made it in: a copy that ran out of room still "verifies", but breaks the app's seal.
MOUNT="$WORK/mount"
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$OUT" >/dev/null
codesign --verify --strict --deep "$MOUNT/$(basename "$APP")" || { hdiutil detach "$MOUNT" >/dev/null; echo "The app in $OUT is incomplete" >&2; exit 1; }
hdiutil detach "$MOUNT" >/dev/null
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
