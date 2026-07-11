# Offline guarantee & proof

whispr-bro runs **entirely on your Mac**. Audio, transcription, formatting, and
history never leave the machine — there is no cloud, no account, no telemetry.
The catch (spec §12): the app needs Accessibility + Input Monitoring + a global
event tap, which means it **cannot run in the App Sandbox**. So "offline" is not
enforced by an OS sandbox — it is enforced by construction and *proven* three
independent ways, plus a documented firewall rule you can add as a fourth,
external check.

## Why there's no networking in the first place

- Nothing in the **app binary** opens a socket. ASR (Parakeet/CoreML) and
  formatting (llama.cpp/Metal) are in-process, on-device inference. History is
  local SQLite. Your audio, transcripts, and history never leave the machine.
- The one dependency that *can* touch the network is FluidAudio's model
  **downloader**. We never install models at runtime — `scripts/fetch-models.sh`
  does that once, at install time — and `DownloadUtils.enforceOffline = true` is
  set as defense-in-depth so the downloader is inert even if reached.
- **The update check is the one deliberate exception**, and it is **not in the
  app binary**: a separate bundled helper (`scripts/whispr-update-check.sh`, a
  short-lived `bash`/`curl` process) contacts `github.com` once a day to read the
  latest release tag. It is **on by default** and reveals only your IP (never any
  audio/transcript). Turn it off in *Settings › General › Check for updates
  automatically* to make **zero** network connections. This is why the audit,
  tripwire, and tcpdump proofs below are scoped to the app binary + a dictation
  cycle — the updater is separate, opt-out, and never runs during dictation.

## The three proofs

### 1. Static symbol audit — `scripts/audit-offline.sh` (runs in CI)

Inspects the linked Mach-O symbol table(s) and fails the build if the app gained
the ability to talk to the network from our own code. Two tiers:

- **Tier 1** — low-level outbound-networking call symbols (BSD sockets,
  CFNetwork stream/socket/HTTP, `nw_*`, TLS). Our binary imports **none**; any
  appearance is a hard failure.
- **Tier 2** — high-level `NSURLSession`/`URLSession` surface. Allowed **only**
  from the vendored FluidAudio downloader (checked against
  `scripts/offline-symbol-baseline.txt`); fails if any such symbol is
  attributable to `WhisprBro`/`WhisprBroCore`, or if the FluidAudio surface
  drifts from the reviewed baseline.

```
scripts/audit-offline.sh                 # audits the release binary
scripts/audit-offline.sh dist/WhisprBro.app   # audits the whole bundle incl. llama.framework
```

Scope: `nm` sees a Mach-O's own table. Our SPM deps (FluidAudio, GRDB) are
**statically linked**, so the executable's table is complete for our code; the
only dynamic library we ship (`llama.framework`) is audited too. System
frameworks link dynamically and their internals are covered by proof #2/#3.

### 2. Runtime `connect()` tripwire — `scripts/net-tripwire.c`

A tiny `DYLD_INSERT_LIBRARIES` interpose library that replaces `connect()` and
**aborts the process** the instant it attempts any non-loopback outbound
connection. Loopback and AF_UNIX are allowed (local IPC). Run over a full
dictation cycle, a clean exit means zero connection attempts.

### 3. tcpdump zero-packet capture — `scripts/verify-offline-capture.sh`

Runs a full dictation cycle (ASR → LLM formatting — the paths a model loader
might use to phone home) under the tripwire, and, with sudo, also captures every
non-loopback packet with `tcpdump` and asserts the count is **zero**.

```
scripts/make-fixture.sh Fixtures/latency.wav        # synthesize a fixture (say + afconvert)
scripts/verify-offline-capture.sh Fixtures/latency.wav      # tripwire only (no sudo)
sudo scripts/verify-offline-capture.sh Fixtures/latency.wav # + tcpdump zero-packet proof
```

Acceptance (spec §11.7): CI fails on any networking symbol; the packet capture
of a full dictation cycle shows **zero** packets from the process.

## 4. (Optional) firewall deny-all — Little Snitch / LuLu

Because the app isn't sandboxed, a paranoid user can add an OS-level outbound
firewall rule as an independent, always-on check:

**Little Snitch**
1. Little Snitch → *Rules* → **New Rule…**
2. Process: `…/WhisprBro.app` (and, for the CLI, the `whispr-bench` binary).
3. **Deny · Any connection · Any port · Any protocol**, forever.
4. Save. The app itself will never prompt because it never connects — if it ever
   tries, Little Snitch blocks and logs it, giving you a visible tripwire.

> **Note on the updater:** the daily update check runs in a *separate* process
> (`bash`/`curl`, not `WhisprBro.app`), so a rule scoped to the app won't cover
> it. If you want truly zero whispr-bro-related traffic, **turn off update checks**
> in *Settings › General* (then even the helper never runs); optionally also add a
> deny rule for the bundled `Contents/Resources/whispr-update-check.sh` helper.

**LuLu** (free, open-source)
1. LuLu → **Rules** → **＋**.
2. Add `WhisprBro.app`, action **Block**, scope **Any**.
3. Since LuLu alerts on the *first* outbound attempt by an unknown process,
   simply leaving it running and never seeing a whispr-bro alert is itself proof.

Either way: install the models once (online), then keep this rule on. Everything
below the model-fetch step works with the network physically off.

## The `whispr-bench verify` / ModelManager integrity check

Separately from the offline proofs, `ModelManager` (Settings → Models → *Verify
on disk*, or `whispr-bench verify`) re-hashes every installed model file against
the checked-in `scripts/*.sha256` manifests — catching a truncated download or
tampering and telling you exactly which model to re-fetch.
