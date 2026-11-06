#!/bin/bash
# Packs the MCP server as a Claude Desktop extension (.mcpb, a zip with manifest.json).
#   bash mcp/pack.sh <output.mcpb> <path to the meetingnotes-mcp binary> [icon.png]
# The extension holds a small launcher that runs the server binary on this Mac (the one built by
# install.sh, or the one inside Meeting Notes.app), so app updates reach Claude Desktop without
# reinstalling the extension, and macOS doesn't block an unsigned binary unpacked from a download.
# The launcher tries the given path first, then the app in /Applications or ~/Applications, then
# wherever Spotlight finds the app, so the extension in the downloadable app works wherever it is.
set -euo pipefail
OUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"   # absolute, since zip runs in the staging folder
SERVER="$2"
ICON="${3:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/server"
cp "$HERE/manifest.json" "$STAGE/manifest.json"
{
  printf '#!/bin/sh\n'
  printf 'BIN="Contents/MacOS/meetingnotes-mcp"\n'
  printf 'for p in %q "/Applications/Meeting Notes.app/$BIN" "$HOME/Applications/Meeting Notes.app/$BIN" "$HOME/.meetnotes/bin/meetingnotes-mcp"; do\n' "$SERVER"
  printf '  [ -x "$p" ] && exec "$p" "$@"\n'
  printf 'done\n'
  printf '%s\n' 'app="$(mdfind "kMDItemCFBundleIdentifier == '"'"'se.frinkle.meetingnotes'"'"'" 2>/dev/null | grep -v "^/Volumes/" | head -n 1)"'
  printf '[ -n "$app" ] && [ -x "$app/$BIN" ] && exec "$app/$BIN" "$@"\n'
  printf 'echo "Meeting Notes was not found. Install it in Applications, then restart Claude." >&2\n'
  printf 'exit 1\n'
} > "$STAGE/server/launch.sh"
chmod +x "$STAGE/server/launch.sh"
if [[ -n "$ICON" && -s "$ICON" ]]; then
  cp "$ICON" "$STAGE/icon.png"
else
  # The manifest names an icon; leave it out rather than ship a broken reference.
  /usr/bin/python3 - "$STAGE/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m.pop("icon", None); json.dump(m, open(p, "w"), indent=2)
PY
fi
if [[ -n "${MCPB_VERSION:-}" ]]; then
  /usr/bin/python3 - "$STAGE/manifest.json" "$MCPB_VERSION" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["version"] = sys.argv[2]; json.dump(m, open(p, "w"), indent=2)
PY
fi
rm -f "$OUT"
(cd "$STAGE" && zip -qrXD "$OUT" .)
