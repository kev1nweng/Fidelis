#!/bin/zsh
# Streams to the headphones for N seconds through the real app, headless, and prints the
# engine log. Source: chime (default), system or silence.
#   scripts/selftest.sh 91-5e-99-c9-d5-ae 30 [system]
set -uo pipefail
cd "${0:A:h}/.."
ADDR=${1:?address}; SECS=${2:-30}; SOURCE=${3:-chime}
APP=$(scripts/build-app.sh)
LOG=out/selftest-$(date +%Y%m%d-%H%M%S).log
: > "$LOG"
tail -f "$LOG" & TAIL=$!
open -W -n --env FIDELIS_SELFTEST=$SECS --env FIDELIS_DEVICE=$ADDR --env FIDELIS_STDERR_LOG=1 --env FIDELIS_SOURCE=$SOURCE \
  --stdout "$PWD/$LOG" --stderr "$PWD/$LOG" "$APP"
RC=$?
sleep 0.3; kill $TAIL 2>/dev/null
echo "exit $RC, log: $LOG"
