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

## Eval harness (`whispr-bench eval`)

Formatter changes are graded, not eyeballed. `whispr-bench eval` scores each
formatter stage against hand-authored golds on three independent axes
(`TranscriptScore`): word-level **WER** (punctuation/case-blind — moves only
when a stage rewrites words, e.g. resolves a self-correction), **punctuation
P/R/F1** (marks keyed by the aligned gold word), and **case accuracy** over
aligned equal words. Fixtures enter at the post-ASR, post-dictionary stage
(`HistoryRecord.rawText`) and mirror the pipeline order (filler strip →
formatter); a raw-vs-gold baseline row shows each stage's lift. Golds are the
ideal POLISHED text, so the rule-based path is *expected* to trail a good LLM
stage on correction fixtures — the harness is comparative, not pass/fail.

    swift run -c release whispr-bench eval                     # built-in seeds
    swift run -c release whispr-bench eval my.json             # personal fixtures
    swift run -c release whispr-bench eval --formatter rules   # skip the LLM

**Fallback provenance (the honesty rail).** Model columns run through
`formatDetailed`, so every row carries its source: pure model output, a
`[fast-path]` marker (the stage's deterministic short-utterance design — the
model is skipped identically on-device), or a loud `[FELL BACK: <reason>]`
marker (unavailable / request-failed / timed-out / implausible — that row
scored `ruleBasedCleanup`, not the model). Each model column prints its
fallback totals under the aggregate; a column with ANY failure fallbacks is
flagged `INVALID — N/17 fell back to rules; NOT model evidence` and the bench
exits non-zero. This closes a measured hole: a Foundation Models daemon
outage (ModelManagerError 1013, observed live) used to produce an
official-looking "foundation" row that was 100% rules output.

**Personal fixtures from history.** The history DB lives under
`~/Library/Application Support/whispr-bro/` (`Paths.home`); the macOS History
window and the iOS History tab both display each row's raw and formatted text.
Copy a row's RAW text into `raw` and hand-correct it into `gold`:

    [{ "id": "mine-1", "raw": "<History rawText>", "gold": "<hand-corrected ideal>" }]

`note` (free-form tag) and `audio` (future ASR-path fixture) are optional.

**Seed-set aggregate, M2 Pro (n=17, micro-averaged)** — before/after the
deterministic fixes (`TextFormatter.repairPunctuation` + the guarded
mid-utterance capitalizer, also applied post-LLM to catch echoed residue):

| Stage | WER | punct P | punct R | punct F1 | case |
|---|---|---|---|---|---|
| raw baseline | 0.116 | 0.53 | 0.32 | 0.400 | 0.838 |
| rules (before) | 0.069 | 0.81 | 0.81 | 0.806 | 0.925 |
| rules (after) | **0.069** | **0.96** | 0.81 | **0.877** | **0.954** |
| Qwen2.5 (before) | 0.040 | 0.83 | 0.94 | 0.879 | 0.948 |
| Qwen2.5 (after) | 0.040 | **0.88** | 0.94 | **0.906** | 0.948 |

WER is byte-identical before/after — the fixes touch only punctuation/casing,
never words. The remaining rules-vs-LLM gap is exactly the LLM's job: comma
insertion, proper nouns, and self-correction resolution.

## iOS formatter stage — Apple Foundation Models (phase i4)

