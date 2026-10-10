# Formatting: what the app does with structure, and how we know

Punctuation and capitalization were measured from the start (`whispr-bench eval`,
`docs/llm-measurement-gate.md`). **Layout never was** — lists, quotations,
paragraph breaks. This is that measurement, the design it produced, and what is
still missing.

Run it:

```
whispr-bench format                    # the shipping path
whispr-bench format --no-structure     # the same fixtures without the layer
whispr-bench format --no-self-repair   # the shipping path without the self-repair rules ([cleanup] self_repair = false)
whispr-bench format -v                 # show passes too
```

Fixtures: `docs/eval/formatting.json` — synthetic, no personal data, so they
live in the repo next to the code they grade.

Lint them with `whispr-bench lint docs/eval/formatting.json` (`format` runs
the same lint before it loads the model): ids are unique, `raw` and `gold`
are non-empty, every fixture carries a tag (the report is per tag), a
`register` is an app category and a `policy` is `inferring` — what the
report takes for granted of a row, and nothing more. These golds are layout,
so the eval lint's invariant (a gold scores 100 against itself under
`ContentGuard`, whose L1 refuses added lines and markdown — §2 below) is
deliberately not asked of them. `lint` knows this file is the format bench's
from `FormatFixture.repoPaths`, a declared list, never from its rows: a new
fixtures file is added there (`format` then runs it by default), and until
it is, the eval lint reads it and fails it loudly; `lint --format` lints a
file as a format file wherever it sits. The list is read against the git
checkout the file is in — the nearest `.git`, which no commit can carry —
not the nearest `Package.swift`, which one could plant under `docs/` to
re-root a stray copy as "the declared path". A `.git` is read with git's own
test, so for the shapes git makes (a clone's directory, a worktree's or a
submodule's gitfile) a nested one is a nested repository whose files never
reach the rail, and one git does not recognise (a hand-made directory, an
empty `HEAD`, a `gitdir:` pointing at nothing) is nothing to the routing
either; hand-made shapes can still differ on a local disk
(docs/eval-benchmark.md §1), never in a commit. Outside any git repository
at all (an export, a tarball) the nearest `Package.swift` is the checkout,
as it is for the repo-tree refusals, and the rail itself refuses to run.
CI's privacy rail (`scripts/lint-fixtures.sh`, docs/eval-benchmark.md §8,
which fails closed on any list git may have cut short;
`scripts/test-lint-fixtures.sh` proves it) runs the same lint
with `--repo-guard`: a `history:` source or an `observed` / `observed_ms`
field in this file fails the build exactly as it would in an eval file.

## 1. The measurement

| | baseline | with the structure layer |
|---|---|---|
| **exact match** | **19/52** | **33/52** |
| spoken commands | 0/13 | 11/13 |
| quotations | 0/4 | 4/4 |
| line breaks | 0/4 | 4/4 |
| paragraph breaks | 0/4 | 3/4 |
| punctuation preserved through a break | 0/7 | 7/7 |
| prose / casing controls | 4/4 | 4/4 |
| **marker MENTIONED, not commanded** | **10/10** | **0/10** |
| counting controls (must NOT become a list) | 0/2 | 0/2 |
| inferred lists (opt-in, off by default) | 0/2 | 1/2 |
| inverse text normalization | 0/2 | 0/2 (not built) |

Baseline = the formatter alone, which is what the app did before. Same
fixtures, same model, one flag apart; both numbers reproduce across runs.

## 1a. The cost, stated properly

**Every sentence that MENTIONS a marker without a determiner touching it is
restructured, and its marker words are deleted.** Not two sentences — the class.
Ten are fixtured; thirty realistic ones were written during review and thirty
failed.

| said | before | with the layer |
|---|---|---|
| "the api returns **new line** delimited json…" | correct | `The API returns` ⏎ `Delimited JSON so the parser is simple.` |
| "marco wants **bullet point** summaries for every section" | correct | `Marco wants:` ⏎ `- Summaries for every section of the report` |
| "google docs handles **new paragraph** spacing better than word" | correct | `Google Docs handles` ⏎⏎ `Spacing better than Word does.` |

The guard is exactly "is there a determiner or preposition touching the phrase",
and nothing else. "a new line of credit" is caught; "new line delimited json" is
not. **There is no lexical rule that separates them** — "thank you new paragraph
best regards" (a command) and "I asked you new paragraph or new line" (not one)
are the same sentence shape, and seven review rounds of trying produced seven
regressions.

Worth being precise about the severity: the damage is **visible and immediate**,
not silent. He sees `The API returns ⏎ Delimited JSON` at the cursor and fixes
it. The words removed are the marker's own, and the output gate never sees the
deletion because it happens before the model — which is why this is the one
guarantee in §3 written as a limit rather than a promise.

**The fix that would actually work is prosody**, not vocabulary: a spoken command
carries a pause on both sides, a mention does not. That needs per-word timings
from the ASR, which this app does not thread through today. Until then the
tradeoff is the one above.

## 2. Two findings that decided the design

