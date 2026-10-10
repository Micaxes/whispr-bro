# The dictation quality benchmark (`whispr-bench eval`)

Plan of record: `dev/plans/whispr-bro-eval-benchmark.md` (this doc is its
contract in the repo — formulas, schema, CLI, and the validation/calibration
plan the human rating loop fulfils). See also
[`docs/llm-measurement-gate.md`](llm-measurement-gate.md) for how the model
stage itself was chosen and hardened; this doc covers the harness that grades
any of it.

**What it is**: a deterministic, zero-network Swift scorer in `whispr-bench`
that grades any formatter (rules / Qwen / Apple FM / the shipped binary / any
text file) against fixtures where the gold text is the annotation. Three
sub-scores per fixture, 0–100 — **F** auto-formatting, **Fi** filler removal,
**M** meaning — blended into a composite **C**, forced to 0 on any hard-fail
gate (a formatter that answers a question or invents a fact does not get a
partial-credit score). Ground truth is the maintainer: golds and annotations
come only from his rating loop (§6 below), never from an export, so the
harness can never grade a model against its own output.

Everything scored lives in `Sources/WhisprBroCore/Eval/` and is pinned by
XCTest (`Tests/WhisprBroCoreTests/`); `whispr-bench` (invisible to XCTest) is
thin glue — flag parsing, file I/O, the git/machine identity — around it.

---

## 1. Fixture schema (`EvalCase` v2)

Backward compatible: today's `{id, raw, gold, note?, audio?}` decodes
unchanged; unknown keys are ignored; every new field is optional with a
derived default. **Gold is the annotation** — alignment against gold catches
over-edits (deletions) and invention (novel tokens) with no hand-authored
spans; new fields exist only for what gold cannot express.

| Field | Type / default | Semantics |
|---|---|---|
| `id`, `raw`, `gold`, `note`, `audio` | v1 | `raw` = post-dictionary verbatim (`HistoryRecord.rawText`); `gold` = the ideal paste. `gold: ""` with non-empty `raw` = **gold-free fixture** (unrated; only the raw↔out gates score it). `audio` stays reserved. |
| `golds` | `[String]`, `[]` | alternate acceptable golds; the scorer uses the best-matching one (highest `C_i`). |
| `tags` | `[String]`, `[]` | free labels; the seed set uses the 14 R3 failure classes; `by_tag` aggregation and `--tag` filter key off them. |
| `register` | `AppCategory` raw value, `"unknown"` | bench uses `StyleRules().directive(for:)` and mirrors `PipelineController` (verbatim categories: no strip, no correction clause). |
| `level` | `"fillers" \| "standard"`, `"standard"` | bench appends `correctionClause` and passes `resolveCorrections` only at `standard`. |
| `language` | `"en"` | selects `FillerStripper.coreFillers(for:)`; Italian/Spanish are a follow-up. |
| `control` | `Bool`, derived: `true` iff `gold == raw` modulo scored marks and case | pass-through fixture; any word-level S/D/I is a failure; run gate `controls_unchanged_pct` counts them. |
| `fillers` | `[{"span","occurrence"}]`, `null` | `null` → derived: `coreFillers(for: language)` occurrences in `raw` deleted in the raw↔gold alignment; `[]` disables derivation; explicit list overrides. |
| `stutters` | `[{"span","keep"}]`, `null` | `null` → derived: maximal runs of ≥2 identical adjacent `stutterCollapsible` words in `raw` that do not survive in `gold`; explicit spans for content-word doubles and non-identical runs. |
| `repairs` | `[{"reparandum","repair","resolve_at"}]`, `[]` | scored only when the run level == `resolve_at` (default `"standard"`). |
| `must_keep` | `[{"span","weight"}]` or `[String]`, `[]` | punct/case-blind contiguous token subsequence that must appear in the output; weight 2 = hedge/stance (default), 5 = fact. Strings decode as weight 2. |
| `alternates` | `[{"from","to":[…]}]`, `[]` | surface forms that are not novel (hyphenation, ITN spellings). Cardinal numbers are canonicalized without annotation. |
| `max_ms` | `Int`, by length (≤15 words 300; ≤60 700; else 1500) | per-fixture latency budget for the report; the run gate uses `--budget-ms` instead. |
| `source` | `"synthetic" \| "history:<rowid>"` | `lint --repo-guard` refuses any `history:` source under the repo tree. |
| `gold_source` | `"seed" \| "history-unrated" \| "ship:<run_key>:<formatter>" \| "edit" \| "draft:<author>"` | provenance of the gold. The `draft:` form is a dispatcher addition (D1, below) for a gold written ahead of a rating session. |
| `annotations_status` | `"confirmed" \| "draft"` | drafts come from `whispr-bench gold` (or an agent, under `draft:<author>`); `lint` warns; **drafts are scored in the composite** (D1) but never counted in `rated_n`; the `unrated` tag drops and the status flips on confirm. |
| `observed`, `observed_ms` | `String?`, `Int?` | what the shipped binary produced (`HistoryRecord.formattedText`, `formatMs`); scored by `--formatter shipped`. Never used as gold. |

Deliberately absent: `entities`, `numbers`, `no_new_content`, `must_not_answer`,
`terminal` — gold plus the novel-token rule covers them, and every field is
one more thing to hand-maintain. `terminal` is read off gold's last mark
(fragments: gold has none).

`whispr-bench lint` has three tiers, and each one is a different kind of
claim about a fixture.

**Errors** are structural — decidable from the text, tie-break free — and
they are the only findings that block a write: any `fillers` / `stutters` /
`repairs.reparandum` / `must_keep` span not found in `raw`; a `must_keep`
span or a `repairs.repair` absent from **every** acceptable gold (`[gold] +
golds`, since the scorer keeps the best of them); a numeric atom in `gold` ∉
canon(`raw`) ∪ `alternates`; `control: true` with word-level S/D/I between
raw and gold; a `stutters.keep` that is not an in-order subsequence of its
span; an empty `golds[i]`; duplicate ids; plus the set-level floors under
`--floors`.

**The invariant** (§9) is the consistency check between an annotation and its
gold, and it is not hand-written: **the primary gold must score 100 against
itself.** Lint runs the scorer with hypothesis = gold against that gold alone
— no best-of, so a generous alternate can never mask a primary gold that
contradicts its own annotations — and errors when F, Fi, M or C comes back
under 100, quoting the scorer's own numbers, verdict and misses:

```
gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 [MISSED] — Fi missed 'the the'
```

Every contradiction surfaces on the axis it would have corrupted: a filler
the gold retains on Fi, a dropped `must_keep` or a repair left standing on M,
a gate on C. The check therefore cannot drift from the scorer — it *is* the
scorer — and nothing else in `lint` reasons about occurrences, alternate
golds or unnamed copies. (Fi is not part of the claim where the fixture
expects no removal or the register is verbatim; the scorer leaves it
undefined and lint prints `—`.)

**Warnings** never block: a core filler that an acceptable gold retains and
no annotation mentions — asked of an explicit `fillers` list exactly as of a
derived one, because `fillers: []` is a legitimate "he keeps it on purpose"
and the invariant is what decides whether the gold still scores; a draft gold
(`annotations_status: draft`); and anything the invariant flags on an
**alternate** gold rather than the primary one. So a fixture whose annotation
only an alternate reads the same way warns, while the primary gold is still
held to 100.

Deliberately not rules: the hand-written annotation-vs-gold checks that used
to live here — per-occurrence arbitration, "the copies an explicit list does
not name must survive in gold", and the union of every gold's reading. Each
re-derived what the scorer already computes, each grew an exception per
fixture shape, and each broke on a real fixture set. The invariant replaces
all three.

`--floors` (seeds only): controls ≥ 15%,
fixtures ≥ 60 words ≥ 20%, fixtures ≥ 30 words ≥ 40%, `agent-prompt`-tagged ≥
60%, one-word ≤ 10%. `--repo-guard`: refuses `history:` sources and `observed`
fields inside the repo tree. The fixture-set hash is SHA-256 of the canonical
(sorted-keys, no-whitespace) JSON — order-invariant.