iOS shipped through phase i1 with NO model stage (llama.cpp is macOS-only in
Package.swift; llama-on-iOS is deferred to a future A/B). Phase i4 wires
`FoundationModelsFormatter` — the on-device Apple system model (~3B, zero
shipped weights, fully offline, `import FoundationModels`) — into the same
`DictationPipeline` seam where macOS injects its llama stage. Safety rails
mirror `TextFormatter`: short-utterance fast path (with the correction-cue
bypass), `maximumResponseTokens ≈ 2×` input, a hard 3.0s deadline race
(chosen between the ~2.5s latency contract — which false-trips the measured
2.8s M2 Pro cold start — and the earlier 4s, too long for a user staring at
an insertion point; prewarm makes cold starts rare), and a new
engine-agnostic output gate (`TextFormatter.plausibleReformatting`: sanitize
+ punctuation repair, then reject). The gate rejects exactly: empty output;
multi-line output from single-line input; word count outside `[0.5, 1.6]×`
the input's (±4 words absolute for ≤ 8-word inputs); and any INTRODUCED
content word — an output token containing a letter that never appears in the
input, compared case-insensitively on punctuation-stripped tokens. Purely
numeric/time tokens are exempt (number denormalization "two thirty" → "2:30"
survives), adjacent-pair concatenations count as input vocabulary (the
prompt-sanctioned split-word merge "double check" → "double-check" survives),
and a.m./p.m. forms are allowlisted. It does NOT catch an answer composed
entirely of input words. Every rejected/unavailable/timed-out path
lands as the rule-based result. Availability is a runtime gate (A17 Pro+/M1+,
Apple Intelligence enabled, assets ready) re-checked per dictation, so
`.modelNotReady` at launch degrades gracefully and recovers mid-session.

**First measurement on this Mac** (M2 Pro, macOS 26.5 — same framework and
wrapper the phone runs, so scores transfer; absolute latency does not),
`swift run -c release whispr-bench eval --formatter all`, seed set n=17,
with the SHARED llama-stage prompt as the FM instructions: F1 0.871 / WER
0.058 / case 0.970, avg 454ms — and **INVALID as model evidence** (`foundation
fallbacks: 4/17 (implausible ×4)`, exit 1). On 4 of 17 fixtures the system
model ANSWERED the dictation instead of formatting it (`bench-standup` →
"Sure, here is the updated design doc: …"; `bench-code` → a generated
JavaScript function; `cap-mid` → "Sure, I'd be happy to review the
document…"; `punct-double` → "Yes, it is done. Okay, let's go."). The
tightened gate rejected all four, so those rows scored the rule-based
fallback — the text always landed, but each answer burned a full model
round-trip to produce rules-level output.

### Prompt hardening (bench-driven iteration)

The answer-the-content failure was eliminated by iterating the FM
INSTRUCTIONS (the llama stage's prompt is unchanged; `PromptBuilder` still
owns the core auto-edit lexicon per language, and the FM stage wraps it).
To make iteration honest, `FoundationModelsFormatter.formatDetailed` now
also returns the REJECTED raw model output on the `.implausible` path, and
the bench prints it under the row — so every iteration shows WHAT the model
did wrong, not just that it fell back. Each step measured with
`whispr-bench eval --formatter foundation`, seed set n=17:

| Config | punct F1 | WER | case | failure fallbacks |
|---|---|---|---|---|
| 0. shared llama prompt (baseline) | 0.871 | 0.058 | 0.970 | 4/17 (answers) |
| 1. + verbatim-transcript framing | 0.793 | 0.064 | 0.947 | 4/17 (still answers) |
| 2. + `<transcript>` markers around the prompt | 0.780 | 0.052 | 0.929 | **0/17** |
| 3. + 3 compact few-shots (first one imperative) | 0.848 | 0.046 | 0.965 | 0/17 |
| 4. few-shot 3 → residue example (`, uh` + two sentences) | 0.906 | 0.040 | 0.959 | 0/17 |
| 5. + "even when nothing else changes" caps clause | 0.892 | 0.035 | 0.971 | 0/17 |
| 6. caps clause reworded (no hedge) — **final** | **0.909** | **0.040** | **0.988** | 0/17 |

What moved the needle, in order:

- **Framing alone (1) does nothing** — the model still answered imperative
  content, and quality dipped.
- **Delimiting the transcript (2) is THE fix for answering** — with the
  dictation quoted between `<transcript></transcript>` markers (defined in
  the instructions; a marker echo in the output is stripped before the
  gate), 0/17 answers on every subsequent run. But "quoted material" alone
  pushed the model into verbatim echoes: lowercase sentence starts kept,
  terminal punctuation dropped, F1 below rules.
- **Few-shots (3, 4) re-anchor the actual edit** inside the quote frame —
  capitalize, punctuate, strip fillers; the first example is imperative
  content that gets cleaned, not fulfilled. None reuse bench-fixture text
  (that would overfit the eval). English-only: it/es would need in-language
  examples (unmeasured), so those languages ship framing + markers only.
- **The caps clause (5, 6) closes the echo class**, but its wording is
  measurably load-bearing: the hedged version (5) deterministically broke
  `correct-day` to all-lowercase; the direct version (6) fixed every
  casing/terminal deficit. Greedy decoding proved DETERMINISTIC per prompt
  on this daemon (repeat runs byte-identical) — earlier "variance" was
  prompt sensitivity, so every word of the instruction block is a tuned
  parameter; edit it only with the bench open.

Two daemon-hang guardrails landed alongside (measured live: a bench run sat
>600s with no progress): the deadline race is now UNSTRUCTURED — the old
`withTaskGroup` race awaited its children on exit, so a daemon request that
ignored cooperative cancellation wedged the caller far past the 3s deadline;
now a one-shot continuation always unblocks at the deadline and the orphaned
request is dropped, with session CREATION inside the raced task (it also
talks to the daemon). And `prewarm()` no longer blocks its caller: the
session-create + prewarm daemon work runs in a DETACHED task — a plain
`Task {}` would inherit the formatter actor's isolation (its closure
captures `self`) and run the daemon calls while holding the actor, which
would wedge both the dictation-start path and the deadline race itself —
so a wedged daemon strands only that one orphan task. Known cost of the
drop-the-orphan design: while the daemon stays wedged, every timed-out
dictation abandons one task holding a `LanguageModelSession` (cooperative
cancellation is ignored by hypothesis), so orphans accumulate unbounded at
one per dictation until the daemon recovers or the process exits.

