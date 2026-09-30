#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f build/engine/EngineBridge.o || ! -f assets/DOOM1.WAD ]]; then
  echo 'Build the app before running tests: bash build.sh' >&2
  exit 1
fi
mkdir -p build/test-data
xcrun clang -arch arm64 -mmacosx-version-min=13.0 -I Sources \
  Tests/engine-smoke.c build/engine/*.o -framework CoreFoundation -framework AudioToolbox -o build/engine-smoke
build/engine-smoke "$PWD/assets/DOOM1.WAD" "$PWD/build/test-data"
build/engine-smoke "$PWD/build/does-not-exist.wad" "$PWD/build/test-data" --expect-error