The format bench's fixtures (`docs/eval/formatting.json`,
docs/formatting-benchmark.md) are not `EvalCase`s and get a lint of their
own, `FormatLint`: their golds are layout — lists, line breaks, quotation
marks — which `ContentGuard` L1 gates by design, so the invariant above can
never hold for them, and the rules are the format bench's instead (unique
ids, non-empty `raw` and `gold`, a tag to report under, a `register` and a
`policy` it reads). Which lint a file gets is declared, never sniffed from
its rows: `lint` sends a path that is one of `FormatFixture.repoPaths` in
its git checkout to `FormatLint` and everything else — including a format
file at an undeclared path, which then fails loudly — to the eval lint;
`--format` lints any given path as a format file. The checkout is the
nearest `.git` above the file (`Leaderboard.gitRoot`), not the nearest
`Package.swift` the repo-tree refusals also accept: a manifest can be
committed under `docs/` and would re-root the declared path under itself,
a `.git` cannot (git refuses the path component), and the walk reads a
`.git` with git's own test (`Leaderboard.isGitRepository`: a directory whose
`HEAD` git can read — `ref: refs/…` or an object id — with `objects` and
`refs` beside it, in the `commondir` for a worktree's, or a `gitdir:` file
pointing at such a directory). For the shapes git makes, then — a clone's
`.git`, a worktree's or a submodule's gitfile — a nested one is a nested
repository whose files `git ls-files` never lists, and one git does not
recognise — a directory made by hand or with an empty `HEAD`, a `gitdir:`
pointing at nothing — is a plain entry of the checkout above, to git and to
the routing alike. Hand-made shapes can still part the two, on a local disk
only — e.g. a `gitdir:` or `commondir` reached through a symlink and `..`,
an unreadable gitfile or `commondir`, a repository initialised over files
the outer checkout tracks. No commit can carry a `.git`, so CI's fresh
checkout holds none, and the repo guard runs on whichever lint a file is
routed to. Where no ancestor is a git repository at all — a `git archive`
export, a tarball — the rail refuses to run (`scripts/lint-fixtures.sh`
needs git to list the tree), and the nearest `Package.swift` or `.git`
(`Leaderboard.checkoutRoot`, the refusals' anchor) is the checkout instead,
so the declared file is still the format bench's there. The repo guard is
the same (`EvalLint.guardExportFields`) under both.

---

## 2. Metrics

### 2.1 Shared alignment core (`Align.swift`)

- **Tokenizer**: whitespace split, boundary marks peeled (`. , ! ? ; : ¿ ¡`
  scored; other symbols such as `+ = * #` are orphan marks and dropped),
  lowercased word core = normal form. Hyphenated tokens keep the hyphen; a
  hyphenated output token whose hyphen-split parts all occur in raw is not
  novel, and neither is one whose APOSTROPHES strip to a raw word —
  dictation says `dont`, the formatter writes `don't`, and both spellings
  are one word to the novelty vocabulary (`Align.unapostrophized`).
- **Number canonicalization**: consecutive number-word tokens and
  hyphenated number words collapse to one numeric atom (`fifty four`,
  `fifty-four`, `54` → `54`; `twenty six K`, `26K` → `26000`; `two
  hundred`, `1,200` → integers), plus the three non-cardinal forms dictation
  produces (task-023): year pairs (`twenty twenty six` → `2026`, `nineteen
  ninety five` → `1995`), decimal "point" runs (`one point five` → `1.5`,
  the scale word left standing: `1.5` `million`) and clock pairs after a
  temporal anchor (`at two thirty` → `2:30`, an hour plus a TENS-word
  minute). Every well-formedness guard
  holds — a mark breaks a run, a list never sums. Applied to raw, gold, and
  output before novelty and must-keep matching — the shipped column has no
  gold, so "26" from "twenty six" and "2026" from "twenty twenty six" must
  never read as invented numerals. Still uncovered and left to `alternates`:
  ordinals, month names, "oh"-infixed years ("nineteen oh five"), fractions
  without "point".
- **The clock pair's two guards.** The anchor set is `{at, by, until,
  till}`, and an anchored pair whose NEXT word is a time-unit noun
  (`second(s)`, `minute(s)`, `hour(s)`, `day(s)`, `week(s)`, `month(s)`,
  `year(s)`) is read back as cardinals. Both exist because the merge
  changes the RAW atom set: `before two forty minute sessions` merged to the
  single atom `2:40`, so the correct output `2 40-minute sessions` read as
  invented content and the live gate refused it. `after` / `before` /
  `around` / `from` head a count at least as often as a time, so they are
  not anchors; `at three thirty minute rounds` stays `3` `30` `minute`
  `rounds`. The residual ambiguity is an anchored pair with no time-unit
  noun behind it (`at three thirty sharp` is a time, `by four twenty each`
  would not be) — narrow enough to name, and pinned in `AlignTests`. The
  SHAPE is a third limit, on top of the two guards: the minute must be a
  tens word, so `at nine fifteen` stays `9` `15`. A teen minute heads a
  count as readily (`three fifteen minute breaks`), and merging it would
  move this shared canon — i.e. the grader and every stored leaderboard
  number — to buy something the shipping path already has: the live
  witness reads `9:15` as the 9 and the 15 he said, whichever way the
  minute was spoken (`OutputGateTests`).
- **Deviation from plan §4.1**, stated here rather than implied: §4.1 scopes
  canonicalization to cardinals and rejects a typed date/time canonicalizer
  as a maintenance sink. The three forms above live in the SHARED canon, so
  they move the GRADER as well as the live gate. No seed exercises them — 0
  of 81 raws carries a spelled year, decimal or clock pair (the three seeds
  that show a digit form get it from the raw, already as digits) — so a
  bench run can neither confirm nor refute them; they are pinned by hand
  count in `AlignTests` and by the acceptance corpus in `OutputGateTests`
  instead. A seed fixture carrying the three shapes was considered and NOT
  added: it changes the fixtures sha, and the leaderboard baseline
  (`ab5355e`) and every column measured against it would stop being
  comparable mid-branch. It belongs to a corpus-growth step, with a
  re-baselined leaderboard row.
- **`align(a, b)`**: Levenshtein on normal forms, returning the op list
  `[.hit(i,j) | .sub(i,j) | .del(i) | .ins(j)]` and counts `H, S, D, I`.
  Sub-ops prefer equal-canonical tokens (`fifty-four` ↔ `54` is a hit).
- Two alignments per gold-scored fixture: **gold↔out** (F, M) and **raw↔out**
  (Fi, gates). Gold-free fixtures use raw↔out only. `lint` uses raw↔gold.
- **Span match**: a span is present in a text iff its normalized
  (canonicalized) tokens occur as a contiguous subsequence; `occurrence`
  disambiguates repeats.
- `STOP = {a, an, the, and, or, to, of, in, on, for, is, are, it, that, this}`.
  `NEG = {not, never, no, none, nothing, nobody, nowhere, cannot} ∪ {tokens
  ending in "n't"} ∪ {the same contractions unapostrophized — `dont`,
  `cant`, `mustnt`, … — the form dictation produces}`. The restoration
  direction needs no lexicon: an out token that is a raw token with an
  apostrophe inserted before a terminal "t" is a formatting fix, never an
  inserted negation (`Align.isApostropheRestored`).

### 2.2 F — auto-formatting (0–100, gold-scored)

On gold↔out `.hit` pairs:

| Component | w | Formula |
|---|---|---|
| **P** punctuation | 0.5 | per-class F1 over mark classes `comma {,}`, `stop {. ! ; : ¡}`, `question {? ¿}`; per class TP = Σ over hit pairs of min(gold count, out count); marks on deleted gold words are FN, on inserted out words FP; **macro-F1 over classes present in gold ∪ out** (a class absent from both is skipped) |
| **C** casing | 0.3 | accuracy over hit pairs **excluding sentence-initial gold positions** (first gold word and any word after a `stop`/`question` mark); `c_initial` reported separately, never scored |
| **T** terminal | 0.2 | 1 if last scored mark of out == last scored mark of gold (`none` == `none` for fragments), else 0 |

`F = 100 × Σ w·comp / Σ w(present)`; a component is absent when its
denominator is 0 (e.g. no non-initial hit words). The pre-existing micro
`wer` / `punctF1` / `caseAccuracy` (`TranscriptScore`) stay as the continuity
line.

Hand-counted (`QualityScoreTests.swift`):

| gold | out | P | C | T | F |
|---|---|---|---|---|---|
| `Okay, we ship it. Do you agree?` | `Okay we ship it. Do you agree?` | comma 0, stop 1, question 1 → 0.667 | 1 | 1 | **83.3** |
| `Push the fix to Zephyrnet.` | `push the fix to zephyrnet.` | 1 | 3/4 (zephyrnet) = 0.75; `c_initial` 0/1 | 1 | **92.5** |
| `Okay, and the` (fragment) | `Okay, and the.` | comma 1, stop F1 0 → 0.5 | 1 | 0 | **55.0** |
| `Meet on Wednesday.` | `Meet on Wednesday.` | 1 | 1 | 1 | **100** |

### 2.3 Fi — filler removal (0–100)

> Build amendment 2026-09-13 (the plan's §4.3 predates it): what a span is
> expected to leave standing follows the span's **provenance** — a derived
> span is read off the gold, an explicit one off its own annotation — and a
> **gold-free** row, having no gold to read, carries one entitlement per span,
> so a shortfall charges only the spans it leaves short. `scoring_version` 4.

Expected removals `E` = derived/annotated `fillers` ∪ `stutters`. Credit, on
the raw↔out alignment (`scoring_version` 4):

- a span's nearest neighbours in raw that are neither expected removals nor
  gold-deleted (previous and next, where they exist) must be **aligned**
  (`.hit` or `.sub`) — a formatter that deletes the clause around "um" earns
  nothing here (M charges the deletion); a reworded neighbour is still there;
- survival is read off the **out window** strictly between the neighbours'
  paired positions (to the text's edge where a neighbour is missing), not off
  the span's own ops: a filler is **removed cleanly** iff the window holds
  none of its forms; a stutter run is **collapsed** iff the window holds each
  of the run's forms exactly as often as the span is expected to leave them
  standing. What else the window holds is M's business — a novel word in the
  filler's place is charged as novelty, not as a missed strip;
- that expected count comes from the span's **provenance**. A *derived* span
  is read off the gold (raw↔gold `.hit`s inside it: once for the "the" of
  `the the`, zero for a filler) — the gold is the statement about the ideal
  output, and a derivation cannot contradict the gold it came from. An
  *explicit* `fillers` / `stutters` entry is read off its own `keep`: an
  annotation is a statement about what `raw` contains, so a gold that retains
  another count is a **malformed fixture** — it scores Fi < 100 against
  itself, which is what `lint`'s invariant reports — never silently
  reinterpreted as the other;
- spans that share a window **and** a form set are one group, credited **per
  span**: with a gold, the group is held to what the gold keeps inside its
  derived spans (the `.hit`s over their union), never to the members' `keep`s
  summed — two runs of one word around a filled pause (`I I um I I` → `I`)
  annotate two keeps while the gold retains one, so the sum would read the
  gold copy as a deficit and a doubled `I I` as exact. Each copy the window
  holds beyond that count is one span left in place (`um um` → `Um,` is one of
  two removed, not two missed; `I I um I I` → `I I` is one run of two
  collapsed), the earlier spans taking the credit and the report naming the
  rest; a copy short of it is a word the gold keeps cut — M charges it on
  gold↔out — not a collapse, and credits none of the group;
- a **gold-free** fixture (every history-export row — the population the
  rating loop starts from) has no such statement: its derived spans carry
  `FillerStripper`'s own contract, "a run collapses to its first word", which
  is all there is to hold an output to until a gold is rated. So each span
  expects its own `keep` and is credited independently — the window's copies
  are handed out one entitlement at a time, a surplus copy charges one span
  and a shortfall charges the spans it leaves short, never the whole group.
  Summing the keeps into one block inverted exactly the shape the per-span
  rule was written for: `I I um I I think we should ship it` → `I think we
  should ship it.` read as a group-wide deficit (1 of 3) while the doubled
  `I I` the contract predicts read as perfect. A single-span group scores the
  same under either rule.

Why the window and not the ops: the aligner's backtrace prefers the diagonal
on equal cost, so a filler in the second-to-last raw slot with a word appended
to the output (`call me um tomorrow` → `Call me tomorrow, thanks.`) aligns as
sub(um→tomorrow), sub(tomorrow→thanks) — a clean removal that reads as two
rewrites — and the mirror shape (a word prepended before a second-slot filler)
shifts the other way. `ContentGuard`'s NEGATED gate reads a governed word's
survival the same way. Version 1 read the span's ops and scored those
removals 0; version 2 read the whole window against each span, so two
fillers sharing one window (`um um`) were both missed when either survived;
version 3 credited per span but held every group to its members' `keep`s
summed, which read the gold's own copy of a restart as a deficit; version 4
is the rule above — the expectation follows each span's provenance, and a
gold-free row hands out one entitlement per span. Every stored run is
re-graded by `whispr-bench score`.

`Fi = 100 × credited / |E|`; **undefined when |E| = 0** (fixture excluded
from the Fi mean; the composite renormalizes). All-filler raw with `gold:
""`: `E` = all tokens, credited iff out is empty. At a verbatim register Fi is
skipped. Repairs are scored in M (which side to keep is a meaning decision).

| raw | gold | out | Fi |
|---|---|---|---|
| `um I also signed into Zephyrnet` | `I also signed into Zephyrnet.` | = gold | um `.del`, next neighbour "i" hit, window empty → **100** |
| same | same | `Zephyrnet.` | next neighbour deleted → **0** (and M: D = 4) |
| `please call me um tomorrow` | `Please call me tomorrow.` | `Please call me tomorrow, thanks.` | sub(um→tomorrow), sub(tomorrow→thanks); window between "me" and the next neighbour's slot = [tomorrow] → **100** (M: "thanks" novel → 25; C 47.5) |
| `the the whisper bro` | `The Whisper Bro.` | = gold | run [the, the] → one hit, one del → **100** |
| same | same | `the the Whisper Bro.` | two hits → **0** |
| `um um call me tomorrow please` | `Call me tomorrow please.` | `Um, call me tomorrow please.` | both "um"s read the window before "call"; it holds one → 1 of 2 → **50** (both gone → 100, both kept → 0; F 75, M 100, C 82.5, MISSED) |
| `I I um I I think we should ship it` | `I think we should ship it.` | = gold | um + two derived `I I` runs (E = 3) read the window before "think"; the gold keeps one "I" of the four, the window holds one → **100** (held to the runs' summed `keep`s it would be a deficit: 1 of 3, C 86.7) |
| same | same | `I I think we should ship it.` | um gone, one surplus "I" → one run of two collapsed → 2 of 3 → **66.7** (F 100, M 100, C 93.3, MISSED); `I I I` → 1 of 3 |
| `the the um the the whisper bro is ready` | `The Whisper Bro is ready.` | = gold / `The the Whisper Bro is ready.` | the same shape on an article → **100** / **66.7** |
| `I I um I I think we should ship it` | `` (`history-unrated`) | `I think we should ship it.` / = raw | gold-free: each run expects its own "I" and the window holds one → one collapsed, one cut → 2 of 3 → **66.7** / nothing removed → **0**; `I I think…`, what the contract predicts, → **100** |
| `very, very flat` | `Very, very flat.` | = gold | "very" ∉ `stutterCollapsible` → E = ∅ → **undefined** |
| `and a and sixty two` + `stutters:[{and a and → and}]` | `and 62` | `and sixty-two` | span: one hit on "and", "a","and" del → **100** |
| `send the the report` + `stutters:[{the the → the}]` | `Send report.` | `Send report.` / `Send the report.` | explicit span, so the `keep` rules: the copy it keeps was cut → **0** / kept → **100**. The gold retains 0 where the annotation keeps 1 — a malformed fixture: scored against itself the gold gets Fi 0, which is `lint`'s invariant error |
| `Uh` | `` | `` / `Uh.` | **100** / **0** |

### 2.4 M — meaning (0–100, gold-scored)

> Build amendment 2026-09-13: `D` also counts a `.sub` whose gold word is
> gone and whose replacement is not novel (the aligner emits "Meet on
> Tuesday." vs gold "Meet on Wednesday." as a sub); a novel replacement is
> charged once as novelty.

On gold↔out: `N_g` = gold word count; `D` = gold tokens with `.del` plus the
amendment's subs — stored on the row as `lost`, beside the alignment's raw
`.del` count `D` (the terminal prints `lost N` after `D` whenever they differ,
so an OVER_EDIT_HEDGE never sits beside `D 0` with nothing to show for it);
`novel` = out tokens with `.ins` or `.sub` whose canonical form ∉ canon(raw) ∪
canon(gold) ∪ `alternates` ∪ STOP ∪ hyphen-split-in-raw; `novelNumerals` =
numeric atoms among `novel`.

```
M_text = 100 · max(0, 1 − 2·D/N_g − 3·novel/N_g)  −  Σ_missed must_keep (4 · weight)      floored at 0
M      = M_text                                       if repairs are not scored
M      = 0.75 · M_text + 25 · resolved / |repairs|    if repairs scored (run level == resolve_at)
resolved = reparandum span absent from out AND repair span present
gated verdict (ANSWERED / INVENTED / NEGATED / OVER_EDIT_FACT) → M = 0
```

A missed `must_keep` costs its deletion share **plus** a flat stance
penalty. That second term is deliberate (importance lost), not double
counting of one signal: an annotated span is one he said matters. Reorders
and same-word substitutions still move WER, which stays in the JSON; only
deletions (over-edit) and novelty (invention) move M, so the axes stay
independent of Fi (missed removals are `.ins` tokens that *are* in raw —
charged in Fi only).

| raw / gold | out | D | novel | M |
|---|---|---|---|---|
| 40-word gold, out drops 3 unannotated tokens | | 3 | 0 | 100·(1 − 6/40) = **85** |
| same, the 3 tokens are `must_keep` "I don't know," w=2 | | 3 | 0 | 85 − 8 = **77**; verdict OVER_EDIT_HEDGE |
| same, w=5 | | 3 | 0 | gated OVER_EDIT_FACT → **0** |
| raw `…the glider plus a 42 on each wing and a 9 on each wing so find the total` | `…42 + 42 + 9 + 9 = 102 units` | — | {102, units}, numerals 1 | INVENTED → **0** |
| raw `and a and sixty two` gold `and 62` | `and sixty-two` | 0 | 0 (canonical 62) | **100** |
| raw `meet on Tuesday, I mean on Wednesday` gold `Meet on Wednesday.` repairs [Tuesday→Wednesday] | `Meet on Tuesday, I mean on Wednesday.` | 0 | 0 | unresolved → 0.75·100 = **75** |
| same | `Meet on Wednesday.` | 0 | 0 | **100** |
| same | `Meet on Tuesday.` | 1 (wednesday), N_g 3 | 0 | M_text 33.3 → 0.75·33.3 = **25** (wrong side scores below echo) |

### 2.5 Hard-fail gates — `ContentGuard` (raw↔out only, no gold needed)

A fixture-free `public struct ContentGuard` in Core, so the macOS
fallback-to-raw guard reuses the exact code the bench validated.

`ContentGuard.Profile` picks the side: `.bench` (the default — everything in
this document) GRADES an edit, `.live` guards a dictation, where a refusal
costs the user a real improvement rather than a leaderboard number. The live
side is SIX rules — L1 structure, L2 runaway, L3 wholesale loss, L4 wordless,
L5 invented numeral, L6 invented content — and mostly a SUBSET of the rules
below: it runs ANSWERED's structure and length rules unchanged, INVENTED with
the numeral rule asking whether the input witnesses the digits of a token whose
digits ARE the fact (a bare numeral, an ordinal, a meridiem — a decimal, a
clock time or a price is plain novel content on BOTH profiles, so a correct ITN
of "two and a half" is never a refusal) and the count rule counting only novel
tokens that carry a letter OF THEIR OWN (a dash invents no content, and neither
does a denormalized number — "the 9th" and "9am" are read with the same
`digitsAreTheFact` the numeral rule uses), and NOTHING of NEGATED: a polarity
inversion lands live and is scored here, a deliberate and measured trade. The
opener, `answer-shape` and `novelShare` rules are bench-only too. Three
constants are live's own — `liveWholesaleLossMinWords`,
`liveWholesaleLossRatio` and `liveInventedNovelTokens` — and each is a number
a 2-column seed run moved; the rules, the evidence for each and the
measurements live in
[`docs/llm-measurement-gate.md`](llm-measurement-gate.md) § "The measurement
round". Every other value below is read by both profiles.

**Deviation from plan §4.5**, stated rather than implied: the ANSWERED row
carries a fifth trigger the plan's table does not (`answer-shape`), the
opener echo is read against the whole raw instead of its first two tokens, and
the INVENTED share rule discounts slip fixes. All three are shared rules, so
they move the GRADER as well as the live gate: a question flattened into a
statement is ANSWERED on both sides (it outranks OVER_EDIT_FACT, so a
question reduced to three of its own words now names the answer rather than
the shrink), and two commissioned slip fixes on a 10-atom output are no longer
an invention density. Measured over the stored personal run (3 columns × 70
rows), the 81 seed golds and a fresh `llama,foundation` seeds run (172 model
pairs): **0 rows change verdict** — the shapes are pinned in `ContentGuardTests`
and `OutputGateTests` instead, which is where a false-positive class belongs.

| Gate | Trigger (constants in `EvalThresholds`) | Reproduces |
|---|---|---|
| **ANSWERED** | `lines(out) > lines(raw)`; ∨ markdown in out absent from raw (`**`, line-initial `- `, `* `, `\d+. `); ∨ first out token ∈ {sure, certainly, here's, here, yes, okay} ∧ the raw does not carry that word ANYWHERE (apostrophes dropped, so "here is" ≡ "here's"); ∨ (`N_out/N_raw > 1.5` ∧ `N_raw ≥ 6`); ∨ **answer-shape**: the raw opens (fillers skipped) with a wh-word or an auxiliary not followed by a negation, and the output opens with neither that word nor carries any `?`, with `novel` empty | id 70 (ratio 2.35, markdown, "Sure"); the measured in-band answer with its opener word removed ("is it done?. okay.. let's go" → "It is done. Okay, let's go.") |
| **INVENTED** | `novelNumerals ≥ 1`; ∨ `novel ≥ 3`; ∨ (`(novel − slip fixes)/N_out > 0.15` ∧ `N_out ≥ 10`), a slip fix being a novel token the alignment `.sub`-ed for a raw word within edit distance 2 and half the longer word ("there" → "they're", "befour" → "before" — the class the system prompt commissions). Gold-free mode: novelty vs raw ∪ alternates only (an ASR-slip fix is 1 novel token — below threshold) | id 54 (an invented total) |
| **NEGATED** | a NEG token in raw whose op is `.del` or `.sub`-to-non-NEG **while the next content token after it survives** — survival read off the out tokens paired to the span negation…governed word (the diagonal tie-break can pair a moved word to the negation's slot); ∨ a NEG token `.ins` between two aligned out neighbours, or a `.sub` FROM a non-NEG raw token ("I do want it" → "I don't want it"). Whole-clause drops ("I don't know, do…" → "Do…": "know" deleted too) are *not* NEGATED — they are over-edits | polarity flips ("do not push" → "push") |
| **OVER_EDIT_FACT** | any `must_keep` w ≥ 5 missed; ∨ (`factLoss/N_g ≥ 0.15` ∧ `N_g ≥ 6`) [gold-scored] where `factLoss` = deleted gold tokens excluding STOP words and tokens inside an annotated hedge-weight `must_keep` span; ∨ (`N_out/N_expected < 0.5` ∧ `N_raw ≥ 6`) [both modes] where `N_expected` = raw atoms minus fillers, stutter extras and scored reparanda | id 58 shape once annotated; empty outputs |

NEGATED's three departures from the literal rule, all pinned in
`ContentGuardTests`:

1. **Discourse "no" is exempt** (`isDiscourseNo`): a "no" that carries its own
   mark ("no, wait") or opens the utterance — past fillers, the openers
   `{yeah, yes, okay, ok, oh, well, so, and, but, right}` and repeated "no"s
   ("no I think we should ship it", "yeah no that's fine", "no no no let's
   not") — is stance or backchannel; dropping it is an over-edit M charges,
   never a flip of the clause after it (19 of the 70 history rows are
   backchannels). The measured cost: a leading DETERMINER "no" reads as
   discourse too — raw `no pushing to main today please` → `Pushing to main
   today, please.` is UNRATED with `dropped_content 1`, a rating-queue
   diagnostic and not a gate. Narrowing it needs a part-of-speech call the
   guard does not make; calibration check 3 (§7) measures this gate's
   recall against his tags.
2. **The "no" → "know" slip fix is not a flip**: a "no" substituted by a word
   the speaker never said is charged as novelty (§3.2 class 9); every other
   negation rewritten to a non-negation is a flip ("we can't ship" → "We can
   ship.").
3. **Insertion also covers a `.sub` from a non-negation** — the mirror of the
   drop rule's sub-to-non-NEG.

Gold-free diagnostics (reported, not scored): `dropped_content` = raw
content tokens (∉ fillers ∪ stutters ∪ STOP) with `.del`, and `ratio`. They
drive the rating queue (`--only flagged` = gated ∨ `dropped_content ≥ 3`).

### 2.6 Per-fixture verdict

Worst of: `ANSWERED > INVENTED > NEGATED > OVER_EDIT_FACT > OVER_EDIT_HEDGE >
REWORDED > MISSED > PUNCT > PASS` (gold-free fixtures: the four gated
verdicts or `UNRATED`).

- **OVER_EDIT_HEDGE**: any `must_keep` w < 5 missed; ∨ (`D ≥ 1` ∧ not all
  deleted tokens ∈ STOP ∧ below the FACT threshold). Not gated.
- **REWORDED**: `1 ≤ novel < 3` below the INVENTED ratio; ∨ any `.sub` whose
  out token ∈ raw (reorder/synonym from raw). Not gated ("grey" →
  "gray", "the deploy's actually today" → "the deploy actually is
  today").
- **MISSED**: `Fi < 100` ∨ an unresolved scored repair.
- **PUNCT**: `F < 100`.
- Control fixtures: any word-level S/D/I vs gold lands at least at REWORDED
  / OVER_EDIT_HEDGE by construction.

### 2.7 On-device semantic similarity — not in the score, not in the branch

`NLEmbedding.sentenceEmbedding(.english)` cosine was measured on 30 of his
edited rows: it separates the answered-question row (0.757, lowest) but
scores the invented-math row **0.962** and the over-edit row **0.951** —
indistinguishable from benign edits — while a negation flip scores 0.734 and
a plain filler strip 0.890. Three cheap lexical signals (length ratio, novel
tokens/numerals, dropped content tokens) catch all three real failure
classes for free, deterministically across OS builds (embedding vectors do
not hold that guarantee). A `--sem` diagnostic column is a one-day follow-up
if a future leaderboard row ever needs it — never a scored term.

---

## 3. Composite, weights, leaderboard row

```
C_i = 0                                   if verdict ∈ {ANSWERED, INVENTED, NEGATED, OVER_EDIT_FACT}
C_i = 0.30·F + 0.20·Fi + 0.50·M           otherwise        (Fi undefined → 0.375·F + 0.625·M)
C   = mean(C_i) over gold-scored fixtures  (macro: each fixture weighs 1)
```

Weights follow the damage in his history (7/25 harmful LLM edits vs 0/11
stripper errors — meaning is where the product breaks) and are refit only by
the calibration report (§7 below); a change bumps `scoring_version` and
`whispr-bench score` re-grades stored outputs. Macro over fixtures is the
headline; `by_tag` means and the micro WER/punct/case line are always
printed beside it, so a class-balanced view is one column away without
letting an n=1 class dominate the personal set.

**Run status** (worst wins): `INVALID` (any `unavailable` / `requestFailed`
fallback — harness broken) > `FAIL` (answered ≥ 1 ∨ invented ≥ 1 ∨ negated ≥
1 ∨ over_edit_fact > 5% of gold-scored ∨ controls unchanged < 95%) > `WARN`
(latency p99 > `--budget-ms` on LLM-path fixtures ≤ 60 words) > `PASS`.
`timedOut` is counted and **scored as the fallback text the user actually
got** — it is real behavior, not a broken harness. `.implausible` — the
output gate (`TextFormatter.gateModelOutput`), llama and FM stages alike —
is a designed fallback: counted as `rejected`, and the rejected pre-gate
text is scored too as `model_verdict`, so the report reads "stage PASS,
model ANSWERED ×3".

**Leaderboard row** (JSONL, one line per column — the column object minus
`rows`, written with sorted keys and nil fields omitted). Rows accumulate,
but exactly one **baseline** row per (`formatter`, `fixtures.name`,
`scoring_version`) survives in a file: when the scoring version or the tree
moves, the regeneration that re-runs the set REPLACES the rows it supersedes
in the same commit instead of stacking a second baseline beside them — which
is why `docs/eval/leaderboard.jsonl` holds three rows (rules, llama,
foundation) at one `git_sha`, not one per sha. Everything else — a labelled
prompt or level experiment (`--label variant-a`) — is history and stays:

```json
{"date":"2026-09-14T18:02:00Z","git_sha":"36ff03b","dirty":false,"label":"baseline",
 "formatter":"llama","model_key":"qwen2.5-1.5b","model_sha256":"…","prompt_sha256":"…","level":"fixture",
 "fixtures":{"name":"seeds","sha256":"…","n":81,"rated_n":81,"draft_n":0},
 "scoring_version":4,"run_key":"3f9a1c2b7e04",
 "scores":{"F":88.4,"Fi":95.0,"M":71.2,"C":79.1},
 "verdicts":{"PASS":58,"PUNCT":9,"MISSED":4,"REWORDED":3,"OVER_EDIT_HEDGE":4,"OVER_EDIT_FACT":1,"NEGATED":0,"INVENTED":1,"ANSWERED":1,"UNRATED":0},
 "gate":{"status":"FAIL","answered":1,"invented":1,"negated":0,"over_edit_fact":1,"controls":49,"controls_unchanged":49,"controls_unchanged_pct":100,"latency_over_budget":false},
 "fallbacks":{"fastPath":12,"rawMode":0,"timedOut":1,"rejected":0,"unavailable":0,"requestFailed":0},
 "latency_ms":{"n_llm":62,"p50":417,"p90":1650,"p99":2900,"p99_le60":1650,"max":3063,"budget":700,"over_budget":29,"ms_per_word":18.4,"reprime_ms":[900,1100],"by_length":{"<=15":{"n":20,"p50":210,"p99":600}}},
 "calibrated":false,
 "machine":{"model":"Mac14,12","os":"26.5.1"}}
