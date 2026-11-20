#!/bin/zsh
# Builds out/Fidelis.app: the menu bar app plus its media helper (own signing identity).
#   scripts/build-app.sh [debug|release]
set -euo pipefail
cd "${0:A:h}/.."
source scripts/env.sh
CONFIG=${1:-debug}
swift build -c "$CONFIG" >&2
BIN=$(swift build -c "$CONFIG" --show-bin-path)
APP=out/Fidelis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp "$BIN/Fidelis" "$APP/Contents/MacOS/Fidelis"
cp "$BIN/FidelisMediaHelper" "$APP/Contents/Helpers/FidelisMediaHelper"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
# Stable designated requirements keep the Bluetooth (TCC) grant across rebuilds.
codesign --force --sign - --identifier dev.fidelis.app.media-helper \
  --requirements '=designated => identifier "dev.fidelis.app.media-helper"' "$APP/Contents/Helpers/FidelisMediaHelper"
codesign --force --sign - --identifier dev.fidelis.app \
  --requirements '=designated => identifier "dev.fidelis.app"' "$APP"
echo "$APP"
