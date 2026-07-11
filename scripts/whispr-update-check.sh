#!/bin/bash
#
# whispr-update-check.sh — the ONE networked piece of whispr-bro, and it is
# deliberately NOT part of the app binary.
#
# The app's headline promise is "zero networking code compiled into the binary,"
# enforced three ways (scripts/audit-offline.sh symbol+source audit,
# scripts/net-tripwire.c connect() abort, scripts/verify-offline-capture.sh
# tcpdump zero-packet proof). An in-process update check would break all three.
#
# So the check lives HERE, in a separate short-lived process the app spawns
# (posix_spawn — no networking symbols in the app) on a daily throttle by
# default, unless the user has turned update checks off (Settings › General).
# This script contacts GitHub, learns the latest release tag, and writes it
# to a local JSON file. The app then just *reads that file* (plain disk I/O) to
# decide whether to show an "update available" pill. Your audio and transcripts
# never touch this path; the only thing that leaves the machine is a single HEAD-
# style request to github.com revealing your IP, exactly as your browser would.
#
# Usage:  whispr-update-check.sh <owner/repo> <output-json-path>
# Exit:   0 wrote a fresh state file · 3 no tagged release · non-zero curl/other.
set -euo pipefail

REPO="${1:?usage: whispr-update-check.sh <owner/repo> <output-json-path>}"
OUT="${2:?usage: whispr-update-check.sh <owner/repo> <output-json-path>}"

LATEST_URL="https://github.com/${REPO}/releases/latest"

# Resolve the redirect WITHOUT following it and WITHOUT downloading a body:
# `/releases/latest` 302-redirects to `.../releases/tag/<TAG>`. `%{redirect_url}`
# prints that Location. No API token, no rate-limit worry for a daily check, and
# no JSON parser needed. `-m` bounds the whole thing; offline → curl exits non-
# zero → `set -e` aborts and no file is written (the app just shows no update).
location="$(curl -fsS --max-time 10 -o /dev/null -w '%{redirect_url}' "$LATEST_URL" 2>/dev/null || true)"

case "$location" in
  */releases/tag/*)
    tag="${location##*/tag/}"
    ;;
  *)
    echo "whispr-update-check: no tagged release (redirect: ${location:-<none>})" >&2
    exit 3
    ;;
esac

[ -n "$tag" ] || { echo "whispr-update-check: empty tag" >&2; exit 3; }

# Strip anything that could break the tiny hand-written JSON (defensive; tags are
# normally clean like v0.2.0). Keep alnum, dot, dash, underscore, plus.
safe_tag="$(printf '%s' "$tag" | tr -cd 'A-Za-z0-9._+-')"
now="$(date +%s)"

tmp="$(mktemp "${TMPDIR:-/tmp}/whispr-update.XXXXXX")"
printf '{"latestTag":"%s","releaseURL":"%s","checkedAt":%s}\n' \
  "$safe_tag" "$location" "$now" > "$tmp"

mkdir -p "$(dirname "$OUT")"
mv -f "$tmp" "$OUT"
echo "whispr-update-check: latest is $safe_tag → $OUT" >&2
