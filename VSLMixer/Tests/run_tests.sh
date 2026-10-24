#!/bin/sh
# Builds and runs the engine tests.  Pass --hardware to also run the loopback
# test, which needs an AudioBox 1818VSL with each output N cabled to input N.
set -e
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/vslmixer-tests"
mkdir -p "$out"
flags="-std=c11 -O2 -Wall -Wextra -Wno-unused-parameter"
libs="-framework CoreAudio -framework AudioToolbox -framework CoreFoundation"

clang $flags dsp_test.c ../Engine/engine.c $libs -o "$out/dsp_test"
"$out/dsp_test"

if [ "$1" = "--hardware" ]; then
    clang $flags loopback_test.c ../Engine/engine.c $libs -o "$out/loopback_test"
    "$out/loopback_test"
fi
