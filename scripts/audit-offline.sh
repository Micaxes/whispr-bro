#!/usr/bin/env bash
#
# audit-offline.sh — static offline guarantee (spec §11.7, §12).
#
# One of three enforcement layers for the "runs entirely on your machine, zero
# network" promise (the other two are runtime: net-tripwire on connect() and a
# tcpdump packet capture — see verify-offline-capture.sh). This one is static
# and cheap enough to gate every CI run.
#
# It inspects the linked Mach-O symbol table(s) and fails if the binary gained
# the ability to talk to the network from OUR code. Two tiers — a hard
# guarantee and a low-noise regression tripwire:
#
#   TIER 1 — low-level outbound-networking call symbols (BSD sockets, CFNetwork
#            stream/socket/HTTP, Network.framework nw_*, TLS). A program must
#            import one of these to open a connection itself. Our binary imports
#            NONE. Any appearance is a hard failure.
#
#   TIER 2 — high-level NSURLSession / URLSession API surface. Allowed to exist,
#            but ONLY from the vendored FluidAudio model downloader (neutralised
#            at runtime by DownloadUtils.enforceOffline and proven inert by the
#            tcpdump/tripwire acceptance tests). Fails if ANY such symbol is
#            attributable to our own modules (WhisprBro / WhisprBroCore), and
#            warns if the FluidAudio surface drifts from the checked-in baseline.
#
# Scope note: nm sees a Mach-O's own symbol table. Our SPM deps (FluidAudio,
# GRDB) are STATICALLY linked into the executable, so its table is complete for
# our code. The only dynamic library we ship is llama.framework (Metal LLM, no
# networking) — when given a .app bundle this script audits it too. System
# frameworks (Foundation/CFNetwork) link dynamically; their internals are out of
# scope here and are covered by the runtime tcpdump/tripwire proof instead.
#
# Declared exception — the updater helper: Contents/Resources/whispr-update-check.sh
# is an opt-out / on-by-default, out-of-process update checker (see README
# "Updating"; disable in Settings › General to make zero connections). It is a
# shell script, not Mach-O and not under Sources/, so it is intentionally NOT
# scanned here — the guarantee this script certifies is precisely "the app BINARY
# contains no networking code," and the helper is by design not part of that
# binary. It runs on a daily throttle when update checks are on (on by default;
# disable in Settings to make zero connections), and never during a dictation
# cycle (so the tcpdump capture stays zero-packet). Do not "fix" this by making
# the app itself perform the check — that WOULD trip Tier 0/1/2.
#
# Usage:  scripts/audit-offline.sh [path-to-binary | path-to-.app]
# With no argument it builds (or reuses) the release WhisprBro binary.
set -euo pipefail

cd "$(dirname "$0")/.."
BASELINE="scripts/offline-symbol-baseline.txt"

TIER1_RE='^_(connect|socket|bind|listen|accept|getaddrinfo|freeaddrinfo|getnameinfo|gethostbyname|gethostbyaddr|res_[a-z]+|send|sendto|sendmsg|recv|recvfrom|recvmsg|inet_[a-z]+|CFSocket[A-Za-z]*|CFReadStreamCreateForHTTP|CFWriteStreamCreateWithHTTP|CFStreamCreatePairWithSocketToHost|CFHTTP[A-Za-z]*|nw_connection_[a-z_]+|nw_endpoint_create[A-Za-z_]*|nw_path_[a-z_]+|SSLHandshake|SSLCreateContext|tls_[a-z_]+)$'
TIER2_RE='NSURLSession|NSURLConnection'
# App Swift source must not USE a networking API at all (Tier 0). This backstops
# a limitation of the symbol audit: app code calling Foundation's shared
# URLSession emits only Foundation's own (shared) thunk symbols, indistinguishable
# from FluidAudio's use — so the symbol table alone can't attribute them to us.
# A direct source scan can. (Comments are stripped first so the docs/comments
# that DISCUSS these APIs don't false-trip.) Defined here, above its use below.
NET_API='URLSession|URLRequest|URLConnection|NWConnection|NWListener|NWEndpoint|NWPathMonitor|CFSocket|CFStream|CFReadStream|CFWriteStream|import +Network|import +Socket|getaddrinfo|SocketPort|\.dataTask|\.downloadTask'
# Attribute a networking symbol to our own code by the distinctive module token,
# independent of the Swift mangled length prefix (WhisprBro -> "9WhisprBro",
# WhisprBroCore -> "13WhisprBroCore"). A plain substring is exact enough: no
# third-party symbol contains "WhisprBro", and this match is only ever applied
# to symbols already filtered to the NSURLSession/URLSession surface.
OURS_RE='WhisprBro'

