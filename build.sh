#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo 'DOOM for macOS requires an Apple Silicon Mac and a native arm64 shell.' >&2
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
  echo 'Install Xcode Command Line Tools first: xcode-select --install' >&2
  exit 1
fi
# Verify cached dependencies too; this only downloads when they are missing.
bash scripts/fetch-dependencies.sh
APP="$PWD/build/DOOM for macOS.app"
CACHE="$PWD/build/module-cache-$(printf '%s' "$PWD" | shasum | cut -c 1-12)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
/usr/bin/python3 scripts/build-icon.py
/usr/bin/python3 scripts/build-engine.py
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$CACHE" -framework AppKit -framework AudioToolbox \
  -import-objc-header Sources/EngineBridge.h Sources/*.swift build/engine/*.o \
  -o "$APP/Contents/MacOS/DOOM"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp assets/DOOM1.WAD "$APP/Contents/Resources/DOOM1.WAD"
cp vendor/doomgeneric/LICENSE "$APP/Contents/Resources/doomgeneric-LICENSE.txt"
cp LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then open "$APP"; fi
