#!/bin/zsh
# Runs a probe command while recording bluetoothd + probe logs, then prints the AVDTP/L2CAP lines.
#   scripts/btlog.sh conntest 91-5e-99-c9-d5-ae none
set -uo pipefail
cd "${0:A:h}/.."
mkdir -p out
L=out/bt-$(date +%Y%m%d-%H%M%S).log
/usr/bin/log stream --level debug --style compact \
  --predicate 'process == "bluetoothd" OR process == "FidelisProbe" OR process == "FidelisProbeHelper"' > "$L" 2>&1 &
LS=$!
sleep 1
scripts/probe.sh "$@"
sleep 1
kill $LS 2>/dev/null
echo "---- bluetoothd AVDTP/L2CAP (from $L)"
grep -E "AVDTP_Connect|A2DPService|OI_L2CAP_Connect|handleOpenL2CAPChannel|DeviceConnected|connectPeer|Connect.*services|L2CAP Disconnect" "$L" | sed -E 's/^[^ ]+ +[^ ]+ +//' | cut -c1-200