```

`prompt_sha256` = SHA-256 of the distinct prompt prefixes sent (system prompt
+ directive + correction clause; `CryptoKit`); `model_sha256` = the GGUF
digest from `scripts/models-llm.sha256` for llama, `foundation@<os build>`,
`rules`, or `shipped@<first 12 hex of fixtures.sha256>` for the shipped column
(the observed outputs are part of the fixture set, so its hash already
identifies what the binary produced); `run_key = sha256(git_sha·formatter·
model_sha·prompt_sha·fixtures_sha·level·scoring_version)[0..<12]`, with
`self_repair=false` appended to the tuple only for a run made with
`--no-self-repair` (the pre-pass without the self-repair rules, as the app
runs with `[cleanup] self_repair = false`; `config.self_repair` and the
leaderboard row's `self_repair` say so, and the report's level column reads
"(self-repair off)"), so every key minted before that flag is unchanged.
`fixtures.draft_n` (dispatcher decision D1) counts draft golds apart from
`rated_n`. `latency_ms.n_llm` is the number of rows in the percentiles — the
model-path rows minus the re-primes listed in `reprime_ms` — so
`over_budget / n_llm` is the fraction the terminal prints; `p50` … `max` are
absent when no timed row exists (a one-fixture llama run whose only model row
is its group's first), never 0. The re-prime exclusion applies to columns
with a live model (llama, foundation) only; the shipped column's
`observed_ms` was measured by the production binary, so every one of its
timed rows counts. A Δ is printed only against the previous row with the same
key tuple minus `git_sha` (a run without the self-repair rules compares only
with its like); `whispr-bench leaderboard --diff` refuses rows
whose `fixtures.sha256` or `scoring_version` differ. Two files:
`docs/eval/leaderboard.jsonl` (repo, **seeds only**, scores only) and
`$WHISPR_EVAL_HOME/leaderboard.jsonl` (personal, never in the repo).

---

## 4. CLI

```
whispr-bench eval [fixtures.json …]
    [--formatter rules|llama|foundation|shipped|all]     # comma list also accepted (e.g. "shipped,llama,foundation")
    [--model qwen2.5-1.5b|qwen3-1.7b|llama3.2-1b]          # LlmCatalog.spec(key:)
    [--system-prompt FILE]                                 # PromptBuilder(family:systemPrompt:) — prompt variants
    [--level fixture|fillers|standard]                     # default fixture; override for A/B on the same golds
    [--no-self-repair]                                     # the pre-pass without the self-repair rules ([cleanup] self_repair = false)
    [--tag T[,T…]] [--only gated|flagged|unrated|all] [--confirmed-only]
    [--budget-ms 700] [--timeout-ms 3000] [--strict-latency]
    [--json runs/<id>.json] [--report runs/<id>.md] [--append leaderboard.jsonl]
    [--ratings ratings.jsonl]                              # live calibration banner (§7)
    [--git-sha SHA[-dirty]] [--dirty] [--label TEXT] [--quiet]
