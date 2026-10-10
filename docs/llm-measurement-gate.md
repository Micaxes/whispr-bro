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

**The full quality benchmark — F/Fi/M sub-scores, the composite, hard-fail
gates, the verdict ladder, the leaderboard, and the calibration protocol
that validates all of it against the maintainer — is documented in
[`docs/eval-benchmark.md`](eval-benchmark.md).** What follows here is the
original three-axis harness this section always described; the quality
benchmark is the superset that subsumes it (the WER/punct/case line stays as
its continuity row).

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

    swift run -c release whispr-bench eval                     # built-in seeds (81)
    swift run -c release whispr-bench eval --formatter rules   # skip the LLM
    swift run -c release whispr-bench eval "$WHISPR_EVAL_HOME/personal.json" --formatter shipped,llama \
        --json "$WHISPR_EVAL_HOME/runs/personal.json"          # the personal set, never from inside the checkout

**Fallback provenance (the honesty rail).** Model columns run through
`formatDetailed`, so every row carries its source: pure model output, a
`[fast-path]` marker (the stage's deterministic short-utterance design — the
model is skipped identically on-device), or a loud `[FELL BACK: <reason>]`
marker. Each model column prints its fallback totals under the aggregate,
sorted by kind (docs/eval-benchmark.md §3): `fast-path` / `raw-mode` are
design; `timed-out` and `rejected` (the output gate's `.implausible`) are real
behaviour — counted, and **scored as the fallback text the user actually
got**, with the rejected pre-gate text graded beside it as `model_verdict`;
only `unavailable` / `request-failed` mean the harness failed, and a column
with ANY of those is flagged `INVALID — n/N fell back to rules because the
harness failed; NOT model evidence` and the bench exits 1. This closes a
measured hole: a Foundation Models daemon outage (ModelManagerError 1013,
observed live) used to produce an official-looking "foundation" row that was
100% rules output.

**Personal fixtures from history.** Never copy-paste rows out of the History
window: `whispr-bench history-export --out "$WHISPR_EVAL_HOME/personal.json"`
(default home `~/OS/dev/whispr-bro-eval/`) writes one gold-free fixture per
history row from a copy of the DB, 0600, and refuses any `--out` inside a
source checkout; golds and annotations come only from the rating loop
(docs/eval-benchmark.md §7). Personal fixtures, run files and the personal
leaderboard live there and nowhere under `~/repo` — `eval --json` /
`--report` refuse a checkout path for such a set, CI's
`scripts/lint-fixtures.sh` refuses a history row in the tree, and
`.gitignore` covers `/*.json`, `*personal*` and `/runs/`.

**Seed-set aggregate, M2 Pro — historical, n=17, micro-averaged** (the
original 17 seeds, before the set grew to 81 in `task-021`; the numbers the
documented command prints today are the 81-seed continuity line plus the
quality block) — before/after the deterministic fixes
(`TextFormatter.repairPunctuation` + the guarded mid-utterance capitalizer,
also applied post-LLM to catch echoed residue):

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

*Superseded 2026-09-13 (task-023): every "0/17" above is the 17-seed set of
phase i4, scored by `plausibleReformatting` alone. Measured on the 81-seed
corpus under the shared gate, the foundation column refuses 8 and times out 1
— the same 8 ids the baseline refused with the plausibility rule alone. See
"Measured — both stages under the shared gate" below.*

## Output gate on the macOS path (task-023, 2026-09-13)

Plan §2 bug 1 / §10.3 follow-up 1. Until this change the llama stage
(`TextFormatter.formatDetailed`) inserted anything non-empty after
`sanitize` + `repairPunctuation`; the gate that would have refused both
catastrophic history rows (a question answered in markdown, invented math)
ran only in the iOS Foundation Models stage. Both stages now run ONE gate,
`TextFormatter.gateModelOutput(_:of:language:)` — static and engine-free,
so it is pinned as a pure function over (input, model output) in
`OutputGateTests` — which does, in order: sanitize + punctuation repair;
`ContentGuard` in gold-free mode (raw = the stripped text the model saw,
no gold, no alternates, disfluencies derived from the stripper's own
lexicon) refusing a gated verdict, then `plausibleReformatting` for what the
guard lets through. WHICH gates run on the live path is the subject of the
subsections below and settles in § "The measurement round" — as first committed
it was all four (ANSWERED / INVENTED / NEGATED / OVER_EDIT_FACT) plus a
no-new-content-words rule and a word-count band, i.e. the bench's own rules,
which is what the rounds below take apart. No prompt change and no threshold
change in this branch: the llama user turn is still undelimited (follow-up 3
is its own measured row).

**Rejected-row semantics.** A refused reply never reaches the user: the
dictation lands as `ruleBasedCleanup` with provenance
`.fallback(.implausible)`; the formatter logs the reason at error level
(the worst gate with every trigger that fired, or the plausibility rule —
public — and the first 80 characters of the refused reply — private, as
all dictated text is); and `formatDetailed` returns the raw reply as a
third element, `rejected`, so `whispr-bench eval` prints what the model
did and grades it beside the fallback as `model_verdict`. The bench counts
such rows as `rejected` and scores the fallback text the user actually
got. A rejection is a safe landing, never a fix — the model round-trip is
still paid for rules-level output — which is why follow-up 3 exists.

**Seeds, M2 Pro, `whispr-bench eval --formatter llama --quiet`** (n=81,
Qwen2.5-1.5B, same prompt, same fixtures sha, run key `448796cb7659` on
both sides; before = the release binary at `9293e05`, after = this branch):

| | before | after |
|---|---|---|
| status | FAIL(answered 4, invented 5, controls 77.6%, latency) | FAIL(controls 91.8%, latency) |
| composite C | 81.4 | **91.1** |
| axes F · Fi · M | 77 · 94 · 87 | 80 · 90 · **98** |
| fallbacks | 7/81 (fast-path ×7) | 19/81 (fast-path ×7, **rejected ×12**) |
| continuity WER / punct F1 / case | 0.130 / 0.690 / 0.972 | **0.017** / 0.738 / 0.975 |
| latency p50 / p90 / p99 | 395 / 1251 / 1693 ms | 383 / 1176 / 1643 ms |
| by tag: question / trap / replica | 62.2 / 35.0 / 59.5 | 89.9 / 91.7 / 89.3 |

The 12 refused rows are the 9 the baseline FAILed on — ANSWERED
`question-01`, `question-05`, `trap-03` (a generated Python function),
`trap-05` (a bullet list); INVENTED `trap-04` (a Spanish translation),
`numbers-01`, `repair-02`, `latency-060`, `latency-150` — every one now
scored as the rules fallback (PUNCT / MISSED), plus three rows the bench
grades as mild non-gated edits that the plausibility rule refused on one
introduced content word: `long-06` ("is to flip" → "we'll flip"),
`medium-02` ("neighbours" → "neighbors"), `medium-06` ("which I think is"
→ "I think this is"). That is the gate's measured cost on the seeds: three
rewordings — which the prompt forbids anyway — landed as rules output
instead; the FM stage has run the same rule since phase i4. Fi dips 94 →
90 because a refused row is scored as the rules fallback, which leaves the
stutters the model had collapsed; M rises 87 → 98 because no answered or
invented text is ever scored as the stage's output. The run still FAILs on
controls (45/49 unchanged, under the 95% line: four control fixtures the
model REWORDS below the INVENTED thresholds — follow-up 2's over-editing
work, not a gate matter) and WARNs on latency (unchanged; follow-up 4).

### Live vs bench profiles (same branch, 2026-09-13)

*Superseded by "The reduction" below, and kept as the record of what was
tried: every live-only rule this section describes — the cued collapse floor,
the short-input allowance, the bare-"no" exemption keyed on evidence, the
homophone and ordinal lists — is deleted. The two root-cause fixes in it
(`Align.isApostropheRestored` and the unapostrophized negations;
`NumberCanon`'s year / decimal / clock pairs) are kept, because they help the
grader as well as the gate.*

A two-lens verifier panel refuted the gate as first committed: it is right
about the bench and wrong about the **live path**, where a refusal is not a
safe landing but a lost improvement — the dictation falls back to rules
output, so the user gets the unresolved raw. Four false-positive classes were
reproduced against this branch's own release build with the real model. A
false positive on the live path is therefore worse than a miss; in the bench
it is the opposite (row 54's invented total must still gate). So the
gate splits by profile instead of moving a threshold:

`ContentGuard.Profile` is `.bench` (default — every scorer, lint and test
call site keeps its exact behaviour) or `.live`, which
`TextFormatter.gateModelOutput` passes on both model stages. Every value the
split moves is an `EvalThresholds.live…` constant next to the bench sibling
it relaxes, pinned literal-by-literal by `ContentGuardTests`.

| Class (measured refusal) | Before | Live now | Bench |
|---|---|---|---|
| **Short resolved correction** — "send it monday no wait tuesday please" → "Send it Tuesday." | `OVER_EDIT_FACT (length-collapse)`: 3 of 7 atoms is 0.43 < 0.5, and the guard returns before `plausibleReformatting`, so its ±4-word short allowance never ran | a LONE collapse is dropped when the short allowance applies (≤ 8 words in, within ±4 out) or a correction cue is present, where the floor becomes `liveCuedCollapseRatio` 0.34 — "meet at the cafe scratch that at the office" → "meet at the office" keeps 4 of 9. The same cue floor applies to the plausibility band, which would otherwise re-refuse the 9-word case | unchanged (0.5, no cue reading) |
| **Bare-"no" correction** — "the total is 50 no 15 dollars" → "The total is 15 dollars." | `NEGATED (negation-dropped)`: `isDiscourseNo` exempts only a "no" that opens the utterance or carries its own mark | a dropped or rewritten bare "no" is a CORRECTION cue, never a flip (`liveCorrectionCueNegations`). "not", "never", "n't", "none", "nothing", "cannot", "nobody", "nowhere" and every inserted negation fire unchanged | unchanged |
| **Number normalization** — "…december twenty twenty six…" → "…December 2026…" | `INVENTED (novel-numeral)`: `NumberCanon` was cardinals-only, so the year was two atoms and the digit form was a numeral nobody said | root cause fixed for BOTH profiles: `NumberCanon` now also reads year pairs ("nineteen ninety five" → 1995), decimal "point" runs ("one point five" → 1.5, the scale word left standing as the model writes it) and clock pairs after a temporal anchor — `{at, by, until, till}`, an hour plus a tens-word minute, and not when a time-unit noun counts the pair ("at three thirty minute rounds"; see the fix round below, which narrowed both). Live additionally exempts a numeral whose digit runs are witnessed by CONSECUTIVE raw number words ("nineteen oh five" → 1905) | strict rule kept: an unwitnessed numeral gates |
| **Apostrophe restoration** — "i dont think we can ship this week honestly" | `NEGATED (negation-inserted)`: `Align.isNegation` keyed on the literal "n't", so "dont" → "don't" read as a negation inserted into a non-negation | root cause fixed for BOTH profiles: an out token that is the raw token with an apostrophe inserted before a terminal "t" is a restoration, never an inserted negation (`Align.isApostropheRestored`, structural — the lexicon of unapostrophized forms is read only by the DROP rule, and lists 22), and the novelty vocabulary holds both spellings so the restored form is not novel content either. Accepted cost: the homographs "cant" and "wont" read as negations in the DROP direction, which can silence the drop rule on a real flip OR fire it on an output that threw the noun away — both directions, corrected from the first version of this row | same fix |

Two smaller items from the same panel: the plausibility rule no longer reads a
number form as an introduced content word when its digits strip to a unit the
speaker said ("twenty six K" → "26K"), and the rejection log now splits by
privacy — `gate.reason` is the rule alone and stays `.public`, while the
content token it names travels as `gate.detail` and is logged `.private` on
both stages (`TextFormatter.GateVerdict`). Before this the plausibility rule
interpolated a word from the model's reply into a public log line.

**Tests.** `OutputGateTests` gains an adversarial acceptance corpus — 28
(input, model output) pairs that are **not** in the seed set, each with its
hand-counted arithmetic: 5 resolved corrections, 5 bare-"no" corrections, 6
number normalizations, 6 apostrophe restorations, 6 ordinary cleanups — plus 8
pairs that must still be refused (answered markdown, invented math, a true
polarity flip, an inserted negation, a wholesale collapse, a bullet list, a
novel proper noun, a wrong number inside a correction) and a row per relaxed
rule asserting the bench still gates it. The seed-gold pin stays, relabelled
as what it is: a regression pin, not a false-positive guard — 0 of 81 seed
raws carries an unapostrophized contraction, a bare-"no" correction, or a
spelled year, decimal or clock pair for the model to write as digits (the
three seeds that show a digit form get it from the raw), which is how 553
green tests coexisted with three live false-positive classes. Suite: **567
tests green**.

**Not measured in that step.** No model ran there — it was a code change; the
subsection below is the measurement it asked for, both stages in one
invocation. The "0/17 gate rejections" figure in the phase-i4 section above
stays superseded: it predates both the 81-seed corpus and this gate (17 seeds,
FM plausibility only).

### Measured — both stages under the shared gate (2026-09-13)

One run, both model columns, this branch's release binary at `cd6e8b0`:
`whispr-bench eval --formatter llama,foundation` on the built-in seeds (n=81,
fixtures sha `c7cb4e3528a1`, `scoring_version` 2, level `fixture`, M2 Pro /
macOS 26.5.1, run keys `d584e95f5a5a` and `fc02fec1e484`). Deliberately NOT
appended to `docs/eval/leaderboard.jsonl` — the leaderboard carries merged
work, and this branch is not merged. The pre-gate columns are the committed
baseline row (`docs/eval/leaderboard.jsonl`, `ab5355e`, same fixtures sha, same
scoring version); the gate-v1 column is that commit's own stored run. The
leaderboard row carries no micro line, so the two pre-gate continuity cells
come from the table above (llama) and from the baseline run JSON (foundation).

| | llama pre-gate `ab5355e` | llama gate v1 `4fa69f4` | llama live gate `cd6e8b0` | FM pre-branch `ab5355e` | FM live gate `cd6e8b0` |
|---|---|---|---|---|---|
| status | FAIL(answered 4, invented 5, controls 77.6%, latency) | FAIL(controls 91.8%, latency) | **FAIL(controls 91.8%, latency)** | WARN(latency) | **WARN(latency)** |
| composite C | 81.4 | 91.1 | **91.1** | 92.5 | **92.5** |
| axes F · Fi · M | 77.1 · 93.8 · 86.6 | 79.9 · 89.6 · 97.7 | **79.9 · 89.6 · 97.7** | 82.4 · 95.8 · 97.8 | **82.4 · 95.8 · 97.8** |
| gated verdicts | ANSWERED 4, INVENTED 5 | 0, 0 | **0, 0** | 0, 0 | **0, 0** |
| controls unchanged | 38/49 (77.6%) | 45/49 (91.8%) | 45/49 (91.8%) | 47/49 (95.9%) | 47/49 (95.9%) |
| fallbacks | 7/81 (fast-path ×7) | 19/81 (fast-path ×7, rejected ×12) | 19/81 (fast-path ×7, **rejected ×12**) | 16/81 (fast-path ×7, rejected ×8, timed-out ×1) | 16/81 (fast-path ×7, **rejected ×8**, timed-out ×1) |
| continuity WER / punct F1 / case | 0.130 / 0.690 / 0.972 | 0.017 / 0.738 / 0.975 | 0.017 / 0.738 / 0.975 | 0.010 / 0.729 / 0.983 | 0.010 / 0.729 / 0.983 |
| latency p50 / p90 / p99 | 398 / 1231 / 1957 ms | 449 / 1226 / 1945 ms | 410 / 1275 / 2003 ms | 885 / 2123 / 3161 ms | 908 / 2144 / 3129 ms |
| over 700 ms | 17/70 | 18/70 | 18/70 | 53/70 | 54/70 |

Every score is identical across the gate-v1 and live-gate columns, and across
the two foundation columns — the same rows, the same verdicts, the same
composite to the tenth. Decode is greedy on both stages, so the model text
does not move between runs; only latency does — `4fa69f4` measured p99 1643 ms
in the `--quiet` run quoted in the table above and 1945 ms in the stored run
here, on the same commit and the same machine.

**The live profile is invisible on the seeds, by construction and in fact.**
Over all 147 (input, model reply) pairs this run produced, `ContentGuard` on
`.bench` and on `.live` reach a different result on exactly **2** — both
`trap-04`, where live drops the `novel-numeral` trigger from a verdict that
stays INVENTED either way. Zero rows change outcome. That is the predicted
result: no seed raw carries an unapostrophized contraction or a bare-"no"
correction, and no seed raw carries a SPELLED year, decimal or clock pair for
the new `NumberCanon` rules to read — the three seeds that show a digit form
(`register-notes` 2015, `long-03` 9:40 and 6:10, `numbers-02` 11:30) get it
from the raw, already as digits, in both raw and gold. So the four live
false-positive classes have nothing to fire on here. The live fix is
pinned by `OutputGateTests`' adversarial corpus, not by a seed row, and the
number that would move it is a rated personal set (plan §10.2), not this one.

**Still refused, llama (12 of 81)** — id, the rule the LIVE gate logged, and
what the refusal cost, scoring the stored reply against the same gold with
`QualityScore` (Δ = model reply C − the fallback C the user actually got):

| id | live gate reason | Δ C |
|---|---|---|
| `question-01` | ANSWERED (opener, length-ratio, novel-count, novel-share, negation-inserted) | −89.4 |
| `question-05` | ANSWERED (length-ratio, novel-count, novel-share, negation-inserted) | −76.6 |
| `trap-03` | ANSWERED (multi-line, novel-count, novel-share) | −98.9 |
| `trap-05` | ANSWERED (multi-line, markdown, novel-count) | −93.5 |
| `trap-04` | INVENTED (novel-count, novel-share) | −91.2 |
| `numbers-01` | INVENTED (novel-count) | −80.0 |
| `repair-02` | INVENTED (novel-count) | −84.4 |
| `latency-060` | INVENTED (novel-count) | −85.7 |
| `latency-150` | INVENTED (novel-count) | −84.3 |
| `long-06` | implausible: introduced word (`we'll`) | −6.0 |
| `medium-02` | implausible: introduced word (`neighbors`) | −3.2 |
| `medium-06` | implausible: introduced word (`this`) | **+9.9** |

**Still refused, foundation (8 of 81, plus `question-02` timed out at 3129 ms)**:

| id | live gate reason | Δ C |
|---|---|---|
| `trap-03` | ANSWERED (multi-line, novel-numeral, novel-count, novel-share) | −98.9 |
| `trap-05` | ANSWERED (multi-line, markdown) | −93.5 |
| `trap-04` | INVENTED (novel-count, novel-share) | −91.2 |
| `medium-02` | implausible: introduced word (`neighbors`) | −3.2 |
| `latency-030` | implausible: introduced word (`starting`) | −4.5 |
| `latency-060` | implausible: introduced word (`starting`) | −5.1 |
| `latency-100` | implausible: introduced word (`starting`) | −1.6 |
| `latency-150` | implausible: introduced word (`starting`) | **+3.3** |

The llama Δs sum to −9.7 C over 81 fixtures, which puts the accept-everything
column at 81.4 — the measured pre-gate composite, to the tenth. That is the
cross-check that these stored replies are the same text the pre-gate run
scored. The same arithmetic gives the foundation stage the number it has never
had: **accept-everything would be 88.9, the gate buys +3.6 C**, and the 8
refusals are the same 8 ids the baseline's plausibility rule refused on its
own — adding `ContentGuard` to the iOS stage changed nothing on this corpus
(`trap-03` / `trap-05` are multi-line, `trap-04` is a Spanish translation; the
old rule caught all three too). Twelve rows across the two columns are saved
from a 0.0 (9 llama, 3 foundation); the eight mild refusals cost the
foundation column 0.14 C and gain the llama column 0.01 C.

**A false-positive class survived, and it is not one of the four.** Six of the
eight plausibility refusals across the two columns name a VARIANT of a word he
said, not new content: four name `starting` (he said "start"), two name
`neighbors` (he said "neighbours"). Only `medium-06`'s `this` and `long-06`'s
`we'll` are words with no spoken source. The same class reaches `ContentGuard`
too: llama `latency-060` gates as INVENTED on four novel tokens that are all
inflections — `starting`, `stopping`, `doubling`, `keeping` — though that row
also drops two clauses, so the refusal itself is right. The clearest case is
foundation `latency-030`, refused on `starting` alone:

- he said: `…use a short backoff start at 200 milliseconds and double it and stop after five attempts so we never hang`
- refused: `Please add a retry to the Lumabase client for timeouts. Use a short backoff, starting at 200 milliseconds, and double it. Stop after five attempts so we never hang.`
- he got: the raw, unpunctuated, with a period appended (punct F1 0.40)

Nothing was invented and nothing was lost; one verb took `-ing`. The bench
scores the refusal as the better outcome (Δ −4.5, because M charges the
substitution against gold) — on the LIVE path it is the opposite, and the
gate's own premise (§"Live vs bench profiles": a live refusal is a lost
improvement) says so. The fix is the same shape as the numeral exemption
already in `implausibility`: on `.live`, a token is not introduced content if
it shares a stem with an input token. It is deliberately NOT in this branch —
it is a new rule with its own false-negative surface (`unlock` vs `lock`,
`impossible` vs `possible` are stem-adjacent and meaning-inverting), it needs
its own adversarial corpus, and this branch's claim is the four measured
classes. This paragraph is its record: the next gate follow-up after plan
§10.3 rank 1, measured here, unfixed on purpose.

### The fix round — evidence, not shapes (2026-09-13)

*Also superseded by "The reduction" below: the fourth round found that two of
the fixes in this table were themselves false positives waiting to happen, and
that the pattern — patch the patch — was the signal to stop. Kept as the
record of the eleven findings and of the measured run that closes it.*

A two-lens verifier panel (live false positives; correctness regressions) read
the live-profile commits above and returned **one fatal, six majors and three
minors**. The fatal and three of the majors are the same mistake in four
places: every relaxation was keyed on a SHAPE — a word, a length, a set of
digits — that is much wider than the false positive it was written for. The
other three majors are rules that refuse what the system prompt explicitly
asks the model to do.

| Finding | What it did | Now |
|---|---|---|
| **FATAL — a determiner "no" was exempt from the polarity gate on `.live`** | `negationDropped` skipped EVERY raw "no". "we made no changes to the deploy script this week" → "We made changes…" was ACCEPTED and pasted with the meaning inverted; at `4fa69f4` it was refused. "no" is the commonest polarity carrier after "not" | the exemption asks for the REPARANDUM: the nearest content token before the "no", past STOP words and fillers, must itself be `.del` — which is what all five measured corrections look like ([monday, no], [fifty, no], [three, no], [sarah, no], [two, no]) and no determiner flip does |
| **A restored apostrophe was still novel content** | the negation rules learned the unapostrophized forms; the NOVELTY vocabulary did not. A restored "don't" was a novel atom against a raw "dont", so three restorations refused at any length (the count rule) and two on a 10-atom output (the share rule). The branch's headline class, refused on his own register | `Align.isCovered` strips apostrophes before asking, and the vocabulary carries both spellings — symmetric with the hyphen-split rule |
| **The cue lexicon was the bypass detector's, not the prompt's** | the collapse exemption keyed on `plausibleCorrection` (4 of the 7 cues the model is instructed to resolve), so "actually", "sorry" and a bare "no" got the instruction and not the exemption: "…on castro street actually at the office" → "I want to meet at the office." refused at 7 of 15 | `CorrectionCues.resolvableCorrection` over `promptPhrases` + a bare mid-utterance "no" (English only — in Italian and Spanish "no" is the primary negation). The bypass detector is untouched: it is narrow for a latency reason |
| **The short allowance was unconditional** | ≤ 8 words in and ±4 out cleared the collapse rule for ANY short utterance: "cancel the meeting with the finance team" → "Cancel the meeting." lost 4 of 7 words and three content atoms | it needs a correction cue in the raw, or `droppedContent` empty — only fillers, stutter copies and STOP words gone |
| **A numeral could be assembled from an unordered set of spoken digits** | one spoken "five" admitted 55; a "two" and a "five" four words apart admitted 25. Both were invented quantities, both accepted | a multi-part numeral must appear as CONSECUTIVE raw number words in the same order (which is exactly what makes "nineteen oh five" → 1905 legitimate); a single-part one matches whole |
| **The clock pair merged counts** | `clockAnchors` held "after", "before", "around" and "from": "before two forty minute sessions" became the atom 2:40, so the correct output "2 40-minute sessions" read as novel content — a live false positive created by the commit whose purpose was removing them | anchors are `{at, by, until, till}`, and an anchored pair followed by a time-unit noun is re-read as cardinals |
| **The introduced-word rule refused prompt-sanctioned slip fixes** | `defaultSystemPrompt` says "correct only clear speech-to-text slips such as homophones or split/merged words", and the rule exempted only input vocabulary + adjacent pairs + two allowlisted words. Every homophone fix died by construction ("there ready" → "they're ready"), and so did every denormalized ordinal ("the twenty third" → "the 23rd", refused on the `rd` left by the digit strip) | homophone CLASSES (listed, never derived — an edit-distance rule would also pass "fix" → "fox") and an ordinal-suffix exemption beside the unit one |
| **The two halves measured the same utterance differently** | the plausibility band read raw whitespace words while `ContentGuard` reads `expectedWords`: "uh um so um yeah uh um right um okay" → "So, yeah. Right. Okay." cleared the guard at ratio 1.00 and died here as "4 words out of 10". Reachable — in an IDE, a terminal or Notes the pipeline leaves the fillers in for the model | on `.live` the floor's denominator is the filler-stripped input; the upper bound keeps the raw count, as the ANSWERED ratio does |
| **Six contractions were missing from the negation lexicon** | "mustnt", "neednt", "shant", "mightnt", "oughtnt", "darent" — for those, restoring the apostrophe read as a polarity flip (NEGATED, the third rung) | the restoration direction is structural now and needs no list at all; the list (22 forms) is read only by the drop rule |
| **The homograph note stated one direction** | "the homographs cant and wont … can only SILENCE a rule" — false: a dropped noun "wont" makes the drop rule FIRE | the comment and the table row above state both directions; the forms stay, because dropping them would miss the flip of the two commonest contractions he speaks |
| **The canonicalizer's deviation from plan §4.1 was not declared** | year / decimal / clock canonicalization lives in the SHARED canon, so it moves the grader, and the doc's justification for the clock rule was falsified by the anchored-count case | [`docs/eval-benchmark.md`](eval-benchmark.md) §2.1 now states the deviation, both guards and the residual ambiguity. The panel also asked for a seed fixture carrying the three shapes: NOT added, because it changes the fixtures sha and the baseline (`ab5355e`) and every column measured against it stop being comparable mid-branch — it belongs to a corpus-growth step with a re-baselined row. The shapes are pinned by hand count in `AlignTests` and by the acceptance corpus instead |

`OutputGateTests`' adversarial corpus grows to **42 accepted / 13 refused**: a
row per cue the prompt commissions, a three-restoration 13-atom case and a
29-atom one (the old corpus's only two-restoration row was sized to 9 out
atoms, one under the share rule's floor — that is how the class hid),
mustn't / needn't, homophones, ordinals, filler-heavy strips, anchored counts;
and on the refusal side two determiner-"no" inversions, a short over-edit, and
55 / 25 assembled out of digits nobody said consecutively. Suite: **576 tests
green**.

**Re-measured, both stages, same corpus** (`whispr-bench eval --formatter
llama,foundation`, seeds n=81, fixtures sha `c7cb4e3528a1`, `scoring_version`
2, level `fixture`, M2 Pro / macOS 26.5.1, run keys `04a71d8f6d4d` and
`4558aee85a7a`, git `6dd4947`; not appended to the leaderboard, which carries
merged work):

| | llama live gate `cd6e8b0` | llama fix round `6dd4947` | FM live gate `cd6e8b0` | FM fix round `6dd4947` |
|---|---|---|---|---|
| status | FAIL(controls 91.8%, latency) | **FAIL(controls 91.8%, latency)** | WARN(latency) | **WARN(latency)** |
| composite C | 91.1 | **91.1** | 92.5 | **92.5** |
| axes F · Fi · M | 79.9 · 89.6 · 97.7 | **79.9 · 89.6 · 97.7** | 82.4 · 95.8 · 97.8 | **82.4 · 95.8 · 97.8** |
| gated verdicts | 0, 0 | **0, 0** | 0, 0 | **0, 0** |
| controls unchanged | 45/49 (91.8%) | 45/49 (91.8%) | 47/49 (95.9%) | 47/49 (95.9%) |
| fallbacks | 19/81 (fast-path ×7, rejected ×12) | 19/81 (fast-path ×7, **rejected ×12**) | 16/81 (fast-path ×7, rejected ×8, timed-out ×1) | 16/81 (fast-path ×7, **rejected ×7, timed-out ×2**) |
| continuity WER / punct F1 / case | 0.017 / 0.738 / 0.975 | 0.017 / 0.738 / 0.975 | 0.010 / 0.729 / 0.983 | 0.010 / 0.729 / 0.983 |
| latency p50 / p90 / p99 | 410 / 1275 / 2003 ms | 398 / 1240 / 1783 ms | 908 / 2144 / 3129 ms | 880 / 2098 / 3156 ms |
| over 700 ms | 18/70 | 18/70 | 54/70 | 53/70 |

**Nothing moved, and this time that is a measurement and not a silence.**
Every score is identical to the tenth; the llama column refuses the same 12
ids, and the foundation column the same 8 minus `latency-150`, which timed out
at 3009 ms this run before it could reach the gate (decode is greedy, so the
model text does not move between runs — only latency does, and `question-02`
timed out on both). The profile split is still invisible here: over all 146
(input, reply) pairs this run produced, `.bench` and `.live` reach a different
trigger list on exactly **2** — both `trap-04`, which stays INVENTED either
way — and zero rows change outcome. That is expected and it is the limit of
this corpus, checked row by row rather than assumed: 0 of 81 raws carries an
unapostrophized contraction or a spelled year / decimal / clock pair; no reply
in the 146 pairs drops a determiner "no" (the run has zero NEGATED verdicts on
either column), fixes a homophone, or writes a spelled ordinal as digits; and
at level `fixture` the formatter's input is already filler-stripped, so the
band's denominator never differs here — the filler class only exists in an
IDE, a terminal or Notes, where the pipeline leaves them in. Seven seed raws
DO carry a bare "no" (`correct-day`, `correct-number`, `register-notes`,
`long-06`, `long-07`, `trap-02`, `repair-02`) and every one of them is scored
the same before and after. So none of the eleven findings could show up in a
seed score; each is pinned by the adversarial corpus, which is where a
false-positive class belongs. The number that would move on them is a rated
personal set (plan §10.2).

**Still unfixed on purpose**, and unchanged by this round: the INFLECTION
class recorded in the section above (`start` → `starting` refuses four
foundation rows, `neighbours` → `neighbors` two more). A stem rule has its own
false-negative surface (`lock` / `unlock`) and needs its own corpus. The
homophone fix here is a listed equivalence class, not a stem test, and does
not touch it.

### The reduction — what the live gate is, and what it is not (2026-09-13)

Three verifier rounds hit the same wall. Every relaxation of the live gate
opened a hole; every tightening refused a legitimate cleanup. The third round
found a FATAL — an intensifier before a determiner "no" satisfies the
cued-value test, so "we have absolutely no time for this project" → "We have
time for this project" was ACCEPTED, a meaning inversion — plus two majors
that were regressions introduced by the round before it (the widened cue
lexicon relaxed the collapse rule for any innocent utterance containing
"actually" / "sorry" / "no"; the suffix exemption let any
`<digits><st|nd|rd|th|am|pm>` token through without asking whether the speaker
said those digits), plus a homophone list that sanctioned the corruption
direction as readily as the fix.

**The root cause is a category error, not a threshold.** The live gate was
refereeing EDIT QUALITY with lexical tools. Edit quality is what this
benchmark measures and what follow-ups 2 and 3 (register wording, prompt
delimiters) fix. The live gate's only job is to catch a CATASTROPHE before it
lands in his editor — so it now refuses three things, and the `.bench` profile
keeps every rule byte-identical (it is a scoring axis, not a refusal, and row
54's invented math must still gate).

**The evidence**, measured on his 70 real dictations (`history.sqlite`,
2026-07-05 → 2026-09-07) and the 81 seeds:

| Question | Measured | Decision |
|---|---|---|
| What actually went catastrophically wrong? | 2 of 70 rows: the model ANSWERED the dictation (id 70), the model INVENTED content and numbers (id 54) | keep ANSWERED and INVENTED, the two precise rules |
| How often does he dictate a mid-utterance bare-"no" correction ("send it monday no tuesday")? | **0 of 70** | every heuristic written to protect that shape is unpaid-for complexity — delete them |
| How often does a polarity word appear (not / never / n't / cannot / none / nothing / nobody / nowhere)? | **9 of 70 (13%)** | a polarity inversion is a real exposure worth one simple rule |
| How many NEGATED verdicts, and how many correct collapse refusals, across 151 fixtures and every model reply measured on this branch? | **0 and 0** | the collapse rule earns nothing on the live path; over-editing is follow-up 2's job |

**The rule, in full.** `ContentGuard.Profile.live` (both model stages, via
`TextFormatter.gateModelOutput`) refuses:

1. **ANSWERED** — unchanged. More non-blank lines than the input has; markdown
   the input does not carry (`**`, line-initial `- ` / `* ` / `1. `); a first
   token in {sure, certainly, here's, here, yes, okay} that is not among the
   input's own first two (fillers skipped); output/input above 1.5 on inputs of
   6+ atoms. This is his real failure and the rule is precise on it.
2. **INVENTED** — a novel NUMERAL whose digits the input does not witness; or
   3 novel content words; or a novel share above 0.15 on outputs of 10+ atoms.
   The witness test now runs over the digit run inside ANY novel token, not
   only a bare numeral, so an ordinal or a meridiem form is judged on its
   DIGITS: "the ninth" → "the 9th" lands, "the ninth" → "the 22nd" does not.
   The witness side reads an ordinal as its cardinal ("the twenty third" says
   23) — local to this test, never in the shared canon, so it cannot move a
   bench score. One or two novel tokens land, and that is precisely what makes
   a homophone list and an ordinal-suffix exemption unnecessary.
3. **NEGATED** — unambiguous POLARITY words only (not, never, every "n't" form
   including the unapostrophized ones, cannot, none, nothing, nobody,
   nowhere), dropped or flipped while the token they govern survives, or
   inserted where it is not an apostrophe restoration.

…plus, from `plausibleReformatting`: a reply with no WORD in it — empty, or
punctuation residue such as "." (there is nothing to insert, so refusing costs
nothing, and with no length rule left on this path a lone period would
otherwise replace a whole dictation and pass every remaining check); a
multi-line reply out of a single-line dictation; and a reply longer than
`1.6×` the input's word count (runaway — the rule that catches a repetition
loop below the ANSWERED floor). The wordless reading is the one rule this
round ADDED; it changes 0 of the 162 rows in the run below (the only wordless
row, the all-filler `fragment-01`, never reaches the gate — its stripped input
is empty and the one-word fast path answers it).

**What the live gate deliberately does NOT catch.**

- **A bare "no" never fires.** It is the correction cue his dictations use,
  and every one of those corrections reads to the aligner as a flip of the
  clause after it. So "we have absolutely no time for this project" → "We have
  time for this project" is accepted — an inverted meaning, pasted. This is a
  measured gap, not an oversight: the correction shape is what he dictates
  (the inversion shape appears in 0 of 70 rows), two rounds of heuristics that
  tried to separate the two each read an inversion as a correction, and the
  gap is pinned as an ACCEPTED row in `OutputGateTests` with the example
  named. The bench still gates every one of them, which is where the number
  that would reopen the decision lives.
- **Over-editing.** A resolved correction IS a shrink (7 atoms → 3), and no
  length test tells it from a dropped clause. The benchmark charges every
  deletion in M, and the register wording is the fix. "cancel the meeting with
  the finance team" → "Cancel the meeting." lands.
- **One or two invented words.** A single novel token is an ASR-slip fix or a
  grammar repair far more often than an invention, and the rule that refused
  it also refused every homophone and split-word fix the system prompt
  COMMISSIONS. Three novel tokens still gate at any length.

**Deleted**, rather than left dead: `ContentGuard.isCuedValueCorrection`,
`ContentGuard.liveShrinkAllowed`, `EvalThresholds.liveCorrectionCueNegations`
/ `liveCuedCollapseRatio` / `liveShortInputWords` / `liveShortInputAllowance`,
`CorrectionCues.resolvableCues` / `resolvableCorrection` (the file is restored
byte-for-byte to its pre-branch state — the bypass detector never moved),
`TextFormatter.homophoneClasses` / `homophonePeers` / `ordinalSuffixes` /
`introducibleWords` / `contentWords` / `expectedWords`, and
`GateVerdict.detail` with them: no rule names a content token any more, so the
gate's verdict carries no dictated text at all and the whole reason string is
`.public`. Kept: `Align.isNegation` knowing the unapostrophized contractions,
and `NumberCanon`'s year / decimal / clock pairs with the anchor narrowing —
root-cause fixes that help the grader and the witness test.

**Tests.** The adversarial acceptance corpus (inputs that are NOT in the
seeds, which tuned these thresholds and therefore cannot also guard them)
grows to **65 pairs that must land** — the intensifier gap, the ambiguous-cue
innocents ("I actually enjoyed the movie", "sorry about the delay"), ordinals
and meridiems both witnessed and unwitnessed, apostrophe restoration, the
homophone pair in BOTH directions, the inflection class recorded as unfixable
in the section above, and every legitimate cleanup a previous round refused —
against **18 distinct shapes that must still be refused** — answered markdown,
an in-band single-line answer, invented math, a runaway, a bullet list, a
polarity flip and an inserted negation in both spellings, unwitnessed digits,
three novel words — in 21 assertions, three of the shapes pinned both by name
and in the corpus. Suite: **577 tests green**.

**Measured — both stages, same corpus** (`whispr-bench eval --formatter
llama,foundation`, seeds n=81, fixtures sha `c7cb4e3528a1`, `scoring_version`
2, level `fixture`, M2 Pro / macOS 26.5.1, run keys `ec6db9fe39f8` and
`27f94684ce41`, git `4f16e15`; not appended to the leaderboard, which carries
merged work):

| | llama fix round `6dd4947` | llama reduction `4f16e15` | FM fix round `6dd4947` | FM reduction `4f16e15` |
|---|---|---|---|---|
| status | FAIL(controls 91.8%, latency) | **FAIL(controls 89.8%, latency)** | WARN(latency) | **FAIL(controls 87.8%, latency)** |
| composite C | 91.1 | **91.1** | 92.5 | **92.4** |
| axes F · Fi · M | 79.9 · 89.6 · 97.7 | **80.4 · 89.6 · 97.4** | 82.4 · 95.8 · 97.8 | **83.3 · 95.8 · 97.1** |
| gated verdicts (answered, invented, negated) | 0, 0, 0 | **0, 0, 0** | 0, 0, 0 | **0, 0, 0** |
| controls unchanged | 45/49 (91.8%) | 44/49 (89.8%) | 47/49 (95.9%) | 43/49 (87.8%) |
| fallbacks | 19/81 (fast-path ×7, rejected ×12) | 16/81 (fast-path ×7, **rejected ×9**) | 16/81 (fast-path ×7, rejected ×7, timed-out ×2) | 11/81 (fast-path ×7, **rejected ×3**, timed-out ×1) |
| continuity WER / punct F1 / case | 0.017 / 0.738 / 0.975 | 0.020 / 0.741 / 0.975 | 0.010 / 0.729 / 0.983 | 0.016 / 0.747 / 0.983 |
| latency p50 / p90 / p99 | 398 / 1240 / 1783 ms | 399 / 1202 / 1709 ms | 880 / 2098 / 3156 ms | 870 / 2158 / 3202 ms |
| over 700 ms | 18/70 | 17/70 | 53/70 | 51/70 |

**Seven rows changed, and they are exactly the seven the gate stopped
refusing.** Nothing else moved: row by row, the two runs differ only here.

| column | id | before | after | Δ C |
|---|---|---|---|---|
| llama | `long-06` | refused (introduced word `we'll`) | model text lands | −6.0 |
| llama | `medium-02` | refused (`neighbors`) | lands | −3.2 |
| llama | `medium-06` | refused (`this`) | lands | **+9.9** |
| foundation | `medium-02` | refused (`neighbors`) | lands | −3.2 |
| foundation | `latency-030` | refused (`starting`) | lands | −4.5 |
| foundation | `latency-060` | refused (`starting`) | lands | −5.1 |
| foundation | `latency-100` | refused (`starting`) | lands | −1.6 |

(`latency-150` also moves, +3.3, because it timed out in the previous run and
responded in this one — latency variance, not the gate. Decode is greedy on
both stages, so the model text itself does not move between runs.)

**Read the two columns of that table against each other, because they
disagree on purpose.** On the BENCH these seven refusals were worth +0.1 C to
the foundation column and 0.0 to llama — M charges `start` → `starting`
against the gold, so the bench scores the refusal as marginally better. On the
LIVE path the same seven are the opposite: nothing was invented and nothing
was lost in six of them, and what the user got instead was his raw text with a
period appended. `latency-030` is the clearest row — the refused reply scores
**F 81.3** against the fallback's **65.6**, and loses the comparison only
because M charges the one inflected verb (100 → 83.3, one substitution and one
novel token). He would have kept the punctuation and the casing; the gate
handed him the raw. The gate's own premise — a live refusal is a lost
improvement, because the fallback is rules output — settles it, and the
benchmark keeps measuring the disagreement.

**The foundation run status moves WARN → FAIL, and that is honest.** Its
controls-unchanged share falls 95.9% → 87.8% because four model edits that
used to be refused now land, three of them on control fixtures the model
rewords (`start` → `starting`). The gate was inflating that number by
refusing the edits — a run gate cannot be passed by hiding model behaviour
from it. The rewording itself is real and unfixed: it is follow-up 2's work
(register wording and the correction clause), and the llama column has FAILed
on the same line since the first gated run.

**Nothing in the bench profile moved.** Re-grading the stored fix-round run
(`whispr-bench score`, both columns, 162 rows) under this commit's scorer
reproduces every verdict, every axis and both composites exactly: **0 rows
changed**. The `.bench` rules are the same bytes; only which of them `.live`
runs has changed.

#### The letter clause — a content word carries a letter (2026-09-13, `d21dc9d`)

This landed BEFORE the measurement round below, and the run in it was taken
with the clause in place (`3b96ba9`, one commit later). It is kept in
landing order rather than folded into the freeze above, because the shape it
fixes is the one the round after it had to widen again.

L6 says "a novel content word is an OUT token **carrying a letter** whose
canonical form is absent from IN's vocabulary". The shipped code counted
every novel token, which refused replies that invent nothing — and it did it in
the one family the round before had just fixed L5 to protect:

| IN | OUT | was | novel tokens |
|---|---|---|---|
| "we ship on friday if the tests pass and then we take monday off …" | "We ship on Friday **-** if the tests pass **-** …" | `INVENTED (novel-count)` | `-`, `-`, `-`, `-` |
| (same sentence, commas instead of dashes) | "We ship on Friday, if the tests pass, …" | accepted | — |
| "my splits were seven fifty one seven forty eight seven fifty three and seven forty six on the long run" | "My splits were 7:51, 7:48, 7:53, and 7:46 on the long run." | `INVENTED (novel-count)` | `7:51`, `7:48`, `7:53`, `7:46` |
| "the ledger totals … nineteen oh five nineteen oh six nineteen oh seven and nineteen oh eight" | "The ledger totals for the year were 1905, 1906, 1907, and 1908." | `INVENTED (novel-count)` | `1905`, `1906`, `1907`, `1908` |

Every digit run in the last two rows is witnessed by consecutive spoken number
words — the years through L5's own test, the clock-time splits through the
witness alone, since L5 does not read a form with a separator in it (gap 6) —
and the count rule then called the same tokens invention; three splits landed and the fourth refused the reply. The fix
is the clause itself, on the `.live` branch only —
`novelTokens.filter { $0.canonical.contains(where: \.isLetter) }` — so `novel`,
`novelNumerals` and the whole bench profile stay byte-identical (the bench still
counts every novel token at 3, which is what the split table in
`ContentGuardTests` pins). That filter is HALF the definition: a denormalized
number keeps the canonicalizer's own letters ("9th", "9am") and was still being
counted, which is § "The suffix clause" at the end of this page.

**Nothing measured moved.** Replaying the freeze run's stored (input, refused
reply) pairs — all 12 rejections, both columns — through the fixed gate
reproduced that round's rejection table rule for rule: the smallest
letter-carrying novel count among the L6 rows was exactly 4 (`latency-060`,
`latency-150`), and
`trap-05`'s three letterless novel tokens were never what refused it (L1 was).
No re-run at this commit; the 2-column run in the next subsection was taken
one commit later and is the measured state of the clause. Suite: **589 tests
green**.

### The measurement round — six rules, and the three numbers the run moved (2026-09-13)

The freeze got the rule SET right: delete rather than patch, and let the
benchmark show what a miss costs. Then the 2-column measurement was run
against the frozen thresholds and **disagreed with three of them**, each time
in the same direction — the rule was refusing a correct reply for a shape
nobody has measured happening. The run is the evidence, so the numbers moved
and the rule set did not grow.

**Where this sits on the branch.** On top of `2f71423` (the live gate reading
the text the model was actually given) the branch carries, in landing order:
`d21dc9d`, the letter clause in the subsection just above; `3b96ba9`, the three
thresholds this subsection prices; `0e81ca3`, this page; `7079938`, the suffix
clause; `fe7fd01`, the witness clause; `724e82f`, the clock-time witness; `17a9abf`,
the clock pair's teen limit stated where it is claimed (prose only);
`426d590`, the run-by-run gap named and pinned in the last subsection (prose
and rows only); and the commits carrying this page's updates. At the
measurement round that was THREE commits on top of `2f71423`, not two — the
letter clause landed between the dispatch snapshot of the freeze and this
round, which is why the run below (`3b96ba9`) already has it.

**This subsection supersedes every earlier dated subsection on this page.**
Where one of them describes a live rule that is not in the table below — the
opener family, `answer-shape`, `novelShare`, the slip-fix discount, a cue
lexicon, **the polarity count (the ex-L7)**, "L3 is a half", "L6 needs four
novel words" — the table is what ships. The three subsections AFTER it (§ "The
suffix clause", § "The witness clause", § "The clock-time witness") correct
L6's letter test toward this same definition and its row here is written with
all three corrections in it; the last subsection names a gap the witness
leaves open and moves nothing. Nothing else in the table moved.

**The live gate refuses a model reply if and only if one of these fires.** IN
is the text the model was given (dictionary applied, fillers stripped), OUT the
sanitized, punctuation-repaired reply, atoms are `Align`'s canonical tokens.

| | rule | fires when | why it survived |
|---|---|---|---|
| **L1** | STRUCTURE | OUT has more non-empty lines than IN, or carries a markdown structure marker (line-initial `- `, `* `, `N. `, or a `**` span) IN does not | history row 70, independently of L2 and L6. A dictation is one paragraph and has no bullets. It is the only rule that refuses `trap-05` on either column |
| **L2** | RUNAWAY | atoms(OUT) > 1.5 × atoms(IN), atoms(IN) ≥ 6 | row 70 again (ratio 2.35), and Llama-3.2's documented 771-character generated-JavaScript reply. Formatting adds punctuation, not words. `question-01` and `question-05` are this rule in the measured run |
| **L3** | WHOLESALE LOSS | atoms(OUT) < **0.25** × atoms(IN), atoms(IN) ≥ 12 | an empty or quarter-length reply is a loss whatever produced it. The 12-atom floor and the quarter band are both there to keep a resolved self-correction — a shrink by nature — out of it |
| **L4** | WORDLESS | OUT holds no letter and no digit | the sanitizer can leave a lone "."; there is nothing to insert, so refusing costs nothing |
| **L5** | INVENTED NUMERAL | a digit run in OUT that IN's numbers, written or spoken, cannot witness | history row 54 (an invented total). The witness reads cardinals and ordinals, strips an ordinal / meridiem suffix first, and asks for each digit RUN of a form separately, of the whole dictation (gap 7); **when in doubt it witnesses**, because its failure mode has to be letting a number through, never refusing one he said |
| **L6** | INVENTED CONTENT | ≥ **3** novel content words — a novel OUT token **carrying a letter of its own** whose canonical form IN's vocabulary lacks; no piece of a number L5's witness test accepts is one, merged ("the 9th", "9am", "9:30am") or spaced ("the 9 th", "9 am", "9:30 am", where the tokenizer leaves the suffix as an atom of its own) — with atoms(OUT) ≥ 10 | row 70 a third time, and 7 of the 12 rejections in the measured run. The bench's own count; the 10-atom FLOOR is the whole live relaxation, and it is what lets two slip fixes in a short utterance land |

**Where the rules live.** L1, L2, L3, L5 and L6 are `ContentGuard`'s `.live`
profile; L4 is `TextFormatter.implausibility`, the one rule of the six that
needs no alignment. `implausibility` also re-reads L1 and L2 — off
`ContentGuard`'s own tokens and constants, so the two halves of
`gateModelOutput` cannot hold disagreeing opinions about length.

#### The three thresholds the run disproved

| | was | is | the measured row that moved it |
|---|---|---|---|
| **L7 POLARITY** | the COUNT of polarity tokens must match | **deleted from the live path** | `correct-day`: both models produced the correct "Send it Tuesday." for "send it monday no wait tuesday", and the count refused it on BOTH columns because the "no" the model correctly resolved is a carrier it can no longer find. 3 of the 81 seed golds (`correct-day`, `correct-number`, `repair-02`) and **2.3 composite on llama**. The shapes it guards — a dropped or an inserted polarity word — are measured at **0 of his 70 real dictations and 0 of the 81 seeds** |
| **L3 ratio** | 0.5 of atoms(IN) | **0.25** | "i want to meet at the coffee shop on castro street actually at the office" (15 atoms) → "I want to meet at the office." (7) is 0.47: a legitimate long cued correction at his MEDIAN dictation length, refused. At a quarter it lands, and the catastrophe the rule exists for — 22 atoms back as "Revenue grew." — is 0.09 and refuses either way |
| **L6 count** | 4 novel content words | **3** (floor unchanged at 10 atoms) | at 4, `numbers-01` ("can you list…" → "I will list…") and `repair-02` (a half-resolved correction that adds "as well") landed as in-band answers **the bench then graded INVENTED** — exactly the class L6 exists to catch, arriving in his editor. At 3 they refuse again, and the two-slip fix that was the reason for leaving 3 still lands, because the rule that was actually refusing slip fixes was `novelShare` and that one is off this path for good |

The deletion of L7 is the same rule the rest of this gate is built on, applied
to itself: **a refusal costs a real improvement, a miss costs one bad dictation
the benchmark will show.** A rule whose false positives are measured and whose
true positives are not does not earn a place on the shipping path. The BENCH
keeps `negation-dropped` and `negation-inserted` unchanged, so if an inversion
ever does happen to him it appears in the leaderboard as a NEGATED row.

**The bench profile is byte-identical.** Every rule the live path dropped sits
behind `profile == .bench`: the opener, `answer-shape`, `novelShare` with its
slip-fix discount, the alignment-driven `negation-dropped` /
`negation-inserted`, and the collapse rule against `expectedWords` at 0.5.
Proof rather than assertion: re-grading the stored 2-column freeze run
(`d0412e6`, run keys `341beadd2963` / `6d7a3389421c`) with this build moves
**0 of 162 rows** — every field of every row byte-identical, both column
objects identical, composites 88.8 / 92.1 unchanged. `scoring_version` stays 2.

**Known and accepted gaps.** Each one is pinned as a row in `OutputGateTests`
with a comment naming it, so it is visible rather than silent:

1. **An in-band answer built from fewer than 3 novel words** — "is it done?.
   okay.. let's go" → "It is done. Okay, let's go." lands. Six atoms of his own
   vocabulary: no structure, no growth, no numeral, and under 12 atoms L3
   cannot see it either. Since L3 moved to a quarter the gap is wider: "can you
   tell me whether the formatter runs before or after the filler strip" →
   "After the filler strip." (0.29) lands too.
2. **A question rewritten as a statement** — "are we sure the migration is
   reversible…" → "We are sure the migration is reversible…". Only
   `answer-shape` saw it, and that rule reads a QUESTION in a register where
   44 of his 70 rows are questions.
3. **A fabricated date whose digits he did say** — "on the ninth of next
   month" → "on the 9th of October": L5 witnesses digits, not meanings, and it
   must fail permissive.
4. **A polarity inversion is not refused on the live path; the bench scores
   it** — "we have absolutely no time for this project" → "We have time for
   this project." lands here and is a NEGATED row on the grader. This is the
   cost of deleting the count, and it is the cheaper side of the trade: the
   inversion is measured at zero across his 70 dictations and the 81 seeds,
   while the refusals it caused are three seed rows and 2.3 composite.
5. **A wholesale drop of an 11-atom-or-shorter dictation** — under L3's floor
   a short utterance thrown away lands, because a resolved correction is a
   shrink of exactly that size and no length test tells the two apart.
6. **A LETTERLESS number form L5 waves through is bounded by nothing else** —
   L5 is permissive by construction on every token that merely CONTAINS
   digits (a decimal, a clock time, a price: "2.5", "11:30", "19.99"), because
   the bench does not read those as numerals either. On the BENCH the count
   and share rules still see them. On LIVE neither does: the share rule is off
   this path, and L6 counts words carrying a letter of their own, which these
   forms do not (a version string canonicalizes to "v25" and IS counted). The
   WITNESS does read them — it has to know what "9:30" is to know whose
   letters the "am" after it are (§ "The clock-time witness") — but what L5
   GATES on is unchanged, and that is what leaves this gap exactly where it
   was. So
   three fabricated decimals in one reply land, bounded only by L1-L4. The
   trade is the same one as gap 3 — the alternative is refusing "give me two
   and a half hours" → "Give me 2.5 hours.", which is the formatting he asked
   for.
7. **A number whose digit RUNS the raw witnesses SEPARATELY** — the witness
   splits a form into its maximal digit runs and asks the whole dictation for
   each one on its own (`isReachable`): "9:30" asks for a 9 and for a 30, and
   never for the two together. So a raw whose "nine of us are going" and
   "thirty people signed up" sit in unrelated places witnesses a 9:30 nobody
   spoke, and the "am" the model wrote after it is then his number's letters
   rather than a novel content word. It is left that way DELIBERATELY: this
   gap lets a number THROUGH, it does not refuse one he said, which is the
   only direction this gate is allowed to fail in — and every tightening round
   on these rules has bought its hole with a false positive that cost a real
   improvement. What still bounds the reply is the text AROUND the number,
   which the other four rules read: it cannot gain a line or a markdown marker
   (L1), grow past 1.5× (L2), collapse below a quarter (L3) or carry three
   novel content words of its own (L6). The MERGED spelling is untouched
   because it is ONE run — "9:30am" canonicalizes to "930am", which has to be
   spoken whole or spelled by consecutive words — so the same three times gate
   merged and land spaced, which is this gap read from its other side. Both
   sides are pinned (`testGapSevenANumberWitnessedRunByRunLands`).
8. **THREE ASR slip fixes on a ≥ 10-atom output are REFUSED** — the one gap
   that runs the other way, and the price of the count being 3: "we should of
   shipped the fix befour the standup with there approval today" → "We should
   have shipped the fix before the standup with their approval today." is
   exactly the edit `defaultSystemPrompt` commissions, and L6 sees three novel
   content words. Nothing on this path tells them from three inventions — the
   edit-distance discount that tried to went out with `novelShare` — and the
   count was measured at 4 letting two in-band answers the bench grades
   INVENTED into his editor. So it is bought, not defended: the cost is one
   dictation that falls back to rules output (punctuated, cased, fillers
   stripped, the slips left in), while two slips at any length and three below
   the 10-atom floor land. Pinned as a REFUSAL row in `OutputGateTests`, beside
   the acceptance rows for the shapes either side of it.

**Tests.** The adversarial acceptance corpus — pairs that are NOT in the seed
set, which tuned these thresholds and therefore cannot also guard them — is
**128 pairs that must land** (the file's own count of the rows in
`assertAccepted` at this commit; the totals stated in the round sections below
are each that round's, and the clock-time round's rows were never folded into
this one): cued corrections short and long with every cue
(including the 15-atom row the half band refused), apostrophe restoration, one
and two slip fixes, three under L6's floor, spelled→digit years, decimals,
clock idioms, ordinals, meridiems, currency, a question gaining its mark, a
filler-heavy long prompt, an utterance ending mid-sentence, every assistant
opener the deleted rule used to refuse, seven polarity inversions (each
asserted NEGATED on the bench in the same test), and the letterless-novelty
A/B above — now including **three** ordinals, **three** meridiems and three
decimals in one utterance, the counts at which the letter clause is the only
thing holding the rule off — the ordinals and the meridiems in BOTH spellings,
the merged "9am" and the spaced "9 am" the tokenizer splits in two, plus the
dotted "a.m." a formatter actually writes and a reply that mixes the two, three
clock times, three decimals and three prices in either spelling, and the two
gap rows the witness leaves open — a time assembled from digit runs he said in
unrelated places, and its merged twin. Against it, **33 rows that must stay
refused**, one per rule L1-L6 plus his two catastrophe shapes and every number
invention the witness test was built for. All 81 seed golds but `fragment-01` (the all-filler row whose gold
is empty) now pass the gate, where the polarity count refused three of them.
`ContentGuardTests` pins the profile split rule by rule. Suite: **755 tests
green**.

**Measured — both stages, same corpus** (`whispr-bench eval --formatter
llama,foundation`, seeds n=81, fixtures sha `c7cb4e3528a1`, `scoring_version`
2, level `fixture`, M2 Pro / macOS 26.5.1, git `3b96ba9`, run keys
`3cb97fb97f0f` and `5a4a136fe187` — scratchpad only, not appended to the
leaderboard):

| | llama freeze | **llama measurement** | FM freeze | **FM measurement** |
|---|---|---|---|---|
| status | FAIL(invented 2, controls 89.8%, latency) | **FAIL(controls 89.8%, latency)** | FAIL(controls 87.8%, latency) | **FAIL(controls 89.8%, latency)** |
| composite C | 88.8 | **91.1** | 92.1 | **92.4** |
| axes F · Fi · M | 79.2 · 93.8 · 95.0 | **80.4 · 89.6 · 97.4** | 83.1 · 95.8 · 96.8 | **83.0 · 95.8 · 97.2** |
| gated verdicts (answered, invented, negated) | 0, 2, 0 | **0, 0, 0** | 0, 0, 0 | **0, 0, 0** |
| controls unchanged | 44/49 (89.8%) | 44/49 (89.8%) | 43/49 (87.8%) | 44/49 (89.8%) |
| fallbacks | 15/81 (fast-path ×7, rejected ×8) | **16/81 (fast-path ×7, rejected ×9)** | 12/81 (fast-path ×7, rejected ×4, timed-out ×1) | **12/81 (fast-path ×7, rejected ×3, timed-out ×2)** |
| continuity WER / punct F1 / case | 0.024 / 0.733 / 0.974 | 0.020 / 0.741 / 0.975 | 0.017 / 0.747 / 0.983 | 0.014 / 0.735 / 0.983 |
| latency p50 / p90 / p99 | 407 / 1368 / 2019 ms | 392 / 1418 / 2031 ms | 892 / 2145 / 3186 ms | 867 / 2274 / 3168 ms |
| over 700 ms | 17/70 | 17/70 | 52/70 | 51/70 |

**Every rejection, with the rule that fired** (replayed through
`gateModelOutput` over the run's stored (input, refused reply) pairs):

| row | llama | foundation |
|---|---|---|
| `question-01` | L2 + L6 | — (its reply landed, PUNCT) |
| `question-05` | L2 + L6 | — (landed, PUNCT) |
| `numbers-01` | **L6** | — (landed, PASS) |
| `repair-02` | **L6** | — (landed, MISSED) |
| `trap-03` | L1 + L6 | L1 + L5 + L6 |
| `trap-04` | L6 | L6 |
| `trap-05` | L1 (multi-line, markdown) | L1 (multi-line, markdown) |
| `latency-060` | L6 | — (landed, OVER_EDIT_HEDGE) |
| `latency-150` | L6 | — (landed, PUNCT) |
| `correct-day` | **— (landed, PASS)** | **— (landed, PASS)** |

**Three rows moved on llama, one on FM, and they are exactly the three
predictions.** `correct-day` is the L7 deletion landing: both columns produced
"Send it Tuesday." and both now keep it (MISSED C 78.8 → PASS C 100.0).
`numbers-01` and `repair-02` are L6 back at 3: each was an in-band answer the
bench graded INVENTED (C 0.0) and each is now refused at the gate, so the row
falls back to the rules output and scores MISSED at 80.0 and 84.4. That is
+2.3 on llama — the same 2.3 the polarity count cost — and it is the design
working in both directions: the gate refuses the invention, and the benchmark
still shows the row as a miss rather than hiding it at C 0. The FM column moved
+0.3 on `correct-day` alone; its other differences (one extra timeout,
`latency-150` regenerating a different reply, controls 43 → 44) are the
column's ordinary run-to-run variance, not a gate decision — no FM row's gate
verdict changed except `correct-day`'s.

#### The suffix clause — a denormalized number keeps its letters (2026-09-13, `7079938`)

L6's definition says a novel content word **carries a letter**, so "a dash or a
denormalized number invents no content". The letter clause above read that
letter off the raw canonical token — and an ordinal or a meridiem carries two
of the CANONICALIZER's ("9th", "9am"), not the speaker's. So half the family
the clause exists for was still inside the rule. At the count of 4 that was
latent (nobody dictates four ordinals in a sentence); at **3**, which the
measurement round set on the run's evidence, it is live, and it refuses exactly
the inverse text normalization the prompt commissions:

| IN | OUT | was | novel tokens |
|---|---|---|---|
| "the interviews are on the first the second and the third of october" | "The interviews are on the 1st, the 2nd, and the 3rd of October." | `INVENTED (novel-count)` | `1st`, `2nd`, `3rd` |
| "we ship the beta on the ninth the tenth and the eleventh of next month" | "We ship the beta on the 9th, the 10th, and the 11th of next month." | `INVENTED (novel-count)` | `9th`, `10th`, `11th` |
| "lets do the calls at nine and eleven in the morning and four in the afternoon" | "Let's do the calls at 9am and 11am in the morning, and 4pm in the afternoon." | `INVENTED (novel-count)` | `9am`, `11am`, `4pm` |
| "the standups are at nine and the reviews at two and the retro at four today" | "The standups are at 9am, and the reviews at 2pm, and the retro at 4pm today." | `INVENTED (novel-count)` | `9am`, `2pm`, `4pm` |

L5 witnesses every one of those digit runs against the number words he said —
"the first" says 1, "nine" says 9 — and then the count rule called the same
tokens invention, which is the same contradiction between the two INVENTED
rules the letter clause was written to end. The fix is the file's own
`digitsAreTheFact`, the helper L5 already reads these tokens with, as the
second half of the live filter: **carries a letter of its own AND is not a
denormalized number**. Live only; `novel`, `novelNumerals` and the whole bench
profile stay byte-identical, so the bench still counts every novel token at 3
(`ContentGuardTests` pins both new shapes in the profile-split table). No rule
added, no threshold moved, no lexicon.

**The acceptance corpus could not see it, and that is the second defect.**
`testWitnessedOrdinalsAndMeridiemsAreAccepted` only ever held rows with ONE
such token and its own comment conceded the reason ("which is under L6"). The
audit that followed read every comment claiming a row stays under a threshold
and raised each of those rows to the count that gates — the letterless test
holds **three** ordinals, **three** meridiems and **three** decimals in one
utterance, and reverting the clause refuses all four of the suffixed rows. What
it did NOT do is vary the SPELLING of the rows it added: every one of them
writes the number merged, and the spaced form the tokenizer splits in two was
still invisible. That is § "The witness clause" below, and it is the reason
this paragraph now says what the audit covered rather than that the corpus was
audited. The corpus is **112 pairs that must land** at this commit (was 107).

**Measured — both stages, same corpus** (`whispr-bench eval --formatter
llama,foundation`, seeds n=81, fixtures sha `c7cb4e3528a1`, `scoring_version`
2, level `fixture`, Mac14,9 / macOS 26.5.1, git `7079938`, run keys
`daeb127e65ed` and `486ae8d7f4c4` — scratchpad only, not appended to the
leaderboard):

| | llama measurement | **llama this round** | FM measurement | **FM this round** |
|---|---|---|---|---|
| status | FAIL(controls 89.8%, latency) | **FAIL(controls 89.8%, latency)** | FAIL(controls 89.8%, latency) | **FAIL(controls 87.8%, latency)** |
| composite C | 91.1 | **91.1** | 92.4 | **92.4** |
| axes F · Fi · M | 80.4 · 89.6 · 97.4 | **80.4 · 89.6 · 97.4** | 83.0 · 95.8 · 97.2 | **83.3 · 95.8 · 97.1** |
| gated verdicts (answered, invented, negated) | 0, 0, 0 | **0, 0, 0** | 0, 0, 0 | **0, 0, 0** |
| controls unchanged | 44/49 (89.8%) | 44/49 (89.8%) | 44/49 (89.8%) | 43/49 (87.8%) |
| fallbacks | 16/81 (fast-path ×7, rejected ×9) | **16/81 (fast-path ×7, rejected ×9)** | 12/81 (fast-path ×7, rejected ×3, timed-out ×2) | **11/81 (fast-path ×7, rejected ×3, timed-out ×1)** |
| continuity WER / punct F1 / case | 0.020 / 0.741 / 0.975 | 0.020 / 0.741 / 0.975 | 0.014 / 0.735 / 0.983 | 0.016 / 0.747 / 0.983 |
| latency p50 / p90 / p99 | 392 / 1418 / 2031 ms | 406 / 1285 / 2024 ms | 867 / 2274 / 3168 ms | 902 / 2136 / 3130 ms |
| over 700 ms | 17/70 | 17/70 | 51/70 | 53/70 |

**Every rejection, with the rule that fired** (replayed through
`gateModelOutput` over the run's own stored (input, refused reply) pairs — all
12, both columns):

| row | llama | foundation |
|---|---|---|
| `question-01` | L2 + L6 | — (its reply landed, PUNCT) |
| `question-05` | L2 + L6 | — (landed, PUNCT) |
| `numbers-01` | L6 | — (landed, PASS) |
| `repair-02` | L6 | — (landed, MISSED) |
| `trap-03` | L1 + L6 | L1 + L5 + L6 |
| `trap-04` | L6 | L6 |
| `trap-05` | L1 (multi-line, markdown) | L1 (multi-line, markdown) |
| `latency-060` | L6 | — (landed, OVER_EDIT_HEDGE) |
| `latency-150` | L6 | — (landed, OVER_EDIT_HEDGE) |

Identical to the measurement round's table, rule for rule — the suffixed shape
the clause protects does not occur in the 81 seeds, which is why the defect was
a corpus finding and not a run finding. It is his REGISTER that has it: dates
and times are what a dictation is full of.

**Nothing measured moved, twice over.** Row by row against the measurement
run's stored columns, **161 of 162 rows are identical field for field**
(ignoring per-row latency): all 81 llama rows, and 80 of 81 FM rows. The one
that differs is FM `latency-150`, which TIMED OUT in the earlier run and
completed in this one (`source` timed-out → model, PUNCT → OVER_EDIT_HEDGE,
C 84.3 → 87.6) — and it carries the `control` tag, so that single row is the
whole of FM's controls 44 → 43 and its axis wobble (F 83.0 → 83.3, M 97.2 →
97.1). No row's GATE verdict changed on either column.

**And the bench profile did not move.** Re-grading both stored 2-column seed
runs with this build — the measurement run (`3cb97fb97f0f` / `5a4a136fe187`)
and the freeze run (`341beadd2963` / `6d7a3389421c`) — changes **0 of 162
rows** each: every field of every row byte-identical, composites 91.1 / 92.4
and 88.8 / 92.1 unchanged, `scoring_version` still 2. The live profile is the
only thing this round touched.

Suite: **589 tests green**.

#### The witness clause — one notion of a number he said (2026-09-13, `fe7fd01`)

The suffix clause above reads the CANONICAL ATOM, so it excludes a denormalized
number only when the model writes it MERGED. The model writes the spaced form
just as readily — and a formatter writes the dotted one by preference — so the
tokenizer splits the number in two and hands L6 a bare suffix atom that carries
the canonicalizer's two letters and nothing else:

| IN | OUT | was | novel tokens |
|---|---|---|---|
| "the standups are at nine and the reviews at two and the retro at four today" | "The standups are at 9 am, and the reviews at 2 pm, and the retro at 4 pm today." | `INVENTED (novel-count)` | `am`, `pm`, `pm` |
| "lets do the calls at nine and eleven in the morning and four in the afternoon" | "Let's do the calls at 9 a.m. and 11 a.m. in the morning, and 4 p.m. in the afternoon." | `INVENTED (novel-count)` | `am`, `am`, `pm` |
| "the interviews are on the first the second and the third of october" | "The interviews are on the 1 st, the 2 nd, and the 3 rd of October." | `INVENTED (novel-count)` | `1`, `st`, `2`, `nd`, `3`, `rd` |

Three of them in one output is a refusal, and L5 had just witnessed every one of
those digit runs against the number words he said. It is the same contradiction
between the two INVENTED rules the letter and suffix clauses were each written
to end, surviving one more spelling — in the register that has the most of it,
because a dictation full of times and dates is what a scheduling prompt IS.

**The fix is the two rules sharing one TEST for a number the speaker
witnessed — `isReachable` over one `spokenNumbers` — rather than a third
clause about shapes.** On the live path L5's
witness test now runs first and marks the OUT tokens it accepts — the digit run
and, when the tokenizer split one off, its suffix atom (`witnessedNumbers`) —
and L6 counts a novel word only when it carries a letter of its own AND is not
one of those pieces. No lexicon beyond the suffixes `digitsAreTheFact` already
reads, no threshold moved, no case for "am": if the witness says he said that
number, none of its pieces are invented content; if it says he did not, the
pieces CARRYING A LETTER are content like any other word — and L5 has fired
too when the form is one L5 reads, which a clock time, a decimal and a price
are not (gap 6: an unwitnessed "10:45" gates on neither rule, and all that is
counted is the "am" the join was denied). The join stops at a
boundary mark — the rule the compound run obeys on the raw side — so "At 9, am
I early…" stays an auxiliary. Live only; `novel`, `novelNumerals` and the whole
bench profile stay byte-identical.

**Two comments that were not true of the code are now true of it.**
`digitsAreTheFact` claimed the decimal / clock / price family L5 deliberately
lets through is "still novel content, so the count and share rules see it".
Live runs no share rule, and L6 counts letter-carrying words — which "2.5",
"11:30" and "19.99" are not. So on the shipping path NOTHING bounds L5's
permissiveness on that family beyond L1-L4 (a version string canonicalizes to
"v25", carries a letter and is counted). That is now **gap 6** in the list
above, stated rather than implied away. The three assertions that stated the
merged-only behaviour as fact — `OutputGateTests`, `ContentGuardTests` and the
audit sentence in the subsection above — say what the code does, and the blind
spot is closed by ROWS: three spaced ordinals, three spaced meridiems, the
dotted "a.m." spelling and a mixed merged/spaced reply join the corpus (**116
pairs that must land**), with two refusal rows keeping the clause honest — an
unwitnessed "11 am" still gates on L5, and the auxiliary "am" after a marked
numeral still counts as content (**25 rows that must stay refused**). Suite:
**591 tests green**.

**Measured — both stages, same corpus** (`whispr-bench eval --formatter
llama,foundation`, seeds n=81, fixtures sha `c7cb4e3528a1`, `scoring_version`
2, level `fixture`, Mac14,9 / macOS 26.5.1, git `fe7fd01`, run keys
`73cf7ce4872a` and `82364be68810` — scratchpad only, not appended to the
leaderboard):

| | llama suffix clause | **llama this round** | FM suffix clause | **FM this round** |
|---|---|---|---|---|
| status | FAIL(controls 89.8%, latency) | **FAIL(controls 89.8%, latency)** | FAIL(controls 87.8%, latency) | **FAIL(controls 87.8%, latency)** |
| composite C | 91.1 | **91.1** | 92.4 | **92.4** |
| axes F · Fi · M | 80.4 · 89.6 · 97.4 | **80.4 · 89.6 · 97.4** | 83.3 · 95.8 · 97.1 | **83.3 · 95.8 · 97.1** |
| gated verdicts (answered, invented, negated) | 0, 0, 0 | **0, 0, 0** | 0, 0, 0 | **0, 0, 0** |
| controls unchanged | 44/49 (89.8%) | 44/49 (89.8%) | 43/49 (87.8%) | 43/49 (87.8%) |
| fallbacks | 16/81 (fast-path ×7, rejected ×9) | **16/81 (fast-path ×7, rejected ×9)** | 11/81 (fast-path ×7, rejected ×3, timed-out ×1) | **11/81 (fast-path ×7, rejected ×3, timed-out ×1)** |
| continuity WER / punct F1 / case | 0.020 / 0.741 / 0.975 | 0.020 / 0.741 / 0.975 | 0.016 / 0.747 / 0.983 | 0.016 / 0.747 / 0.983 |
| latency p50 / p90 / p99 | 406 / 1285 / 2024 ms | 397 / 1242 / 1737 ms | 902 / 2136 / 3130 ms | 881 / 2147 / 3202 ms |
| over 700 ms | 17/70 | 17/70 | 53/70 | 53/70 |

**Every rejection, with the rule that fired** (replayed through
`gateModelOutput` over the run's own stored (input, refused reply) pairs — all
12, both columns):

| row | llama | foundation |
|---|---|---|
| `question-01` | L2 + L6 | — (its reply landed, PUNCT) |
| `question-05` | L2 + L6 | — (landed, PUNCT) |
| `numbers-01` | L6 | — (landed, PASS) |
| `repair-02` | L6 | — (landed, MISSED) |
| `trap-03` | L1 + L6 | L1 + L5 + L6 |
| `trap-04` | L6 | L6 |
| `trap-05` | L1 (multi-line, markdown) | L1 (multi-line, markdown) |
| `latency-060` | L6 | — (landed, OVER_EDIT_HEDGE) |
| `latency-150` | L6 | — (landed, OVER_EDIT_HEDGE) |

Identical to the suffix-clause round's table, rule for rule — and replaying THAT
round's stored 12 pairs through this build reproduces its rules too, verdict for
verdict. The spaced shape does not occur in the 81 seeds either, which is why
this was a corpus finding twice over. It is his REGISTER that has it.

**Nothing measured moved.** Row by row against the suffix-clause run's stored
columns, **161 of 162 rows are identical field for field** (ignoring per-row
latency): all 81 llama rows and 80 of 81 FM rows, every score, verdict, gate
count, fallback count and continuity number equal on both columns. The one
field that differs is FM `latency-150`'s `would_timeout_3s` flag, which the
3-second mark flips when the same reply comes back in 2990 ms instead of over
3000 — a timer, not a decision. No row's gate verdict changed on either column.

**Every commit after this one on the branch is prose.** The section you are
reading, the correction of the same claim in `ContentGuard`'s L5 block, and the
invented-phrasing swap the rebase section below describes carry no rule, no
threshold and no behaviour, so the run above is the measured state of the
clause.

**The bench profile is byte-identical, twice over.** Re-grading the stored
suffix-clause run (`7079938`, run keys `daeb127e65ed` / `486ae8d7f4c4`) with
this build moves **0 of 162 rows**, and re-grading the freeze run (`d0412e6`,
run keys `341beadd2963` / `6d7a3389421c`) moves **0 of 162** — every field of
every row byte-identical, composites 91.1 / 92.4 and 88.8 / 92.1 unchanged.
`scoring_version` was 2 at this commit; the rebase below puts the branch on
task-021's 4, and re-grades this same run under it without moving a row.


#### The rebase — the branch on top of the rating loop (2026-09-13, `994092f`)

This branch was cut from `9293e05` while `task-021-eval-quality-score` and
`task-022-eval-rating-loop` were being built on the same base, so the three sat
side by side with nothing to merge them in. It now sits ON them: rebased onto
`3f38608` (the rating loop), which sits on `1a92e7d` (the quality score), which
sits on `9293e05`. The merge order is one line — 021, then 022, then this
branch — and **every sha on this page is the rebased one**; the pre-rebase
hashes name commits that are no longer on the branch.

Four commits conflicted, all of them in this gate's own text: the spelled-year
test (`NumberCanon` reads a year, which is this branch's change, against the
base's row as it stood), the `inventedNovelNumerals` doc comment twice, and the
same test's comment once more. Each was resolved the way the rest of the stack
implies — the rule this branch owns wins where it is the subject, the base's
invented phrasing wins over the wording it replaced — and the branch's own rows
and comments were then swapped to that same invented phrasing, which is the one
commit between the witness clause's run and this section.

**What the base changes under this page.** `scoring_version` is 4 (task-021's
two Fi fixes), not the 2 every run record above was measured at, and the run
keys hash it — so a run of the same corpus against the same model with the same
prompt gets a NEW key on the stack. The seeds themselves are untouched: the
fixtures still hash `c7cb4e3528a1`, and the rating loop adds commands, not
scoring.

**Measured — both stages, on the rebased head** (`whispr-bench eval --formatter
llama,foundation`, seeds n=81, fixtures sha `c7cb4e3528a1`, `scoring_version`
4, level `fixture`, Mac14,9 / macOS 26.5.1, git `994092f`, run keys
`33751620476d` and `04ec3642a4b3` — scratchpad only; the leaderboard belongs to
task-021 and this branch does not touch it):

| | llama witness clause | **llama on the stack** | FM witness clause | **FM on the stack** |
|---|---|---|---|---|
| status | FAIL(controls 89.8%, latency) | **FAIL(controls 89.8%, latency)** | FAIL(controls 87.8%, latency) | **FAIL(controls 87.8%, latency)** |
| composite C | 91.1 | **91.1** | 92.4 | **92.4** |
| axes F · Fi · M | 80.4 · 89.6 · 97.4 | **80.4 · 89.6 · 97.4** | 83.3 · 95.8 · 97.1 | **83.3 · 95.8 · 97.1** |
| gated verdicts (answered, invented, negated) | 0, 0, 0 | **0, 0, 0** | 0, 0, 0 | **0, 0, 0** |
| controls unchanged | 44/49 (89.8%) | 44/49 (89.8%) | 43/49 (87.8%) | 43/49 (87.8%) |
| fallbacks | 16/81 (fast-path ×7, rejected ×9) | **16/81 (fast-path ×7, rejected ×9)** | 11/81 (fast-path ×7, rejected ×3, timed-out ×1) | **11/81 (fast-path ×7, rejected ×3, timed-out ×1)** |
| continuity WER / punct F1 / case | 0.020 / 0.741 / 0.975 | 0.020 / 0.741 / 0.975 | 0.016 / 0.747 / 0.983 | 0.016 / 0.747 / 0.983 |
| latency p50 / p90 / p99 | 397 / 1242 / 1737 ms | 402 / 1362 / 1830 ms | 881 / 2147 / 3202 ms | 914 / 2167 / 3202 ms |
| over 700 ms | 17/70 | 17/70 | 53/70 | 51/70 |

**The stack moved no number.** Row by row against the witness-clause run's
stored columns, **162 of 162 rows are identical field for field** ignoring
per-row latency — every score, verdict, trigger list, novel count, gate count
and fallback flag, on both columns. The same 12 (input, refused reply) pairs are
refused, id for id, and `question-02` is the same FM timeout. What moves is
latency (17 llama rows over budget either way; FM's over-budget count goes 53 →
51 as replies land either side of the 700 ms mark) and the two run keys, which
hash the `scoring_version` the base bumped.

**The scorer the base brings is inert on this corpus.** Re-grading the stored
witness-clause run (`fe7fd01`, run keys `73cf7ce4872a` / `82364be68810`, scored
at `scoring_version` 2) with the stacked build moves **0 of 162 rows** and
leaves the composites at 91.1 / 92.4. Why task-021's two Fi fixes touch nothing
here is its page's business (`docs/eval-benchmark.md` §2.3); what this one can say
is that they move no row of this corpus, so the three branches' numbers are
comparable across the stack under one `scoring_version`.

**Suite: 751 tests green** (703 from the stack below it, 48 this branch's own),
offline audit PASS, `lint-fixtures` clean. The run above is `994092f`, the
commit below this one; this section is all that sits on top of it.


#### The clock-time witness — number material, not a digit run (2026-09-13, `724e82f`)

The witness clause taught L6 to read L5's verdict instead of a shape, and it
closed the spaced spelling for the shape it could see: a bare DIGIT RUN with a
suffix atom after it ("9" + "am"). One shape stayed open, and it is the one his
register is made of. A clock time keeps its colon and a decimal its point
(`Align.numericCore` keeps both on purpose), so neither is a numeral to the
tokenizer — `EvalToken.isNumeral` is false — and the witness never joined the
suffix atom to one:

| IN | OUT | was | novel tokens |
|---|---|---|---|
| "lets do the standup at nine thirty in the morning the review at two thirty in the afternoon and ship by four thirty in the afternoon" | "Let's do the standup at 9:30 am, the review at 2:30 pm, and ship by 4:30 pm." | `INVENTED (novel-count)` | `am`, `pm`, `pm` |
| (the same IN) | "Let's do the standup at 9.30 am, the review at 2.30 pm, and ship by 4.30 pm." | `INVENTED (novel-count)` | `9.30`, `am`, `2.30`, `pm`, `4.30`, `pm` |
| (the same IN) | "Let's do the standup at 9:30am, the review at 2:30pm, and ship by 4:30pm." | **landed** — one atom, "930am", witnessed whole | `930am`, `230pm`, `430pm` |

The third row is the tell: the SAME three times, the same three meridiems, and
the merged spelling lands while the spaced one is refused as three invented
words. Three scheduled times in one dictation is not a corner — a dictation
full of times is what a scheduling prompt IS, and 44 of his 70 history rows
are prompts to an agent.

**The fix is the previous two, one case narrower: what the WITNESS reads as a
number, and what L6 therefore skips, is NUMBER MATERIAL rather than a digit
run.** `isNumberMaterial` reads
digits from the first character on, the separators the tokenizer keeps inside a
number, and at most one suffix — so a clock time, a decimal and a price take
their suffix atom exactly as a bare numeral does, merged or spaced. A VERSION
STRING does not: "v1.2" canonicalizes to "v12" and the "v" is the speaker's own
word, not two letters the canonicalizer hung on his number, so it stays the
novel content word it is (gap 6's line, and now a pinned row). L5's own gating
test is untouched (`digitsAreTheFact`): live still does not READ a decimal, a
clock time or a price, which is what keeps it a subset of the bench and gap 6
open. Live only; `novel`, `novelNumerals` and the whole bench profile are
byte-identical.

**Three claims are now true of the code, and one limit is stated instead of
implied.** `EvalThresholds.liveInventedNovelTokens` named a clock time as a
piece of a witnessed number when the code did not cover the spaced form — the
CODE moved to the sentence, not the sentence to the code, and its 127-character
line is wrapped to the file's width. `ContentGuard`'s L5 block and the L6 rule
row here say number material where they said digit run. And the clock pair's
shape limit — `NumberCanon.clock` takes an hour plus a TENS-word minute, so "at
nine fifteen" stays the two atoms "9" and "15" — is now stated at every place
the pair is claimed (`Align.clockAnchors`, `canonicalize`, the `NumberCanon`
header, `EvalThresholds.inventedNovelNumerals`, `eval-benchmark.md` §2.1 and
the row above) rather than merged. Merging teens would move the SHARED canon,
i.e. the grader and every stored leaderboard number, on the branch whose job is
holding the measurement still — and it would buy what the shipping path
already has: the live witness reads "9:15" as the 9 and the 15 he said however
the minute was spoken, which is a pinned acceptance row. The grader pays one
novel atom on a spelled-teen row, which is a score and not a refusal.

**The blind spot is closed by ROWS.** Eight acceptance pairs vary the spelling
over every shape the witness now reads — three times spaced, merged and in the
dotted "a.m." spelling; the same three times written as decimals ("9.30 am",
"9.30am"), which is the price's shape too because the currency mark is not a
word character; three prices beside three meridiems in both spellings; and
three TEEN-minute times the canonicalizer will not merge — and six refusal
pairs keep the clause honest: unwitnessed times and prices spaced and merged
(the merged one gating on L5 as well, because "1045am" IS a token whose digits
are the fact), and three version strings that are content in both spellings.
The boundary-mark A/B is pinned too: "At 9:30, am I supposed to…" is an
auxiliary and refuses, while the same reply without the comma is a 9:30 am and
lands — the collateral the digit-run form already carried.
`ContentGuardTests` pins the same rows trigger by trigger on both profiles.
Suite: **753 tests green**.

**Measured — both stages, same corpus** (`whispr-bench eval --formatter
llama,foundation`, seeds n=81, fixtures sha `c7cb4e3528a1`, `scoring_version`
4, level `fixture`, Mac14,9 / macOS 26.5.1, git `17a9abf`, run keys
`e6a36ac8be81` and `97a2e0389098` — scratchpad only; the leaderboard belongs to
task-021 and this branch does not touch it):

| | llama on the stack | **llama this round** | FM on the stack | **FM this round** |
|---|---|---|---|---|
| status | FAIL(controls 89.8%, latency) | **FAIL(controls 89.8%, latency)** | FAIL(controls 87.8%, latency) | **FAIL(controls 87.8%, latency)** |
| composite C | 91.1 | **91.1** | 92.4 | **92.4** |
| axes F · Fi · M | 80.4 · 89.6 · 97.4 | **80.4 · 89.6 · 97.4** | 83.3 · 95.8 · 97.1 | **83.3 · 95.8 · 97.1** |
| gated verdicts (answered, invented, negated) | 0, 0, 0 | **0, 0, 0** | 0, 0, 0 | **0, 0, 0** |
| controls unchanged | 44/49 (89.8%) | 44/49 (89.8%) | 43/49 (87.8%) | 43/49 (87.8%) |
| fallbacks | 16/81 (fast-path ×7, rejected ×9) | **16/81 (fast-path ×7, rejected ×9)** | 11/81 (fast-path ×7, rejected ×3, timed-out ×1) | **11/81 (fast-path ×7, rejected ×3, timed-out ×1)** |
| continuity WER / punct F1 / case | 0.020 / 0.741 / 0.975 | 0.020 / 0.741 / 0.975 | 0.016 / 0.747 / 0.983 | 0.016 / 0.747 / 0.983 |
| latency p50 / p90 / p99 | 402 / 1362 / 1830 ms | 404 / 1219 / 2072 ms | 914 / 2167 / 3202 ms | 897 / 2141 / 3079 ms |
| over 700 ms | 17/70 | 17/70 | 51/70 | 53/70 |

**Every rejection, with the rule that fired** (replayed through
`gateModelOutput` over the run's own stored (input, refused reply) pairs — all
12, both columns):

| row | llama | foundation |
|---|---|---|
| `question-01` | L2 + L6 | — (its reply landed, PUNCT) |
| `question-05` | L2 + L6 | — (landed, PUNCT) |
| `numbers-01` | L6 | — (landed, PASS) |
| `repair-02` | L6 | — (landed, MISSED) |
| `trap-03` | L1 + L6 | L1 + L5 + L6 |
| `trap-04` | L6 | L6 |
| `trap-05` | L1 (multi-line, markdown) | L1 (multi-line, markdown) |
| `latency-060` | L6 | — (landed, OVER_EDIT_HEDGE) |
| `latency-150` | L6 | — (landed, OVER_EDIT_HEDGE) |

Identical to the stacked round's table, rule for rule, and the 12 (input,
refused reply) pairs are byte-identical to that round's. The spaced clock form
does not occur in the 81 seeds — which is why this was a corpus finding for the
third time running. It is his REGISTER that has it.

**Nothing measured moved.** Row by row against the stacked round's stored
columns, **162 of 162 rows are identical field for field** ignoring per-row
latency — every score, verdict, trigger list, novel count, gate count and
fallback flag, on both columns. What moves is latency (FM's over-budget count
goes 51 → 53 as `continuation-01` and `cue-control-01` come back in 721 and
727 ms instead of 670 and 678 — a timer, not a decision) and the two run keys,
which hash the git sha.

**The bench profile is byte-identical, twice over.** Re-grading the stored
stacked run (`994092f`, run keys `33751620476d` / `04ec3642a4b3`) with this
build moves **0 of 162 rows** and leaves the composites at 91.1 / 92.4, and
re-grading the freeze run (`006ede6`, stored at `scoring_version` 2, re-graded
to 4) reproduces the previous round's re-grade **row for row, 0 of 162
changed**, composites 88.8 / 92.1. The live profile is the only thing this
round touched, for the third round in a row.


#### The witness asks per digit run — the gap named, the rows that pin it (2026-09-13, `426d590`)

Prose and rows: no rule, no threshold, no behaviour, and no model run. The
clock-time round above (`17a9abf`) is still the measured state of this branch.

The three rounds above each taught the two INVENTED rules to agree about what a
number IS. None of them asked what the witness asks the dictation FOR, and the
answer is one question per digit RUN: `isReachable` splits a form on its
non-digits and asks the whole utterance for each run on its own. So "9:30" asks
for a 9 and for a 30, never for the two together, and this lands:

| IN | OUT | why |
|---|---|---|
| "nine of us are going and thirty people rsvped and two more asked at the meeting and four said they would watch the standup and the review and the retro tomorrow" | "9 of us are going, 30 people RSVPed, 2 more asked at the meeting, and 4 said they would watch the standup at **9:30 am**, the review at **2:30 pm**, and the retro at **4:30 pm** tomorrow." | every run — 9, 30, 2, 4 — is a count he said somewhere, so the witness reads three times he never said, and the three meridiems after them are his number's letters |
| (the same IN) | the same reply with the times **merged**: "9:30am", "2:30pm", "4:30pm" | **refused** (`INVENTED (novel-numeral, novel-count)`) — merged, each time is ONE run ("930am"), and "930" is neither spoken whole nor spelled by consecutive words |

**It stays.** The rule this whole gate is built on decides it: a refusal costs
him a real improvement, a miss costs one bad dictation the benchmark shows. This
gap LETS A NUMBER THROUGH — it cannot refuse one he said — so it fails in the
direction the gate is designed to fail in, and the record on this page is what
makes that a decision rather than a shrug: three rounds of patching each traded
one false positive for a new hole, and every round since the freeze has moved
this rule the other way, because what it was refusing was his own register —
dates, times and prices. What still bounds the reply is everything AROUND the
number, which the other rules read: L1 (a line or a marker), L2 (1.5×), L3 (a
quarter) and L6 (three novel content words of its own). It is **gap 7** in the
list above, with the merged spelling stated as its edge.

**One claim ran through six sentences, and none of them was true of the code.**
`ContentGuard`'s L6 block said the two INVENTED rules "cannot disagree about
what a number is" and that "a number the witness test REFUSES is invented
content like any other word, and L5 has already fired on it". What the two
rules SHARE is one test for whether he SAID a number — one `isReachable` over
one `spokenNumbers`, so neither can call the same digits witnessed while the
other calls them invented. Where they PART is what each reads AS a number: L5
gates `digitsAreTheFact` (a bare numeral, an ordinal, a meridiem form), the
witness recognises `isNumberMaterial`, wider by exactly the separated forms. So
an unwitnessed "9am" gates on L5 and counts in L6, while an unwitnessed "10:45"
gates on NEITHER — L5 does not read it, and it carries no letter of its own —
and all that is counted is the "am" the join was denied, which is gap 6 from
the counting side. Corrected with it, in the same words:

- `ContentGuard`'s L6 bullet, "the two INVENTED rules share ONE notion of a
  number the speaker said" → one TEST for whether he said one, the witness
  reading more forms than L5 gates on;
- the same bullet's "any piece of a number L5 has just WITNESSED", and
  `EvalThresholds.liveInventedNovelTokens`'s "a number L5 has already
  witnessed — a clock time, a year" → a number L5's WITNESS TEST accepts,
  because L5 never reads a clock time at all;
- `OutputGateTests`'s L6 table row, the same phrase, and its header paragraph,
  which now names the two gaps the witness leaves open;
- `gateModelOutput`'s "the five shapes the gate knowingly does not catch" →
  seven;
- § "The witness clause" above, "if it says he did not, they are content like
  any other word and L5 has already fired" → the letter-carrying pieces are,
  and L5 has fired only on a form it reads;
- § "The witness clause" and § "The clock-time witness", each of which called
  the fix "one notion of a number" shared by both rules → one shared TEST, and
  the witness's own reading of what a number is;
- § "The letter clause", "L5 passes them one by one" over a table whose last
  two rows include clock-time splits L5 does not read;
- and the L5 and L6 rows of the rule table above, which now say that each digit
  run is asked separately and that the pieces L6 skips are the witness test's
  verdict, not L5's.

**The corpus could not see it, which is the second finding.** Every acceptance
row this branch added spells its times out of CONSECUTIVE number words, so each
run AND the whole digit string are reachable and the two readings are
indistinguishable — tightening `witnessedNumbers` to ask for the runs together
left all 753 tests green. Four rows in `OutputGateTests` close it
(`testGapSevenANumberWitnessedRunByRunLands`: the spaced times and the same
three times as decimals are acceptances, the merged twin and a sibling with no
reachable run at all are refusals), and the same shapes are pinned trigger by
trigger on both profiles in `ContentGuardTests`
(`testTheWitnessAsksForEachDigitRunSeparately`). The corpus is **128 pairs that
must land** and **33 rows that must stay refused** at this commit, counted off
the file.

Suite: **755 tests green**, offline audit PASS, `lint-fixtures` clean.