### Final measured state

`whispr-bench eval --formatter all` after hardening — foundation column
verified over three consecutive clean runs (rows byte-identical, exit 0,
0/17 failure fallbacks):

| Stage | WER | punct P | punct R | punct F1 | case | avg | worst |
|---|---|---|---|---|---|---|---|
| raw baseline | 0.116 | 0.53 | 0.32 | 0.400 | 0.838 | — | — |
| rules | 0.069 | 0.96 | 0.81 | 0.877 | 0.954 | ~0ms | — |
| Qwen2.5 (macOS stage) | 0.040 | 0.88 | 0.94 | 0.906 | 0.948 | 169ms | 401ms |
| Foundation Models | **0.040** | 0.86 | **0.97** | **0.909** | **0.988** | 524ms | 983ms (1.9s cold) |

The foundation stage now leads the table on punctuation F1 and case accuracy
and matches Qwen2.5 on WER, with zero gate rejections. Remaining known
deficits, all safe under-edits (the golds chart future progress):
`bench-standup` ends "morning, thanks." instead of "morning? Thanks.";
`correct-number` and `premise-fillers` resolve only partially (the same
class Qwen2.5 fails); and the long-span correction is now ECHOED
(`meet at 2 actually 3 pm`) rather than resolved — its scored WER is worse
than the old run's 0.10, but the old number was a **hallucinated blend**
("2:30 pm", a time never spoken), which no longer occurs in the final
config. Latency: avg ~525–540ms, worst ~1.0–1.9s (first request absorbs the
cold start; prewarm mitigates) — modestly above the pre-hardening 454ms
because all 14 model rows now decode full cleaned output instead of 4 being
cut short by rejection.

Verdict: with 0/17 answer-class failures over consecutive runs, F1/case
above the rules floor and the macOS Qwen2.5 stage, and the number-blend
hallucination gone, the stage is fit to stay default-ON for iOS — pending
the standing **device-only unknowns:** real iPhone 15 Pro Max latency
(~30 tok/s class, expect ×2–4 the M2 Pro numbers — the 3.0s deadline was
tuned on M2 Pro data alone and MUST be re-measured on-device; the few-shot
block also grows the instruction prefill, so re-measure, don't extrapolate),
thermal throttling under repeated dictations, and how often `.modelNotReady`
occurs in the field.
