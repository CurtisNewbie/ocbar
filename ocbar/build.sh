#!/bin/bash
set -e

SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX13.sdk")
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/ocbar.app"

echo "Building ocbar..."
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  "$DIR/ocbar/Models.swift" \
  "$DIR/ocbar/ProcessScanner.swift" \
  "$DIR/ocbar/OpenCodeClient.swift" \
  "$DIR/ocbar/SessionMonitor.swift" \
  "$DIR/ocbar/StatusBubble.swift" \
  "$DIR/ocbar/AppDelegate.swift" \
  "$DIR/ocbar/main.swift" \
  -framework AppKit \
  -framework UserNotifications \
  -o "$DIR/ocbar_bin"

echo "Bundling ocbar.app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$DIR/ocbar_bin" "$APP/Contents/MacOS/ocbar"
cp "$DIR/ocbar/Info.plist" "$APP/Contents/Info.plist"

echo "Done: $APP"
echo "Run with: open $APP"
