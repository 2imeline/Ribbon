#!/usr/bin/env bash
# Builds build/Ribbon.app and build/Ribbon.zip (Apple Silicon).
# BUILD_NUMBER sets the version (1.0.<n>); SIGN_IDENTITY picks a certificate
# (default: "Ribbon Self-Signed" if present in your keychain, else ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${BUILD_NUMBER:-0}"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP=build/Ribbon.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Ribbon" "$APP/Contents/MacOS/Ribbon"
cp Resources/AppIcon.icns Resources/Saved.wav "$APP/Contents/Resources/"
sed "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"

# A stable certificate keeps macOS permissions across rebuilds; use "Ribbon Self-Signed" if this Mac has it.
if [ -z "${SIGN_IDENTITY:-}" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Ribbon Self-Signed"'; then
  SIGN_IDENTITY="Ribbon Self-Signed"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
ditto -c -k --keepParent "$APP" build/Ribbon.zip
echo "Built $APP (1.0.$BUILD)"
