# LLM measurement gate (task-009, spec §11.3, §13.1)

The default reformatting model was **frozen from on-device data**, not chosen a
priori. Benchmarked on the target machine (Apple M2 Pro, 16GB) via
`whispr-bench llm <key>`, four realistic raw-dictation transcripts each, greedy
sampling, in-process llama.cpp b9862 on Metal, KV-cached system prefix.

## Results

| Model (Q4_K_M) | Load | Format avg | best | worst | Quality |
|---|---|---|---|---|---|
| Llama-3.2-1B-Instruct | 0.31s | 436ms | 239ms | **987ms** | ❌ disqualified |
| Qwen2.5-1.5B-Instruct | 1.09s | **366ms** | 290ms | 463ms | ✅ **default** |
| Qwen3-1.7B (no-think) | 1.20s | 331ms | 302ms | 365ms | ⚠️ inconsistent |

## Decision: Qwen2.5-1.5B-Instruct

Latency was **not** the deciding factor — all three fit the budget (ASR ~90ms +
format + insert ~50ms ≤ 700ms p99). Quality was:

- **Llama-3.2-1B — disqualified.** Two failure modes on the *default* auto-edit
  instruction: (1) it prepends a preamble (`Here is the cleaned text:`) despite
  "output only the cleaned text"; (2) on the code-dictation sample it *answered*
  the content — generating a full JavaScript function (771 chars, 987ms) instead
  of cleaning the sentence. A dictation formatter that completes/answers the
  dictated text is worse than no formatting.
- **Qwen3-1.7B (no-think) — inconsistent.** Tightest latency, but the prefilled
  empty `<think></think>` block makes it under-edit: 2 of 4 samples were echoed
  with fillers removed but **no punctuation or capitalization added** — missing
  the core job.
- **Qwen2.5-1.5B — reliable.** All four samples: punctuation added, fillers
  removed, meaning preserved, no preamble, no runaway, no answering. Occasional
  minor rephrase (mitigated by the "do not reword" system-prompt tightening).

Runaway protection: the Formatter caps generation at ~2× the input token count,
so even a misbehaving model can't produce a Llama-style essay in production.

Qwen3-1.7B and Llama-3.2-1B remain selectable presets (`LlmCatalog`), but the
frozen default is **Qwen2.5-1.5B** (`LlmCatalog.default`).

## End-to-end validation (real Parakeet input)

The per-model bench above feeds *artificially raw* lowercase transcripts (the
hard case). In production the LLM sees **Parakeet output, which is already
punctuated**, so it edits far more conservatively. `whispr-bench e2e` on the
real fixtures (ASR → Qwen2.5 format), M2 Pro:

| Fixture | ASR | EDIT | Change | asr+format | ≈ E2E (+insert) |
|---|---|---|---|---|---|
| short | 99ms | 201ms | **unchanged** (already clean) | 300ms | ~350ms |
| long (2 sentences) | 115ms | 409ms | fixed `per cent`→`percent`, added a comma | 524ms | ~574ms |
| plan | 84ms | 171ms | **unchanged** | 255ms | ~305ms |

On already-clean input Qwen2.5 leaves the text alone (no rephrasing), and it
fixes genuine STT errors (`per cent` → `percent`) — exactly the intended
auto-edit behavior. Every case lands under the **700ms p99** target, the
2-sentence worst case included.
## Task-014 Auto-Clean — on-device findings

**Premise check (spec §1.3): Parakeet emits fillers verbatim.** `say`-synthesized
dictation "um so I was uh thinking … meet at 2 uh actually 3 … um yeah"
transcribes as `"Um, so I was uh thinking … meet at 2, uh, actually 3 p.m. Um,
yeah."` — the fillers survive ASR. So the deterministic `FillerStripper` (Phase 1)
has real work; the "kill-the-ums" win is not already done by the ASR.

**Filler strip** is deterministic and ~0ms; it runs on every route (LLM path and
raw/fast-path). Latency harness unchanged (p99 ≈ 480ms).

**Self-correction (level `standard`) is best-effort on the frozen Qwen2.5-1.5B —
this is why it is opt-in, not the GA default.** Measured with `whispr-bench cleanup`:

| input | output | verdict |
|---|---|---|
| `let's meet at 2 actually 3` | `Let's meet at 3.` | ✅ resolved |
| `send it monday no wait tuesday` | `Send it Tuesday.` | ✅ resolved |
| `I actually enjoyed the movie` | `I actually enjoyed the movie.` | ✅ preserved (cue is content) |
| `so I was thinking we should meet at 2 actually 3 pm` | echoed unchanged | ⚠️ not resolved (long span) |
| `the total is 50 no sorry 15 dollars` | echoed unchanged | ⚠️ not resolved (number span) |

The model resolves short, example-like corrections and correctly leaves
non-corrections alone, but **does not generalize to longer or number-heavy
corrections** — it safely under-edits (echoes) rather than mangling (bias-to-keep).
The **inline few-shot examples are load-bearing**: without them the model neither
corrects nor reliably punctuates; with them, clean no-correction inputs are
preserved byte-for-byte-modulo-punctuation (no over-edit regression). A stronger
correction tier would need a small fine-tune (spec §12 Phase 3), deferred.
