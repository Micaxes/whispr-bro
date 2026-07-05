#!/usr/bin/env bash
#
# make-fixture.sh — synthesize a 16kHz mono wav for the offline/latency proofs
# (spec §11.7). Uses macOS `say` + `afconvert` so no audio blob is committed.
#
# Usage:  scripts/make-fixture.sh [out.wav] ["spoken text"]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-Fixtures/latency.wav}"
TEXT="${2:-hey so i was thinking we should ship the offline proof today and then write up the little snitch rule for the docs}"

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say -o "$TMP/f.aiff" "$TEXT"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/f.aiff" "$OUT"
echo "· wrote $OUT ($(afinfo "$OUT" 2>/dev/null | grep -i 'Data format' | sed 's/^[[:space:]]*//'))"