fail=0
declare -a all_tier2=()

# Audit one Mach-O file. Sets fail=1 on a Tier-1 hit or our-code Tier-2 hit;
# accumulates the file's Tier-2 symbols into all_tier2 for the baseline diff.
audit_one() {
  local bin="$1" syms tier1 tier2 ours
  syms="$(nm "$bin" 2>/dev/null | awk '{print $NF}')" || return 0
  [[ -z "$syms" ]] && return 0

  tier1="$(printf '%s\n' "$syms" | grep -E "$TIER1_RE" | sort -u || true)"
  if [[ -n "$tier1" ]]; then
    echo "  ✗ TIER 1 — $bin imports low-level networking call(s):" >&2
    printf '      %s\n' $tier1 >&2
    fail=1
  fi

  tier2="$(printf '%s\n' "$syms" | grep -E "$TIER2_RE" | sort -u || true)"
  if [[ -n "$tier2" ]]; then
    ours="$(printf '%s\n' "$tier2" | grep -E "$OURS_RE" || true)"
    if [[ -n "$ours" ]]; then
      echo "  ✗ TIER 2 — $bin: our own code references a networking API:" >&2
      printf '      %s\n' $ours >&2
      fail=1
    fi
    all_tier2+=("$tier2")
  fi
}

# ---- collect target Mach-O files ------------------------------------------
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  TARGET="$(find .build -type f -path '*release*' -name WhisprBro 2>/dev/null | head -1 || true)"
  if [[ -z "$TARGET" ]]; then
    echo "· no release binary found — building (swift build -c release)…"
    swift build -c release --product WhisprBro >/dev/null
    TARGET="$(find .build -type f -path '*release*' -name WhisprBro 2>/dev/null | head -1 || true)"
  fi
fi

declare -a FILES=()
if [[ -d "$TARGET" && "$TARGET" == *.app ]]; then
  echo "· auditing app bundle: $TARGET (executable + bundled Mach-O)"
  while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q 'Mach-O' && FILES+=("$f")
  done < <(find "$TARGET/Contents/MacOS" "$TARGET/Contents/Frameworks" -type f 2>/dev/null)
elif [[ -f "$TARGET" ]]; then
  # Validate it's actually Mach-O — else nm returns nothing and audit_one would
  # pass a non-binary (or unreadable) path as "clean" (a false PASS).
  if ! file "$TARGET" 2>/dev/null | grep -q 'Mach-O'; then
    echo "FAIL: $TARGET is not a Mach-O binary" >&2
    exit 2
  fi
  echo "· auditing: $TARGET"
  FILES+=("$TARGET")
else
  echo "FAIL: target not found: ${TARGET:-<none>}" >&2
  exit 2
