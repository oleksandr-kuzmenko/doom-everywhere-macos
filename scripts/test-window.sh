#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/test-module-cache
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$PWD/build/test-module-cache" -framework AppKit \
  Sources/FrameView.swift Sources/WindowPresentation.swift Tests/window-smoke.swift \
  -o build/window-smoke
build/window-smoke
