#!/usr/bin/env bash
# make-icon.sh — render both brand app-icon variants (brand doc §4) to
# Assets/AppIcon-Dark.icns and Assets/AppIcon-Cream.icns. Committed output;
# make-app.sh ships both and picks the Finder default. Re-run after a brand
# change in scripts/make-icon.swift.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/Assets"

for variant in dark cream; do
  TMP="$(mktemp -d)"
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET" "$variant"
  # Capitalize for the file name (Dark / Cream).
  name="$(tr '[:lower:]' '[:upper:]' <<< "${variant:0:1}")${variant:1}"
  iconutil -c icns -o "$ROOT/Assets/AppIcon-$name.icns" "$ICONSET"
  cp "$ICONSET/icon_512x512@2x.png" "$ROOT/Assets/AppIcon-$name-preview.png"
  rm -rf "$TMP"
  echo "wrote Assets/AppIcon-$name.icns"
done
