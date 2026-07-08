#!/usr/bin/env bash
# fetch-models.sh — install-time model download (the ONLY networked step).
#
# Fetches the exact model-file subsets whispr-bro needs, at PINNED revisions,
# then verifies/creates a per-model SHA-256 manifest. The app and whispr-bench
# only ever load from disk (DownloadUtils.enforceOffline blocks runtime fetch).
#
#   ASR: Parakeet-tdt-0.6b-v2 CoreML (~464MB) — the ~2.5GB full repo would
#        also drag in legacy models FluidAudio never loads.
#   VAD: Silero VAD unified 256ms v6 CoreML (~1MB).
#
# usage: scripts/fetch-models.sh
#   dest base: ~/Library/Application Support/whispr-bro/models
#   (honors WHISPR_BRO_HOME, matching Paths.swift)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${WHISPR_BRO_HOME:-$HOME/Library/Application Support/whispr-bro}"
MODELS="$BASE/models"

# fetch_and_verify <repo> <rev> <dest-dir> <manifest-file> <file...>
# The dest-dir basename must be the folder name FluidAudio expects (repo slug
# minus "-coreml"), since the loaders resolve models by that exact name.
fetch_and_verify() {
  local repo="$1" rev="$2" dest="$3" manifest="$4"
  shift 4
  local files=("$@")

  echo "== $repo @ ${rev:0:12} -> $dest"
  local f out
  for f in "${files[@]}"; do
    out="$dest/$f"
    if [[ -s "$out" ]]; then
      echo "skip  $f"
      continue
    fi
    mkdir -p "$(dirname "$out")"
    echo "fetch $f"
    # Temp name + atomic mv: an interrupted run can never leave a truncated
    # file that a later run would skip (and the manifest path would canonize).
    curl -fL --retry 3 --retry-delay 2 -o "$out.tmp" \
      "https://huggingface.co/$repo/resolve/$rev/$f"
    mv "$out.tmp" "$out"
  done

  echo "verifying ${#files[@]} checksums…"
  local computed
  computed="$(cd "$dest" && for f in "${files[@]}"; do shasum -a 256 "$f"; done)"
  if [[ -s "$manifest" ]]; then
    if diff <(printf '%s\n' "$computed") "$manifest" >/dev/null; then
      echo "OK: matches $(basename "$manifest") (rev $rev)"
    else
      echo "FAIL: checksum mismatch against $(basename "$manifest") — refusing." >&2
      echo "Delete '$dest' and re-run, or investigate before trusting these files." >&2
      exit 1
    fi
  else
    printf '%s\n' "$computed" > "$manifest"
    echo "WARNING: no $(basename "$manifest") existed — this run TRUSTED the bytes"
    echo "HuggingFace served (trust-on-first-use) and generated the manifest from"
    echo "them. Review and commit it to pin future installs; regenerating it"
    echo "later re-opens this trust window."
  fi
}

# ASR — Parakeet-tdt-0.6b-v2 (dir basename MUST be parakeet-tdt-0.6b-v2)
fetch_and_verify \
  "FluidInference/parakeet-tdt-0.6b-v2-coreml" \
  "ee09c569f73759e6d44c9bd16766f477b2b36d39" \
  "$MODELS/parakeet-tdt-0.6b-v2" \
  "$SCRIPT_DIR/models.sha256" \
  Preprocessor.mlmodelc/analytics/coremldata.bin \
  Preprocessor.mlmodelc/coremldata.bin \
  Preprocessor.mlmodelc/metadata.json \
  Preprocessor.mlmodelc/model.mil \
  Preprocessor.mlmodelc/weights/weight.bin \
  Encoder.mlmodelc/analytics/coremldata.bin \
  Encoder.mlmodelc/coremldata.bin \
  Encoder.mlmodelc/metadata.json \
  Encoder.mlmodelc/model.mil \
  Encoder.mlmodelc/weights/weight.bin \
  Decoder.mlmodelc/analytics/coremldata.bin \
  Decoder.mlmodelc/coremldata.bin \
  Decoder.mlmodelc/metadata.json \
  Decoder.mlmodelc/model.mil \
  Decoder.mlmodelc/weights/weight.bin \
  JointDecision.mlmodelc/analytics/coremldata.bin \
  JointDecision.mlmodelc/coremldata.bin \
  JointDecision.mlmodelc/metadata.json \
  JointDecision.mlmodelc/model.mil \
  JointDecision.mlmodelc/weights/weight.bin \
  parakeet_vocab.json

echo

# ASR (multilingual, OPT-IN) — Parakeet-tdt-0.6b-v3 CoreML (~465MB). Serves the
# non-English dictation languages (Italian, Spanish, + 23 more European langs;
# auto-detecting). English stays on v2 above and does NOT need this. Enable with:
#   scripts/fetch-models.sh multilang
# int8 encoder + JointDecisionv3 are the v3 defaults (dir basename MUST be
# parakeet-tdt-0.6b-v3).
if [[ "${1:-}" == "multilang" || "${1:-}" == "all" ]]; then
  fetch_and_verify \
    "FluidInference/parakeet-tdt-0.6b-v3-coreml" \
    "aed02740059203c4a87495924f685de3722ae9ce" \
    "$MODELS/parakeet-tdt-0.6b-v3" \
    "$SCRIPT_DIR/models-v3.sha256" \
    Preprocessor.mlmodelc/analytics/coremldata.bin \
    Preprocessor.mlmodelc/coremldata.bin \
    Preprocessor.mlmodelc/metadata.json \
    Preprocessor.mlmodelc/model.mil \
    Preprocessor.mlmodelc/weights/weight.bin \
    Encoder.mlmodelc/analytics/coremldata.bin \
    Encoder.mlmodelc/coremldata.bin \
    Encoder.mlmodelc/metadata.json \
    Encoder.mlmodelc/model.mil \
    Encoder.mlmodelc/weights/weight.bin \
    Decoder.mlmodelc/analytics/coremldata.bin \
    Decoder.mlmodelc/coremldata.bin \
    Decoder.mlmodelc/metadata.json \
    Decoder.mlmodelc/model.mil \
    Decoder.mlmodelc/weights/weight.bin \
    JointDecisionv3.mlmodelc/analytics/coremldata.bin \
    JointDecisionv3.mlmodelc/coremldata.bin \
    JointDecisionv3.mlmodelc/metadata.json \
    JointDecisionv3.mlmodelc/model.mil \
    JointDecisionv3.mlmodelc/weights/weight.bin \
    parakeet_vocab.json
  echo
fi

# VAD — Silero unified 256ms v6 (dir basename MUST be silero-vad)
fetch_and_verify \
  "FluidInference/silero-vad-coreml" \
  "b419383c55c110e2c9271fa6ee0ea83d03c70d96" \
  "$MODELS/silero-vad" \
  "$SCRIPT_DIR/models-vad.sha256" \
  silero-vad-unified-256ms-v6.0.0.mlmodelc/analytics/coremldata.bin \
  silero-vad-unified-256ms-v6.0.0.mlmodelc/coremldata.bin \
  silero-vad-unified-256ms-v6.0.0.mlmodelc/metadata.json \
  silero-vad-unified-256ms-v6.0.0.mlmodelc/model.mil \
  silero-vad-unified-256ms-v6.0.0.mlmodelc/weights/weight.bin

echo "done. models ready under: $MODELS"
