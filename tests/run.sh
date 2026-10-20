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

echo "==> Building the tests"
SOURCES=()
for f in src/*.swift; do [[ "$f" == src/App.swift ]] || SOURCES+=("$f"); done
xcrun --sdk macosx swiftc "${FLAGS[@]}" -o "$OUT/tests" "${SOURCES[@]}" tests/main.swift

echo "==> Running the tests"
"$OUT/tests"

echo "==> Checking install.sh syntax"
bash -n install.sh
echo "All good."
