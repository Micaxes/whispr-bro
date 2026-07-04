#!/usr/bin/env bash
# fetch-llm-models.sh — download ONE selectable reformatting LLM (Q4_K_M GGUF).
#
# Separate from fetch-models.sh (ASR/VAD) because these files are large
# (~0.8-1.3GB each) and only one is needed at runtime. Same guarantees:
# PINNED revision, atomic temp+mv download, SHA-256 verify (trust-on-first-use
# recorded to scripts/models-llm.sha256 if not yet pinned).
#
# usage:  scripts/fetch-llm-models.sh [llama3.2-1b | qwen2.5-1.5b | qwen3-1.7b | all]
#   dest:  $WHISPR_BRO_HOME/models/llm/<key>/<file>.gguf
#   default key: qwen2.5-1.5b

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${WHISPR_BRO_HOME:-$HOME/Library/Application Support/whispr-bro}"
LLM_DIR="$BASE/models/llm"
MANIFEST="$SCRIPT_DIR/models-llm.sha256"

# key | repo | pinned-rev | file
ROWS=(
  "llama3.2-1b|bartowski/Llama-3.2-1B-Instruct-GGUF|067b946cf014b7c697f3654f621d577a3e3afd1c|Llama-3.2-1B-Instruct-Q4_K_M.gguf"
  "qwen2.5-1.5b|bartowski/Qwen2.5-1.5B-Instruct-GGUF|9eadc66189c7641e1ddd226b8267a9119b2ce2d4|Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
  "qwen3-1.7b|bartowski/Qwen_Qwen3-1.7B-GGUF|dcb19155b962dbb6389f4691a982043a8e651022|Qwen_Qwen3-1.7B-Q4_K_M.gguf"
)

fetch_one() {
  local key="$1" repo="" rev="" file="" row found=0
  for row in "${ROWS[@]}"; do
    IFS='|' read -r k r v f <<<"$row"
    if [[ "$k" == "$key" ]]; then
      repo="$r"; rev="$v"; file="$f"; found=1; break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "unknown model '$key'. choices: llama3.2-1b qwen2.5-1.5b qwen3-1.7b all" >&2
    exit 2
  fi

  local dest="$LLM_DIR/$key" out
  out="$dest/$file"
  mkdir -p "$dest"

  if [[ -s "$out" ]]; then
    if grep -q " $key/$file\$" "$MANIFEST" 2>/dev/null; then
      if (cd "$LLM_DIR" && shasum -a 256 -c <(grep " $key/$file\$" "$MANIFEST") >/dev/null 2>&1); then
        echo "OK: $key present and verified"
        return 0
      fi
      echo "FAIL: $key checksum mismatch vs models-llm.sha256 — delete and re-run." >&2
      exit 1
    fi
    echo "skip download ($key already present); recording checksum"
  else
    echo "== $repo @ ${rev:0:12} -> $out"
    curl -fL --retry 3 --retry-delay 2 -o "$out.tmp" \
      "https://huggingface.co/$repo/resolve/$rev/$file"
    mv "$out.tmp" "$out"
  fi

  # Verify against pinned manifest, or record on first use (TOFU).
  local line
  line="$(cd "$LLM_DIR" && shasum -a 256 "$key/$file")"
  if grep -q " $key/$file\$" "$MANIFEST" 2>/dev/null; then
    if ! printf '%s\n' "$line" | diff - <(grep " $key/$file\$" "$MANIFEST") >/dev/null; then
      echo "FAIL: $key checksum mismatch vs models-llm.sha256 — refusing." >&2
      exit 1
    fi
    echo "OK: $key matches models-llm.sha256"
  else
    printf '%s\n' "$line" >> "$MANIFEST"
    echo "recorded $key checksum to models-llm.sha256 (trust-on-first-use) — commit to pin"
  fi
}

case "${1:-qwen2.5-1.5b}" in
  all) for r in "${ROWS[@]}"; do fetch_one "${r%%|*}"; done ;;
  *)   fetch_one "${1:-qwen2.5-1.5b}" ;;
esac
