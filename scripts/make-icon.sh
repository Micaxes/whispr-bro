#!/usr/bin/env bash
# make-icon.sh — render the brand app icon to Assets/AppIcon.icns (brand doc §4).
# Committed output; make-app.sh copies it into the bundle. Re-run after a brand
# change to the echo-w / squircle in scripts/make-icon.swift.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

swift "$ROOT/scripts/make-icon.swift" "$ICONSET"

mkdir -p "$ROOT/Assets"
iconutil -c icns -o "$ROOT/Assets/AppIcon.icns" "$ICONSET"

# Keep a full-res preview alongside for quick visual review.
cp "$ICONSET/icon_512x512@2x.png" "$ROOT/Assets/AppIcon-preview.png"

rm -rf "$TMP"
echo "wrote $ROOT/Assets/AppIcon.icns (+ AppIcon-preview.png)"