whispr-bench eval --value-flags          # prints the flags that take a value (scripts/bench-eval.sh reads it)
whispr-bench score runs/<id>.json [--fixtures f.json] [--json out.json] [--report out.md]
whispr-bench lint [fixtures.json …] [--repo-guard] [--floors] [--format]
whispr-bench history-export [--db PATH] [--since YYYY-MM-DD] [--min-words N] --out personal.json
whispr-bench leaderboard file.jsonl [--diff RUN_KEY_A RUN_KEY_B] [--top N] [--ratings ratings.jsonl]
whispr-bench rate runs/<id>.json --out ratings.jsonl [--fixtures personal.json]
    [--only gated|flagged|unrated|all] [--column NAME] [--rerate]
    [--pairwise runs/<other>.json] [--session ID]
whispr-bench gold fixtures.json --ratings ratings.jsonl [--runs runs/<id>.json[,…]]
    [--write] [--skip-failing]
whispr-bench calibrate --fixtures f.json --runs runs/<id>.json[,…] --ratings ratings.jsonl
    --out calibration.md
scripts/bench-eval.sh [eval args…]     # git rev-parse --short HEAD + dirty -> --git-sha; appends
                                        #   docs/eval/leaderboard.jsonl for the seeds set only
```

No fixtures path = the built-in seeds (`EvalCase.seeds`, 81 fixtures).
`--formatter all` expands to rules, llama, foundation, plus `shipped` when a
fixture carries an `observed` output — a column with nothing to score would
be noise. `rate` / `gold` / `calibrate` are the human rating loop (§6 below):
they need no model and touch no network.

`--ratings` makes the calibration banner live, and it does a different job
on each command, because only one of them knows which fixtures it is looking
at.

On **`eval`** the log is read: `n` is how many rows of THIS fixture set he
has rated, `zero_edit_rate` per column is his SHIP share, and the row a run
appends is `calibrated: true` only when a `calibration.json` marked `valid`
hashed this exact `fixtures.sha256`. Without the flag the log defaults to
`$WHISPR_EVAL_HOME/ratings.jsonl` when that variable is set; with nothing
readable the banner is `PENDING (n=0 rated)`.

On **`leaderboard`** the log is NOT counted. A leaderboard file holds rows,
not fixtures, and a rating carries no fixture-set identity to filter the log
by — counting it would score his personal rows against a seeds table. There
the flag only says where to look for a `calibration.json` (beside the log,
then `$WHISPR_EVAL_HOME`), and only a record hashed against the rows' own
fixture set may speak: `n` is then that record's own count, written by
`calibrate`. A record for another set, or none at all, reads
`PENDING (n=— rated)` — an em dash, never a number borrowed from elsewhere.
Without `--ratings` and without `$WHISPR_EVAL_HOME` the table prints alone,
as it always did.

`--append` refuses a path inside this checkout unless the fixture set being
scored is the seeds (no fixtures path given) — `Leaderboard.refusesAppend`.
`--json` and `--report` refuse a path inside the checkout whenever any
fixture carries what only an export writes (a `history:` source or an
`observed` output — `Leaderboard.refusesRunOutput`), because a run file
stores every row's raw text and output verbatim; `whispr-bench score` applies
the same refusal to its own `--json` / `--report`. Personal run files go
under `$WHISPR_EVAL_HOME/runs/`. `scripts/bench-eval.sh` leans on the append
refusal: it injects `--append docs/eval/leaderboard.jsonl` itself only when
no fixtures path was given, never overrides an `--append` you already
passed, and resolves relative `--json` / `--report` paths against the
checkout root (`runs/` is gitignored for that).

### Exit codes

`0` PASS or WARN (`3` for WARN with `--strict-latency`) · `1` INVALID · `2`
FAIL. `lint`: `0` clean (warnings still print), `1` on any error.

### Run JSON (`EvalRun`)

Codable in Core so tests round-trip it; the canonical encoder sorts keys —
two runs of the same outputs encode byte-identical except `date`, which is
the reproducibility contract `run_key` and `whispr-bench score` rest on.

```json
{"schema":3,"run_id":"2026-09-14T180200-36ff03b-seeds","date":"…","git_sha":"36ff03b","dirty":false,
 "machine":{"model":"Mac14,12","os":"26.5.1"},"scoring_version":4,
 "fixtures":{"path":"seeds","name":"seeds","sha256":"…","n":81,"rated_n":81,"draft_n":0,"unrated_n":0},
 "columns":[{"formatter":"llama","model_key":"qwen2.5-1.5b","model_sha256":"…","prompt_sha256":"…","level":"fixture",
   "config":{"timeout_ms":3000,"budget_ms":700,"label":"baseline"},"run_key":"…",
   "scores":{"F":88.4,"Fi":95.0,"M":71.2,"C":79.1},
   "micro":{"wer":0.041,"punct_f1":0.906,"case":0.98},
   "gate":{…},"verdicts":{…},"fallbacks":{…},
   "latency_ms":{…,"by_length":{"<=15":{"n":20,"p50":210,"p99":600},"16-60":{…},"61-150":{…}}},
   "by_tag":{"agent-prompt":{"C":74.0,"F":…,"Fi":…,"M":…,"n":30},"question":{"C":40.0,"n":5}},
   "rows":[{"id":"agent-hedge-03","stripped":"…","out":"…","source":"model","ms":410,"would_timeout_3s":false,"reprime":false,
            "verdict":"PASS","triggers":[],"F":100,"Fi":100,"M":100,"C":100,"H":14,"S":0,"D":0,"lost":0,"I":0,"novel":0,"novel_numerals":0,
            "dropped_content":0,"ratio":0.93,"missed_must_keep":[],"unresolved_repairs":[],"c_initial":1.0,"gold_index":0}]}]}
