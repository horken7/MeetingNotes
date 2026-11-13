#!/bin/bash
# Builds the app and runs the unit tests. Needs only the Xcode command line tools.
#   bash tests/run.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
FLAGS=(-parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0")
ROOT="$PWD"; source packaging/sources.sh

echo "==> Building the app"
xcrun --sdk macosx swiftc -O "${FLAGS[@]}" -o "$OUT/MeetingNotes" "${APP_SOURCES[@]}"

echo "==> Building the MCP server"
# Top-level code, so without -parse-as-library.
xcrun --sdk macosx swiftc -O "${FLAGS[@]:1}" -o "$OUT/meetingnotes-mcp" mcp/main.swift

echo "==> Packing the Claude Desktop extension"
bash mcp/pack.sh "$OUT/MeetingNotes.mcpb" "$OUT/meetingnotes-mcp"
unzip -l "$OUT/MeetingNotes.mcpb" | grep "server/launch.sh" >/dev/null
# The launcher runs the given server, and falls back to the app's bundled copy.
unzip -p "$OUT/MeetingNotes.mcpb" server/launch.sh > "$OUT/launch.sh"
sh -n "$OUT/launch.sh"
grep -F "Meeting Notes.app/\$BIN" "$OUT/launch.sh" >/dev/null
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  | sh "$OUT/launch.sh" | grep '"serverInfo"' >/dev/null
/usr/bin/python3 -c 'import json,sys,zipfile; m=json.loads(zipfile.ZipFile(sys.argv[1]).read("manifest.json")); assert m["server"]["entry_point"]=="server/launch.sh" and "icon" not in m' "$OUT/MeetingNotes.mcpb"

echo "==> Building the tests"
SOURCES=()
for f in src/*.swift; do [[ "$f" == src/App.swift ]] || SOURCES+=("$f"); done
xcrun --sdk macosx swiftc "${FLAGS[@]}" -o "$OUT/tests" "${SOURCES[@]}" "${SHARED_SOURCES[@]}" tests/main.swift

echo "==> Running the tests"
MEETINGNOTES_MCP="$OUT/meetingnotes-mcp" "$OUT/tests"

echo "==> Checking the install and packaging scripts"
bash -n install.sh
for f in packaging/*.sh mcp/pack.sh; do bash -n "$f"; done
bash packaging/info-plist.sh 1.2.3 45 > "$OUT/Info.plist"
plutil -lint "$OUT/Info.plist" >/dev/null
[[ "$(plutil -extract CFBundleShortVersionString raw "$OUT/Info.plist")" == "1.2.3" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$OUT/Info.plist")" == "se.frinkle.meetingnotes" ]]
echo "All good."
