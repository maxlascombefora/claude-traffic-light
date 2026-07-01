#!/usr/bin/env bash
# Build "Claude Traffic Light.app" and install it to ~/Applications so Spotlight finds it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="Claude Traffic Light.app"
BUILD_APP="dist/$APP"
DEST_DIR="$HOME/Applications"

echo "==> building release binary"
swift build -c release

echo "==> assembling bundle"
rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"
cp ".build/release/TrafficLight" "$BUILD_APP/Contents/MacOS/TrafficLight"
cp "Packaging/Info.plist"        "$BUILD_APP/Contents/Info.plist"
cp "Packaging/AppIcon.icns"      "$BUILD_APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUILD_APP/Contents/PkgInfo"

echo "==> ad-hoc code-signing"
codesign --force --deep --sign - "$BUILD_APP" >/dev/null 2>&1 || \
  echo "   (codesign skipped; app will still run locally)"

echo "==> installing to $DEST_DIR"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/$APP"
cp -R "$BUILD_APP" "$DEST_DIR/"

# Remove the staging copy so Spotlight only indexes the installed app, not a duplicate.
rm -rf "$BUILD_APP"
rmdir dist 2>/dev/null || true

# Nudge Launch Services so Spotlight indexes it promptly.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST_DIR/$APP" >/dev/null 2>&1 || true

echo "==> done: $DEST_DIR/$APP"
echo "    Launch from Spotlight: \"Claude Traffic Light\"  (or: open \"$DEST_DIR/$APP\")"
