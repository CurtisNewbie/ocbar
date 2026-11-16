#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX13.sdk")
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/tests"

# shortcut: IslandPanel.swift is not compiled here, so resolveQuestion's call into islandQuestionHead,
# the hidden release in pruneQuestionState, the panel's retractAlert session-id match and
# AppDelegate's reminder wiring are untested. Extend this list when a seam reaches into another file.
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  "$DIR/ocbar/ocbar/Models.swift" \
  "$DIR/tests/main.swift" \
  -framework AppKit \
  -o "$BIN"

"$BIN"
