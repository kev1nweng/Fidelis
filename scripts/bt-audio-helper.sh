#!/bin/bash
# Turns macOS's own Bluetooth audio (A2DP and AVRCP) off or back on, then restarts bluetoothd
# so it reads the change. Installed root-owned as /Library/PrivilegedHelperTools/fidelis-bt-audio by
# scripts/install-bt-helper.sh, which lets the installing user run exactly
# `sudo -n <helper> off` and `sudo -n <helper> on` without a password.
#
#   fidelis-bt-audio off|on
#
# bluetoothd checks each profile against the com.apple.MobileBluetooth.debug preferences before
# it connects it. The value must be the string "FALSE" (a boolean is ignored), and on macOS 27 it
# was read only with both nestings present, so both are written. Only these keys are touched.
# Nothing changes, and bluetoothd keeps running, when the setting is already as asked.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

DOMAIN=/Library/Preferences/com.apple.MobileBluetooth.debug
# Audio (A2DP) and the remote control (AVRCP): with AVRCP free too, Fidelis holds it and sets
# the headphones' own volume, as macOS does for its own Bluetooth audio.
SERVICES="a2dp avrcp"

snapshot() { defaults export "$DOMAIN" - 2>/dev/null || true; }

before=$(snapshot)
case "${1:-}" in
off)
    for service in $SERVICES; do
        defaults write "$DOMAIN" "$service" -dict-add ServiceSettings -string FALSE
        defaults write "$DOMAIN" ServiceSettings -dict-add "$service" -string FALSE
    done
    ;;
on)
    # Each of the two dictionaries is written back without our key (`defaults import` would
    # merge, keeping it), or deleted when nothing else is left in it.
    pairs=""
    for service in $SERVICES; do pairs="$pairs $service:ServiceSettings ServiceSettings:$service"; done
    for pair in $pairs; do
        outer=${pair%%:*} inner=${pair#*:}
        rest=$(defaults export "$DOMAIN" - 2>/dev/null | plutil -extract "$outer" xml1 -o - - 2>/dev/null) || continue
        rest=$(printf '%s' "$rest" | plutil -remove "$inner" -o - - 2>/dev/null || printf '%s' "$rest")
        if [[ "$(printf '%s' "$rest" | plutil -convert json -o - -)" == "{}" ]]; then
            defaults delete "$DOMAIN" "$outer"
        else
            defaults write "$DOMAIN" "$outer" "$rest"
        fi
    done
    ;;
*)
    echo "usage: $0 off|on" >&2
    exit 64
    ;;
esac

if [[ "$(snapshot)" == "$before" ]]; then
    echo "unchanged"
    exit 0
fi
# launchd starts it again at once; every Bluetooth connection drops for a few seconds.
killall bluetoothd 2>/dev/null || true
echo "changed; bluetoothd restarted"
