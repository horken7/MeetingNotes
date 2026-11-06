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
  dmgbuild -s "$ROOT/packaging/dmg-settings.py" -D app="$APP" -D background="$WORK/background.tiff" "$VOLUME" "$OUT"
else
  echo "dmgbuild not found; making a plain disk image"
  mkdir -p "$WORK/stage"
  cp -R "$APP" "$WORK/stage/"
  ln -s /Applications "$WORK/stage/Applications"
  hdiutil create -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
fi
hdiutil verify "$OUT" >/dev/null
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
