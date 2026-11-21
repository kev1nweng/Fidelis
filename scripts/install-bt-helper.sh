#!/bin/bash
# Installs the helper that turns macOS's own Bluetooth audio off and on (or removes it with -u),
# so Fidelis can turn it off while it streams without asking for a password each time.
#
#   scripts/install-bt-helper.sh path/to/bt-audio-helper.sh USER
#   scripts/install-bt-helper.sh -u
#
# It installs the helper root-owned, and a sudoers rule that lets USER run exactly
# `fidelis-bt-audio off` and `fidelis-bt-audio on` without a password (checked with visudo
# before it goes in). Removing it turns macOS's Bluetooth audio back on first.
set -euo pipefail

HELPER=/Library/PrivilegedHelperTools/fidelis-bt-audio
RULE=/private/etc/sudoers.d/fidelis-bt-audio

if [[ $EUID -ne 0 ]]; then
    if [[ -t 0 ]]; then
        exec sudo "$0" "$@"
    fi
    # No terminal to type a sudo password into: ask with the macOS admin dialog.
    # AppleScript quotes each argument itself, so paths with spaces or non-ASCII survive.
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    exec osascript - "$script" "$@" <<'APPLESCRIPT'
on run argv
    set cmd to ""
    repeat with a in argv
        set cmd to cmd & quoted form of (a as text) & " "
    end repeat
    do shell script cmd with prompt "Fidelis wants to install a helper that turns macOS's own Bluetooth audio off while it streams." with administrator privileges
end run
APPLESCRIPT
fi

if [[ "${1:-}" == "-u" ]]; then
    [[ -x "$HELPER" ]] && "$HELPER" on || true
    rm -f "$RULE" "$HELPER"
    echo "Removed $HELPER and $RULE"
    exit 0
fi

SOURCE="${1:?helper script}"
USER_NAME="${2:?user name}"
if [[ ! "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || ! id -u "$USER_NAME" >/dev/null 2>&1; then
    echo "Not a user on this Mac: $USER_NAME" >&2
    exit 1
fi

# Root installs and checks copies, not the (user-writable) originals.
staging=$(mktemp -d /private/tmp/fidelis-bt-helper.XXXXXX)
trap 'rm -rf "$staging"' EXIT
cp "$SOURCE" "$staging/helper"
bash -n "$staging/helper"
cat > "$staging/rule" <<EOF
# Installed by Fidelis (scripts/install-bt-helper.sh): lets $USER_NAME turn macOS's own
# Bluetooth audio off and on. Fidelis removes it from its menu.
$USER_NAME ALL = (root) NOPASSWD: $HELPER off, $HELPER on
EOF
visudo -cf "$staging/rule" >/dev/null

mkdir -p "$(dirname "$HELPER")"
install -o root -g wheel -m 0755 "$staging/helper" "$HELPER"
install -o root -g wheel -m 0440 "$staging/rule" "$RULE"
if ! sudo -l -U "$USER_NAME" "$HELPER" off >/dev/null 2>&1; then
    rm -f "$RULE"
    echo "sudo does not read $RULE (no #includedir in /etc/sudoers?)" >&2
    exit 1
fi
echo "Installed $HELPER for $USER_NAME"
