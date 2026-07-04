# whispr-bro

A private, fully-local voice dictation app for macOS (Apple Silicon) — a [Wispr Flow](https://wisprflow.ai) clone where **nothing ever leaves your machine**.

Hold a hotkey, speak, release: your words are transcribed on the Apple Neural Engine (Parakeet-tdt-0.6b-v2 via FluidAudio), auto-edited by an in-process local LLM (llama.cpp, Metal), and inserted at the cursor of whatever app you're in. Zero network code compiled into the binary. No account, no telemetry, no cloud.

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

Runnable. Implemented milestones (tracked as a Gitmoot goal, see the spec):

- **task-007** — walking skeleton: push-to-talk hotkey → Parakeet ASR → paste (~90ms ASR on M2 Pro)
- **task-008** — VAD (silence-trim + hands-free lock), password-field refusal, tap watchdog, waveform HUD
- **task-009** — in-process llama.cpp auto-edit stage (Qwen2.5-1.5B on Metal, frozen from an [on-device measurement gate](docs/llm-measurement-gate.md)); end-to-end ~305–574ms

Remaining: context-aware per-app styles (010), personal dictionary (011), searchable history (012), offline-proof hardening (013).

## Build & run

```bash
scripts/build-llama-xcframework.sh   # build llama.cpp -> Vendor/llama.xcframework (needs Xcode + `brew install cmake`)
scripts/fetch-models.sh              # ASR (Parakeet) + VAD (Silero), ~465MB, checksum-pinned
scripts/fetch-llm-models.sh          # default auto-edit LLM (Qwen2.5-1.5B, ~940MB); or `all` for the benchmark set
scripts/make-signing-cert.sh         # one-time: stable self-signed cert so TCC grants survive rebuilds
scripts/make-app.sh                  # build + bundle dist/WhisprBro.app, then `open` it
```

`whispr-bench` is the measurement harness: `whispr-bench file|mic|vad|llm|e2e …` (times each pipeline stage on your machine).

## Requirements

- macOS 14+ on Apple Silicon
- Xcode + `cmake` (to build the llama.cpp xcframework)
- ~1.5GB disk for the default models (fetched once, checksum-pinned; the full LLM benchmark set is ~3GB)
- Permissions: Microphone, Accessibility, Input Monitoring
