#!/usr/bin/env bash
# fetch-models.sh — install-time model download (the ONLY networked step).
#
# Fetches the Parakeet-tdt-0.6b-v2 CoreML bundle (the exact ~464MB subset
# FluidAudio needs — a full git clone would be ~2.5GB of mostly legacy models)
# at a PINNED revision, then verifies/creates the SHA-256 manifest
# (scripts/models.sha256). The app and whispr-bench only ever load from disk.
#
# usage: scripts/fetch-models.sh [dest-dir]
#   default dest: ~/Library/Application Support/whispr-bro/models/parakeet-tdt-0.6b-v2
#   (honors WHISPR_BRO_HOME, matching Paths.swift)

set -euo pipefail

REPO="FluidInference/parakeet-tdt-0.6b-v2-coreml"
REV="ee09c569f73759e6d44c9bd16766f477b2b36d39" # main @ 2025-09-25
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/models.sha256"

BASE="${WHISPR_BRO_HOME:-$HOME/Library/Application Support/whispr-bro}"
# The basename MUST be parakeet-tdt-0.6b-v2: FluidAudio resolves the model
# folder by that exact name (repo slug minus "-coreml").
DEST="${1:-$BASE/models/parakeet-tdt-0.6b-v2}"

FILES=(
  Preprocessor.mlmodelc/analytics/coremldata.bin
  Preprocessor.mlmodelc/coremldata.bin
  Preprocessor.mlmodelc/metadata.json
  Preprocessor.mlmodelc/model.mil
  Preprocessor.mlmodelc/weights/weight.bin
  Encoder.mlmodelc/analytics/coremldata.bin
  Encoder.mlmodelc/coremldata.bin
  Encoder.mlmodelc/metadata.json
  Encoder.mlmodelc/model.mil
  Encoder.mlmodelc/weights/weight.bin
  Decoder.mlmodelc/analytics/coremldata.bin
  Decoder.mlmodelc/coremldata.bin
  Decoder.mlmodelc/metadata.json
  Decoder.mlmodelc/model.mil
  Decoder.mlmodelc/weights/weight.bin
  JointDecision.mlmodelc/analytics/coremldata.bin
  JointDecision.mlmodelc/coremldata.bin
  JointDecision.mlmodelc/metadata.json
  JointDecision.mlmodelc/model.mil
  JointDecision.mlmodelc/weights/weight.bin
  parakeet_vocab.json
)

echo "dest: $DEST"
for f in "${FILES[@]}"; do
  out="$DEST/$f"
  if [[ -s "$out" ]]; then
    echo "skip  $f"
    continue
  fi
  mkdir -p "$(dirname "$out")"
  echo "fetch $f"
  # Download to a temp name and move atomically so an interrupted run can
  # never leave a truncated file that a later run would skip (and the
  # manifest-generation path would canonize).
  curl -fL --retry 3 --retry-delay 2 -o "$out.tmp" \
    "https://huggingface.co/$REPO/resolve/$REV/$f"
  mv "$out.tmp" "$out"
done

echo
echo "verifying checksums…"
compute_manifest() {
  (cd "$DEST" && for f in "${FILES[@]}"; do shasum -a 256 "$f"; done)
}

if [[ -s "$MANIFEST" ]]; then
  if diff <(compute_manifest) "$MANIFEST" >/dev/null; then
    echo "OK: all ${#FILES[@]} files match scripts/models.sha256 (rev $REV)"
  else
    echo "FAIL: checksum mismatch against scripts/models.sha256 — refusing to proceed." >&2
    echo "Delete '$DEST' and re-run, or investigate before trusting these files." >&2
    exit 1
  fi
else
  compute_manifest > "$MANIFEST"
  echo "WARNING: no scripts/models.sha256 existed — this run TRUSTED the bytes"
  echo "HuggingFace served (trust-on-first-use) and generated the manifest from"
  echo "them (${#FILES[@]} entries). Review and commit it to pin future installs;"
  echo "regenerating it later re-opens this trust window."
fi

echo "done. models ready at: $DEST"