fi
[[ ${#FILES[@]} -eq 0 ]] && { echo "FAIL: no Mach-O files in $TARGET" >&2; exit 2; }

for f in "${FILES[@]}"; do audit_one "$f"; done

# ---- Tier 0: app source must not USE a networking API ---------------------
# Closes the symbol-audit blind spot (app code reusing Foundation's shared
# URLSession). Scans our own Swift source, comment-stripped.
if [[ -d Sources ]]; then
  src_hits=""
  while IFS= read -r f; do
    hit="$(sed 's|//.*||' "$f" | grep -nE "$NET_API" || true)"
    [[ -n "$hit" ]] && src_hits+="$f: $hit"$'\n'
  done < <(find Sources -name '*.swift' -type f 2>/dev/null)
  if [[ -n "$src_hits" ]]; then
    echo "✗ TIER 0 — app Swift source uses a networking API:" >&2
    printf '%s' "$src_hits" >&2
    fail=1
  else
    echo "✓ TIER 0 — no networking API used in app Swift source"
  fi
fi

# ---- summarise Tier 1 -----------------------------------------------------
[[ "$fail" -eq 0 ]] && echo "✓ TIER 1 — no low-level socket / CFNetwork / nw_ / TLS call symbols"

# ---- Tier 2 classification (robust to toolchain mangling drift) -----------
# The hard gate is the OWNING MODULE of each NSURLSession/URLSession symbol, not
# a byte-exact baseline: every such symbol must be OWNED by a known-allowed
# source — the vendored FluidAudio downloader, Foundation's own URLSession
# extension thunks, or the ObjC runtime metadata they pull in. Anything else is
# a NEW, unreviewed networking source and fails. Our own code (WhisprBro*) hard-
# fails separately, per-file, in audit_one.
#
# The patterns are ANCHORED to the owning-module token, NOT floating substrings:
#   ^__?OBJC          ObjC metadata (_OBJC_/__OBJC_… class & protocol records)
#   ^_\$s10FluidAudio  Swift symbol whose owning module is FluidAudio
#   FoundationE        a Foundation-declared extension thunk (…C10FoundationE…)
# A floating 'Foundation' would be wrong: nearly every URLSession symbol merely
# REFERENCES a Foundation type (URL/Data as 10Foundation3URLV/4DataV) in its
# signature, so a genuinely new third-party networking symbol would be misread
# as Foundation-owned. `FoundationE` matches only extensions DECLARED in
# Foundation, which third-party code cannot emit. This survives Swift/Xcode
# bumps (which reshuffle mangled suffixes) that a literal baseline would false-
# fail on. The baseline file is kept only as a human-readable drift log.
VENDOR_RE='^__?OBJC|^_\$s10FluidAudio|10FluidAudioE|10FoundationE'
cur="$(printf '%s\n' "${all_tier2[@]:-}" | grep -E '.' | sort -u || true)"
if [[ -z "$cur" ]]; then
  echo "✓ TIER 2 — no NSURLSession/URLSession surface at all"
else
  unknown="$(printf '%s\n' "$cur" | grep -vE "$VENDOR_RE" | grep -vE "$OURS_RE" || true)"
  if [[ -n "$unknown" ]]; then
    echo "✗ TIER 2 — NSURLSession/URLSession symbol from an UNRECOGNIZED source" >&2
    echo "  (not FluidAudio / Foundation / ObjC runtime, and not app code):" >&2
    printf '    %s\n' $unknown >&2
    fail=1
  else
    echo "✓ TIER 2 — $(printf '%s\n' "$cur" | grep -c .) NSURLSession symbols, all from FluidAudio / Foundation / ObjC runtime"
  fi
  # Soft, non-gating drift note against the committed baseline (documentation
  # only — a change here is worth a glance after a dependency bump, but must
  # never break CI on a toolchain reshuffle).
  if [[ -f "$BASELINE" ]]; then
    base="$(grep -vE '^\s*#|^\s*$' "$BASELINE" | sort -u || true)"
    drift="$(comm -3 <(printf '%s\n' "$cur") <(printf '%s\n' "$base") 2>/dev/null || true)"
    [[ -n "$drift" ]] && echo "· note: Tier-2 surface differs from $BASELINE (informational — regenerate after a dependency bump)"
  else
    {
      echo "# Human-readable drift log of the NSURLSession/URLSession symbols in the"
      echo "# WhisprBro binary. NOT a CI gate — audit-offline.sh classifies by source"
      echo "# (FluidAudio / Foundation / ObjC runtime). All entries below must be from"
      echo "# the vendored FluidAudio downloader or Foundation's URLSession thunks,"
      echo "# neutralised at runtime by DownloadUtils.enforceOffline and proven inert"
      echo "# by verify-offline-capture.sh (tcpdump) + net-tripwire (egress abort)."
      printf '%s\n' "$cur"
    } > "$BASELINE"
    echo "· note: wrote a fresh Tier-2 drift log at $BASELINE (review + commit)"
  fi
fi

echo
if [[ "$fail" -ne 0 ]]; then
  echo "OFFLINE AUDIT: FAIL" >&2
  exit 1
fi
# Scope the claim honestly: this proves no networking API in app source, no
# low-level networking symbols, and no networking-API surface from a new/unknown
# module. It cannot, by itself, prove a dependency never reaches the network at
# runtime — that is the job of net-tripwire + verify-offline-capture.sh.
echo "OFFLINE AUDIT: PASS — app source uses no networking API; no new networking symbols."
