#!/bin/bash
set -e

SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX13.sdk")
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/ocbar/ocbar"
APP="$DIR/ocbar/ocbar.app"

echo "Building ocbar..."
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  "$SRC/Models.swift" \
  "$SRC/OpenCodeClient.swift" \
  "$SRC/SessionMonitor.swift" \
  "$SRC/StatusBubble.swift" \
  "$SRC/AppDelegate.swift" \
  "$SRC/main.swift" \
  -framework AppKit \
  -framework UserNotifications \
  -o "$DIR/ocbar/ocbar_bin"

echo "Bundling ocbar.app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$DIR/ocbar/ocbar_bin" "$APP/Contents/MacOS/ocbar"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"

DEST="$HOME/Applications"
echo "Installing to $DEST..."
mkdir -p "$DEST"
rm -rf "$DEST/ocbar.app"
cp -R "$APP" "$DEST/"

echo "Done: $APP"
echo "Installed: $DEST/ocbar.app"
echo "Opening $DEST/ocbar.app"
# open() only activates an already-running instance; quit it so the new build loads.
pkill -x ocbar 2>/dev/null || true
sleep 0.3
open "$DEST/ocbar.app"