```

`fixtures.draft_n` is a dispatcher addition (D1) over the plan's original
shape: drafts count separately from both `rated_n` (confirmed golds only) and
`unrated_n` (gold-free), because a draft IS scored in the composite but must
never be read as validated. Schema 3 adds `lost` (§2.4's D) to every
gold-scored row; `model_verdict` / `rejected` appear only on rows the output
gate refused (nil fields are omitted, never `null`).

Outputs are stored in every run, so a `scoring_version` bump re-grades old
runs with `whispr-bench score` and no model.

---

## 5. Validation plan — proving the benchmark

Model-free, in `Tests/WhisprBroCoreTests/`, run in CI.

**Sanity formatters** (`ReferenceFormatters.swift`, in the test target) over
every seed:

| Formatter | Output | Expected |
|---|---|---|
| `goldCopy` | gold | F = Fi = M = C = 100, verdict PASS on all 81; status PASS (any seed whose gold fails its own scorer is a broken fixture — `lint`'s invariant, §1, is this same call over every fixture file) |
| `echo` | the raw, verbatim | Fi = 0 wherever E ≠ ∅ (the one formatter that misses every removal); M 100 on controls (PUNCT at worst); MISSED on disfluency and repair fixtures, OVER_EDIT_HEDGE on the three ASR-slip seeds (the slip echoed loses one gold word); status PASS. Out == raw makes every raw↔out gate trivially silent, so the "never gated" claim is not made here |
| `echoStripped` | stripped raw (the bench's own input to every formatter) | **never ANSWERED / INVENTED / NEGATED, never collapses** — real `.del` ops on every derived filler and identical run, so the gates are exercised on an honest pass-through; Fi = 100 wherever only fillers and identical runs are expected (85.4 over the seeds: the five annotated runs the stripper cannot see); M 97.3; status PASS |
| `fillerOnly` | raw minus core fillers, no other change | Fi = 100 on filler-only fixtures, 0 on stutter-only; M ≥ 90; verdict PUNCT/MISSED |
| `deleteAll` | `` | Fi = 100 on all-filler fixtures; OVER_EDIT_FACT everywhere else; C ≈ 0; status FAIL |
| `answerer` | `"Sure, here's that:\n1. **" + raw` | ANSWERED × 81, C = 0, status FAIL |
| `inventor` | gold + ` 140 units` | INVENTED × 81 (novel numeral), status FAIL |
| `hedgeDropper` | gold minus every `must_keep` span | OVER_EDIT_HEDGE exactly on fixtures with w = 2 spans, OVER_EDIT_FACT on w = 5; on one pinned fixture M = 100·(1 − 6/40) − 8 = 77 |
| `negator` | gold with the first NEG token removed | NEGATED exactly on fixtures containing a NEG token followed by a surviving content word |
| `reorderer` | gold with two adjacent content words swapped | S only, REWORDED, no gate |

Ordering asserted (`testCompositeOrderingOfTheSanityFormatters`), by means
over the 81 seeds: `goldCopy (100) > echoStripped ≥ fillerOnly ≥ echo > 0`;
`inventor = answerer = 0`; `deleteAll = 1.8` (not 0: the all-filler seed's
empty gold is a PASS at 100, and the two mark-free fragments earn F's terminal
credit for none == none); `hedgeDropper = 96.8 < goldCopy`, and per fixture
`fillerOnly ≥ echo`. The plan's literal chain `echo > hedgeDropper` cannot
hold over the whole set and is **not** asserted: on 75 of 81 seeds the
dropper has no `must_keep` span to remove and IS the gold copy, which lifts
its mean above every pass-through without saying anything about hedge
handling. The hedge link is pinned where it means something — over the six
seeds that carry a span (`hedge-01…05`, `numbers-03`): echo 76.3 vs
hedgeDropper 57.2, and echo 68.8 vs 61.4 over the annotated set.

**Properties**: adding a novel numeral never raises C; removing a
`must_keep` span never raises C; F is invariant under word edits that keep
punctuation keyed to hit words; Fi is invariant under casing; sentence-initial
recasing never moves C; `score` twice → byte-identical JSON (date excluded);
reordering fixtures leaves aggregates unchanged; a 150-word fixture and
sixteen 5-word ones weigh equally in C while micro WER moves the other way;
v1 `{id, raw, gold}` JSON decodes and scores; unknown keys ignored; `the the`
derived, `very, very` not, `[]` disables; `EvalThresholds` literals pinned;
`run_key` stable across two runs; the decisions behind `--append` and
`--json` / `--report` are pure predicates (`Leaderboard.refusesAppend`,
`Leaderboard.refusesRunOutput`) pinned on both sides — a repo path is refused
for non-seed / export-carrying fixtures, allowed for the seeds and for any
path outside a checkout; `lint --repo-guard` refuses `history:` sources and
`observed` fields; the flag parser (`EvalOptions`) and its value-flag list
are pinned, so scripts/bench-eval.sh's arg walk reads the binary's own list.

**Replica fixtures** for the shapes of ids 70 / 54 / 58 pinned to ANSWERED /
INVENTED / OVER_EDIT_HEDGE; `testPlausibleAcceptsEverySeedGold` extended to
the new seeds.

**Acceptance on real data** (private, not a test): `eval
~/OS/dev/whispr-bro-eval/personal.json --formatter shipped` must report h70
ANSWERED and h54 INVENTED with everything else UNRATED; after the first
rating pass, h58 / h69 / h26 / h43 must land at OVER_EDIT_HEDGE with M < 80
under `--formatter llama`, the 14 clean rows PASS, controls untouched; then
`calibrate`.

---

## 6. Rating loop (`whispr-bench rate` / `gold` / `calibrate`)

Ground truth is the maintainer. Five seconds a row turns his SHIP / FIX /
WRONG into the golds every gold-scored metric above needs, and into the κ
§7 demands before the composite may be called a validated metric. Nothing
in this loop needs a model or a network: it reads a stored run, shows the
text, and writes JSONL.

### Modes and keys

| Mode | Screen | Keys | Produces |
|---|---|---|---|
| **Triage** (default) | raw, the column's output, an inline word diff off the scorer's own alignment, the fixture's annotations, the metric's own verdict line | `1` SHIP · `2` FIX (punctuation or case only) · `3` WRONG (meaning changed) — on 2/3 a tag picker opens (`a`…`m` toggle a chip, Enter records) | the zero-edit bit, tags, spans, golds |
| **Pairwise** (`--pairwise other-run.json`) | raw, then A and B in slots randomised by a stable hash of the fixture id AND the session id — blind, replayable from `--session`, and re-drawn from scratch by every session | `a` · `b` · `=` | preference pairs for calibration check 5; never a gold |

Triage also takes: `k` mark a dropped span `must_keep` (weight 2), `K` the
same at weight 5 (a fact), `e` edit the gold in `$EDITOR` (a 0600 temp file,
deleted after), `=` "this output is also fine" (an alternate gold), `s` skip,
`y` confirm the fixture's draft annotations as they stand, `q` quit (records
already written stay), `?` help.

The queue is flagged rows first — gated, or `dropped_content ≥ 3` — then
gold-free ones, then the rest, so the five minutes he actually spends go to
the rows that are probably wrong. `--only gated|flagged|unrated|all` narrows
it, `--column NAME` takes one formatter, and an output already rated (same
`fixture_id` + `output_sha`) is skipped unless `--rerate` — which is how the
≥ 7-day re-rate pass for the consistency ceiling is run. "Already rated" is a
verdict, or a record carrying a GOLD (`e` / `=`, which `y` then writes without
a verdict): re-offering that row would ask him to type the same gold twice. A
`k` / `K` mark is not enough — the mark rides along in the log and `gold`
drafts the span from it either way, while the row still owes its verdict and
comes back for one.

### Scripted mode

When stdin is not a TTY, `rate` reads **one key or answer per line** instead
of raw keystrokes, and ends cleanly at EOF with whatever it has written. The
`e` key then reads the replacement gold from the next line rather than
opening an editor (an editor with no terminal is not an editor). This is how
the tests drive the loop, and how an agent can:

```
printf '1\n3\nc\n\ns\n' | whispr-bench rate runs/personal.json \
    --fixtures personal.json --only flagged --column shipped --out ratings.jsonl
