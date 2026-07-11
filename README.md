# whispr-bro

A private, fully-local voice dictation app for macOS (Apple Silicon) — a [Wispr Flow](https://wisprflow.ai) clone where **nothing ever leaves your machine**.

Hold a hotkey, speak, release: your words are transcribed on the Apple Neural Engine (Parakeet via FluidAudio), auto-edited by an in-process local LLM (llama.cpp, Metal), and inserted at the cursor of whatever app you're in. Zero network code compiled into the binary. No account, no telemetry, no cloud. The microphone opens only while you're holding the hotkey — the macOS mic indicator is lit while dictating, not for the whole session.

| | Wispr Flow | whispr-bro |
|---|---|---|
| ASR + LLM inference | Cloud (Baseten/AWS) | **On-device** |
| Screen context | Sent to servers | **Never leaves the process** |
| Works offline | No | **Only** works offline |
| Latency (end-of-speech → text) | ~700ms p99 | ~480–650ms target |

## How it works

The full architecture — mermaid diagrams, component/latency/model/privacy tables, build milestones — lives in:

- **[Issue #1: Architecture — how whispr-bro works](https://github.com/Micaxes/whispr-bro/issues/1)** (canonical, with research provenance)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (in-repo copy of the spec)

## Status

Runnable. All build milestones (tracked as a Gitmoot goal, see the spec) are merged:

- **task-007** — walking skeleton: push-to-talk hotkey → Parakeet ASR → paste (~90ms ASR on M2 Pro)
- **task-008** — VAD (silence-trim + hands-free lock), password-field refusal, tap watchdog, waveform HUD
- **task-009** — in-process llama.cpp auto-edit stage (Qwen2.5-1.5B on Metal, frozen from an [on-device measurement gate](docs/llm-measurement-gate.md)); end-to-end ~305–574ms
- **task-010** — context-aware per-app formatting styles (Slack casual / Mail formal / IDE verbatim)
- **task-011** — personal dictionary + hand-editable TOML config
- **task-012** — searchable local history (GRDB + SQLite FTS5)
- **task-013** — hardening + offline proof (CI symbol audit, `connect()` tripwire, tcpdump capture, on-disk sha256 verify)
- **task-014** — Auto-Clean: deterministic filler removal + LLM self-correction resolution

Recent additions:

- **On-demand microphone** — the mic (and the macOS orange indicator) opens on hotkey key-down and closes on release, instead of running for the whole session. Matches Wispr Flow; the built-in mic's ~100ms warm-up is hidden by reaction time.
- **Languages** — English (default), **Italian**, and **Spanish**, selectable in Settings → Models. English stays on Parakeet v2; Italian/Spanish use the multilingual Parakeet v3 model (fetch it with `scripts/fetch-models.sh multilang`).

## Build & run

```bash
scripts/build-llama-xcframework.sh   # build llama.cpp -> Vendor/llama.xcframework (needs Xcode + `brew install cmake`)
scripts/fetch-models.sh              # English ASR (Parakeet v2) + VAD (Silero), ~465MB, checksum-pinned
scripts/fetch-models.sh multilang    # ALSO fetch Parakeet v3 for Italian/Spanish (~465MB more; optional, checksum-pinned)
scripts/fetch-llm-models.sh          # default auto-edit LLM (Qwen2.5-1.5B, ~940MB); or `all` for the benchmark set
scripts/make-signing-cert.sh         # one-time: stable self-signed cert so TCC grants survive rebuilds
scripts/make-app.sh                  # build + bundle dist/WhisprBro.app (prints the `open` command)
```

`whispr-bench` is the measurement harness: `whispr-bench file|mic|vad|llm|e2e …` (times each pipeline stage on your machine).

## Requirements

- macOS 14+ on Apple Silicon
- Xcode + `cmake` (to build the llama.cpp xcframework)
- ~1.5GB disk for the default models (fetched once, checksum-pinned; +465MB for the Italian/Spanish model, the full LLM benchmark set is ~3GB)
- Permissions: Microphone, Accessibility, Input Monitoring

## Updating

whispr-bro is distributed as a GitHub repo, so a new version is a new [release](https://github.com/Micaxes/whispr-bro/releases). The app can tell you when one is out — **without breaking the zero-network guarantee.**

The trick: the app binary still contains **zero networking code** (the [offline guarantee](docs/OFFLINE.md) is untouched). The version check runs in a **separate process** — [`scripts/whispr-update-check.sh`](scripts/whispr-update-check.sh), bundled at `Contents/Resources/`. Once a day the app spawns that helper; the helper `curl`s GitHub for the latest release tag and writes it to a local `update-state.json`. The app then just **reads that file** and, if the tag is newer than the running build, shows a small "update available" prompt in the bottom-left (and in the menu bar). **Download** opens the release page in your browser — the app never downloads either.

- **On by default,** with a one-time, non-blocking notice on first launch that says so and points to the off switch (*Settings › General › Check for updates automatically*). The first check may run at launch; **turn it off there and no further checks run — with checks off, whispr-bro makes zero network connections.** **Check for updates…** in the menu is always available for a manual one-shot check.
- **What actually leaves the machine:** only that daily `curl` to `github.com`, revealing your IP exactly as your browser would — and only while enabled. Your audio, transcripts, and history never touch this path.
- **Honest scope:** the offline audit certifies the *app binary + `llama.framework`*. The updater is a declared, separate, **opt-out (on-by-default)** component that is never linked into the binary and never runs during a dictation cycle — so `audit-offline.sh`, `net-tripwire`, and the tcpdump capture all stay green (verified).
- **Cutting a release (maintainer):** bump [`VERSION`](VERSION), tag it (e.g. `v0.2.0`), run `scripts/make-app.sh` (it stamps `CFBundleShortVersionString` from `VERSION`), and publish a GitHub release on that tag. Note: builds are self-signed and **not** notarized, so a downloaded `.app` is quarantined — first launch needs *System Settings › Privacy & Security › Open Anyway*.
