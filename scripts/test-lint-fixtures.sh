#!/usr/bin/env bash
#
# test-lint-fixtures.sh — proves the privacy rail (scripts/lint-fixtures.sh)
# fails closed. It builds throwaway git repositories around a copy of the
# rail and runs it in each: a clean tree passes, a history row fails, and
# every way the file list could come back short fails too — no checkout, a
# corrupt index, a nested repository git cannot read, a tracked file
# missing from the working tree (deleted, or staged and then deleted), a
# dangling symlink, a file it cannot read, a directory git cannot open
# (with or without a tracked file inside). Each case also checks the
# reason the rail gives, so it fails for its own reason. CI runs it right
# after the rail itself, so a change that lets any of these pass again
# fails the build.
#
# Usage:  scripts/test-lint-fixtures.sh [path-to-whispr-bench]
# With no argument it uses .build/debug/whispr-bench (`swift build` makes it).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BIN="${1:-.build/debug/whispr-bench}"
[[ "$BIN" = /* ]] || BIN="$ROOT/$BIN"
if [[ ! -x "$BIN" ]]; then
  echo "test-lint-fixtures: no whispr-bench at $BIN (swift build first)" >&2
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/test-lint-fixtures.XXXXXX")"
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
# git must not find a repository above the work dir (a TMPDIR inside a
# checkout would turn the no-checkout case into a checkout).
export GIT_CEILING_DIRECTORIES="$work"

CLEAN='[{"id": "rail-ok", "raw": "ship it today", "gold": "Ship it today."}]'
HISTORY='[{"id": "rail-history", "raw": "ship it today", "gold": "Ship it today.", "source": "history:7"}]'
GIT=(git -c init.defaultBranch=main -c user.name=rail -c user.email=rail@example.invalid -c commit.gpgsign=false)

# A throwaway checkout holding the rail and one clean, committed fixtures file.
fresh() {
  local dir="$work/$1"
  mkdir -p "$dir/scripts" "$dir/docs/eval"
  cp "$ROOT/scripts/lint-fixtures.sh" "$dir/scripts/"
  printf '%s\n' "$CLEAN" > "$dir/docs/eval/cases.json"
  "${GIT[@]}" -C "$dir" init -q
  "${GIT[@]}" -C "$dir" add -A
  "${GIT[@]}" -C "$dir" commit -q -m fixtures
  echo "$dir"
}

passed=0; failed=0
# expect <case> <0|1> <dir> [reason]: run the rail there; compare its exit
# status and, when a reason is given, find it in the rail's output, so each
# case fails for its own reason and not for a neighbouring one.
expect() {
  local got=0 why=""
  (cd "$3" && scripts/lint-fixtures.sh "$BIN") > "$work/$1.log" 2>&1 || got=1
  if [[ $got -eq $2 && ( -z "${4:-}" || -n "$(grep -F -- "$4" "$work/$1.log")" ) ]]; then
    passed=$((passed + 1)); printf '  ok    %-30s exit %s%s\n' "$1" "$got" "${4:+  ($4)}"
  else
    [[ $got -eq $2 ]] || why="exit $got, expected $2"
    [[ -z "${4:-}" || -n "$(grep -F -- "$4" "$work/$1.log")" ]] || why="${why:+$why; }no \"$4\" in the output"
    failed=$((failed + 1)); printf '  FAIL  %-30s %s\n' "$1" "$why"
    sed 's/^/        /' "$work/$1.log"
  fi
}

d=$(fresh clean)
expect clean 0 "$d"

d=$(fresh history-row)
printf '%s\n' "$HISTORY" > "$d/docs/eval/cases.json"
expect history-row 1 "$d" "is a history row"

d="$work/no-checkout"
mkdir -p "$d/scripts"
cp "$ROOT/scripts/lint-fixtures.sh" "$d/scripts/"
expect no-checkout 1 "$d" "not inside a git checkout"

d=$(fresh corrupt-index)
printf 'not an index' > "$d/.git/index"
expect corrupt-index 1 "$d" "git ls-files failed"

d=$(fresh broken-nested-repo)
mkdir -p "$d/docs/eval/nested/.git/objects" "$d/docs/eval/nested/.git/refs"
printf 'ref: refs/heads/main\n' > "$d/docs/eval/nested/.git/HEAD"
: > "$d/docs/eval/nested/.git/commondir"
expect broken-nested-repo 1 "$d" "git ls-files failed"

d=$(fresh tracked-file-missing)
rm "$d/docs/eval/cases.json"
expect tracked-file-missing 1 "$d" "cannot read"

d=$(fresh staged-then-deleted)
printf '%s\n' "$HISTORY" > "$d/docs/eval/cases.json"
"${GIT[@]}" -C "$d" add docs/eval/cases.json
rm "$d/docs/eval/cases.json"
expect staged-then-deleted 1 "$d" "cannot read"

d=$(fresh dangling-symlink)
ln -s nowhere.json "$d/docs/eval/dangling.json"
expect dangling-symlink 1 "$d" "cannot read"

if [[ $(id -u) -ne 0 ]]; then   # root reads through any mode
  d=$(fresh unreadable-file)
  chmod 000 "$d/docs/eval/cases.json"
  expect unreadable-file 1 "$d" "cannot read"

  # git cannot open a directory: it warns and lists the rest, so only the
  # warning shows that a history row inside it was never read.
  d=$(fresh unreadable-untracked-directory)
  mkdir -p "$d/docs/private"
  printf '%s\n' "$HISTORY" > "$d/docs/private/rows.json"
  chmod 000 "$d/docs/private"
  expect unreadable-untracked-directory 1 "$d" "git ls-files warned"

  d=$(fresh unreadable-directory)
  printf '%s\n' "$HISTORY" > "$d/docs/eval/untracked.json"
  chmod 000 "$d/docs/eval"
  expect unreadable-directory 1 "$d" "git ls-files warned"
else
  echo "  skip  unreadable-file, unreadable-untracked-directory, unreadable-directory (running as root)"
fi

echo "test-lint-fixtures: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
