#!/bin/bash
# Builds the app and runs the unit tests. Needs only the Xcode command line tools.
#   bash tests/run.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
FLAGS=(-parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0")

echo "==> Building the app"
xcrun --sdk macosx swiftc -O "${FLAGS[@]}" -o "$OUT/MeetingNotes" src/*.swift

echo "==> Building the MCP server"
# Top-level code, so without -parse-as-library.
xcrun --sdk macosx swiftc -O "${FLAGS[@]:1}" -o "$OUT/meetingnotes-mcp" mcp/main.swift

echo "==> Packing the Claude Desktop extension"
bash mcp/pack.sh "$OUT/MeetingNotes.mcpb" "$OUT/meetingnotes-mcp"
unzip -l "$OUT/MeetingNotes.mcpb" | grep -q "server/launch.sh"
/usr/bin/python3 -c 'import json,sys,zipfile; m=json.loads(zipfile.ZipFile(sys.argv[1]).read("manifest.json")); assert m["server"]["entry_point"]=="server/launch.sh" and "icon" not in m' "$OUT/MeetingNotes.mcpb"

echo "==> Building the tests"
SOURCES=()
for f in src/*.swift; do [[ "$f" == src/App.swift ]] || SOURCES+=("$f"); done
xcrun --sdk macosx swiftc "${FLAGS[@]}" -o "$OUT/tests" "${SOURCES[@]}" tests/main.swift

echo "==> Running the tests"
MEETINGNOTES_MCP="$OUT/meetingnotes-mcp" "$OUT/tests"

echo "==> Checking install.sh syntax"
bash -n install.sh
echo "All good."
