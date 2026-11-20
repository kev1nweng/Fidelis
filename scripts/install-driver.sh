#!/bin/bash
# Install the Fidelis audio driver (or remove it with -u), then restart coreaudiod.
# Adapted from the Sendspin for Mac driver installer (Apache-2.0).
#
#   scripts/install-driver.sh [path/to/Fidelis.driver]
#   scripts/install-driver.sh -u
#
# Restarting coreaudiod briefly interrupts all audio on this Mac.
set -euo pipefail

BUNDLE_NAME="Fidelis.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

if [[ $EUID -ne 0 ]]; then
    if [[ -t 0 ]]; then
        exec sudo "$0" "$@"
    fi
    # No terminal to type a sudo password into: ask with the macOS admin dialog.
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    args=$(printf ' %q' "$script" "$@")
    exec osascript -e "do shell script \"${args//\"/\\\"}\" with prompt \"Fidelis wants to install its audio driver.\" with administrator privileges"
fi

restart_coreaudiod() {
    echo "Restarting coreaudiod…"
    # launchd starts it again; since macOS 14.4 kickstart -k refuses it. audiomxd first, so
    # AirPlayXPCHelper's re-registrations don't pile up with each restart (Sendspin issue #1).
    killall -9 audiomxd || true
    sleep 1
    killall -9 coreaudiod
}

if [[ "${1:-}" == "-u" ]]; then
    if [[ -d "$HAL_DIR/$BUNDLE_NAME" ]]; then
        rm -rf "${HAL_DIR:?}/$BUNDLE_NAME"
        echo "Removed $HAL_DIR/$BUNDLE_NAME"
        restart_coreaudiod
    else
        echo "Not installed"
    fi
    exit 0
fi

SOURCE="${1:-$(cd "$(dirname "$0")/.." && pwd)/out/Fidelis.app/Contents/Library/Audio/Plug-Ins/HAL/$BUNDLE_NAME}"
if [[ ! -d "$SOURCE" ]]; then
    echo "Driver bundle not found: $SOURCE (run scripts/build-app.sh first)" >&2
    exit 1
fi

# Verify the copy root installs, not the (user-writable) original.
staging=$(mktemp -d /private/tmp/fidelis-driver.XXXXXX)
trap 'rm -rf "$staging"' EXIT
ditto "$SOURCE" "$staging/$BUNDLE_NAME"
codesign --verify --strict "$staging/$BUNDLE_NAME"
mkdir -p "$HAL_DIR"
rm -rf "${HAL_DIR:?}/$BUNDLE_NAME"
mv "$staging/$BUNDLE_NAME" "$HAL_DIR/"
chown -R root:wheel "$HAL_DIR/$BUNDLE_NAME"
echo "Installed $HAL_DIR/$BUNDLE_NAME"
restart_coreaudiod
