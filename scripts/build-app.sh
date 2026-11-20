#!/bin/zsh
# Builds out/Fidelis.app: the menu bar app, its media helper (own signing identity) and the
# audio driver (Contents/Library/Audio/Plug-Ins/HAL/Fidelis.driver; install it with
# scripts/install-driver.sh or from the app's menu).
#   scripts/build-app.sh [debug|release]
set -euo pipefail
cd "${0:A:h}/.."
source scripts/env.sh
CONFIG=${1:-debug}
swift build -c "$CONFIG" >&2
BIN=$(swift build -c "$CONFIG" --show-bin-path)
cmake -S Driver -B Driver/build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build Driver/build -j8 >&2
APP=out/Fidelis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp scripts/install-driver.sh "$APP/Contents/Resources/install-driver.sh"
# Localizations: compile the string catalogs into <lang>.lproj (en is the source language).
mkdir -p "$APP/Contents/Resources/en.lproj"
for catalog in Resources/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done
cp "$BIN/Fidelis" "$APP/Contents/MacOS/Fidelis"
cp "$BIN/FidelisMediaHelper" "$APP/Contents/Helpers/FidelisMediaHelper"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Library/Audio/Plug-Ins/HAL"
ditto Driver/build/Fidelis.driver "$APP/Contents/Library/Audio/Plug-Ins/HAL/Fidelis.driver"
# Stable designated requirements keep the Bluetooth (TCC) grant across rebuilds.
codesign --force --sign - --identifier dev.fidelis.app.media-helper \
  --requirements '=designated => identifier "dev.fidelis.app.media-helper"' "$APP/Contents/Helpers/FidelisMediaHelper"
codesign --force --sign - --identifier dev.fidelis.app \
  --requirements '=designated => identifier "dev.fidelis.app"' "$APP"
echo "$APP"
