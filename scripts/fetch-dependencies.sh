#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DOOM_REV=dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284
WAD_SHA=1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771
mkdir -p vendor assets
if [[ ! -d vendor/doomgeneric ]]; then
  git clone https://github.com/ozkl/doomgeneric.git vendor/doomgeneric
  git -C vendor/doomgeneric checkout --detach "$DOOM_REV"
fi
if [[ "$(git -C vendor/doomgeneric rev-parse HEAD)" != "$DOOM_REV" ]]; then
  echo "Unexpected doomgeneric revision; expected $DOOM_REV. Existing checkout left untouched." >&2
  exit 1
fi
if [[ -n "$(git -C vendor/doomgeneric status --porcelain --untracked-files=normal)" ]]; then
  echo 'doomgeneric has local changes. Preserve them elsewhere and restore the pinned checkout before building.' >&2
  exit 1
fi
if [[ ! -f assets/DOOM1.WAD ]]; then
  WAD_TMP=$(mktemp "$PWD/assets/doom1-download.XXXXXX")
  trap 'rm -f "$WAD_TMP"' EXIT
  curl --fail --location --retry 2 https://raw.githubusercontent.com/nneonneo/universal-doom/main/DOOM1.WAD -o "$WAD_TMP"
  echo "$WAD_SHA  $WAD_TMP" | shasum -a 256 -c -
  mv "$WAD_TMP" assets/DOOM1.WAD
fi
echo "$WAD_SHA  assets/DOOM1.WAD" | shasum -a 256 -c -
echo "doomgeneric $DOOM_REV and DOOM1.WAD verified."
