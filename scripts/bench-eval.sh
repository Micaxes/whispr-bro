#!/usr/bin/env bash
#
# bench-eval.sh — the seeds-baseline wrapper around `whispr-bench eval`
# (dev/plans/whispr-bro-eval-benchmark.md §6.1, §10.1 step 8).
#
# `whispr-bench eval` itself never shells out to git (Sources/ stays
# Tier-0 clean, so it can't) — it takes the git identity as a `--git-sha`
# flag. This script is that flag: `git rev-parse --short HEAD` plus a
# `git status --porcelain` dirty check, folded into the one token the
# runner expects (`--git-sha <sha>` or `<sha>-dirty`). Everything else you
# pass is forwarded to `whispr-bench eval` untouched.
#
# It also appends the run to docs/eval/leaderboard.jsonl, but ONLY when
# the invocation scores the built-in seeds — i.e. no fixtures.json path
# was given (`whispr-bench eval`'s own default). A run against any other
# fixtures file (his personal set, always given as an explicit path)
# never gets an `--append` injected here, and `whispr-bench eval` refuses
# one anyway if you pass your own pointing inside this checkout (plan
# §3.3) — belt and braces so his dictations can never land in the repo.
# If you already passed your own `--append`, this script leaves it alone.
#
# Usage:
#   scripts/bench-eval.sh [eval args…]
#
#   scripts/bench-eval.sh --formatter rules --json /tmp/x.json --report /tmp/x.md --label smoke
#   scripts/bench-eval.sh --formatter all --label baseline
#       # seeds, no fixtures path -> also appended to docs/eval/leaderboard.jsonl
#   scripts/bench-eval.sh ~/OS/dev/whispr-bro-eval/personal.json --formatter shipped \
#       --json ~/OS/dev/whispr-bro-eval/runs/personal.json \
#       --append ~/OS/dev/whispr-bro-eval/leaderboard.jsonl
#       # a fixtures path -> docs/eval/leaderboard.jsonl is never touched;
#       # `--json` / `--report` for a personal set are refused inside the
#       # checkout (the run file stores every row's text)
#
# Relative `--json` / `--report` paths resolve against the checkout root
# (this script cd's there); `runs/` is gitignored for exactly that.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="$ROOT/.build/release/whispr-bench"
# ALWAYS build, never "only if missing": an existing binary from another
# branch measures that branch's code while the row records THIS commit — it
# is how a post-gate baseline once landed carrying the pre-gate numbers.
# SwiftPM is incremental, so this costs about a second when it is current.
echo "· building whispr-bench (release)…"
swift build -c release --product whispr-bench

SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  SHA="${SHA}-dirty"
fi

# A bare (non-`--flag`) argument is a fixtures path UNLESS it's the value
# consumed by a flag that takes one — walk the args the same way
# EvalOptions.parse does so `--json /tmp/x.json` doesn't get misread as a
# fixtures path just because `/tmp/x.json` has no leading `--`. The list
# comes from the binary (`EvalOptions.valueFlags`), never from a copy here.
VALUE_FLAGS=" $("$BIN" eval --value-flags) "
has_fixture_path=0
has_append=0
has_git_sha=0
skip_next=0
for arg in "$@"; do
  if [[ $skip_next -eq 1 ]]; then
    skip_next=0
    continue
  fi
  if [[ "$VALUE_FLAGS" == *" $arg "* ]]; then
    skip_next=1
    [[ "$arg" == "--append" ]] && has_append=1
    [[ "$arg" == "--git-sha" ]] && has_git_sha=1
    continue
  fi
  case "$arg" in
    --*) ;; # a value-less flag (--confirmed-only, --strict-latency, --dirty, --quiet, …)
    *) has_fixture_path=1 ;;
  esac
done

args=("$@")
if [[ $has_git_sha -eq 0 ]]; then
  args+=(--git-sha "$SHA")
fi
if [[ $has_fixture_path -eq 0 && $has_append -eq 0 ]]; then
  args+=(--append "$ROOT/docs/eval/leaderboard.jsonl")
fi

exec "$BIN" eval "${args[@]}"