**A 1.5B cannot be prompted into structure.** Given a system prompt that
explained line breaks, bullets and quotations
(`docs/eval/structure-prompt-experiment.txt` — rerun it with
`whispr-bench cleanup "<text>" docs/eval/structure-prompt-experiment.txt`), the
shipping model produced **no line breaks at all**, dropped "he said" from a
quotation, rewrote "new paragraph" as "new line", and *stopped capitalizing
sentences it had been getting right*. A small model given two jobs does
neither. Structure is therefore deterministic here, and the model is never told
about it.

**The benchmark itself refused to grade layout.** `whispr-bench eval` lints its
golds, and a correct bulleted list fails that lint:

```
error: [cmd-bullet] gold does not score 100 against itself — gated multi-line, markdown
error: [list-inferred] gold numeral '1' is not in raw or alternates
```

`ContentGuard`'s **L1 STRUCTURE** rule refuses added lines and markdown
markers, and it is right to: it exists because this model once answered a
question in a bulleted list instead of formatting it. So layout gets its own
benchmark, and L1 is left exactly as it was.

## 3. The design

```
strip fillers → EXTRACT markers → LLM → output gate → APPLY structure → finish
```

The markers are lifted out **before** the model and the real structure is
applied **after** the gate. Three consequences, all of them the point:

- the model sees one clean line and does the job it is good at;
- the gate compares one line against one line, so **L1 never fires and nothing
  it guards is relaxed**;
- a marker cannot be mangled by a model that never saw it.

Positions survive the rewrite by word **alignment** (`Align.align`), not
character offsets — the model re-punctuates and re-cases freely, so a mark
remembers the word it came before. Rendering works on the output's own
whitespace chunks, never on a rebuild from parsed tokens: a token carries a word
and its punctuation, so a rebuild silently ate the `=` in `let x = 1` when this
was first written.

**What is guaranteed:** every letter and digit of the formatter's output
survives (`testNoLetterOrDigitIsEverLost`), and the only punctuation ever
removed is a terminator this layer itself inserted — a mark records that at
insertion time, so his own full stop, an abbreviation's period, an ellipsis and
a semicolon in code are untouchable. **What is not guaranteed:** a marker
this layer ACCEPTS has its words removed before the model, so a wrongly accepted
one deletes them where no gate can see it — that is §1a, and it is the cost of
the feature. A marker it DECLINES keeps its words, even when that prints a
trailing "New line." into the text: a visible stray word beats a silent
deletion. The only exception is a redundant marker ("new line new line"), which
is dropped because he said it twice and meant it once.

This is a deterministic cousin of what the literature recommends. *Paragraph
Segmentation Revisited* (arXiv:2512.24517) forces breaks by constrained
decoding so hallucination is impossible by construction; AssemblyAI's
production punctuation model (arXiv:2501.05948) gates a generator with a token
classifier, which "reduces hallucinations". Shipping dictation apps — Wispr
Flow, Superwhisper, Aqua, VoiceInk, Handy — all free-generate and constrain
with prose instead, which is where their reported failures come from. Full
survey: `~/OS/dev/research/wispr-flow-formatting.md`.

### What the speaker can say

`new line` / `next line` / `line break` · `new paragraph` ·
`bullet point` / `next bullet` / `next bullet point` ·
`and I quote` … `unquote` · `open quote` … `close quote` / `end quote`

Bare `bullet` and bare `quote` are **not** markers — both are ordinary words.
Neither is any phrase carrying its own determiner; see Guards below.

Spoken punctuation ("period", "comma", "question mark") is deliberately **not**
supported: Parakeet already punctuates, and those words carry their ordinary
meaning far too often to be worth the false positives.

### Guards

**One determiner check, plus verb frames for `bullet` alone.** That is the whole
guard, and it is the shape it is because six review rounds proved the
alternative does not exist:

> "thank you **new paragraph** best regards" is a command.
> "I asked you **new paragraph** or new line and you said neither" is not.

Those are the same string. Every attempt to separate them with a second word
list — subject pronouns, modals, verb frames — fixed one and broke the other,
five rounds running. So the guard stayed at one rule and the *phrases* that
needed more than one rule were removed instead:

| removed | why |
|---|---|
| "start a new paragraph", "start a new line", "skip a line" | each carries its own determiner, which blinds the determiner guard. "PLEASE start a new paragraph here is the plan" and "I WILL start a new paragraph when the section changes" are indistinguishable. Say "new paragraph". |
| bare "quote" | an ordinary verb. Matching it deleted his verb and wrapped the rest of the sentence in quotation marks ("please quote the new price and then unquote the old one"). Say "and I quote" or "open quote". |

`bullet point` keeps a verb-frame list because it is the one marker that is
itself an ordinary verb ("can you bullet point that for me"), and no determiner
ever precedes it. Object pronouns are deliberately not in that list: "email ME
bullet point finish the deck" is a real list.

- **Determiner guard** — "a new line of credit", "the bullet point I made",
  "every new paragraph" stay literal. A marker preceded by a determiner or
  followed by "of"/"about"/"for" is speech *about* layout.
