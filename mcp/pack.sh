#!/bin/bash
# Packs the MCP server as a Claude Desktop extension (.mcpb, a zip with manifest.json).
#   bash mcp/pack.sh <output.mcpb> <path to the meetingnotes-mcp binary> [icon.png]
# The extension holds a small launcher that runs the binary built by install.sh, so app updates
# reach Claude Desktop without reinstalling the extension, and macOS doesn't block an unsigned
# binary unpacked from a download.
set -euo pipefail
OUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"   # absolute, since zip runs in the staging folder
SERVER="$2"
ICON="${3:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/server"
cp "$HERE/manifest.json" "$STAGE/manifest.json"
printf '#!/bin/sh\nexec %q "$@"\n' "$SERVER" > "$STAGE/server/launch.sh"
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
rm -f "$OUT"
(cd "$STAGE" && zip -qrXD "$OUT" .)
