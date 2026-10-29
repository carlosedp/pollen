#!/bin/sh
# Compiles lib/Engine_Pollen.sc and plays it on a real scsynth, in a container (podman or
# docker): jackd's dummy driver stands in for a sound card, test/sc/CroneEngine.sc for norns'.
#
#   test/sc/run.sh          (from anywhere; builds the image the first time)
#
# Without mi-UGens: the reverb is the FreeVerb2 fallback (MiVerb is checked in the browser's
# engine, test/engine.mjs, and on a norns).
set -e
cd "$(dirname "$0")/../.."
RUN=$(command -v podman || command -v docker)
"$RUN" image inspect pollen-sc >/dev/null 2>&1 || "$RUN" build -q -t pollen-sc -f test/sc/Containerfile test/sc
"$RUN" run --rm -v "$PWD":/w:Z -w /w pollen-sc sh -c '
  jackd -r -d dummy -r 48000 -p 256 >/tmp/jack.log 2>&1 &
  sleep 1
  printf "includePaths:\n  - /w/lib\n  - /w/test/sc\n" > /tmp/conf.yaml
  export XDG_RUNTIME_DIR=/tmp QTWEBENGINE_CHROMIUM_FLAGS=--no-sandbox QTWEBENGINE_DISABLE_SANDBOX=1
  QT_QPA_PLATFORM=offscreen timeout 300 sclang -l /tmp/conf.yaml test/sc/engine.scd 2>&1 \
    | grep -v -E "^(compiling|Found|Compil|NumPrimitives|SC_AudioDriver|Welcome|  |-> |Booting|JackDriver|jackdmp|Copyright|This is free|JACK server|server name|PublisherGraph|Requesting|SuperCollider 3 server|Shared memory|Server .local. exited|class library|\*\*\* Welcome)"
'
