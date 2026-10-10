#!/usr/bin/env bash
#
# lint-fixtures.sh — the privacy rail CI runs (docs/eval-benchmark.md §8,
# plan §3.3): no history row and no shipped output may live in the tree.
#
# Runs `whispr-bench lint --repo-guard` over every fixtures file that would
# reach the repo — tracked, or untracked and not ignored — plus the built-in
# seeds (a run with no fixtures file still exercises the guard once). A
# fixtures file is any *.json whose text carries a "raw" key; anything else
# (asset catalogs, package manifests, the self-repair test fixtures) is not
# a fixtures file and is skipped.
#
# Two kinds of fixtures file reach `lint`, and it tells them apart by a
# declared list, never by their rows: a path in `FormatFixture.repoPaths`
# (docs/eval/formatting.json — the format bench's layout golds, which the
# eval invariant's scorer gates by design) gets the format bench's own
# rules; every other file gets the full eval lint and its invariant. The
# list is read against the git checkout the file sits in — the nearest
# `.git` that passes git's own test for a repository, and no commit can
# carry a `.git` — so nothing a commit can carry (a stray Package.swift
# under docs/, say) can re-root a copy as the declared path; hand-made
# shapes on a local disk are another matter (docs/eval-benchmark.md §1).
# (Outside a git checkout this script refuses to run; `whispr-bench lint`
# there anchors on the nearest Package.swift.)
# Both get the same repo guard, so a history row or a shipped output fails
# here whichever file it sits in — and a format file at an undeclared path
# is not waved through: the eval lint fails it loudly until it is declared.
# Exit 1 on any lint error, so a personal export that lands in the checkout
# by hand, by a mis-pointed --out, or by a future flag fails the build.
#
# The file list is git's, and the rail fails closed on it: it exits 1
# rather than guard a shorter list outside a git checkout, when `git
# ls-files` fails or prints any warning (a broken nested repository, a
# directory it cannot open), and when a listed path cannot be read — a file
# or directory without read permission, a dangling symlink, a tracked file
# missing from the working tree (staged or not: `git rm` it, or restore it).
# A process substitution would hide git's exit status, so the list goes
# through a file whose status, and whose stderr, are checked.
# scripts/test-lint-fixtures.sh proves each of these in throwaway
# repositories, and CI runs it right after this script.
#
# Usage:  scripts/lint-fixtures.sh [path-to-whispr-bench]
# With no argument it uses the debug build (`swift build` makes it) or the
# release one, whichever exists, and builds debug otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

# Before anything else, a build included: without git there is no list.
# git's own message says why when this is not a checkout.
if [[ "$(git rev-parse --is-inside-work-tree || true)" != true ]]; then
  echo "lint-fixtures: not inside a git checkout; the rail needs git to list the tree" >&2
  exit 1
fi

BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  for candidate in .build/debug/whispr-bench .build/release/whispr-bench; do
    [[ -x "$candidate" ]] && BIN="$candidate" && break
  done
fi
if [[ -z "$BIN" ]]; then
  echo "· building whispr-bench (debug)…"
  swift build --product whispr-bench
  BIN=.build/debug/whispr-bench
fi

# The trap is set before either file exists, so a failed second mktemp
# leaves nothing behind. Tracing is switched off for the one call whose
# stderr is read: any line there counts as a warning.
list=""; errs=""
trap 'rm -f ${list:+"$list"} ${errs:+"$errs"}' EXIT
list="$(mktemp "${TMPDIR:-/tmp}/lint-fixtures.XXXXXX")"
errs="$(mktemp "${TMPDIR:-/tmp}/lint-fixtures.XXXXXX")"
if ! (unset GIT_TRACE GIT_TRACE_PACKET GIT_TRACE_PACK_ACCESS GIT_TRACE_PERFORMANCE \
        GIT_TRACE_SETUP GIT_TRACE_SHALLOW GIT_TRACE_CURL GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF
      git ls-files -z --cached --others --exclude-standard -- '*.json') > "$list" 2> "$errs"; then
  cat "$errs" >&2
  echo "lint-fixtures: git ls-files failed; refusing to guard a partial list" >&2
  exit 1
fi
if [[ -s "$errs" ]]; then
  cat "$errs" >&2
  echo "lint-fixtures: git ls-files warned; refusing to guard a list it may have cut short" >&2
  exit 1
fi

files=()
while IFS= read -r -d '' f; do
  rc=0
  grep -q '"raw"' "$f" || rc=$?
  case $rc in
    0) files+=("$f") ;;
    1) ;;
    *) echo "lint-fixtures: cannot read $f (missing from the working tree? git rm or restore it)" >&2; exit 1 ;;
  esac
done < "$list"

if [[ ${#files[@]} -eq 0 ]]; then
  echo "· no fixtures file in the tree (the seeds are Swift); guarding the seeds"
  "$BIN" lint --repo-guard
else
  echo "· repo guard over ${#files[@]} fixtures file(s): ${files[*]}"
  "$BIN" lint --repo-guard "${files[@]}"
  "$BIN" lint --repo-guard
fi