- **Pruning** — a marker that structures nothing (trailing, or a leading line
  break), and an unpaired or empty quotation, **keeps its words**. Dropping them
  was a silent deletion that happened *before* the output gate, where nothing
  downstream could see it.
- **Registers** (`SpokenStructure.Policy`) — a shell gets **nothing** (a newline
  there is Return, which runs the half-typed command); an IDE gets breaks but no
  bullets, no invented periods and no forced capitals.

### Inferred lists

"first … second … third" (or "one … two … three") becomes a numbered list with
no spoken marker — the thing Wispr Flow does with a fine-tuned cloud model. Here
it is rules, and deliberately strict: the run must start at the first item,
ascend without gaps, reach **three** items, never be preceded by a determiner or
followed by "of", and every item must carry at least **two** words of its own.

Everything below that bar stays prose, which is always a safe answer. The
controls that must never convert are in the fixture set and in
`SpokenStructureTests`:

> "I have one dog, two cats and three birds" · "first we ship it then we tell the
> team" · "the first thing you notice… the second… the third time" · "one of the
> things I noticed… two of the tests… three people"

VoiceInk's shipped prompt is the only other implementation anywhere with an
explicit version of this guard: *"Format clear enumerations as vertical lists…
Keep ordinary mentions of connected items in prose."*

### Finishing

The model capitalizes an opening word and terminates a sentence only
*sometimes*. Where the register wants it (`Policy.finishes` — not code, not a
shell), both are made certain, and a closing quotation takes the period inside
it: `right."` not `right".`

**Always a period, never a guessed question mark.** Inferring "?" from the
opening word turned "can do" into "can do?"; narrowing the predicate to
auxiliary-plus-pronoun then lost "is the migration reversible?". The model marks
its own questions correctly nearly always, and on the rare one it leaves bare, a
period is the small predictable error rather than the large surprising one.

## 4. What is still missing

| gap | evidence | status |
|---|---|---|
| **Inverse text normalization** — "forty two maple street" stays words, "fifteen hundred dollars" never becomes `$1,500` | 0/2, tagged `not-built` | **the biggest remaining gap.** `NumberCanon` already parses spoken numbers to digits for the invented-numeral gate, so the parsing half exists; the risky half is deciding *when* to digitize ("I have two options" must stay words). Deserves its own benchmark and gate. |
| Proper nouns in short segments — `- Call marco` | 2 fixtures | model limitation, not layout. The personal dictionary can pin specific names. |
| Model over-edits a control — "needs a topic sentence" → "should begin with a topic sentence" | 1 fixture | known Qwen behaviour (`docs/llm-measurement-gate.md`); two novel words is under L6's three-word floor. |
| A dangling connective — "Thanks for the update, and" before a break | `cmd-connective-before-break` FAILS by design; its gold holds the right answer | deliberate. Trimming it deleted "or" from "ship it friday OR new line we could wait", which changed what he said. Awkward beats lossy. |
| A list item keeps a comma he paused on — "- Buy milk," | not fixtured | the same trade: his punctuation is never rewritten, so a pause comma before a bullet survives. |
| The model ANSWERS a question about layout — "could you skip a line between the paragraphs" → "Sure, I'll skip a line between paragraphs." | not fixtured | pre-existing and **deliberate**: the opener and answer-shape gates are bench-only, because live they refused formatted imperatives (`docs/llm-measurement-gate.md`). This feature makes speech *about* layout more likely, so the gap is more reachable — but re-enabling those rules is a measured decision that was already taken the other way. |
| Arbitrary inferred structure — headings, tables, code fences | not fixtured | needs a fine-tuned formatter. Wispr Flow reportedly emits markdown tables and backticks; a generic local 1.5B will not, and prompting it makes everything else worse (§2). |

## 5. Honest comparison

Wispr Flow runs a **fine-tuned Llama in the cloud** (Baseten/TensorRT, p99
<700ms) with app category, surrounding text and a screenshot as context, and
infers structure with no spoken markers — they position explicitly *against*
commands as "unnatural… interrupt your flow of thought". They do nonetheless
support them: their help centre documents "new line", "next line", "line
break", "skip a line", "new paragraph"/"start a new paragraph", quotation
marks and ~30 punctuation names, handled inside the same model as *a precision
override on top of inference, not the mechanism*.

whispr-bro runs a generic 1.5B **locally, offline, by design**. It cannot match
open-ended inference, and prompting it to try measurably degrades the core job.
What it can do — and now does — is handle every structure the speaker states
outright, deterministically, with the marker consumed and no model involved.
Wispr supports most of the same commands — breaks, paragraphs, quotation marks,
punctuation names, though **not** a bullet command — and routes them through the
model that also free-generates everything else. Here they cannot be mangled,
because nothing that could mangle them ever sees them.

**Inference is where the gap is real and stays open.** Wispr turns speech into
a list with no marker at all. The rules tried here could not: see §4.

The path to closing the inference gap, if it is ever worth it, is a fine-tuned
local formatter or the tagger-gates-generator architecture from §3 — not a
longer prompt.