```

### The record

One JSON object per line in `ratings.jsonl` (0600, append-only):

```json
{"fixture_id":"h58","run_key":"7ae02c57ba33","formatter":"shipped","output_sha":"59c7af1ea20e",
 "verdict":"wrong","tags":["dropped-hedge"],"must_keep":[{"span":"I don't know,","weight":2}],
 "should_go":[],"gold_edit":"…","alt_gold":"…","ms_to_rate":5200,
 "rated_at":"2026-09-14T18:03:00Z","session":"20260914T180200Z"}
```

`output_sha` is the first 12 hex of SHA-256 over the output he was shown, so
a record pins the TEXT, not the run. Two fields extend the plan's list, both
optional and both omitted unless they apply: `confirm: true` is the `y` key
(no §7.2 field carries a confirm pass), and `verdict` is **absent** on a
pairwise record — a pick between two outputs is not a SHIP/FIX/WRONG
judgement of either, and a fake one would poison the weighted-κ check that
reads this file. A pairwise record instead carries
`"pair":{"a_run":…,"b_run":…,"slot":"a|b","pick":"a|b|="}`, where `slot` is
where `a_run`'s output was shown. `rate` records `a_run` as the run it put in
slot A, so its own lines always read `"slot":"a"`: pinning `a_run` to one run
instead would make `preference` +1 every time he prefers that run, and
calibration check 5's τ_b undefined exactly where the agreement is strongest.

### Ratings → golds (`whispr-bench gold`)

`whispr-bench gold personal.json --ratings ratings.jsonl [--runs runs/…json] [--write] [--skip-failing]`

| Rating | Effect on the fixture |
|---|---|
| SHIP | the output becomes `gold`, `gold_source: "ship:<run_key>:<formatter>"`; a second, differing SHIP is appended to `golds[]`. `annotations_status` does not move — a SHIP judges an output, not the annotations |
| `=` (also fine) | appended to `golds[]`, never the gold |
| `gold_edit` | becomes `gold`, `gold_source: "edit"`, `annotations_status: "confirmed"` — it beats a SHIP and every draft annotation, being his own text; the result reports the record's HTER (S+D+I over the gold's words) against the output he edited |
| `y` | `annotations_status: "confirmed"`, and the `unrated` tag drops |
| WRONG + `dropped-fact` / `dropped-hedge` | that candidate's raw→output deletions become `must_keep` drafts at weight 5 / 2 — unless he marked spans with `k`/`K`, which override |
| any gold, once set | a deletion beside a correction cue (`actually`, `I mean`, `no wait`, `sorry`) drafts a `repairs` entry |
| a gold that keeps a filled pause — or any part of one — the row still expects removed | `fillers: []` — `lint`'s own opt-out (the row that keeps its "uh" on purpose), which is all-or-nothing; the diff names what the gold kept and what the row stops expecting |
| a gold that leaves an annotated stutter run other than its `keep` says — a copy too many standing, or a kept word cut | that entry drops and the rest of the list stands; Fi charges the surplus and the deficit alike, and its expected set is `fillers` ∪ `stutters`, so bending the filler half alone would leave the axis on and score his own gold 0 |
| either bend | `annotations_status: "draft"` — the bend is a machine's decision about his annotations, and an axis switched off under `confirmed` reads as a call somebody checked |

Fillers, stutters and `control` are never written as values: they stay
derived from raw and gold, so a change to the derivation never moves an
unchanged file's hash. The one exception is the bend above, and it writes no
derived list either — an opt-out (`fillers: []`, the only way a gold he
ACCEPTED can keep a filled pause without failing `lint`) and his own stutter
list minus the entries his gold contradicts. What the annotation is held to
is what the gold LEAVES of the span AT THE OCCURRENCE it names, counted word
by word: a run left standing, one half collapsed and one collapsed PAST the
`keep` all contradict it, because Fi holds an explicit span to its own
`keep` and charges a copy too many and a kept word cut alike — both score
the gold he just accepted 0 on that axis. A run the gold collapses exactly
as annotated bends nothing, and neither does a disfluency the gold replaces
(aligned, and gone from it, so it expects nothing) or one the gold removes
while keeping another run of the same words further down (the occurrence is
a raw index, followed through the raw→gold alignment — the gold's own
occurrences have already moved). His gold is the ground truth; the
annotation bends to it, in either direction, never the other way round.
Anything drafted — a `must_keep`, a repair, or either bend — sets
`annotations_status: "draft"`; an edit (or `y`) sets `"confirmed"`, and a
SHIP leaves the status where it was. A `y` in the same pass as a draft is
held: a confirm covers what he was LOOKING at.

Three refusals keep the file safe. A **confirmed** gold or annotation is
never overwritten (a differing SHIP can only append to `golds[]`). Two
different edits for one fixture are a **conflict**: listed, and that fixture
left exactly as it was. A candidate gold that **contradicts a confirmed
annotation** — it drops a `must_keep` span, breaks a repair, or leaves a
filler or a stutter run other than it says — is refused the same way,
because the bend that would absorb it is a deletion and a deletion of his
work is his call; a candidate carrying a **numeral the speaker never said**
is refused whatever the status, since no annotation edit can absorb that
error. A *draft* annotation refuses nothing: his gold wins, the contradicting
draft is dropped and named in the diff. "Confirmed" is the ANNOTATIONS' own
status throughout: a gold-free row (every row a history export writes) can
carry annotations he confirmed, and they are protected exactly as a seed's
are — but only annotations somebody WROTE. `fillers` and `stutters` derive
from raw and gold when the field is absent, and a derived expectation is
nobody's annotation: an export writes `confirmed` and no annotations at all,
so reading the status there would refuse every row whose accepted output
keeps an "uh".

`--write` re-checks the whole derived set through `EvalLint`, and a row THIS
pass derived that fails refuses the write — one derived row that fails lint
is a scoring bug waiting to happen. The refusal names that row, its rule and
`--skip-failing`, which writes every change that lints clean and lists the
ones it held back with their errors: a 70-row session must not lose 22 good
golds to one bad row. A change is held back only when its derived row breaks
a rule its original row did not. An error the file already carried refuses
nothing at all — the pass never touched that row, holding a change back
cannot fix it, and a `--skip-failing` re-run would write the same file byte
for byte — so the plain path writes and prints those errors as the warnings
they are, with the `lint` command that lists them. The file goes back
sorted-keys pretty-printed (diffable by hand), 0600, and is refused inside a
source checkout.

Because a record pins its output by digest, `--runs` supplies the run files
whose rows resolve those digests; the fixtures' own `observed` column
resolves the shipped one without help. A record nobody can resolve is listed,
never guessed at.

### Calibration (`whispr-bench calibrate`)

See §7 — the six checks, their thresholds, and the `calibration.json` this
writes for `eval` and `leaderboard` to read.

### Privacy

Everything in this loop stays under `$WHISPR_EVAL_HOME` (default
`~/OS/dev/whispr-bro-eval/`) and every file it writes is **0600, created
owner-only** — `ratings.jsonl`, the rewritten fixtures file, `calibration.md`
and `calibration.json`, plus the `$EDITOR` temp file, which is deleted after
the edit. `rate --out`, `gold --write` and `calibrate --out` all refuse a
path inside a source checkout. Run files, reports and leaderboards go through
the same writer (`EvalFile`), so no eval output lands world-readable.

---

## 7. Calibration protocol (`whispr-bench calibrate` → `calibration.md`)

The rating loop (§6) exists to satisfy this contract. Until it does, every
report and leaderboard row carries `CALIBRATION: PENDING (n=…)` /
`calibrated: false`, and the composite decides nothing on its own — it is a
number, not yet a validated metric.

| # | Check | Statistic | Target |
|---|---|---|---|
| 1 | His own consistency (20 rows re-rated ≥ 7 days later) | Cohen's κ on SHIP/FIX/WRONG | the **ceiling** — the metric is never claimed above it |
| 2 | Metric verdict vs his verdict (PASS → SHIP; PUNCT / MISSED → FIX; else → WRONG) | **weighted κ** (raw agreement printed, never used — it overstates κ by 30–40 pp) | κ ≥ 0.6 |
| 3 | Gate detectors vs his tags | precision + recall per flag | ANSWERED / INVENTED / NEGATED recall ≥ 0.9; OVER_EDIT precision ≥ 0.7 |
| 4 | Separation | AUROC of M for WRONG-vs-not; of C for SHIP-vs-not | ≥ 0.9 / ≥ 0.85 |
| 5 | Ranking | pairwise picks vs `C_i`: Kendall τ_b (ties excluded); Spearman ρ of C vs his 3-level rating | τ_b ≥ 0.5; ρ ≥ 0.7 |
| 6 | Weights | logistic fit SHIP ~ F + Fi + M, printed as a suggestion only | weights change by hand → `scoring_version` bump → `score` re-grades stored runs |

**Valid** = checks 2–5 pass on ≥ 100 rated rows and ≥ 40 pairs.
`zero_edit_rate` (share of SHIP per column) is the Wispr-style north star,
reported per column once ratings exist.

Every statistic returns *undefined* rather than a number where the evidence
does not support one — κ when neither side varied, AUROC with one class
empty, ρ on a constant column, τ_b with everything tied, the logistic fit on
collinear axes — and an undefined check is `n/a`, which never counts as a
PASS. Raw agreement is printed beside κ and never used as a target (it
overstates agreement by 30–40 pp). The weight suggestion is printed and
never applied: a weight change is a hand edit, bumps `scoring_version`, and
re-grades stored runs through `score`. Check 3 is stricter still: §7.4 names
ANSWERED / INVENTED / NEGATED recall as conditions of VALID, so an
*unmeasured* one (no rating carries that tag yet) holds the whole check at
`n/a` instead of dropping out of it — a sub-check that neither passes nor
fails would let VALID through on evidence nobody has. The chip list carries
`negated` (key `m`) for exactly that reason: without a chip, no rating could
ever label the gate and the check could never honestly pass.

`calibrate --out calibration.md` also writes `calibration.json` beside it:

```json
{"date":"2026-09-14T19:00:00Z","fixtures_sha256":"…","kappa_weighted":0.71,"n":124,"pairs":48,"valid":true}
```

That file is the only thing that can turn a leaderboard row's `calibrated`
flag true, and only for a run whose `fixtures.sha256` matches it exactly.

---

## 8. Privacy rules

- **His dictations never enter this repo.** The personal fixture set,
  ratings, runs, and leaderboard live at `$WHISPR_EVAL_HOME` (default
  `~/OS/dev/whispr-bro-eval/`, recorded in `context/systems.md`) — not a git
  repo, never under `~/repo`.
- **The export never drafts a gold.** `whispr-bench history-export` emits
  `gold: ""` (`gold_source: "history-unrated"`) for every row — golds and
  annotations come only from the rating loop. Drafting `gold =
  formattedText` would hide exactly the rows the benchmark exists to catch.
- **Draft golds are real golds, honestly labeled** (dispatcher decision D1):
  a `gold_source: "draft:<author>"` fixture with `annotations_status:
  "draft"` IS scored in the composite by default (a draft still catches a
  regression) — the status line prints `DRAFT GOLDS: n/N` so the number is
  never mistaken for validated, `rated_n` counts confirmed golds only, and
  `--confirmed-only` excludes drafts entirely when you need the strict set.
- **Every file the eval surface writes is 0600, created owner-only.** Run
  JSONs, reports, leaderboards, `ratings.jsonl`, a rewritten fixtures file,
  `calibration.md` / `calibration.json` and the rating loop's `$EDITOR` temp
  file all go through `EvalFile`, which stages them in a sibling file
  *created empty* at 0600, streams the bytes into that descriptor, and swaps
  it over the target — never a chmod after the bytes land, which would leave
  a world-readable window, and never `createFile(contents:)` with a payload
  either: on Darwin that routes through `NSData`'s atomic write, whose own
  auxiliary file holds the whole payload at 0644 until the mode is applied at
  the end. `Data.write(options: .atomic)` and `FileManager.createFile` without
  attributes both produce 0644 under the default umask, so neither is called
  directly anywhere in the bench.
- **Three independent guards, not one.** (1) `whispr-bench eval --append`
  refuses a path inside this checkout unless the fixture set is the seeds
  (`Leaderboard.refusesAppend`); `--json` / `--report` — in `eval` and in
  `score` — refuse a path inside the checkout whenever a fixture carries a
  `history:` source or an `observed` output (`Leaderboard.refusesRunOutput`),
  because a run file stores every row's text; `history-export --out` refuses
  a checkout path outright. (2) `scripts/lint-fixtures.sh` runs in CI
  (`build-test-audit`, after the unit tests): `whispr-bench lint
  --repo-guard` over every fixtures file that would reach the repo (tracked,
  or untracked and not ignored) plus the seeds, and fails the build on any
  `history:`-sourced fixture or `observed` field — in an eval file and in
  the format bench's file alike. Which lint a file gets is declared, not
  read off its rows: a path in `FormatFixture.repoPaths`
  (`docs/eval/formatting.json`) of the git checkout it sits in — anchored
  on `.git`, the one marker a commit cannot carry, so nothing in the tree
  can re-root a declared path under itself; outside any git repository,
  where there is no rail, on the checkout root (§1) — gets `FormatLint`, every
  other file the eval lint, and both run the one guard
  (`EvalLint.guardExportFields`), so no fixtures file in the tree is
  outside it. (3) `.gitignore` is the belt
  under both: `/eval/personal*`, `/Bench/personal*`, `*personal*.json`,
  `*personal*.jsonl`, `/*.json` (nothing legitimate is a root-level JSON) and
  `/runs/` (where a relative `--json runs/x.json` lands from the checkout
  root). `scripts/bench-eval.sh` never injects `--append
  docs/eval/leaderboard.jsonl` when a fixtures path was given, so a personal
  run through it can't reach the repo even by omission. A hand-copied
  fixture (raw + gold, no export fields) is invisible to (1) and (2) by
  construction — that is why the workflow is `history-export`, never
  copy-paste, and why personal files live at `$WHISPR_EVAL_HOME` and nowhere
  under `~/repo`.

---

## 9. How to

### Add a fixture

1. Write one `EvalCase` JSON object (§1) — at minimum `id`, `raw`, `gold`.
   Synthetic fixtures go in `EvalCase.seeds` (Swift, so XCTest pins them
   directly); ad-hoc fixtures for a one-off comparison can live in any JSON
   file and be passed as a positional argument.
2. Run `whispr-bench lint your-fixtures.json` — fix every error (a bad span
   or an uncanonicalized number would score silently wrong, not loudly; an
   error naming F / Fi / M / C means the gold does not score 100 against its
   own annotations, so the gold or the annotation has to move).
3. Run `whispr-bench eval your-fixtures.json --formatter rules` once and
   read the row: confirm the verdict and axis scores match what you meant
   before trusting a model column against it.

### Rate a run and turn it into golds

```
whispr-bench rate "$WHISPR_EVAL_HOME/runs/personal.json" \
    --fixtures "$WHISPR_EVAL_HOME/personal.json" --only flagged \
    --out "$WHISPR_EVAL_HOME/ratings.jsonl"
whispr-bench gold "$WHISPR_EVAL_HOME/personal.json" \
    --ratings "$WHISPR_EVAL_HOME/ratings.jsonl" \
    --runs "$WHISPR_EVAL_HOME/runs/personal.json"          # dry run: read the diff first
whispr-bench gold "$WHISPR_EVAL_HOME/personal.json" \
    --ratings "$WHISPR_EVAL_HOME/ratings.jsonl" \
    --runs "$WHISPR_EVAL_HOME/runs/personal.json" --write [--skip-failing]
whispr-bench calibrate --fixtures "$WHISPR_EVAL_HOME/personal.json" \
    --runs "$WHISPR_EVAL_HOME/runs/personal.json" \
    --ratings "$WHISPR_EVAL_HOME/ratings.jsonl" \
    --out "$WHISPR_EVAL_HOME/calibration.md"
```

Rate flagged rows first (gated or ≥ 3 dropped content words), read the gold
diff before writing it, and re-run `calibrate` after each session: the next
`eval --ratings …` prints the live count and the leaderboard row carries the
column's `zero_edit_rate`. A week later, `rate --rerate --only flagged` over
~20 rows gives check 1 its consistency ceiling.

### Compare a prompt variant

```
scripts/bench-eval.sh --formatter llama --system-prompt eval/prompt-variant-a.md \
    --json runs/variant-a.json --report runs/variant-a.md --label variant-a
scripts/bench-eval.sh --formatter llama --system-prompt eval/prompt-variant-b.md \
    --json runs/variant-b.json --report runs/variant-b.md --label variant-b
whispr-bench leaderboard docs/eval/leaderboard.jsonl --diff <run_key_a> <run_key_b>
```

Both runs score the same seeds under the same `scoring_version`, so the Δ is
refused if either changes — the comparison is only ever prompt vs prompt,
nothing else moved. `--level` lets you A/B a level (`fillers` vs `standard`)
on the identical golds the same way. `runs/` under the checkout is gitignored;
a personal set's run files are refused there anyway and go under
`$WHISPR_EVAL_HOME/runs/`.

### Read a report

The terminal output ends with the continuity + new blocks, in this order:

```
  llama      fallbacks: 13/81 · by design: fast-path ×12 · scored as the fallback text: timed-out ×1
  shipped    fallbacks: n/a (history records no provenance; a row is a model row when production would have run the model — ≥ 6 words, or a correction cue at standard — else fast-path)

status     rules PASS | llama FAIL(answered 1, invented 1) | foundation PASS        DRAFT GOLDS: 0/81
composite  rules 71.4 | llama 79.1 | foundation 84.0        CALIBRATION: PENDING (n=0 rated)
axes       F 88/91/93 · Fi 82/95/96 · M 61/71/78
latency    llama p50 417 p90 1650 p99 2900 (≤60w 1650) max 3063 · over 700ms 29/62 · 18.4 ms/word · reprime 900,1100 · WARN
by tag     agent-prompt 74.0 (30) · question 40.0 (5) · control 96.2 (20) · …
```

The fallback lines follow §3's rule: fast-path / raw-mode rows are the
stage's design, timed-out / rejected rows are real behaviour scored as the
fallback text the user got, and only `unavailable` / `request-failed` rows
add a second line — `INVALID — n/N fell back to rules because the harness
failed; NOT model evidence` — the same `harnessFailures` the status line and
the exit code read. Each row's own line reads `verdict · F Fi M C · D [lost N]
I novel · ms`; `lost` appears only when §2.4's D differs from the alignment's.
`status` and `composite` are per formatter column, worst-status-wins for the
process exit code. The `--report` markdown adds what doesn't fit a terminal:
the leaderboard row and its Δ vs the previous comparable row, a verdict
histogram per column, every gated fixture (raw / output / gold word diff,
so you can see exactly what tripped ANSWERED/INVENTED/NEGATED/OVER_EDIT_FACT),
the worst 10 fixtures by C per column, latency broken out by length bucket
plus the excluded `reprime_ms` values, fallback provenance counts, and the
calibration banner. Read status and composite first — everything else is
"why", not "whether".
