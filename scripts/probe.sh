#!/bin/zsh
# Builds fidelis-probe, wraps it in a minimal .app so it is its own TCC-responsible process
# (Bluetooth permission is otherwise charged to the terminal/IDE that launched it), runs it,
# and streams its output.
#
#   scripts/probe.sh list
#   scripts/probe.sh caps 91-5e-99-c9-d5-ae
#   scripts/probe.sh flood 91-5e-99-c9-d5-ae secs=15 eqmid=0
set -euo pipefail
cd "${0:A:h}/.."

# The Xcode toolchain on this machine pairs an older clang with the CLT macOS 27 SDK and fails
# to link; the Command Line Tools toolchain is self-consistent.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
# (Alternatively: Xcode toolchain with SDKROOT pointing at Xcode's own SDK.)

# Plain clang: SwiftPM's new build system currently fails on this machine ("Unknown error parsing
# property list"), and the probe is a handful of Objective-C files anyway.
mkdir -p out
BIN=out/FidelisProbe
# libldac (Apache-2.0, AOSP): the two unity-build translation units, as in its Android.bp.
xcrun clang -O2 -w -c third_party/libldac/src/ldaclib.c -Ithird_party/libldac/inc -o out/libldac.o
xcrun clang -O2 -w -c third_party/libldac/src/ldacBT.c -Ithird_party/libldac/inc -o out/libldacBT.o
xcrun clang -fobjc-arc -fmodules -g -O1 -Wall -Wno-unused-function \
  -framework Foundation -framework IOBluetooth -framework CoreBluetooth \
  Sources/FidelisProbe/*.m -o "$BIN" out/libldac.o out/libldacBT.o
APP=out/FidelisProbe.app
mkdir -p "$APP/Contents/MacOS" out
cp "$BIN" "$APP/Contents/MacOS/FidelisProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.fidelis.probe</string>
  <key>CFBundleName</key><string>Fidelis Probe</string>
  <key>CFBundleExecutable</key><string>FidelisProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Fidelis talks to your headphones directly to stream LDAC.</string>
</dict></plist>
PLIST
# The media-channel helper must be a separate client identity for bluetoothd: same binary, own
# embedded Info.plist and signing identifier.
mkdir -p "$APP/Contents/Helpers"
cat > out/helper-Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.fidelis.probe.helper</string>
  <key>CFBundleName</key><string>Fidelis Probe Helper</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Fidelis opens the audio channel to your headphones.</string>
</dict></plist>
PLIST
xcrun clang -fobjc-arc -fmodules -g -O1 -w \
  -framework Foundation -framework IOBluetooth -framework CoreBluetooth \
  -sectcreate __TEXT __info_plist out/helper-Info.plist \
  Sources/FidelisProbe/*.m out/libldac.o out/libldacBT.o -o "$APP/Contents/Helpers/FidelisProbeHelper"
codesign --force --sign - --identifier dev.fidelis.probe.helper \
  --requirements '=designated => identifier "dev.fidelis.probe.helper"' "$APP/Contents/Helpers/FidelisProbeHelper" >&2

# A stable designated requirement keeps the TCC grant across rebuilds.
codesign --force --sign - --identifier dev.fidelis.probe \
  --requirements '=designated => identifier "dev.fidelis.probe"' "$APP" >&2

LOG=out/probe-$(date +%Y%m%d-%H%M%S).log
: > "$LOG"
tail -f "$LOG" & TAIL=$!
open -W -n --stdout "$PWD/$LOG" --stderr "$PWD/$LOG" "$APP" --args "$@" || true
sleep 0.3; kill $TAIL 2>/dev/null || true
echo "log: $LOG" >&2
