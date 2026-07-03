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

Design spec v1 complete; implementation tracked as a Gitmoot goal following the milestones in the spec. Nothing runnable yet.

## Requirements (planned)

- macOS 14.4+ on Apple Silicon
- Xcode / Swift 5.10 toolchain
- ~2.5GB disk for models (fetched once, at install time, checksum-pinned)
- Permissions: Microphone, Accessibility, Input Monitoring
