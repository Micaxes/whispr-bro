#!/usr/bin/env bash
#
# verify-offline-capture.sh — behavioural offline proof (spec §11.7 acceptance).
#
# The static audit (audit-offline.sh) proves the binary has no networking call
# sites of its own. This proves the RUNNING process — through a full dictation
# cycle (ASR → LLM formatting), the paths where a model loader might otherwise
# phone home — never actually opens the network. Two independent checks:
#
#   1. connect() tripwire (no sudo): run whispr-bench e2e under the
#      net-tripwire dylib. Any outbound connect() aborts the process, so a
#      clean exit == zero connection attempts. This is the strong, portable
#      check and the one CI/dev runs rely on.
#
#   2. tcpdump packet capture (needs sudo): capture every non-loopback packet
#      sent by the process for the duration of the run and assert the count is
#      zero. This is the spec's headline acceptance ("packet capture of a full
#      dictation cycle shows zero packets"). Skipped with a note if not root.
#
# Usage:  scripts/verify-offline-capture.sh <fixture.wav>
#         sudo scripts/verify-offline-capture.sh <fixture.wav>   # + tcpdump
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE="${1:-}"
if [[ -z "$FIXTURE" || ! -f "$FIXTURE" ]]; then
  echo "usage: $0 <fixture.wav>   (a 16kHz mono wav to dictate through the pipeline)" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DYLIB="$WORK/net-tripwire.dylib"

echo "· compiling net-tripwire…"
cc -O2 -dynamiclib -o "$DYLIB" scripts/net-tripwire.c

echo "· building whispr-bench (release)…"
swift build -c release --product whispr-bench >/dev/null
BENCH="$(find .build -type f -path '*release*' -name whispr-bench | head -1 || true)"
[[ -x "$BENCH" ]] || { echo "FAIL: whispr-bench not built" >&2; exit 2; }

rc=0

# ---- check 1: connect() tripwire ------------------------------------------
echo
echo "=== check 1/2 — connect() tripwire over a full dictation cycle ==="
if DYLD_INSERT_LIBRARIES="$DYLIB" "$BENCH" e2e "$FIXTURE"; then
  echo "✓ tripwire: whispr-bench e2e completed without any outbound connect()"
else
  code=$?
  # abort() from the tripwire is SIGABRT → exit 134; distinguish from a plain
  # bench error so a model-missing failure doesn't masquerade as a violation.
  if [[ $code -eq 134 ]]; then
    echo "✗ tripwire: an outbound connect() was attempted during dictation (SIGABRT)" >&2
    rc=1
  else
    echo "✗ whispr-bench e2e failed (exit $code) — cannot conclude offline; fix the run first" >&2
    rc=1
  fi
fi

# ---- check 2: tcpdump packet capture --------------------------------------
# Note: macOS BSD tcpdump has no `-i any` pseudo-device, and cannot filter by
# PID, so this captures the DEFAULT-ROUTE interface host-wide for the run
# window. Run it on a quiescent machine (quit browsers/mail/cloud sync) so a
# captured packet means whispr-bro. The per-process guarantee is check 1's
# tripwire; this is the corroborating wire-level view the spec calls for.
echo
echo "=== check 2/2 — tcpdump packet capture (zero non-loopback packets) ==="
if [[ "$(id -u)" -ne 0 ]]; then
  echo "· skipped (needs sudo). For the full spec acceptance run, on a quiet machine:"
  echo "    sudo $0 $FIXTURE"
else
  # Capture on BOTH the IPv4 and IPv6 default-route interfaces (egress could
  # leave by either, and they can differ — e.g. a VPN utun). macOS has no
  # `-i any`, so we run one tcpdump per unique interface. Fall back to en0.
  IFACES=()
  for fam in -inet -inet6; do
    dev="$(route -n get $fam default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    [[ -n "$dev" ]] && IFACES+=("$dev")
  done
  # shellcheck disable=SC2207
  # `|| true`: with no default route (airplane mode / VPN-only), grep matches
  # nothing and exits 1 — without the guard, pipefail+errexit would abort here
  # before the en0 fallback below.
  IFACES=($(printf '%s\n' "${IFACES[@]:-}" | grep -E '.' | sort -u || true))
  [[ ${#IFACES[@]} -eq 0 ]] && IFACES=(en0)
  echo "· capturing on: ${IFACES[*]} (host-wide — keep the machine otherwise idle)"

  PIDS=(); PCAPS=(); started=1
  for dev in "${IFACES[@]}"; do
    pc="$WORK/cap-$dev.pcap"
    tcpdump -i "$dev" -n -w "$pc" 'not (host 127.0.0.1 or host ::1) and (tcp or udp)' >/dev/null 2>&1 &
    PIDS+=("$!"); PCAPS+=("$pc")
  done
  sleep 1
  for pid in "${PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || started=0; done

  if [[ $started -eq 0 ]]; then
    echo "✗ tcpdump failed to start on one or more interfaces — cannot conclude (not a pass)" >&2
    rc=1
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  else
    # Run WITHOUT the tripwire: this is the INDEPENDENT wire-level proof, so the
    # bench must be free to actually emit a packet if it would. (Check 1 already
    # ran it under the tripwire.) Capture the exit status — a bench that never
    # completed a dictation would yield 0 packets that must NOT read as a pass.
    bench_ok=1
    "$BENCH" e2e "$FIXTURE" >/dev/null 2>&1 || bench_ok=0
    sleep 1
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done

    if [[ $bench_ok -eq 0 ]]; then
      echo "✗ whispr-bench e2e did not complete — cannot conclude (not a pass)" >&2
      rc=1
    else
      total=0; wrote=1
      for pc in "${PCAPS[@]}"; do
        [[ -s "$pc" ]] || wrote=0
        n="$(tcpdump -r "$pc" 2>/dev/null | wc -l | tr -d ' ')"
        total=$((total + n))
      done
      if [[ $wrote -eq 0 ]]; then
        echo "✗ a capture file was never written — cannot conclude (not a pass)" >&2
        rc=1
      elif [[ "$total" -eq 0 ]]; then
        echo "✓ tcpdump: 0 non-loopback packets across ${IFACES[*]} during the dictation cycle"
      else
        echo "✗ tcpdump: $total non-loopback packet(s) captured across ${IFACES[*]} — NOT offline" >&2
        echo "  (if the machine wasn't idle these may be unrelated; check 1's tripwire is authoritative)" >&2
        for pc in "${PCAPS[@]}"; do tcpdump -r "$pc" 2>/dev/null | head -10 >&2; done
        rc=1
      fi
    fi
  fi
fi

echo
if [[ $rc -eq 0 ]]; then
  echo "OFFLINE CAPTURE: PASS"
else
  echo "OFFLINE CAPTURE: FAIL" >&2
fi
exit $rc
