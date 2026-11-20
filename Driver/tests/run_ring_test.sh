#!/bin/bash
# Build and run the ring buffer unit test (adapted from Sendspin; ASan makes its concurrent case spin for minutes).
set -euo pipefail
cd "$(dirname "$0")/.."
PREFIX=build/libASPL-prefix
[[ -d $PREFIX/include ]] || { echo "build the driver first (cmake --build build)" >&2; exit 1; }
mkdir -p build/tests
clang++ -std=c++17 -Wall -Wextra -O2 -fsanitize=undefined \
    -isystem "$PREFIX/include" \
    tests/ring_test.cpp src/LoopbackHandler.cpp "$PREFIX/lib/libASPL.a" \
    -framework CoreFoundation -framework CoreAudio \
    -o build/tests/ring_test
build/tests/ring_test
