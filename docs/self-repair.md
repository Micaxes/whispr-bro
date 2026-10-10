# Self-repair: removing what he took back, by rules

A dictation is spoken, so it carries the speaker's own repairs: a word said
twice, a word cut off and restarted, "on Thursday, no wait, Friday", a sentence
followed by "scratch that". Before this stage they came through verbatim
unless the 1.5B formatter happened to resolve them, and it mostly did not.

`SelfRepair` (`Sources/WhisprBroCore/Dictionary/SelfRepair.swift`) removes them
with deterministic rules: no model, deletion only, well under a millisecond on
a typical dictation. It is a port of a reference implementation that was
measured on the maintainer's own dictations, attacked by a red team, hardened,
checked again on a holdout written after the hardening, and hardened once more
where the port's reviewers found it deleting a list item, a correction he
was only describing, a doubled word that was meant or a short word of
another language, putting a verb in a noun's place, keeping the word a
correction took back, taking back a whole clause for a verb phrase or a
noun, grafting a correction onto a relative clause, or taking a
determiner, a verb or a subject that a correction left alone (§3, §5).
The last two rounds added no deletion: every change refuses one, and now no
correction can take a word the version before them keeps — each dictation
runs through that version's rules first, and nothing they keep is deleted
(§3, "The valve").

```
whispr-bench repairs --text "ship it Thursday, no wait, Friday after lunch"
whispr-bench repairs --in rows.jsonl --out run.jsonl              # a set: per-rule fires, latency
whispr-bench repairs --in set.json --compare reference.jsonl      # byte parity with the reference (§8)
```

## 1. Where it runs

```
ASR → dictionary → SELF-REPAIR → filler strip → spoken layout → formatter → finishing
```

- **After the dictionary**, so a dictionary term is protected (it is never
  taken for a cut-off word, and never re-cased).
- **Before the filler strip**, because the fillers are its evidence: "ten,
  uh, ten runs" is a repeat across a filled pause; once the strip has run it
  reads "ten, ten runs", a list. It never deletes a filler on its own — a
  filler inside a deleted run goes with it, and the strip takes the rest.
- **Before the spoken layout**, and blind to it: a layout phrase ("bullet
  point", "new line", "new paragraph", "open quote" …) is a boundary no rule
  reads, deletes or reaches across (guard T16). Two equal items in a row —
  "bullet point yes bullet point yes bullet point no", a roll call, a tally —
  stay two items, and a doubled "new line new line" is left for
  `SpokenStructure`, which drops the redundant one itself.
- **Under the filler strip's gate** (`DictationPipeline.prePass`): nothing at
  the verbatim level, nothing in a verbatim register — the code editors,
  terminals and notes apps the app recognizes (`AppCategoryResolver`, and
  the registers `[cleanup] verbatim_categories` names: `ide`, `terminal`
  and `notes` by default). Every other app gets the full pass: cmux
  resolves to no category on purpose (`HistoryExport.registerOverrides`
  says why), so the rules and the filler strip both run there. Settings'
  caption says so, and `SettingsCopyTests` holds it to the resolver. The
  level decides which rules run:

| Auto-Clean level | Rules |
|---|---|
| Off (verbatim) | none |
| Fillers and repeats (the default) | R1 repetition, R1B inflected restart, R3 cut-off words — the ones the next word completes ("lo logs"); not R3's lone non-words |
| Standard | all eight, R3's lone non-words included ("the b chair") |

  A lone one- or two-letter non-word can be a lower-case abbreviation ("the
  pr is ready", "ask my pt"), so only Standard takes it. On the maintainer's
  dictations that costs 3 of the repairs the Fillers level would otherwise
  fix (he dictates at Standard, where they are fixed); on the holdout it
  keeps 8 rows of content at Fillers.

  The middle level was "Fillers only" until it took repeated and cut-off
  words too. Only the label changed (`Level.displayName`, which Settings,
  the menu bar, the iOS app and `config.toml`'s comment all print); the
  saved value is still `fillers`, so no one's level moved.
- **`collapse_stutters`** (`[cleanup]` in `config.toml`, on by default) is the
  switch for repeated words: off, the filler strip keeps "I I", and R1 does
  not run either. The other rules still do.
- **`self_repair`** (`[cleanup]`, on by default; Settings → Auto-Clean →
  Self-corrections, "Fix self-corrections") is the rules' own switch. Off,
  no rule runs at any level: the pre-pass is the filler strip alone, the app
  before the rules byte for byte. Replayed against a build of that version
  (2f70cab) over the four commit-safe sets — 1,677 rows × 3 levels × 7
  registers × `collapse_stutters` on and off, 70,434 dictations — what
  reached the formatter and the final text are identical on every one (47
  of those rows are pinned in `SelfRepairSwitchTests`); on, the rules change
  1,120 of the 13,416 prose-register dictations at Fillers and 2,512 at
  Standard (2,520 before v9 kept a compound's head corrected alone both
  ways), and none in a verbatim register. It is the way out when the
  rules keep taking words he meant (§7), short of a lower level, which also
  drops what the model resolves. Settings' level rows and the "Rules only"
  subtitle follow the switch: off, they say fillers and stutters ("I I I")
  are removed, and at Standard that spoken corrections are left to the AI
  rewrite, or stay when it is off too (`SelfRepairCopy`, held to the
  pre-pass in `SettingsCopyTests`). The switch's own caption says the same:
  off, only fillers go, and stutters while `collapse_stutters` is on; at
  Standard the AI rewrite "can still resolve some spoken corrections". Some,
  not all: through the app's text path at Standard in the messaging
  register, with the rules off, the model resolved 8 of 12 invented cued
  corrections, left 3 as said ("Send the report to Sam, I mean Dana, before
  noon") and reversed one ("Let's use Redis. Scratch that, let's use
  Postgres." came out "Let's use Postgres. Scratch that, let's use
  Redis."); the round-3 review measured 2 of 6.
  The Settings toggle rewrites that one line of `config.toml` in place
  (`ConfigStore.setCleanupSwitch`): comments, layout, line endings and
  permissions stay, a symlink is written through, and an edit that would
  change any other setting is refused and writes nothing; then the file is
  reloaded. Each dictation takes it from the snapshot it starts with,
  Command Mode with nothing selected follows it, and the iOS app reads the
  same key.
- **English only.** It does not run when the dictation language is Italian or
  Spanish, and on an English dictation it leaves alone any text that
  NaturalLanguage's recognizer is at least 90% sure is another language (4+
  words). The doubles an English dictation borrows are kept, at both levels
  (T3), where the rules know the word: the fixed and emphatic doubles of
  Italian, Spanish, Portuguese, French, German, Arabic, Hindi, Greek and
  Hawaiian on one list ("ciao ciao", "tanti tanti baci", "quasi quasi",
  "tchau tchau", "yalla yalla", "lomi lomi"); on a second, the everyday
  words of Italian, Spanish, Portuguese and French that English does not
  use, doubled for emphasis ("caldo caldo", "lento lento", "piccolo
  piccolo", "lindo lindo", "scusa scusa"); and the double of any word spelt
  with a letter English does not use ("già già"). A double of a word on
  neither list still loses a copy ("the sea was cristallino cristallino
  today"; §7). Their "W a W" idioms are not restarts either ("Uno a uno we
  checked every room", "Paso a paso", T23). Nor does R3 take the short
  words it borrows for cut-off junk at Standard (T20): a one- or two-letter
  word of Italian, Spanish, French, Portuguese or German stays ("ti amo",
  "fa freddo", "ve lo dico", "j'ai lu", "eu ia", "wo bist du") — every
  string the macOS spelling checkers of those languages accept as a word
  of its language; the letters, abbreviations, numerals and chat shorthand
  they also accept ("gr", "pr", "pq") are still taken (§3) — as do
  English's own "kung fu", "deja vu", "a photo op" and "wi fi". A short
  word of a language those checkers do not cover can still go at Standard
  (Hawaiian "ua mau ke ea" loses its "ua"; §7).
- The same stage runs in `whispr-bench eval`, `cleanup` and `format`, and in
  Command Mode when nothing is selected (`DictationPipeline.finish`: the
  spoken words land as a dictation's do), so the leaderboard measures what
  ships. `--no-self-repair` runs the bench without the rules, as
  `self_repair = false` runs the app; an eval run made so records it in its
  config (`"self_repair": false`), its `run_key` and its leaderboard row,
  marks its level "(self-repair off)" in the report, and is compared only
  with runs like it (every key minted before the switch is unchanged). On
  the 81 seeds the rules column scores C 90.4 without the rules, 91.6 with
  them.

## 2. The rules

Each pass runs the rules in the order below; passes repeat (at most 4) until
one deletes nothing. Every example is invented.

| Rule | Removes | Said → kept | Level |
|---|---|---|---|
| R4S sentence retraction | a sentence taken back by the cue that opens the next one: "scratch that" always; another cue only when the new sentence restates the first two words | "Let's use Redis. Scratch that, let's use Postgres." → "Let's use Postgres." | Standard |
| R5 cued numeric restart | a number corrected after a cue | "it takes about 3, sorry, 4 seconds" → "it takes about 4 seconds" | Standard |
| R4 cued swap | X and the cue in "X, no wait, Y", where X and Y fill the same slot (same day, month, colour, direction, name, or the same word class) — never a noun X and a Y that heads a verb phrase of its own (T24), and never a compound noun's head for a lone word: a new modifier said with the head again replaces the whole compound, and a possessive said with the head again keeps both (T25); "scratch that" mid-sentence takes back X's verb phrase (T26: not one inside a relative clause after the verb) or its clause, or, when only a noun phrase follows a clause with a verb, that noun phrase's slot (T21); never a word v11's rules keep (the valve) | "ship it Thursday, no wait, Friday" → "ship it Friday"; "Book a window seat, scratch that, an aisle seat" → "Book an aisle seat"; "Use the staging bucket, I mean, prod bucket" → "Use the prod bucket"; "Review the draft, scratch that, Dana Smith's draft" → "Review Dana Smith's draft"; "Use the shared folder, I mean, Sam's folder" stays | Standard |
| R2 restart | an abandoned start restated: "G B G" — not an idiom of another language ("Uno a uno", T23) | "I told them to I told you to stop" → "I told you to stop" | Standard |
| R2B pronoun restart | a lone "I" restarted as another subject | "I we should leave now" → "We should leave now" | Standard |
| R3 fragment | a cut-off word before the word it starts ("check the lo logs" → "check the logs"; "the sto, the stock room" → "the stock room"); at Standard also a 1–2 letter non-word between words, unless it is a short word of another language or of English the rules list (T20) | | Fillers (cut-off words), Standard (all) |
| R1 repetition | a word or phrase (up to 4 words) said again, directly, across a filler, or across "like" / "you know" | "we went over over these" → "we went over these" | Fillers, Standard |
| R1B inflected restart | a word restarted as its plural after a number or a plural word | "two more server servers" → "two more servers" | Fillers, Standard |

The cues: "I mean", "I meant", "no wait", "scratch that", "or rather",
"sorry", and — only with a comma before them — "actually", "no", "wait".

## 3. The guards

The first version fired on content that looks like a repair. A blind red team
wrote 858 rows to break it; each guard below stops one class of false fire,
and each is pinned by a fixture that fires once the guard is switched off
(`SelfRepairTests.testEveryGuardIsLoadBearing`). T16 to T26 came from the
port's reviewers. Not every guard only stops a fire: T14 and T22 let a fire
through, T24 stops a word swap but after "scratch that" takes back a clause
that v7 kept (part stop, part fire), T25 stops one swap and widens another,
and T26 narrows a retraction. T22's cases are kept whole again once it is
off (`testT22LetsItsStuttersThrough`), and T25's and T26's come out
otherwise (`testT25ReplacesTheWholeCompound`,
`testT26KeepsWhatStandsBeforeTheVerb`); v10's, v11's and v12's readings
have their own tests (`testT24ReadsOnlyAnObjectAsARestatement`,
`testT26StopsAtARelativeClause`, `testT25KeepsAPossessiveBothWays`,
`testT24ReadsNoNameAsAVerb`, `testTheValveKeepsWhatV11Keeps`).

| Guard | Keeps | Example |
|---|---|---|
| T1 | a noun, then the same word as the bare verb of an inverted question | "Does the scan scan every folder?" |
| T2a, T2b | a name, then the word it spells | "I hope Will will review it", "Drew drew it" |
| T3 | fixed and emphatic doubles: English ones, other languages' (a list), the everyday words of Italian, Spanish, Portuguese and French that English does not use (a second list), and the double of any word spelt with a letter English does not use | "a win win", "cous cous", "Same same, but different", "tanti tanti baci", "quasi quasi", "lomi lomi", "woof woof", "It was caldo caldo at the beach", "già già" |
| T4 | spoken symbols, keys and layout markers | "dash dash help", "C plus plus", "new line new line" |
| T5 | single-quoted text, like double-quoted text | "He kept typing 'the the' by mistake." |
| T5b | brackets and quotation marks: a deletion never orphans one | "(the the cat sat there)" |
| T6 | emphatic "do do" after its subject | "We do do retros" |
| T7 | "so so" and "my my" before a break | "The demo was so so, the music was better." |
| T8 | "up up" | "Line them up up front." |
| T9 | a capitalised double mid-sentence | "Their opener was The The." |
| T10 | a repeated non-word | "It beeps zz zz zz all night." |
| T11a | the letter after "an" | "Add an m maybe, not an n." |
| T11b | a unit after digits | "Add 2 g garlic" |
| T13 | across a sentence break, a number that does not stand alone | "Can we do 6? I mean 7 works too." |
| T14 | (a fix, not a stop) a repeat across an earlier deletion is still found | "I think I, I think we should wait." → "I think we should wait." |
| T15 | a bracket, quote or dash is not a sentence end | "We use Redis (version 7). Scratch that, …" |
| T16 | spoken layout: a marker phrase is a boundary — never read, deleted or reached across | "survey answers bullet point yes bullet point yes bullet point no" keeps both yeses |
| T17 | a correction inside words he presents as words — reported, quoted, specified, exemplified, labelled — where a frame around them shows it (a heuristic) | "Add a fixture where the input is meet on Tuesday, no wait, Wednesday", "The bug report says it costs 30, sorry, 40 dollars", "Use leave at 4, sorry, 5 as the probe" |
| T18 | a double that stands alone — the whole sentence, or its first or last clause: an interjection, a sign-off, a chant; a layout marker is a break but no sentence edge (the punctuation written on it is one), and a bulleted item is never alone | "Cool cool, see you then.", "Forza forza!", "See you Sunday, baci baci", "see you at eight new line hugs hugs", "See you at eight new line. Hugs hugs, call me later." |
| T19 | English grammar doubles: a phrasal verb's particle before the same preposition, when a time follows (or, after the verb's object, a noun phrase); "are", "were", "did" after a wh-word and its subject | "Swing by by noon", "Think it over over the weekend", "What the options are are listed below" |
| T20 | a short word of another language, or of English, between words: R3 does not take it for a cut-off one | "Running late, ti chiamo after lunch.", "Tell them ve lo porto domani.", "Nobody knows, chi sa, maybe it works.", "Connect to the wi fi network." |
| T21 | after a mid-sentence "scratch that", a bare noun phrase takes back only the noun phrase in its slot; when no slot fits, both are kept | "Book a window seat, scratch that, an aisle seat." → "Book an aisle seat."; "The cache was slow, scratch that, the database." stays |
| T22 | (a fix, not a stop) "is", "was", "do", "does" said twice right after a wh-word are a stutter; with a subject between they stay, as before | "What is is your name?" → "What is your name?"; "What it is is a timing bug." stays |
| T23 | a one-word head of another language opening an idiom: R2 does not take it for a restart | "Uno a uno we checked every room.", "Paso a paso we got there." |
| T24 | (part stop, part fire) a verb heading its own phrase after the cue — an object or a particle right after it, or the noun before the cue said again as its object (across determiners, the object's own modifiers, a two-word verb's second word and one particle, not a preposition or "and"; after in, on, off or over both are kept, also when the phrase runs on into a clause of its own) — is no replacement for that noun: both are kept; after "scratch that" it is a clause, and the clause before it goes, unless a noun with its own object reads the same and nothing shows a verb: then both are kept. A name opening the phrase, an inflected word after its first, or a first word modifying a possessive is no verb: then the noun phrase takes its slot (T21), and a clause goes only where a name opens it; the noun said again with its modifiers and no determiner keeps both, and after "scratch that" T21's slot does not take it when the phrase opens with a word that is no determiner or adjective | "Reset the branch, I mean, fork the branch." stays; "Wash the deck, I mean, power wash the deck." stays; "Delete the logs, scratch that, archive the logs." → "Archive the logs."; "Send the team, scratch that, client the slides." stays; "Send the file, I mean, link to the file." → "Send the link to the file."; "Can you send the invoice, scratch that, Dana Smith the invoice?" → "Can you send Dana Smith the invoice?"; "Email expense receipts, I mean, print expense receipts." and "Send old log files, scratch that, forward old log files." stay |
| T25 | (a stop and a wider swap) a compound noun's head is no slot for a lone word after the cue: said again with a new modifier, the whole compound is replaced — not when a verb follows the head said again, and not for an addition ("works too"); said again with a possessive (with or without its own determiner), both are kept, after every cue; corrected by its modifier alone, both are kept | "Use the staging bucket, I mean, prod bucket." → "Use the prod bucket."; "Use the shared folder, I mean, Sam's folder." stays; "Book the big room, I mean, small room is free." stays; "Restart the staging server, I mean, prod." stays |
| T26 | (a narrower fire) "scratch that" before a verb phrase with no subject takes back that verb phrase, not the subject, auxiliary or first conjunct before it — but not a verb inside a relative clause after the verb: then the whole clause goes; after a relative clause in the subject, the main clause's verb phrase goes | "I'll call him, scratch that, text him tonight." → "I'll text him tonight."; "Email the guy who can fix it, scratch that, call him." → "Call him."; "The client who called will email the contract, scratch that, mail the contract." → "The client who called will mail the contract." |

**T16 in detail.** The markers are found as `SpokenStructure` will find them
once the fillers are gone: its own phrases, in its order, on the words
lower-cased with punctuation dropped ("Bullet point," and "new, um, line"
both count). Its refusals ("a new line of credit", a register without
bullets) are not copied: a phrase it will leave as words is still a boundary
here, which can cost a repair but never an item. No rule deletes a marker, so
a sentence retracted across one is kept whole ("Buy milk. Scratch that, new
line buy eggs" stays): removing it would leave the marker with nothing before
it, and `SpokenStructure` would print "New line" as words.

**T17 in detail.** A dictated prompt, spec or test about this very app often
holds a repair inside words presented as words — what was said, what the
app typed, what a test should hold — rather than in the message itself. The
rules cannot read meaning, so T17 reads the frames that introduce words as
words (the reference's MENTIONS, v4) and keeps every word they reach:

- a verb whose object can be words — say, write, type, dictate, transcribe,
  read, hear, print, paste, insert, show, display, return, output, expect —
  with a subject: "the bug report says …", "when I said …", "it should
  return …" (dictate and transcribe take words even without one). Not an
  imperative ("Say thanks …"), a hedge ("I'd say …"), "as I said", an
  instrument's reading ("my watch says 48, sorry, 49"), or an object that
  is a thing ("I wrote the report on Monday, sorry, Tuesday"), a quantity
  ("we expected 30, sorry, 40 guests") or a prediction ("I expect we'll
  land at 6, sorry, 7"): those are his corrections, and they are fixed;
- a noun for words with a copula, a containing verb or a linker: "the input
  is …", "the transcript contains …", "a test where …", "an input like …",
  "the phrase …" — not when what follows places or grades the noun ("the
  message is from Sam, I mean Dana" is fixed);
- the two sides of a described rewrite: "… becomes …", "turn … into …", "…
  comes out as …", and the side before it when the side after deletes to it
  ("given meet at 2, actually 3, the rules return meet at 3");
- an exemplifier ("for example …", "such as …", "e.g. …"), a label before a
  colon ("Expected: …", "she wrote back: …"), a repair named after the words
  ("… is a cued swap"), a spoken quotation ("and I quote … unquote"), a mark
  of literal fidelity ("keep … verbatim", "… as is"), a deletion described
  on the text ("it deleted Thursday from Thursday, no wait, Friday") and
  words put into a test ("use … as the probe", "add … to the test").

A mention reaches to the end of its clause, twelve words at most, and across
the commas around a cue ("Friday, no wait, Saturday" is one stretch).

It is a heuristic over the words around a stretch, not an understanding of
it: a description no frame matches is still repaired, and some corrections
he makes inside words he reports are kept (§7 says which). "like" alone
opens no mention ("things like …"): as a trigger anywhere it cost 2 of the
maintainer's fixed repairs, 33 synthetic and 11 red-team ones.

**Its numbers are development numbers.** The probes below are invented
sentences written by the people who wrote the frames, who tuned the frames on
them; v3's four triggers were the phrasings of the round-1 probes they were
measured on, and these frames will likewise read their own probes better than
new text. A probe counts only if the rules change it once T17 is off.

| Probes (invented), rules alone, Standard | Descriptions kept intact | Real corrections still fixed |
|---|---|---|
| development: 8 batches | 247 of 260 (v3: 39) | 200 of 203 (v3: 203) |
| one batch written before the code, run once | 25 of 28 (v3: 0) | 18 of 20 (v3: 17) |

The measure to trust is a set written blind to the frames: on the round-1
reviewer's 25 fresh descriptions, through the app at the maintainer's
settings with the rules alone, the app without the rules kept 21 intact and
v3 kept 5; v4 has not been measured on them by its authors. On the five eval
sets T17 v4 loses no repair at either level: it keeps three more synthetic
rows that describe a correction (two at Fillers), and changes none of the
maintainer's dictations and no fire in the written-English corpus.

Before the red team the rules also knew the commoner look-alikes: "the fact
that that", "what it is is", "had had", "very very", "Bora Bora", "at AT&T",
"from time to time", "the The Times", "I paid for forty", "plan b", "the s
flag", "my ex explained it", "by done I mean merged".

**Doubles that are meant: T3, T18, T19 in detail.** R1 takes a word said
twice, and some doubles are the words themselves. The reviewers found the
rules cutting other languages' doubles that were meant, at both levels:
"Baci baci" became "Baci", "Quasi quasi I'll stay another week" became
"Quasi I'll stay …" (from "I'm tempted to" to "almost"), and "the lomi lomi
massage" lost a "lomi". Three guards keep them — a principle wherever one
reaches, a list where none does:

- **A word English does not spell** (T3). The double of any word with a
  letter outside ASCII is another language's: "già già", "più più",
  "tschüss tschüss", "não não". The rules' word lists are English and know
  nothing of such a word. None of the maintainer's 121 dictations holds an
  accented letter, so this costs them nothing; it does keep a stutter on an
  accented English loan word ("the café café").
- **A list** (T3), 138 words: the fixed and emphatic doubles of other
  languages — Italian ("tanti tanti", "baci baci",
  "forza forza", "quasi quasi", "zitto zitto", "subito subito", "presto
  presto", "via via", "piano piano"), Spanish, Portuguese, French and German
  ("claro claro", "tchau tchau", "bisous bisous", "ja ja"), Arabic, Hindi and
  Greek ("yalla yalla", "jaldi jaldi", "siga siga"), Hawaiian ("lomi lomi",
  "huli huli", "lau lau"), kisses and sound words ("mwah mwah", "woof woof",
  "putt putt"). A word is on it only if its double is a set expression in its
  language and the word is not everyday English, so that a stutter on it is
  rare: in the 2.32 million words of written English (§5) 77 of the 113 words
  added never occur and 104 at most five times; the commonest are "ay" (102,
  16 of them its own double) and "via" (44 — a stuttered "via via" is kept).
  Everyday words stay off ("wiki", "sim", "vite", "zoom", "cool", "sorry"):
  doubled, they are mostly stutters.
- **A second list** (T3, since v7), 653 words: the everyday words of
  Italian, Spanish, Portuguese and French that English does not use — the
  adjectives and adverbs those languages double for emphasis ("caldo
  caldo", "stanco stanco", "lento lento", "piccolo piccolo", "lindo lindo",
  "despacito despacito"), their doubled interjections, imperatives and
  endearments ("scusa scusa", "amore amore"), and the nouns of their "W a
  W" idioms (T23 below). It is built from hand-written lemmas with every
  gender and number form spelt out (`work-r1/foreign_words.py` in the
  private eval), and a word is on it only if Apple's English word embedding
  does not hold it and written English uses it fewer than five times in
  the 2.32 million words of §5, with Apple's Italian, Spanish or French
  embedding as a check on the spelling (NaturalLanguage has no Portuguese
  one). So English's look-alikes stay off ("solo", "fine", "care",
  "petite", "gelato"); the Italian words English holds only as a borrowed
  term of music, art or a name are on ("piccolo", "dolce", "forte",
  "fresco", "alto"). The reviewers' own test — fewer than five times in
  that corpus, nothing else — was measured and not used: the corpus is
  mostly nineteenth-century novels, 102 of 173 modern words checked fall
  under it ("email", "app", "password", "update", "workout"), and as a
  guard it would have kept six stutters the rules fix in the eval sets —
  four synthetic ("backfill backfill", "onboarding onboarding") and two in
  the holdout ("repo repo", "update update") — to stop one false fire (a
  holdout "cache cache", the noun and then the verb).
- **A double that stands alone** (T18): the whole sentence, or its first or
  last clause, cut off by punctuation, with no filler between the copies —
  "Cool cool, see you then.", "Sorry sorry, I meant the other file.", "Forza
  forza!", "See you at eight, hugs hugs." A stutter is a false start before
  the words that follow it; a double with nothing after it in its clause is
  an interjection, a sign-off or a chant (three copies chanted at a
  sentence's end were kept from the first version). Between two commas it
  still goes ("eggs, milk milk, and bread"), and so does a double that runs on
  into its sentence ("Tomorrow tomorrow we ship"). It keeps a list item
  stuttered at a sentence edge ("Milk milk, eggs and bread."). Since v7 a
  spoken layout marker is a break but no sentence edge, and the words after
  "bullet point" are a list item, never an interjection: "groceries bullet
  point eggs eggs bullet point milk" loses an "eggs" and "to do new line
  invoices invoices new line pay rent" an "invoices" (v5 and v6 kept both,
  and with the AI rewrite on the formatter can leave them too), while "see
  you at eight new line hugs hugs" stays — its other edge is the text's.
  Since v8 the punctuation the recogniser writes on a marker's own words
  counts like any other: "See you at eight new line. Hugs hugs, call me
  later." keeps both (v7 read no edge at "new line." and lost a "hugs").
  One rule decides the edge — the punctuation written, wherever it was
  written; a bare marker is a break, no edge — so a one-word item said
  twice still loses a copy between bare markers, and keeps both when the
  recogniser wrote it as a sentence of its own ("To do. New line. Invoices
  invoices. New line. Pay rent.", "Agenda new line. Budget budget, hiring,
  roadmap."), as "Milk milk, eggs and bread." does.
  With the AI rewrite on, the model sees what the rules keep and can still
  merge a double they kept on purpose; only "Rules only" keeps every one
  (§6).
- **English grammar** (T19). A phrasal verb's particle before the same word
  as a preposition — "swing by by noon", "come over over the holidays",
  "think it over over the weekend", "pass the salad over over the table" —
  read from the verbs that take the particle (swing, stop, drop, come, pop
  and go by; come, go, head, sleep, stay, have, think, talk, pass and others
  over; come, swing, stop, drop and head around; write, jot and note down)
  and from what follows. Right after the verb only a time keeps it ("by
  noon", "by 6 pm", "over the holidays", "by the end of the day"), because
  the same shape is a stutter when the verb takes what follows: "we went
  over over these numbers", "swing by by the office" and "went over over the
  last two weeks of data" still lose a word. A number is a time only after
  "by" or "around", and only as a clock time ("by 5 if you can"): after
  "over" it is an amount, so "I looked over over 40 resumes" and "drop by
  by 5 percent" or "by by 5 each year" still lose a word too. After the
  verb's object, a noun phrase keeps it as well. And "are",
  "were" and "did" after a wh-word and its subject: "what the options are
  are listed below", "whatever you did did the trick". With nothing between
  the wh-word and the double it is the commonest question stutter, and it
  goes: "What are are you doing tonight?", "How did did that happen?"; since
  T22 so do "What is is your name?" and "How does does it work?", which every
  version before kept. "had had", "that that", "what it is is", "in in" and
  "on on" were kept from the first version, "up up" since the red team.

On the maintainer's 121 dictations the three change nothing, at either
level; on the synthetic, public and red-team sets nothing either. The
holdout and the corpus numbers are in §5. Probes, rules alone (each level
gives the same counts; a probe counts as a double only if v4 cut it):

| Probes (invented), rules alone, Fillers and Standard | Doubles kept intact | Stutters still fixed |
|---|---|---|
| development: 129 sentences, tuned on | 76 of 78 (v4: 0) | 26 of 30 (v4: 30) |
| 58 sentences written before the code, run once | 33 of 33 (v4: 0) | 11 of 14 (v4: 13) |

Every stutter they no longer fix is one of the costs above, written in on
purpose: "the café café", "the jalapeño jalapeño", "the résumé résumé",
"Milk milk, eggs and bread.", "we need eggs, bread, milk milk.", "Bread
bread, milk and coffee." The two development doubles still cut are gaps
(§7): "All it is is a typo" and "he logged out out of habit". The held-out
batch ran before a last fix — a number after the particle as an amount, found
by reviewing the code, with seven development probes added for it — which
changes none of its sentences: the only one with a number after a doubled
particle, "swing by by six and …", reads as a clock time either way.

**Short words, a noun phrase after "scratch that", a double after a wh-word:
T20, T21, T22 in detail.** The integrated branch's reviewers found three more
ways the rules took words he meant, or kept a stutter:

- **Short words of other languages** (T20). At Standard R3 takes a lone 1–2
  letter word that is no English word as a cut-off one, and that included
  short words of other languages: "Running late, ti chiamo after lunch."
  lost its "ti", "fa freddo" its "fa", "chi sa" its "sa" — 8 of the reviewers' 10
  mixed English–Italian messages lost a word, and with the AI rewrite on the
  word is gone before the model sees the text. R3 now keeps the short words
  of other languages (Italian "ti", "su",
  "fa", "sa", "li", "po", "mo", "fu"; Spanish "es"; French "je", "qu", "ta",
  "vu"; German "ja", "zu", "ab"; Portuguese "ao"; Hawaiian "ka", "ke") and
  English words it took for junk ("kung fu", "deja vu", "a photo op", "pi",
  "an ab workout", "oy", "ew"). Only that rule reads the list: a word on it
  said twice is still a stutter to R1. v6's list missed some, and so did
  v7's: v7 added "ve", "lu", "bu", "pu", "ri", "ir" and others ("ve lo
  dico", "j'ai lu", "nous avons bu", "eu ri", "vamos ir", "de buena fe",
  "wo bist du" keep their short word) and claimed every short word of those
  languages, checked against a list written by hand; v8 adds the 16 that
  list missed and checks the claim against the macOS spelling checkers
  instead (below). "um" and "er" (Portuguese "one", German "he") are
  fillers the filler strip takes first, and "fo" (a Spanish and French
  interjection, archaic Italian) stays off — it is far likelier a cut-off
  "for". It also holds English "fi" ("wi fi", "hi fi" and "lo fi" lost it), and so a
  split "we've" keeps its tail: v6 made "I think we ve been there" "I think
  we been there". It changes no row of the five eval sets, at either level;
  in written English v6's list removes 5 of R3's 38 fires at Standard (an
  Italian "mi fa", Irish and archaic "mo" in *Ulysses*, a German "zu", a
  Mayan "ti") and adds none, and v7's additions change none.
- **"Scratch that" before a bare noun phrase** (T21). Mid-sentence, with
  nothing else to match, "scratch that" took back the whole clause before it:
  "Book a window seat, scratch that, an aisle seat." became "An aisle seat.",
  "Invite every engineer, scratch that, only leads." became "Only leads." Now,
  when the words after the cue are a noun phrase with no verb of their own
  and the clause before it has one, only the noun phrase that ends at the cue
  goes — its determiner, numbers and adjectives with it: "Book an aisle
  seat.", "Invite only leads.", "We should take the late one.", "We need 5
  servers, scratch that, a cluster." → "We need a cluster." When the word
  before the cue is no noun ("The cache was slow, scratch that, the
  database."; "Sam fixed it, scratch that, Priya.") or the two heads are of
  different closed kinds ("I want the report by Friday, scratch that, the
  summary."), both are kept: the rules cannot tell which word the correction
  is for. A clause after the cue still takes the clause back ("I'll take the
  train, scratch that, I'll drive." → "I'll drive."), and so does a noun
  phrase after a clause with no verb ("The large pizza, scratch that, two
  medium ones." → "Two medium ones."). Which words are verbs and nouns comes
  from NLTagger (§7 has what that costs).
- **A double right after a wh-word** (T19, T22), above: v5 kept "are are"
  after any nearby wh-word, so "What are are you doing tonight?" kept its
  stutter; the subject between them is what makes the double grammar.

None of the three changes a row of the maintainer's dictations or of the
other four sets, at either level. Probes, rules alone, at Standard, with
v5's count in brackets (at Fillers R3 takes no lone short word and R4 does not
run, so only the wh-word rows change there, the same as at Standard):

| Probes (invented), rules alone, Standard | development (v5) | written before the code, run once (v5) |
|---|---|---|
| a short word of another language or of English kept | 13 of 13 (3) | 6 of 6 (3) |
| junk R3 must still take, taken | 3 of 4 (3) | 2 of 2 (2) |
| a double right after a wh-word, fixed | 12 of 12 (0) | 5 of 5 (0) |
| a double after a wh-word and its subject, kept | 8 of 8 (8) | 3 of 3 (3) |
| a noun phrase after "scratch that": swapped in its slot / both kept / damaged | 7 / 0 / 0 (1 / 0 / 6) | 3 / 0 / 0 (1 / 0 / 2) |
| no slot fits: both kept | 2 of 2 (0) | 1 of 1 (0) |
| a clause after "scratch that": the clause taken back | 4 of 4 (4) | 2 of 2 (2) |

The development miss is a probe written wrong: its "th" is on R3's list of
English short words already.

**List items, other languages' words and idioms: T18, T3, T20 and T23 in
v7.** The branch's round-1 reviewers found four more ways the rules took
what he meant: a one-word list item said twice between layout markers was
kept (T18 read a marker as a sentence edge); 36 of 49 common Italian
adjectives and adverbs doubled for emphasis lost a copy ("The soup was
buona buona, thanks." → "… buona, thanks."); an idiom "W a W" opening a
sentence lost "W a" to R2 ("Uno a uno we checked every room." → "Uno we
checked every room."); and v6's short-word list missed Italian "ve",
French "lu", "bu" and "pu" and Portuguese "ri" and "ir", while this page
said it held them all. T18 and T20 now do what is described above, T3 has
its second list, and T23 is new: R2's restart grammar is English, so a
one-word head of another language — not ASCII, or on one of T3's lists of
other languages' words — opens no restart ("Paso a paso", "Dia a dia",
"Mas y mas"); "Send a send the file" still loses "Send a", and "Win a win
the game" its "Win a" (T3's English words are not other languages').

None of the four changes a row of the maintainer's dictations or of the
other four sets, at either level, or a fire in the written-English corpus.
Probes, rules alone, at Standard, with v6's count in brackets (at Fillers R2
and R3's lone words do not run, so their rows stay as they were; the rest
read the same):

| Probes (invented), rules alone, Standard | development (v6) | written before the code, run once (v6) |
|---|---|---|
| a short word of another language or of English kept | 12 of 12 (0) | 8 of 8 (2) |
| junk R3 must still take, taken | 4 of 4 (4) | 1 of 2 (1) |
| a one-word list item said twice, fixed | 6 of 6 (0) | 3 of 3 (0) |
| a double beside a layout marker that stands alone, kept | 4 of 4 (4) | 2 of 2 (2) |
| another language's word doubled for emphasis, kept | 12 of 12 (0) | 8 of 8 (0) |
| an English stutter on a content word, fixed | 8 of 8 (8) | 4 of 4 (4) |
| an idiom "W a W" of another language, kept | 5 of 5 (0) | 3 of 3 (0) |
| an English restart "W a W …", fixed | 4 of 4 (4) | 2 of 2 (2) |

The held-out miss is a probe written wrong: its "st" is on R3's list of
English short words. Every word of the doubles written before the code
("freddo", "morti", "contenta", "sporchi", "bollente", "vuota",
"tranquilo", "forte") was on the second list; a word that is not still
loses a copy (§7).

**A verb after the cue, punctuation on a layout marker, the rest of the
short words: T24, T18 and T20 in v8.** The branch's round-3 reviewers
found three more:

- **A verb read as a noun** (T24). R4's word swap took the noun before the
  cue and the first word after it as filling the same slot whenever
  NLTagger gave both the same open class, and NLTagger often reads a verb
  after a cue as a noun: "Reset the branch, I mean, fork the branch."
  became "Reset the fork the branch.", "Drop the staging database, I mean,
  clone it first." became "Drop the staging clone it first."; the reviewers
  found 10 of 47 verbs garbled after "I mean" before "<verb> the logs", and
  every cue did it. On 47 one-word verbs of our own in "Can you delete the
  logs, <cue> <verb> the logs?", v7 garbled 13 or 14 after each of the
  eight cues; v8 garbles none. (A phrasal verb whose particle NLTagger
  reads as a preposition still garbled in v8 — "Warm up the cache, I
  mean, clear out the cache" became "Warm up the clear out the cache" —
  until v9, below; with a new object it still does, §7.)
  A verb phrase after the cue is a clause, not a slot filler. When the
  word after the cue can be a verb (no function word, a noun, verb or
  adjective to NLTagger) and an object follows it straight away — a
  determiner, a possessive or an object pronoun, but not "that" (after a
  noun it opens a relative clause: "the summary that I wrote") and not one
  that opens a time ("salad this time") — or a verb particle does ("warm
  up the cache"), and the word before the cue heads a noun phrase (no verb
  to NLTagger, with an article, demonstrative, possessive, determiner,
  preposition or 's before it, across up to three modifiers), the swap is
  off and both are kept. After "scratch that" such a phrase is a clause,
  so the clause before it goes ("Delete the logs, scratch that, archive
  the logs." → "Archive the logs.") — a fire v7 did not make, so T24 was
  never only a stop, and for a noun with its own object v8 took a clause
  that v7 swapped right (v9 below). A verb for a verb still swaps ("Can
  you fork, I mean, clone the repo?" → "Can you clone the repo?"), and so
  does a noun with no object after it ("Put the cup, I mean, glass on the
  table.", "Send the report, I mean, summary that I wrote."). It costs a
  noun swap whose new noun takes its own indirect object, now kept both
  ways ("Send the team, I mean, client the slides."; after "scratch that"
  v8 made it "Client the slides.", fixed in v9), and leaves gaps (§7).
- **Punctuation on a layout marker** (T18), above.
- **The rest of the short words** (T20). v7 still took 16 one- and
  two-letter words of those languages for junk: Portuguese "ia" ("eu ia te
  ligar") and "ar", Spanish "uy", "ea", "ey", "ji", "jo", "ju" and "ro",
  German "hu", Italian and Portuguese "ih", "ut" (the note) and "oc" of
  French and Italian, French "ra" (a drum stroke) and "ki", and Portuguese
  "cu". R3 now keeps them, and the claim rests on the system's own lists:
  the macOS spelling checkers of Italian, Spanish, French, Portuguese (both)
  and German accept 350 one- and two-letter strings, and R3 takes none that
  is a word of its language. It still takes the other 158 — letters and
  their names (17), abbreviations and symbols (114: "cc", "gr", "pr",
  "wh"), Roman numerals (7), chat shorthand (14: "pq", "vc", "xo"), five
  that are no word of those languages we could attest — and "fo" (macOS
  26.5.1; the private eval lists every one with its class).

None of the three changes a row of the maintainer's dictations or of the
other four sets, at either level; in the written-English corpus T20's
additions remove 10 false R3 fires at Standard, all in *Ulysses* (Latin
"ut" and "ea", Irish and spelled-out "ar", a ballad's "ra"), and T24 and
T18 change none. Probes, rules alone, with v7's count in brackets (at
Fillers R4 and R3's lone words do not run, so only the marker rows change
there, the same as at Standard):

| Probes (invented), rules alone, Standard | development (v7) | written before the code, run once (v7) |
|---|---|---|
| a verb heading its phrase after a cue: both kept | 18 of 18 (5; 13 garbled) | 10 of 10 (6; 4 garbled) |
| the same after "scratch that": the clause taken back | 4 of 4 (1; 3 garbled) | 2 of 2 (2) |
| a verb for a verb, fixed | 5 of 5 (5) | 3 of 3 (3) |
| a noun for a noun with no object after it, fixed | 8 of 8 (8) | 4 of 4 (4) |
| a noun with its own indirect object or a time after it, fixed (the cost) | 2 of 4 (4) | 0 of 2 (1) |
| a verb, a preposition and a bare noun, both kept (a gap, §7) | 0 of 3 (0) | 0 of 1 (0) |
| a double after a marker that carries a stop, kept | 7 of 7 (0) | 4 of 4 (0) |
| a list item said twice beside markers, fixed | 4 of 4 (4) | 2 of 2 (2) |
| a list item said twice as a sentence of its own, fixed | 0 of 3 (1) | 0 of 1 (0) |
| a sign-off said twice as a sentence of its own, kept | 3 of 3 (3) | 1 of 1 (1) |
| a short word of another language kept | 12 of 12 (1) | 10 of 10 (0) |
| junk R3 must still take, taken | 6 of 7 (6) | 3 of 3 (3) |

The rows that cost something are measured in on purpose: the list items
written as sentences of their own follow the one rule above (v7 kept two
of the three development ones as well), and the gap rows are §7's. The
development miss among the junk is a probe written wrong: its "sh" is on
R3's list of English short words.

**A noun's own object after "scratch that", a compound's head, the verb
phrase taken back: T24, T25 and T26 in v9.** The re-check of the round-3
fixes found T24 doing more than it said, and two older ways R4 took words
that were meant:

- **"Scratch that" before a noun with its own object** (T24). v8 read a
  word NLTagger tags as a noun, with a determiner after it, as a verb
  heading its phrase — and after "scratch that" took the clause before the
  cue back: "Send the team, scratch that, client the slides." became
  "Client the slides.", "Call the plumber, scratch that, electrician my
  neighbor recommended." became "Electrician my neighbor recommended.",
  where v7 swapped the noun. Now, where a noun with its own object,
  indirect object or reduced relative reads the same, that shape is a verb
  phrase only with a verb's evidence: the object said again ("Delete the
  logs, scratch that, archive the logs." → "Archive the logs.") or an
  object pronoun no noun takes ("Rename the file, scratch that, delete
  it.", "Please delete the old photos, scratch that, back them up." →
  "Please back them up."). Without it nothing fires and both are kept.
  That is the price: a verb NLTagger reads as a noun, with a new object
  and no object pronoun — it, them, him, me or us; "her" and "you" are not
  read so in v9 — keeps both too ("Move the call, scratch that, book a
  room.", which v8 took back right; "Call the vendor, scratch that, text
  her." as well, until v10 read "her" ending the phrase as one). A word NLTagger reads as a verb is
  not in doubt, and NLTagger does that to most verbs after "scratch that"
  ("Water the plants, scratch that, feed the cat." → "Feed the cat.") —
  and to some nouns, which still lose the clause, as in v7 and v8 (§7).
- **The object said again** (T24) also stops the swap: NLTagger reads the
  particle of "clear out", "print out", "hand in" or "boot up" as a
  preposition, so v8 made "Warm up the cache, I mean, clear out the cache
  before the demo." into "Warm up the clear out the cache before the
  demo."; both are kept now, and after "scratch that" the clause goes
  (v10 reads only an object this way, and after in, on, off or over keeps
  both, after "scratch that" too: below). A
  new object after such a particle still garbles ("Delete the draft, I
  mean, print out a copy."; §7). Reading a closed set of particles as a
  verb's whatever their tag was measured and not applied: it kept "print
  out a copy", but cost 7 to 10 of the 10 noun swaps before a
  prepositional phrase that v9 makes in 12 probes ("Take the mug, I mean,
  cup off the shelf."). And
  "let's" or "it's" is no possessive: "Let's fork, I mean, clone the repo."
  swaps again ("Let's clone the repo."; v8 kept both, and after "scratch
  that" lost "Let's").
- **A compound's head** (T25). R4 paired the head of a compound noun with
  the correction's modifier, so the word taken back stayed and the cue
  went: "Use the staging bucket, I mean, prod bucket." became "Use the
  staging prod bucket.", and "Restart the staging server, I mean, prod."
  lost the head: "Restart the staging prod.". Now a new modifier said
  with the head again replaces the whole compound ("Use the prod
  bucket.", "Run the integration tests, and tell me which ones fail."),
  and a lone word after the cue is no compound's head: both are kept —
  after "scratch that" too, unless what follows opens a clause. With no
  determiner the compound is read after a verb: "Check credit card, I
  mean, debit card." → "Check debit card."; "Restart staging server, I
  mean, prod." stays. An adjective before the noun is no compound: "Book
  a cheap flight, I mean, train." → "Book a cheap train.". The cost: a
  compound whose head alone is corrected keeps both ("Send the sales
  report, I mean, summary."), one synthetic row among them (§5).
- **The verb phrase taken back** (T26). "Scratch that" took back the whole
  clause before it even when only its verb phrase was corrected: "I'll
  call him, scratch that, text him tonight." became "Text him tonight.",
  and "We shipped it on Friday and then deleted the logs, scratch that,
  archived the logs." lost its first conjunct. When what follows the cue
  is a verb phrase with no subject of its own, the retraction now starts
  at the verb of X's verb phrase if what stands before that verb can stay
  — an auxiliary or modal, "to", a coordinator, "please", a contracted
  pronoun, or a subject after an auxiliary or a coordinator: "I'll text
  him tonight.", "We shipped it on Friday and then archived the logs.",
  "Can you text the team?", "I want to archive them.". Otherwise the
  clause goes as before ("The tests failed, scratch that, rerun them." →
  "Rerun them."). It deletes less than v8 did — and where v8 made no
  fire because the clause held a quoted word, the shorter range can fire
  ("The 'beta' build failed so can you email the team, scratch that, call
  them." → "… so can you call them."). v10 stops it at a relative clause
  (below).

None of the four changes a row of the maintainer's dictations, at either
level, or of the public, red-team and holdout sets, or a fire in the
written-English corpus; one synthetic row keeps both now (a compound's
head corrected alone: "… a copy of the production database, no wait,
snapshot …"), so the synthetic set's Standard fixes go from 221 to 220
(§5). Probes, rules alone, at Standard, with v8's count in brackets (at
Fillers R4 does not run, and nothing changes):

| Probes (invented), rules alone, Standard | development (v8) | written before the code, run once (v8) |
|---|---|---|
| a noun with its own object after "scratch that": both kept, no word lost | 10 of 10 (0; 10 lost the clause) | 1 of 5; 4 lost words (0; 5) |
| the same nouns after the other strong cues: both kept | 4 of 4 (4) | 2 of 2 (2) |
| a verb phrase after "scratch that" saying the object again or taking a pronoun: the clause taken back | 10 of 10 (10) | 4 of 5 (4) |
| the same with a new object: the clause taken back | 4 of 5 (5) | 3 of 3 (3) |
| a verb for a verb after "let's", fixed | 5 of 6 (0) | 0 of 3 (0) |
| a possessive before the noun, a verb after the cue: both kept | 3 of 3 (2) | 1 of 1 (1) |
| a phrasal verb saying the object again: both kept | 5 of 5 (1; 4 garbled) | 2 of 2 (1) |
| the same after "scratch that": the clause taken back | 2 of 2 (1) | 1 of 1 (1) |
| a phrasal verb with a new object: both kept (a gap, §7) | 2 of 3 (2) | 1 of 1 (1) |
| a compound corrected with its head said again: the compound replaced | 8 of 8 (0; 8 garbled) | 4 of 4 (0; 3 garbled) |
| a compound corrected by its modifier alone: both kept | 5 of 5 (0; 5 garbled) | 3 of 3 (0; 3 garbled) |
| a compound's head corrected alone, fixed (the cost) | 0 of 2 (2) | 0 of 1 (1) |
| an adjective before the noun: the swap, or with the head said again the phrase | 3 of 3 (2) | 2 of 2 (1) |
| a full noun phrase after "scratch that": its slot (T21) | 2 of 2 (2) | 1 of 1 (1) |
| a weak cue before a compound: both kept | 2 of 2 (2) | — |
| a phrasal verb split around its object, the noun corrected before the particle, fixed (the cost) | 0 of 4 (0; 1 lost the clause) | 0 of 2 (0; 1) |
| "scratch that" after a coordinated clause: only the last conjunct taken back | 4 of 4 (0) | 2 of 2 (0) |
| after a subject and an auxiliary, "to", "please" or a contraction: those kept | 7 of 7 (0) | 3 of 4 (0) |
| no lead-in before the clause's verb, or a subject after the cue: the clause, as before | 5 of 5 (5) | 1 of 2 (1) |

The held-out row that loses words is §7's: NLTagger reads three of its
five nouns after "scratch that" as verbs ("Pay the contractor, scratch
that, painter his deposit." → "Painter his deposit.") and one as an
adverb, and v7 and v8 lost the same words. Its other misses are §7's
too: the "let's" swaps where NLTagger tags the two verbs differently (v7
kept them as well), "lower it" read as an adverb, a verb for a verb
("The printer jammed, scratch that, restart it." → "The printer restart
it.", as in v8), and the evidence price ("I'll mow the lawn, scratch
that, rake the leaves." keeps both). Two more batches were written
before their code: 58 particle sentences, which measured the two
particle readings not applied (above, and the split phrasal verb in §7),
and 18 with no determiner before the compound, on which the reading
applied took 10 of 10 compounds from garbled to right and left the verb
and object swaps as they were.

**An object said again, a relative clause, a possessive: T24, T26 and T25
in v10.** The re-check of v9 found two of its new readings taking words v8
kept, and smaller gaps beside them:

- **The noun said again, read only as an object** (T24). v9 counted the
  noun before the cue said again anywhere in the next four words as the new
  verb's object — across a preposition or "and" too. A noun swap whose new
  noun had a phrase of its own then lost the verb after "scratch that"
  ("Send the file, scratch that, link to the file." became "Link to the
  file."; v8 "Send the link to the file.") and was kept both ways after the
  other cues ("Order the pizza, I mean, salad and pizza."). On the
  reviewers' battery of such rows — 20 verbs, 20 noun pairs, eight cues,
  3,200 rows — v8 got 3,032 right and v9 none. Now only determiners and
  possessives may stand between, after at most one particle right after
  the verb — out, up, down, back or away ("clear out the cache"): the swap
  goes through again, 2,712 of the 3,200, and no row loses a word v8 kept.
  In, on, off and over are a particle or a preposition — "Pack the charger,
  I mean, plug in the charger." reads like "Fix the door, I mean, lock on
  the door." — so after one of them both are kept, after "scratch that"
  too: that is the 320 rows of the battery's "in the" and "on the" pairs,
  which v8 swapped right (the other 168 rows v10 misses, v8 missed too; §7
  has the list of particle verbs measured and not applied). And "her" at the end of the phrase, or before "tonight",
  "later" and the like, is the object pronoun: "Call the vendor, scratch
  that, text her." → "Text her." again (v8 did so; v9 kept both, 45 of the
  200 control rows of the reviewers' second battery).
- **A relative clause** (T26). v9 took the last verb with an auxiliary or
  "to" before it even inside a relative clause, and grafted the correction
  onto it: "Email the guy who can fix it, scratch that, call him." became
  "Email the guy who can call him.". Now a verb after who, whom, whose or
  which — or after that, where or when right after a noun — is the
  relative clause's, and the whole clause goes, as in v8 ("Call him."); a
  verb before the relative word still keeps what stands before it ("Please
  email the guy who can fix it, scratch that, call him." → "Please call
  him."). On the reviewers' 1,600 such rows v8 got 1,500 right, v9 200 and
  v10 1,500; the other 100 are v8's own swap of one verb for another. It
  costs where "that" after a noun opens a complement ("Tell the team that
  we should ship it, scratch that, delay it." → "Delay it.", as in v8) and
  where who or which opens an embedded question (§7).
- **A possessive as the new modifier** (T25). In v9 "Use the shared folder,
  I mean, Sam's folder." became "Use the Sam's folder." (v8 kept both): the
  possessive took the old modifier's place and left its determiner. A
  possessive said with the head again now replaces the whole noun phrase,
  its determiner too ("Use Sam's folder.", "Book a conference room, I mean,
  Priya's room." → "Book Priya's room."), and a preposition before it stays
  ("Store it in cold storage, I mean, Sam's storage." → "Store it in Sam's
  storage."). With a number in the phrase nothing fires, after "scratch
  that" too — is the count still meant? — so "Book the 2 corner tables,
  scratch that, Sam's tables." keeps both, where v8 took the noun phrase's
  slot ("Book Sam's tables."). Refusing a possessive outright was measured
  and not applied: of the 36 development sentences it fixes 23 fewer — 22
  stay as said and one garbles ("Print the old today's report.").
- **A modifier of another kind** (T25). v9's spec asked the two modifiers'
  kinds to match — a weekday for a weekday, a colour for a colour; the code
  never did, and the swap is what is meant: "Book the Monday meeting, I
  mean, team meeting." → "Book the team meeting.". With the clause, 15 of
  18 such sentences keep both and 3 more garble where no compound is read
  ("Grab the blue budget folder."), and every possessive of a name is
  refused (a capitalised word is a name's kind); the spec now says what the
  code does.
- **A verb's second object** (T25's cost, now named): "Send Sam updates, I
  mean, notes." reads as a compound and keeps both (v8 "Send Sam notes.").
  §7 has the two exemptions measured.
- **The word classes only where T25 can matter.** T25 asked NLTagger before
  its checks on the words alone, so the port tagged dictations v8 never
  tagged — 2.5 ms more on one of the maintainer's longest. The checks on the
  words now come first; no output changes (§5).

None of these changes a row of the maintainer's dictations or of the other
four sets, at either level, or a fire in the written-English corpus. Probes,
rules alone, at Standard, as right / kept as said / damaged, with v9's and
v8's counts in brackets (at Fillers R4 does not run, and nothing changes):

| Probes (invented), rules alone, Standard | development (v9; v8) | written before the code, run once (v9; v8) |
|---|---|---|
| a noun swap whose new noun's phrase says the noun again across a preposition or "and" (the reviewers' 59 and 14 of ours) | 55 / 16 / 2 (5 / 31 / 37; 68 / 3 / 2) | 5 / 0 / 1 (0 / 4 / 2; 5 / 0 / 1) |
| the object said again across a particle, a determiner or a possessive: both kept, after "scratch that" the clause | 29 / 1 / 0 of 30 (30 / 0 / 0; 24 / 0 / 6) | 10 / 0 / 0 (10 / 0 / 0; 8 / 0 / 2) |
| "scratch that" after a relative clause: the clause (the reviewers' 22 and 10 of ours) | 24 / 0 / 8 (3 / 1 / 28; 26 / 0 / 6) | 5 / 0 / 0 (0 / 1 / 4; 5 / 0 / 0) |
| after a complement or an infinitive: only the verb phrase | 19 / 0 / 0 (19 / 0 / 0; 0 / 0 / 19) | 3 / 0 / 0 (3 / 0 / 0; 0 / 0 / 3) |
| "that" after a noun opening a complement (the cost) | 1 / 2 / 1 (2 / 2 / 0; 1 / 2 / 1) | 1 / 0 / 1 (2 / 0 / 0; 1 / 0 / 1) |
| an embedded question after a verb (the cost) | 0 / 1 / 2 (2 / 1 / 0; 0 / 1 / 2) | — |
| a subordinate clause, so, if, when, because (a gap, §7) | 2 / 0 / 4 (2 / 0 / 4; 5 / 0 / 1) | 0 / 1 / 2 (0 / 1 / 2; 2 / 1 / 0) |
| a possessive said with the head again: the whole noun phrase (the reviewers' 25 and 11 of ours) | 30 / 4 / 2 (6 / 4 / 26; 7 / 26 / 3) | 4 / 0 / 0 (0 / 0 / 4; 1 / 3 / 0) |
| a weak cue before a possessive: both kept | 2 of 2 (2; 2) | 1 of 1 (1; 1) |
| a compound's modifier replaced by one of another kind, or the same | 25 / 0 / 0 (25 / 0 / 0; 0 / 17 / 8) | 4 / 0 / 0 (4 / 0 / 0; 0 / 2 / 2) |
| a verb's second object corrected (the cost) | 0 / 14 / 0 (0 / 14 / 0; 11 / 3 / 0) | 0 / 3 / 0 (0 / 3 / 0; 3 / 0 / 0) |
| "her" ending the phrase after "scratch that" | 3 / 0 / 1 (1 / 2 / 1; 3 / 0 / 1) | — |

The development damage is mostly older: of the eight relative-clause
sentences, six are v8's own swap of one verb for another ("Message the
client who wants to cancel, scratch that, call them." → "… wants to call
them."), one is a subordinate clause ("so she can fix it") and one reads
"We need to email them." where the reviewers wrote "Email them."; the two
swaps lost are NLTagger reading "copy" and "notes" as verbs, as v8 did.
The held-out batch's misses are §7's: a noun NLTagger reads as a verb
("curtains"), a complement "that", the subordinate clauses, and the verb's
second object.

**A possessive's determiner, in, on, off or over running on, a relative
clause in the subject: T25, T24 and T26 in v11.** The re-check of v10 found
its new readings taking words v8 kept — the determiner a possessive needs,
a subject and its verb, a verb's lead-in — and two of its narrowings losing
fixes v9 made:

- **A possessive's phrase** (T25). v10 replaced the whole noun phrase for
  every possessive and found where it starts by walking back to the first
  determiner across any word: "Use the old laptop, I mean, manager's
  laptop." became "Use manager's laptop." (v9 "Use the manager's laptop."),
  "The kids ate cold pizza, I mean, Sam's pizza." became "Sam's pizza.", and
  "Send the team updated numbers, I mean, Sam's numbers." lost "the team".
  Now the determiner goes only when the possessor takes none — a name (any
  capitalised word), everyone's, someone's, nobody's, today's, tonight's,
  tomorrow's, yesterday's, or a family word used as a name — and stays for
  a common noun ("Use the manager's laptop."); a quantifier stays ("Bring
  both old chargers, I mean, Sam's chargers." → "Bring both Sam's
  chargers."); and the walk crosses only the phrase's own modifiers: at a
  verb, a pronoun or a noun after an adjective the start is the modifier,
  as in v9 ("The kids ate Sam's pizza.", "Send the team Sam's numbers.").
  On the reviewers' two batteries — 12,288 rows of verbs, noun phrases,
  possessors and cues, and 3,500 with a subject and its verb or an indirect
  object before the phrase — v10 got 7,168 and 1,000 right, v11 all of
  both.
- **A finite verb is no modifier** (T25). With nothing between the verb and
  the head, v9 and v10 took the verb for the modifier: "The kids ate pizza,
  I mean, cold pizza." became "The kids cold pizza.". A verb right after a
  noun is now that noun's verb (one in -ed or -en only when no verb comes
  before it, else it is a participle: "Send the team updated numbers"), and
  both are kept, as in v8.
- **An addition, and a verb's two objects** (T25). "We can use the shared
  folder, I mean, Sam's folder works too." offers a second folder; v10 made
  it "We can use Sam's folder works too.". A phrase after the cue that ends
  with "too", "either" or "as well", or holds "also", now keeps both: 1,152
  of 1,152 such rows (v10 none). And after a verb that takes two objects,
  "the", one noun and a plural read as two objects as well as one compound
  ("Give the dog treats, I mean, Sam's treats.": v10 "Give Sam's treats."),
  so a possessive there keeps both: of 2,880 such rows v10 damaged 2,700,
  v11 none. The cost is the compound reading of the same words: "Send the
  sales reports, I mean, Dana's reports." keeps both (v10 "Send Dana's
  reports."); of 2,880 such rows v10 fixed 2,700, v11 none (§7).
- **The object said again after a modifier or a two-word verb** (T24). v10
  read the noun before the cue said again as the new verb's object only
  across determiners: "Delete the old files, scratch that, archive the old
  files." kept both (v8 and v9 "Archive the old files."), and "Wash the
  deck, I mean, power wash the deck." became "Wash the power wash the deck."
  (v9 kept both). The object's own modifiers after its determiner or
  possessive, and a two-word verb's second word right before one, count
  again: on 1,792 two-word-verb rows after the cues other than "scratch
  that" v10 garbled 1,012 and v11 none, and after "scratch that" v11 takes
  back the verb phrase or the clause in 206 of 256 (v10 31); both as v9.
  With no determiner a modifier still reads as a noun swap's ("Fix the
  sink, I mean, guest bathroom sink." → "Fix the guest bathroom sink.").
- **In, on, off or over running on** (T24). After "scratch that", v10 took
  the whole clause back when the phrase saying the noun again ran on into a
  clause of its own: "Can you check the tires, scratch that, pressure in the
  tires before we leave?" became "Pressure in the tires before we leave?"
  (v8 swapped it right). That clause is the run's, so both are kept now, as
  without the run; a verb right after the noun said again makes the phrase
  a subject, and the clause goes, as in v10 ("I'll fix the door, scratch
  that, lock on the door is broken." → "Lock on the door is broken."). Of
  the reviewers' 360 such rows with a verb in the run, v10 lost the verb in
  324; v11 keeps both in 288 and loses it in the 72 where NLTagger reads the
  new noun as a verb ("trim on the wall", "mats in the car"), as v8 did.
- **"When" after a noun** (T26). v10 read "when" right after any noun as a
  relative word: "Call the client when you can review it, scratch that,
  merge it." became "Merge it." (v9 "Call the client when you can merge
  it."), on all 800 noun rows of the reviewers' battery, and so after
  "tomorrow" or "Friday". "When" opens a relative clause now only after "a"
  or "the" and a time noun ("Find a time when we can all meet, scratch
  that, call them." → "Call them."); after any other word it opens a
  subordinate clause again: 800 of 800.
- **A relative clause in the subject** (T26). v10 took the whole clause
  after any relative word: "The client who called will email the contract,
  scratch that, mail the contract." became "Mail the contract.". When no
  verb comes before the relative word, the relative clause is the
  subject's, and the scan for the verb phrase resumes at the main clause —
  its first auxiliary or modal after the relative clause's verb, or its
  first verb that "to" does not introduce: "The client who called will mail
  the contract.", "The guy who fixed it said to email him."; 9 of the
  reviewers' 10. The tenth has a verb before its relative clause ("I think
  the thing that we should do is call him") and goes whole, as in v8 and
  v10.

None of these changes a row of the maintainer's dictations or of the other
four sets, at either level, or a fire in the written-English corpus.
Probes, rules alone, at Standard, as right / kept as said / damaged, with
v10's, v9's and v8's counts in brackets (at Fillers R4 does not run, and
nothing changes):

| Probes (invented), rules alone, Standard | development (v10; v9; v8) | written before the code, run once (v10; v9; v8) |
|---|---|---|
| a common-noun possessor: its determiner stays | 13 / 0 / 0 (0 / 0 / 13; 13 / 0 / 0; 0 / 0 / 13) | 5 / 0 / 0 (0 / 0 / 5; 5 / 0 / 0; 0 / 0 / 5) |
| a name, or a pronoun-like or time possessor: the whole noun phrase | 14 / 0 / 0 (14 / 0 / 0; 0 / 0 / 14; 0 / 6 / 8) | 5 / 0 / 0 (5 / 0 / 0; 0 / 0 / 5; 0 / 1 / 4) |
| a quantifier before the old phrase: it stays | 4 / 0 / 0 (1 / 0 / 3; 3 / 0 / 1; 0 / 3 / 1) | 1 / 0 / 0 (0 / 0 / 1; 1 / 0 / 0; 0 / 1 / 0) |
| a subject and its verb, or an indirect object, before the old modifier: they stay | 13 / 1 / 0 (2 / 1 / 11; 13 / 1 / 0; 1 / 12 / 1) | 4 / 0 / 0 (0 / 0 / 4; 4 / 0 / 0; 1 / 3 / 0) |
| a possessive correcting a subject, the clause running on | 5 / 0 / 0 (5 / 0 / 0; 0 / 0 / 5; 1 / 4 / 0) | — |
| a finite verb right before the head (no modifier) | 1 / 4 / 0 (0 / 0 / 5; 0 / 0 / 5; 1 / 4 / 0) | 0 / 1 / 0 (0 / 0 / 1; 0 / 0 / 1; 0 / 1 / 0) |
| a verb's two objects: both kept | 0 / 7 / 0 (0 / 0 / 7; 0 / 0 / 7; 0 / 5 / 2) | 0 / 1 / 0 (0 / 0 / 1; 0 / 0 / 1; 0 / 1 / 0) |
| the same words read as a compound (the cost) | 2 / 3 / 0 (5 / 0 / 0; 0 / 0 / 5; 1 / 4 / 0) | — |
| an "I mean" that adds: both kept | 6 / 0 / 0 (0 / 0 / 6; 0 / 0 / 6; 6 / 0 / 0) | 1 / 0 / 0 (0 / 0 / 1; 0 / 0 / 1; 1 / 0 / 0) |
| a two-word verb saying the object again | 7 / 1 / 3 (0 / 1 / 10; 7 / 1 / 3; 0 / 1 / 10) | 3 / 0 / 0 (0 / 0 / 3; 3 / 0 / 0; 0 / 0 / 3) |
| a modifier between the determiner and the object said again | 15 / 0 / 0 (8 / 5 / 2; 15 / 0 / 0; 12 / 0 / 3) | 3 / 0 / 0 (3 / 0 / 0; 3 / 0 / 0; 3 / 0 / 0) |
| noun swaps that must stay swaps | 8 / 2 / 0 (8 / 2 / 0; 2 / 8 / 0; 8 / 2 / 0) | — |
| in, on, off or over saying the noun again and running on, after "scratch that": both kept (v8's swap is right) | 0 / 5 / 1 (0 / 1 / 5; 0 / 0 / 6; 4 / 0 / 2) | 0 / 2 / 0 (0 / 0 / 2; 0 / 0 / 2; 2 / 0 / 0) |
| the same after the other strong cues: both kept | 2 / 0 / 0 (2 / 0 / 0; 2 / 0 / 0; 0 / 0 / 2) | — |
| the same with a verb right after: the clause | 2 / 1 / 0 (3 / 0 / 0; 2 / 0 / 1; 0 / 0 / 3) | 1 / 0 / 0 (1 / 0 / 0; 1 / 0 / 0; 0 / 0 / 1) |
| "when" after a noun or a time word: the subordinate verb phrase | 9 / 0 / 0 (0 / 0 / 9; 9 / 0 / 0; 0 / 0 / 9) | 2 / 0 / 0 (0 / 0 / 2; 2 / 0 / 0; 0 / 0 / 2) |
| "when" after "a" or "the" and a time noun: the clause | 4 / 0 / 0 (4 / 0 / 0; 2 / 0 / 2; 4 / 0 / 0) | 0 / 0 / 1 (0 / 0 / 1; 0 / 0 / 1; 0 / 0 / 1) |
| a relative clause in the subject: the main verb phrase | 10 / 1 / 1 (0 / 1 / 11; 10 / 1 / 1; 0 / 1 / 11) | 2 / 0 / 1 (1 / 0 / 2; 2 / 0 / 1; 1 / 0 / 2) |
| a relative clause in the object: the clause | 5 / 1 / 1 (5 / 1 / 1; 0 / 1 / 6; 5 / 1 / 1) | 1 / 0 / 0 (1 / 0 / 0; 0 / 0 / 1; 1 / 0 / 0) |

Every damaged development sentence comes out as in v10: the two-word verbs
NLTagger reads as an adverb ("Review double check the numbers.") or whose
old verb it reads as an interjection ("Please mop the floor" loses
"Please"), "trim on the wall" read as a verb, the embedded "where" after an
indirect object, a relative "where" after "had lunch", the subject's
relative clause with no lead-in before its main verb ("Emailed us."), and a
verb swapped for a verb; none deletes a word v10 kept. The held-out batch's
two are §7's too: "text" read as a noun after "scratch that" ("The nurse who
saw us will call text tonight.") and a verb swapped for a verb.

**The valve: T25 and T24 in v12.** The final review of v11 still found
its newest readings taking words v8 had kept, in two places: the
possessive said with the head again (T25), and the readings v11 added
for the noun said again after "scratch that" (T24). Each round before had
fixed the last review's finds with a new reading, and the next review had
found the new reading taking words too. v12 adds none: every change
refuses a fire v11 made, or makes it shorter. On every input this work
has — the five eval sets, the written-English corpus, the 260,000 seeded
rows (20,000 new, aimed at v12's refusals), the reviewers' own 156,000
seeded rows, every probe of every round and every reviewer battery,
781,301 rows — v12 deletes no word v11 keeps, at either level: none of
1,562,602 runs, by the multiset of the words deleted and by their
positions alike (`monotone_check.py`, kept with the private eval). That
held on those inputs, not on every input: the review of v12 found
perturbations aimed at its refusals where v12 took words v11 kept, and v13
makes the rule how the rules run (below). The check catches what it should:
on a copy of v11 made to take one more word on every strong-cue fire it
flags 216,299 runs, and on a copy where a refused possessive falls through
to "scratch that"'s clause (the bug fixed in v10) 3,608; on v11 itself,
none. v12 deletes less than v11 in 160,572 rows at Standard (6,546 of the
20,000 aimed at it, 3,895 of the other 240,000 seeded rows, 3,326 of the
reviewers' 156,000, the rest in the probes and batteries) and in none at
Fillers; no row of the five sets or of the corpus changes, at either level.

- **A possessive said with the head again keeps both** (T25), after every
  cue and on every path, with or without a determiner of its own. v10 and
  v11 replaced the old noun phrase, and the walk to its start crossed
  words the correction left alone: an indirect object ("Send my manager
  sales reports, I mean, Dana's reports." → "Send Dana's reports."), a
  subject and a verb NLTagger reads as a noun ("Our store stocks winter
  coats, I mean, Dana's coats." → "Dana's coats."), a second modifier
  ("Send the team updated sales numbers, I mean, Sam's numbers." → "Send
  the team updated Sam's numbers.") and the determiner a capitalised
  common noun needs ("Use the old laptop, I mean, CEO's laptop." → "Use
  CEO's laptop."). v8's own paths garbled too: a word swap of a lone head
  ("Grab the charger, sorry, mom's charger." → "Grab the mom's charger.")
  and, after "scratch that", T21's slot walking across an indirect object
  ("Give the kids draft plans, scratch that, the manager's plans." → "Give
  the manager's plans."). A narrower swap was measured and not applied — a
  name, one determiner and one modifier right after the verb, nothing
  after the head, with every other v12 refusal: on the review's batteries
  it still took a word v8 kept and got the row wrong in 5,231 rows, the
  recipient of a verb not on v11's two-object list in 4,120 ("Tell the
  kids stories, I mean, Mom's stories." → "Tell Mom's stories."), a
  title's determiner in 1,000 ("Use Director's laptop.") and a name
  recipient in 111. The price is every fix of the shape: of the 215,912
  battery rows that say a possessive with the head again, v12 keeps all;
  v11 got 60,120 of them right and garbled 71,761, v8 got 11,203 right and
  garbled 89,241 (§7).
- **A name, a subject and its verb, a modifier of a possessive: no new
  verb after "scratch that"** (T24). v11's two new readings of the noun
  said again — after a determiner and a modifier, and after a two-word
  verb's second word — read a name as the new verb ("Can you send the
  invoice, scratch that, Dana Smith the invoice?" → "Can you Dana Smith
  the invoice?"), a subject and its verb as a two-word verb ("We need to
  call the vendor, scratch that, Sam called the vendor." → "We need to Sam
  called the vendor."), and, since v9, a possessive opened by an adjective
  or a noun as a verb and its object ("Print the weekly report, scratch
  that, last week's report." → "Last week's report."). Those readings still
  stop the noun swap, but are no verb's evidence when the phrase opens with
  a capitalised word inside its sentence, when the word after its first is
  inflected (-ed, -s, or one of 56 irregular pasts), or when its first word
  is an adjective, or a noun before a possessor in lower case that needs a
  determiner of its own; a name is no verb before an object either ("Sam
  the invoice"). A bare noun phrase then takes T21's slot, as in v8 ("Can
  you send Dana Smith the invoice?", "Review Dana Smith's draft.", "Print
  last week's report."), and a clause goes whole only where a name opens
  it and v11 took the whole clause too ("Call the vendor, scratch that, Sam
  called the vendor." → "Sam called the vendor."). On the review's
  batteries that is 12,424 rows right that v11 garbled — the names, full
  names and a determiner after them, and the possessives opened by an
  adjective or a noun. With a lead-in, v8's whole clause is out of reach —
  it took the lead-in v11 kept — so both are kept: of 700 such rows v8 got
  623 right, v12 30 (v11 30, and 670 garbled).
- **The noun said again with its modifiers and no determiner** (T24): a
  swap of the noun before the cue left the old modifiers before the new
  phrase ("Email expense receipts, I mean, print expense receipts." →
  "Email expense print expense receipts.", v8 to v11), and after "scratch
  that" T21's slot left the old verb before the new one ("Send old log
  files, scratch that, forward old log files." → "Send forward old log
  files."); both are kept now, with up to three modifiers. A phrase that
  opens with a determiner or an adjective still takes the slot ("Email
  spare keys, scratch that, new spare keys." → "Email new spare keys.").
  On the review's 5,060 such rows v11 garbled 518 and v12 39, the slot
  where NLTagger reads the new verb as an adjective (§7).
- **A new modifier said with the head again before a verb of its own**
  (T25) is a new clause's subject, not a correction: "Book the big room, I
  mean, small room is free." keeps both (v9 to v11 "Book the small room is
  free."), and so does "prod bucket works too tonight", which v11's
  addition reading missed. "Please" is no verb there ("prod bucket
  please" still swaps). The review's 160 such rows: v11 garbled all, v12
  keeps all.
- **What a refused cue reads stays.** A refusal keeps the cue, but a later
  fire could still take the words around it: a later cue's fire took the
  phrase after it, and a second pass then read the first cue again on
  other words ("Book the corner table, scratch that, Sam's table, scratch
  that, cancel it." would have become "Cancel it."; v11 "Book cancel
  it."; v13 also never reads a refused cue again); or a repeat's first copy
  went where v11's swap had taken its second ("Take the team the team
  photos, no wait, team's photos, then call me." would have lost the first
  "the team"; v11 "Take the team the team's photos, then call me."). The
  phrase after a refused cue, and the words before it that v11's fire for
  that cue could have taken, are now kept from every later fire, and no
  repeat, restart or fragment is fixed where the copy or the word it keeps
  lies there. The monotone check found these rows: 2 by the multiset and 22
  more by position, of the 1,562,602 runs. A repeat outside those words is
  still fixed ("We went over over the numbers, I mean, Sam's numbers." →
  "We went over the numbers, I mean, Sam's numbers.").
- **`addition()` reads phrase ends computed once per view**, as the
  sentence and clause starts are: a long run of "I mean" with no commas
  between was quadratic. A refusal's kept words are added once per range
  too, and the check after a repeat finds its words by bisection: adding
  the phrase to its end at every refused cue of such a run was quadratic
  again. Release builds of v11 and v12 interleaved, five rounds, each row's
  best: on the maintainer's dictations v12 takes 0.67, 0.46 and 3.06 ms at
  p90 up to 60, 61 to 150 and over 150 words (v11 0.68, 0.48 and 3.04); on
  "use the staging bucket I mean prod bucket" said again and again with no
  commas, 15.8, 28.7, 58.2, 138.9 and 362.7 ms at 2,000 to 32,000 words
  (v11 16.3, 32.6, 77.6, 219.6 and 670.6). A run of names after "scratch
  that" costs v12 more per cue, linearly: 24.4 to 506 ms at 2,000 to
  32,000 words (v11 17.3 to 309).

The review's batteries (and round 6's possessive battery), rules alone,
Standard, no dictionary: right / kept as said / garbled per version, and
the rows where v12 deletes a word v8 kept (of them right). Where both kept
is the ideal (keep), "kept" is right and "right" counts another accepted
answer:

| Battery, rules alone, Standard (rows) | v8 | v11 | v12 | v12 takes a word v8 kept (right) |
|---|---|---|---|---|
| after "scratch that": a two-word name and the object said again (3,168) | 2,232 / 0 / 936 | 0 / 0 / 3,168 | 2,480 / 328 / 360 | 248 (248) |
| the same with a modifier (3,168) | 2,232 / 0 / 936 | 0 / 0 / 3,168 | 2,480 / 328 / 360 | 248 (248) |
| after "scratch that": a full name's possessive (2,592) | 2,232 / 0 / 360 | 0 / 0 / 2,592 | 2,232 / 0 / 360 | 0 (0) |
| after "scratch that": a one-word name and the object said again (1,440) | 0 / 0 / 1,440 | 0 / 0 / 1,440 | 992 / 0 / 448 | 0 (0) |
| after "scratch that": a name, a determiner (and a modifier) and the object said again (3,520) | 920 / 0 / 2,600 | 0 / 0 / 3,520 | 3,520 / 0 / 0 | 0 (0) |
| a possessive said again, a recipient before the old phrase, its modifier a noun (44,352) | 0 / 14,784 / 29,568 | 0 / 7,952 / 36,400 | 0 / 44,352 / 0 | 0 (0) |
| a possessive said again, a recipient before the old phrase, its modifier a noun, after "scratch that" (11,088) | 294 / 0 / 10,794 | 294 / 0 / 10,794 | 0 / 11,088 / 0 | 0 (0) |
| the same, its modifier an adjective (22,176) | 0 / 7,392 / 14,784 | 14,336 / 3,808 / 4,032 | 0 / 22,176 / 0 | 0 (0) |
| the same, its modifier an adjective, after "scratch that" (5,544) | 168 / 0 / 5,376 | 3,752 / 0 / 1,792 | 0 / 5,544 / 0 | 0 (0) |
| a possessive said again, two nouns before the head (324) | 36 / 72 / 216 | 324 / 0 / 0 | 0 / 324 / 0 | 0 (0) |
| a possessive said again, a subject and its verb before the old phrase (5,760) | 290 / 2,460 / 3,010 | 2,320 / 516 / 2,924 | 0 / 5,760 / 0 | 0 (0) |
| a possessive said again, a common-noun possessor (2,880) | 0 / 0 / 2,880 | 2,880 / 0 / 0 | 0 / 2,880 / 0 | 0 (0) |
| a possessive said again, a name possessor (2,240) | 256 / 1,024 / 960 | 2,240 / 0 / 0 | 0 / 2,240 / 0 | 0 (0) |
| a possessive said again after a subject and verb or a recipient (150) | 14 / 123 / 13 | 76 / 67 / 7 | 0 / 150 / 0 | 0 (0) |
| a possessive or a modifier said again before a predicate (keep) (160) | 0 / 64 / 96 | 0 / 0 / 160 | 0 / 160 / 0 | 0 (0) |
| after "scratch that": a name and its verb, no lead-in (100) | 89 / 0 / 11 | 100 / 0 / 0 | 100 / 0 / 0 | 11 (11) |
| the same with a lead-in (700) | 623 / 0 / 77 | 30 / 0 / 670 | 30 / 670 / 0 | 3 (3) |
| a possessive said again after a verb's two objects, the verb off v11's list (keep) (6,400) | 2,008 / 4,392 / 0 | 0 / 480 / 5,920 | 0 / 6,400 / 0 | 0 (0) |
| the same after "scratch that" (keep) (1,600) | 502 / 120 / 978 | 0 / 120 / 1,480 | 0 / 1,600 / 0 | 0 (0) |
| the same, the verb on v11's list (keep) (4,000) | 1,250 / 2,260 / 490 | 0 / 3,500 / 500 | 0 / 4,000 / 0 | 0 (0) |
| a possessive said again, two modifiers before the head (3,125) | 0 / 2,640 / 485 | 0 / 700 / 2,425 | 0 / 3,125 / 0 | 0 (0) |
| the same after a subject and its verb (1,250) | 0 / 1,000 / 250 | 250 / 800 / 200 | 0 / 1,250 / 0 | 0 (0) |
| a possessive said again, a capitalised title or acronym as the possessor (2,400) | 0 / 1,920 / 480 | 0 / 192 / 2,208 | 0 / 2,400 / 0 | 0 (0) |
| the same, a name as the possessor (control) (720) | 120 / 576 / 24 | 720 / 0 / 0 | 0 / 720 / 0 | 0 (0) |
| after "scratch that": a possessive opened by an adjective or a noun (720) | 450 / 0 / 270 | 0 / 0 / 720 | 720 / 0 / 0 | 270 (270) |
| a possessive said again after a recipient that is a name, an adjective and a noun, or "my" and a noun (keep) (2,808) | 816 / 1,408 / 584 | 18 / 685 / 2,105 | 0 / 2,808 / 0 | 0 (0) |
| a possessive said again before a verb of its own (300) | 66 / 150 / 84 | 0 / 0 / 300 | 0 / 300 / 0 | 0 (0) |
| an "I mean" that elaborates on a possessive (keep) (54) | 0 / 54 / 0 | 0 / 27 / 27 | 0 / 54 / 0 | 0 (0) |
| the object said again with no determiner, after "scratch that" (730) | 433 / 1 / 296 | 368 / 194 / 168 | 368 / 323 / 39 | 0 (0) |
| the object said again with no determiner (4,330) | 0 / 3,771 / 559 | 0 / 3,980 / 350 | 0 / 4,330 / 0 | 0 (0) |
| round 6's possessives: a common-noun possessor (4,096) | 0 / 0 / 4,096 | 4,096 / 0 / 0 | 0 / 4,096 / 0 | 0 (0) |
| round 6's possessives: a common-noun possessor, after "scratch that" (1,024) | 0 / 0 / 1,024 | 1,024 / 0 / 0 | 0 / 1,024 / 0 | 0 (0) |
| the same, a name or pronoun-like possessor (2,048) | 0 / 1,024 / 1,024 | 2,048 / 0 / 0 | 0 / 2,048 / 0 | 0 (0) |
| the same, a name or pronoun-like possessor, after "scratch that" (512) | 224 / 0 / 288 | 512 / 0 / 0 | 0 / 512 / 0 | 0 (0) |

Over all 321,596 rows with an ideal, v8 is right in 42,230, keeps 164,403
as said and garbles 114,963; v11 84,460 / 146,726 / 90,410; v12 36,729 /
281,033 / 3,834. Every row v12 garbles comes out as v8's or v11's own
output (3,388 as both, 442 as v11, 4 as v8): on these rows v12 makes no
garble of its own. Off them it could ("Bring the kids my old snacks snacks,
I mean, the client's snacks the client's snacks please." came out "Bring
the client's snacks the client's snacks please.", where v8 and v11 keep
"the kids my old snacks, I mean,"); v13 keeps them too (below). It deletes
a word v8 kept in 3,631 of them and is right in 3,607 (the other 24 are
v9's to v11's: a compound swapped across two modifier kinds, "Book the
Monday meeting, I mean, team meeting." → "Book the team meeting.", which
that review's probes count as kept both, and a two-word verb's lead-in
after "scratch that"), and a word v11 kept in none.

What the valve gives back, over all 781,301 rows: v12 changes 160,572 at
Standard and none at Fillers, every one by deleting less than v11 —
144,961 keep both, 8,995 come out as v8 had them and 6,616 keep part of
what v11 took. By the v11 fire v12 refuses or shortens: a possessive said
with the head again in 118,049, a word swap in 20,056 (v8's own, refused
for a possessive after a weak cue or for the object said again with no
determiner), a verb phrase or a clause after "scratch that" in 17,769,
T21's slot in 2,903, a new modifier said with the head again in 1,749, and
a repeat, a restart or a cut-off word inside the words a refused cue reads
in 43 (§7). 146,762 of the 160,572 have an ideal: v11 got 60,182 of those
right and garbled 86,580; v12 gets 23,198 right and garbles 4.

**The valve, by construction (v13).** v12's check held on every natural
and seeded input the round had, but the review of v12 aimed perturbations at
its refusals — a stutter on the word before the cue, the phrase after it said
twice, a second cue after it, an unbalanced bracket — and v12 deleted words
v11 kept in 121 of 300,000 random ones and in 960 of 46,080, 1,296 of 13,824
and 1,639 of 20,000 aimed ones (29,160 of the whole 359,424 the last sample
was drawn from), by three mechanisms. v13 closes each where it arises, and
beneath them makes the rule how the rules run:

- **A refused correction is never read again.** A refusal kept the phrase
  after its cue, but nothing before the cue when v11 made no correction
  there. Once a stutter there was fixed, a second pass read the cue again,
  and its restart onset reached a word it had not reached before: "Bring the
  kids my old snacks snacks, I mean, the client's snacks the client's snacks
  please." lost "the kids my old snacks, I mean," (v11 kept them; v13
  "Bring the kids my old snacks, I mean, the client's snacks the client's
  snacks please."). Every cue a refusal declines is now skipped by every
  later scan, in every pass.
- **Each correction is read as v11 read it.** The scan reads every cue twice
  on the same words — its own way, and v11's: where v11's correction would
  start, against v11's own record of where its last correction ended — and
  corrects only where v11 corrects, from v11's start or later. Where its
  correction is the shorter (a held reading's slot after "scratch that"),
  the words v11 took and v13 leaves are kept from every later fire: "We need
  to give to give the plants, scratch that, Dana the plants." → "We need to
  give to give Dana the plants." (v12 let the repeat rule take the first
  "to give": "We need to give Dana the plants."; v11 kept one more "to":
  "We need to give to Dana the plants."). Where v11 corrects and v13 does
  not, those words and the phrase after the cue are kept, and the cue
  declined.
- **Where v11's correction would be refused, so is v13's.** A longer
  correction can be refused where a shorter one is not: it would orphan a
  bracket, take a quoted word, a layout marker or a word he presents as
  words. "I should check the ) lease, scratch that, Dana Smith's lease" is
  kept whole (v12 took the slot: "I should check the ) Dana Smith's
  lease").
- **No correction takes a word v11's rules keep.** Each dictation runs
  through v11's own rules first — the same words, word classes, guards and
  level; R4 and R5 as v11 read every cue, every other rule as here — and no
  fire is applied that deletes a word that run keeps. That makes the rule a
  property of how the rules run, not of the inputs measured: on every
  input, at both levels, the words v13 deletes are a subset of the words v11
  deletes, by position and so as words. The three fixes above leave it
  little to stop: without that run, on the 7,960,052 inputs below, v13
  would delete a word v11 keeps in 325, 126 of them a word v11 keeps
  altogether and 199 only another copy of a word v11 deletes. Every one is
  a second-order reading of words a refusal or a shorter correction left in
  place: the repeat rule taking the other copy of a repeat v11 fixed, or a
  word v11 kept (249; "Remember to sign shared to sign shared files, no
  wait, scan shared files!" — v11's restart took "sign shared to", across
  the two copies, v12's repeat the first "to sign shared"; and a guard
  reading a word v11 had deleted: in "I should pay the car, scratch um
  that, Dana the car car?", with "pay" kept, the guard that keeps "Does the
  fix fix the crash?" no longer sees the inverted question v11's "I should
  Dana the car car?" shows it, and the repeat rule took a "car" v11 kept),
  a later correction or a later pass reading a cue on words v11 had taken
  (72), and a cut-off word or a restart (4). v13 keeps all of those as
  said, but for what v11 also takes ("I should pay Dana the car car?"). The
  price is time: the rules run twice, NaturalLanguage once (§5).

The check (`check_r8.py`, kept with the private eval) runs v13 and v11 side
by side, at both levels, over every input this work has: the five eval sets
(with his dictionary), the written-English corpus, the 260,000 seeded rows,
the reviewers' own 156,000, every probe and battery of every earlier round
(781,301 rows); the v12 review's whole collection (1,358,197 rows), its
fresh batteries (34,068), its ablation inputs (102,798), its 300,000 random
perturbations and its 869,328 aimed ones; and 6,071,337 perturbations of
our own over every battery, probe and seeded row that holds a cue
(1,718,514 of them), each given the word before the cue said twice, the
phrase after it said again, a second cue after it, an unbalanced bracket or
quote, a layout marker, and the two words before the cue said again — every
battery and probe row also two more kinds, a second cue's variant and three
combinations. That is 7,960,052 distinct inputs, 15,920,104 runs: v13
deletes a word v11 keeps in none, by position or as words. The review's
fixed-point inputs — v12's outputs fed back, and inputs with their
whitespace normalised — were checked apart, the 241,391 distinct inputs
(328,888 of their 328,927 rows) this work could trace to an input that is
not held out: none there either. So were its ideal outputs, the 47,134
distinct texts its batteries accept as right, run as inputs (9,823 of them
in neither set above): none, and v13 is v12 on every one. The check flags
copies of v13 made to fail: the v11 run off (325 runs), and with it off, a
declined cue read again (42,702 runs, 42,271 by the words), no words kept
before a shorter correction (4,598, 3,616 by the words), no refusal where
v11's correction is refused (2,312, 2,110 by the words), a correction where
v11 makes none or from before its start (326, 127 by the words), one more
word on every strong cue's correction (903,800, 862,661 by the words) or a
refused possessive falling through to "scratch that" (132,220, 130,171 by
the words); with the v11 run on but its filter reading only a fire's last
word, 194 (6 by the words), or only R4's and R5's fires, 254 (58 by the
words) — on the 325 inputs where the three fixes alone fail; on every other
input the run has nothing to stop, and a filter reading only a fire's first
word stops all 325 (every fire it stops starts with a word v11 keeps); v12
itself, 48,969, 47,755 by the words; on v11 itself, none. And the v11 run
inside v13 deletes exactly what v11 deletes, on every one of those runs.

What it costs: on the 321,596 battery rows with an ideal, nothing — v13's
outputs are v12's on every one (36,729 right, 281,033 kept as said, 3,834
garbled). Over all the inputs, v13 deletes less than v12 in 216,872 runs at
Standard and none at Fillers (3 of them on the inputs v12's check read, all
seeded; 120,058 on the review's aimed rows, 96,811 on our perturbations);
it deletes more than v12 in 501 and differs both ways in 52, every one
within what v11 deletes: where v12 read a refused correction again in a
later pass and kept the words around it, v13, which never reads it again,
fixes a stutter there ("Show my boss wedding photos wedding photos photos,
no wait, Priya's photos." → "Show my boss wedding photos, no wait, Priya's
photos."; v12 kept "photos photos"). On the five eval sets and the corpus
no row changes against v12, at either level, and none of the maintainer's
dictations, rules only or with the formatter (§8).

## 4. The contract

- **Deletion only.** The output is the input's tokens with whole tokens
  removed, byte for byte, except two case fixes: a deleted run that opened a
  sentence (or a line, right after a layout marker) passes its capital on
  ("Delete it, scratch that, keep it." → "Keep it."), and a repeat keeps the
  first copy's lower case ("about About two" → "about two").
- **No word v11's rules keep** (v13, the valve). Each dictation runs through
  the rules of v11 — the version before the last two rounds — first, and no
  fire is applied that deletes a word that run keeps: on any input, at both
  levels, the words deleted are a subset of the words v11 deletes, by
  position and so as words. The reference does the same, and the check over
  every input this work has finds no exception (§3).
- **Never inside a quotation**, double, curly or single, written or
  spoken ("and I quote … unquote").
- **Never a layout marker**, and never across one (T16).
- **A correction inside words he presents as words** is kept where a frame
  shows them (T17, §3). That is a heuristic, not a guarantee (§7).
- **A dictionary term is never a fragment** and is never re-cased.
- **Numbers:** R4's word swap, R2's and R2B's restarts and R3's fragments
  never take one. A number goes as a repeat only across a filler ("ten, uh,
  ten", R1) and as a cued numeric correction (R5); what is taken back whole
  goes with its numbers — R4S's sentence ("We need 5 servers. Scratch that,
  …"), R4's "scratch that" clause ("it costs 5 dollars, scratch that, it is
  free") or verb phrase (T26: "I'll order 5 chairs, scratch that, rent
  them" → "I'll rent them"), the noun phrase a bare one replaces after it
  (T21: "we need 5 servers, scratch that, a cluster" → "we need a
  cluster") and R4's restart from its onset ("order 3 chairs, actually,
  order a table"); and R1B can take a number word as an inflected restart
  ("two hundred hundreds"). A compound's swap (T25) never takes one: its
  modifier and head are words; and a possessive said with the head again
  replaces nothing (both are kept). The reference and the port agree on
  every one of these, and on every fire of the parity runs (§8): of the
  fires there that took a number, over both levels and all 7,960,052
  distinct inputs of v13's check, 108,851 were R5, 35,763 R1 across a
  filler, 14,294 R4S and 32,376 R4 retractions taken whole — by the code
  path that chose where the deletion starts, 21,817 clauses and 5,182 verb
  phrases taken back by "scratch that", 3,391 noun phrases in their slot
  (T21) and 1,986 restarts from the onset; none was R2, R2B, R3 or an R4
  word swap (a swap, a closed kind, T25's compound).
- **No orphaned bracket or quotation mark.**
- **A fixed point, as measured.** Its output fires nothing on every row of the
  five eval sets, the written-English corpus, every fixture but four and
  1,000 generated dictations (`SelfRepairPropertyTests`). The four are the
  valve's (v13): where v11 corrects and v13 does not, or v13's correction
  is the shorter, a repair the words v11 took and v13 keeps hold is left
  undone, and a second run, reading those words afresh, makes it ("We need
  to give to give the plants, scratch that, Dana the plants." → "We need to
  give to give Dana the plants.", whose second run is "We need to give Dana
  the plants."); over every input of v13's check, 211,237 of its 3,048,807
  changed outputs fire again at Standard, nearly all of them aimed
  perturbations (v12 on the same inputs: 51,475), and 7,823 of 2,832,721 at
  Fillers, where v13 is v11 and v12 (no correction runs there); on the
  inputs v12's check read, 37 at Standard (v12, measured the same way, 36)
  and none at Fillers. It is not guaranteed on
  any input: the reference form joins the kept words with single spaces, so a
  text whose language or word-class reading depended on a line break, U+3000
  or U+001C between words can read differently the second time; and the
  repeat's case fix can lower-case a capital a guard read ("… mark Mark g- …"
  loses "mark" on the first run and "g-" on the second); and T17 reads its
  mentions once, before any deletion, so a deletion that takes a frame's own
  word ("are fragments", "word for, er, word") leaves a repair the second run
  takes; and T21 reads word classes too, so a second reading can change its
  verdict: once R3 has taken a fragment right before the clause's verb ("ch
  check with …"), or the words are joined by single spaces, NLTagger can
  read that verb as a noun, and the clause T21 kept the first time goes;
  and R1 can take a repeat right before a cue that read the phrase one way
  with it, and another way without it: a noun, a modifier or a verb said
  twice ("Text weekly chairs, or rather, stress stress test weekly
  chairs?" → "Text weekly chairs, or rather, stress test weekly
  chairs?", whose second run is "Text weekly stress test weekly
  chairs?"). On seeded synthetic input at Standard, 35 of 30,000 noisy
  rows (odd whitespace, mixed scripts) and 2 of 30,000 structured rows fire
  again (one of each is T21's), none of 20,000 layout-and-mention rows, 2
  of 20,000 rows aimed at T17's frames, none of 20,000 aimed at the doubles
  guards, none of 20,000 aimed at T19–T22, none of 20,000 aimed at v7's
  changes, none of 20,000 aimed at v8's, none of 20,000 aimed at v9's, 1 of
  20,000 aimed at v10's (T21's verdict again: once a sentence before it is
  gone, NLTagger reads "tonight" as a verb, and v8 and v9 fire on that row
  the second time too), none of 20,000 aimed at v11's (v11 had 2: a
  modifier said twice, and on the shorter text T25's possessive applied;
  v12 replaces no possessive) and 1 of 20,000 aimed at v12's (a noun said
  twice before an "I meant" that adds); on the reviewers' own 156,000, 27
  (in four of their six sets: 17, 4, 3 and 3), all but one a word said
  twice before a cue — the doubled verb above among them — and one a
  second "scratch that" whose clause the first fire had shortened; at
  Fillers none of the 416,000. The reference does the same on the same
  rows, byte for byte: its second pass and the port's are identical on all
  of them, and on every other row of the round.
- **Whitespace:** the pipeline keeps the input's own whitespace between the
  surviving tokens (a line break from a dictionary target survives a deletion
  next to it), and a dictation nothing fired on passes through untouched.

## 5. The measurements

The eval sets and the scorer live with the private eval, outside this repo.
Every number below is for the deterministic path the app runs — the rules,
then the filler strip, the spoken layout, the rule-based cleanup and the
finishing pass — reproduced end to end by replaying every row through the
pipeline compiled from this code (§8). At Standard:

| Set | Rows | Repairs to remove | Fixed today (no rules, no model) | Fixed with the rules | Words damaged | Protected look-alikes broken |
|---|---|---|---|---|---|---|
| synthetic | 623 | 538 | 5 | **220 (41%)** | 15 in 9 rows (today 14 in 8) | 9 of 483 (today 8) |
| public (SpeakoFlow, CC-BY-4.0) | 57 | 29 | 0 | **8 (28%)** | 0 | 0 of 54 |
| red team | 858 | 349 | 9 | **175 (50%)** | 6 in 2 rows (today 4 in 1) | 2 of 850 (today 1) |
| holdout (written to attack v2) | 139 | 34 | 1 | **30 (88%)** | 23 in 18 rows | 18 of 107 |
| the maintainer's own dictations | 116 | 33 | 2 | **23 (70%)** | **0** | **0 of 112** |

At Fillers and repeats (the default level):

| Set | Fixed today | Fixed with the rules | Words damaged | Protected broken |
|---|---|---|---|---|
| synthetic | 5 | 116 | 15 in 9 rows (today 14 in 8) | 9 of 483 (today 8) |
| public | 0 | 5 | 0 | 0 of 54 |
| red team | 9 | 85 | 4 in 1 row (today the same) | 1 of 850 (today 1) |
| holdout | 1 | 21 | 8 in 7 rows (today 0) | 7 of 107 (today 0) |
| the maintainer's own dictations | 2 | 12 | 0 | 0 of 112 |

Read the holdout rows for what they are: 105 of its 139 rows are hard
negatives written after the guards existed, to find what they miss. The
misses are the known gaps in §7. At Fillers, taking R3's lone non-words out
of that level cut its false fires there from 22 rows to 14, and the doubles
guards (T3, T18, T19) cut them to 7: the noun-then-verb outside T1's frame
("Does the new build build"), "you and I, I think", "log out out of", a
two-word double ("Try it try it") and a cut-off "tab" before "table". The
seven rows those guards now keep, at both levels ("goody goody", "woof
woof", "putt putt", "swing by by noon", "come over over the holidays", "pass
the box over over the fence", "write it down down the side"), are no
evidence about new text: this page named three of them as gaps before the
guards were written, and their author had read the holdout's doubles.

**Lists and descriptions** (synthetic probes the reviewers wrote, through the
app's text path at Standard in the maintainer's register):

- 25 spoken lists, several with two equal items in a row: before T16 the
  rules lost an item in 10 of them rules-only — in each of the unknown,
  messaging and mail registers, at both levels — and in 9 with the formatter
  on; now in none: every probe has the line count the app had without the
  rules.
- Dictations that describe a correction: §3 has T17's numbers, all of them
  development numbers. Of the round-1 probes that describe one, the rules
  now keep two more than v3 ("a negative test for I'm 34, actually 35", "a
  cued swap like Monday, sorry, Tuesday"). With the formatter on, the
  formatter and the filler strip can still collapse a doubled word inside a
  description, as they did before the rules.
- Doubles that are meant ("tanti tanti baci", "Cool cool, see you then.",
  "swing by by noon", "caldo caldo"): §3 has the probe numbers. Through the
  app's text path, rules only, the guards' doubles reach the formatter whole
  at both levels
  (`DictationPipelineTests`); the filler strip collapses only its own short
  words ("the the", "I I"), none of which is one of them.

**With the formatter on top.** On the maintainer's dictations, running the
1.5B formatter after the rules (the default) fixed no repair the rules left
(still 23 of 33), damaged 37 words in 3 rows, broke 5 of the 112 protected
spans and invented a word in 1 row, and spent 469 ms median, 1.33 s at p90, on
the 77 dictations it saw. Without the rules, that formatter path fixed 7 and
8 of the 33 in two measured runs, and damaged words in 3 dictations. At
Fillers, the default level, it fixed 15 of the 33 (without the rules 6),
and the damage there is the model's own: 96 words in 12 rows and 9 of the
112 protected spans broken without the rules as with them (one row more in
the latest run, where the model answered instead of timing out). That is
why "Rules only — no AI rewrite" exists (§6).

**The model's 150-word ceiling counts the dictation before the rules.** Past
150 words the formatter skips the model by design
(`TextFormatter.Config.llmWordLimit`: on longer text the 1.5B paraphrases or
echoes). It used to count what reached it, and the rules run first and only
delete, so they could bring a long dictation under the ceiling and onto the
model that skipped it before: red-team row rl10, 152 words, lost 3 to the
rules and went to the model, which merged a protected "that that". The
formatter is now handed the count the dictation would have had without the
rules — the strip alone, the same all-filler fallback, the same spoken layout
lifted out — or the text's own when that is more
(`DictationPipeline.FormatterInput.ceilingWords`); fillers and layout still do
not count, as before, and with `self_repair` off the count is the text's own.
macOS, Command Mode with nothing selected, the iOS stage, the bench's
llama, foundation and shipped columns, `whispr-bench cleanup` (the app's own
text path, `DictationPipeline.finish`) and `whispr-bench format` all apply it
(`ModelCeilingTests`). Over
the four commit-safe sets at both levels, in every register, with
`collapse_stutters` on and off — 46,956 formatter calls — whether the model
runs on length is now the decision the app made before the rules on every
one; the rules had brought 36 of them under the ceiling (six red-team rows at
Standard: rl03, rl10, rl13, rl21, rl22, rl23), and all are skipped again.
Seven of the maintainer's dictations are over the ceiling; the rules bring
none of them under it, so nothing changes there.

**The seeds benchmark** (`scripts/bench-eval.sh`, the 81 synthetic seeds
in this repo, rows in `docs/eval/leaderboard.jsonl`): composite C 90.4 →
91.6 for the rules column, 91.1 → 92.0 with the llama formatter, 92.4 →
93.0 with Apple's; on the 8 `repair` seeds 82.7 → 87.6, 87.6 → 92.5 and
85.2 → 90.0. No seed scores lower in any column, the 49 controls score
exactly as before, and latency does not move. (T16, T17 and the Fillers
split change the rules' output on none of the 81 seeds.)

**Written English** (16 Project Gutenberg books and WikiText-2, 40,509
paragraphs, 2.32 million words, each paragraph read as a dictation; written
text holds almost no self-repairs, so nearly every fire is a false one): 113
fires, 0.49 per 10,000 words. 76 of them are in *Ulysses*; the other 37 are
0.18 per 10,000 words, 22 of those "or rather". At Fillers: 66 fires, 0.28
per 10,000 words. T16 and T17 change none, at either level; the doubles
guards remove three at both, all in *Ulysses* (two chants and a French "là
là"), and add none; T20 removes five at Standard (an Italian "mi fa" and an
Irish and an archaic "mo" in *Ulysses*, a German "zu" and a Mayan "ti" in
WikiText), and T19, T21 and T22 change none; v7's changes (T3's second list,
T18 at layout markers, T20's additions, T23) change none either; v8's
T20 additions remove ten, all in *Ulysses* (Latin "ut" and "ea", Irish and
spelled-out "ar", a ballad's "ra"), and T24 and v8's T18 change none;
v9's changes (T24's, T25 and T26) change none either, and nor do v10's,
v11's or v12's.

### Latency

`SelfRepair.apply` per dictation, release build, M2 Pro, NaturalLanguage on
(the tagger runs only when a cued swap needs a word class, the language
recognizer only when a rule fired or before the tagger; both models load
once at launch, ~70 ms, off the main thread):

| Dictation length | p50 | p90 | max |
|---|---|---|---|
| up to 60 words | 0.06 ms | 0.70 ms | 2.4 ms |
| 61–150 words | 0.41 ms | 0.68 ms | 2.4 ms |
| over 150 words | 2.6 ms | 4.1 ms | 4.1 ms |

(The maintainer's 121 dictations, release builds of v8, v9, v10 and v11
run interleaved, five rounds, each row's best: at p90 up to 60 and up to
150 words v8 0.67 and 0.47 ms, v10 0.66 and 0.49 ms, v11 0.68 and 0.46 ms;
in v12's run, v12 0.67 and 0.46 ms, v11 0.68 and 0.48 ms; in v13's, which
runs v11's rules before its own, v13 0.70, 0.68 and 4.12 ms, v12 0.68, 0.47
and 3.07 ms and v11 0.69, 0.47 and 3.12 ms at p90 up to 60, 61 to 150 and
over 150 words. The unpunctuated "I mean" run v12 made linear stays so: at
32,000 words v13 466.5 ms, v12 374.7 and v11 679.0; the run of names after
"scratch that" 569.6 ms (v12 511.8, v11 307.2).
v9 took 1.92 ms at p90 between 61 and 150 words: T25 asked NLTagger before
its checks on the words alone, so v9 tagged dictations v8 never tagged; v10
reads the words first. In v10's own measurement one of those dictations took
0.45 ms in v8, 2.29 ms in v9 and 0.47 ms in v10. Earlier, three runs each:
with T19–T22 0.04, 0.27 and 2.05 ms at the median, with v7 0.04, 0.29 and
2.2 ms, with v8 0.04, 0.29 and 2.1 ms. T17 reads its
mentions only when a fire is about to land: up to 150 words it costs
nothing measurable; over 150 words, where the rules fire, about 0.3 ms at
the median and 0.7 ms at most. Over 2.32 million words of prose the cost is linear, about 3 µs a
word.)

At 2,000 words (warm medians, synthetic): about 4.9 ms when nothing fires,
8.3 ms with a stutter or a cued fire, 14.5 ms when a cued swap pulls the
word-class tagger over the whole text, and up to 20 ms on pathological input
("the like" said a thousand times). A long run of cues with only commas
between them ("the cat, sorry, the cat, sorry, …") used to be quadratic —
4.4, 11.5, 35 and 118 ms at 1,000 to 8,000 words — because every cue scanned
back to its sentence start; the sentence and clause starts are now computed
once per pass, and it is linear: 3.9, 7.7, 15.4 and 31.9 ms in v10's
interleaved measurement (v8 4.0, 8.0, 15.8 and 31.6 ms; v9, which tagged
every cue for T25, 9.1, 16.9, 32.1 and 63.8 ms), and 4.2, 8.3, 16.5 and
32.8 ms in v11's (v10 4.2, 8.2, 16.5 and 33.0 ms in the same run); in
v12's, at 2,000 to 16,000 words, 8.8, 16.4, 33.2 and 76.9 ms (v11 8.7,
16.3, 33.1 and 78.0); in v13's, 14.6, 27.9, 53.8 and 120.3 ms (v12 8.9,
16.5, 33.1 and 76.5, v11 8.7, 16.6, 33.0 and 77.8). A text packed with
T17's frame words and repairs ("the input is", "for example", "said", cued
swaps) takes 13.2 ms at 2,000 words, 8.9 ms without T17, and stays linear:
50.8 ms at 8,000. NaturalLanguage itself stalls for 40–80 ms about once in
4,000 calls. The tagger still reads the whole text: tagging only a window
around the cue would change the word classes it reports, and with them the
parity with the reference (§8).

## 6. Rules only — no AI rewrite

A saved switch (menu bar, and Settings → Auto-Clean), **off by default**. On,
every dictation takes the deterministic path above and the formatting model
stays out of memory — about 1 GB back. Bring-up leaves it on disk; switching
the setting on unloads the model (after any dictation that is using it has
landed); switching it off loads it in the background so the next dictation
does not wait for it. With the setting on, Command Mode loads it only to edit
a selection and frees it again once the edit has landed; with nothing
selected, Command Mode is a dictation and does not load it.

Every load and unload runs in order on one serial chain (`ModelResidency`,
Core), and each reads the switch when it runs, not when it was queued. A flip
to on always queues the unload: queued behind a load still in flight, it
frees what that load brought in; with nothing in memory it does nothing. A
flip to off queues the background load at the flip itself (when the model is
installed), and that load stands down if the switch is back on by the time it
runs. Before, a flip back
on during the 1–2 s load (a double click on the switch is enough) found no
model in memory yet, queued nothing, and the load then left about 1 GB
resident for the session. The decisions are `RulesOnlyMode` (Core, tested:
launch, dictation, command, flip), the ordering `ModelResidency`'s (tested
against a host whose load can be held in flight, `ModelResidencyTests`), and
`PipelineController` hosts both.

Without a usable model the switch is hidden, and Settings and the menu bar
say which of three things is true (`FormattingModelStatus`): the model is not
installed; it is installed but not loaded yet (the app is still starting); or
it is installed but failed to load (Models → Verify on disk checks the file;
relaunch to try again). In each case dictations take the rules-only path.

**What only "Rules only" keeps for certain.** With the AI rewrite on (the
default), the model reads what the rules leave and may still collapse a
double they kept on purpose (§3). The reviewers measured it on a held-out
set of mixed-language doubles, at Standard in the maintainer's settings, on
the rules before T19's subject test and T20–T22: the rules alone kept 25 of
26 intact; with the rewrite on, 15 of 26 reached the
cursor whole — the model merged 10 that the rules had kept, as many as it
merges without the rules. Over all their doubles, 15 of the 18 lost with the
rewrite on were the model's. "Rules only" keeps each one the rules keep. The
same holds for the short words T20 keeps: through the app's text path, in
the messaging register, the rules leave "Landed safe, tell them ve lo dico
domani." whole at both levels; with the model on, the output gate refused
its rewrite at Fillers, so the words reached the cursor whole, and at
Standard the model rewrote the Italian ("… tell them we'll leave
tomorrow."). It kept "caldo caldo", "buona buona" and "Uno a uno" as the
rules did, and made "we ve" "we've".

## 7. Known gaps

When the rules take words he meant, "Undo last Auto-Clean (paste raw)" in the
menu bar pastes the dictation as it was said, and "Fix self-corrections" off
(§1) stops the rules altogether. Settings' "How corrections work" names the
commonest cases level by level, and every example it gives is held by test to
what the pre-pass does (`SelfRepairCopy`, `SettingsCopyTests`).

Measured and deliberately not guarded — each guard tried for them cost real
fixes, or none is possible from the words alone:

- **A description no frame matches is still taken for a repair.** T17 reads
  the words around a stretch, not its meaning, and new phrasings get past
  it: a gerund with no subject ("Saying ship it Friday, no wait, Saturday
  should keep both"), a test request with no placing verb ("run the bench on
  call Sam, I mean Sara", "check what happens with Monday, sorry, Tuesday"),
  a verb outside its lists ("I got send it Monday, sorry, Tuesday back",
  "Priya texted see you at 6, sorry, 7"), "leave … alone", "produce … from
  …", a number after a text noun's copula ("the raw text was 7, sorry, 8
  pm"), words reported after a comma ("the way she said it, we, we really
  need this"), and "the red team found that the cache cache". On the batch
  of probes written before the code, 3 of 28 descriptions were still
  changed; on new text expect more (§3). "Undo last Auto-Clean (paste raw)"
  in the menu bar pastes exactly what was said.
- **A correction he makes inside words he reports is kept where the words
  after the reporting verb read as a clause**: a pronoun subject ("She said
  it costs 30, sorry, 40", "I keep saying we should leave at 6, sorry, 7"), a
  copula or a modal ("My boss said the deadline is Friday, sorry, Thursday",
  "… the team will ship Friday, sorry, Thursday"), a past tense in -ed ("…
  the deadline moved to Friday, sorry, Thursday"), and a greeting said to
  someone ("I said hi to Sam on Friday, sorry, Saturday"). A noun subject
  with a verb in the present or an irregular past reads as the verb's
  object, and the correction is made: "My boss said the rules keep row 6,
  sorry, row 7" and "She said the meeting starts at 6, sorry, 7" lose the
  first number; so do words after "told me" or "said to" ("She told me the
  deadline is Friday, sorry, Thursday" → "… is Thursday"). Also kept: a bare
  plural after a verb of writing ("Claude
  keeps writing long commit titles on Monday, sorry, Tuesday": without a
  determiner a noun phrase reads like quoted words), an adjective after a
  text noun's copula ("the dictation was long, I mean short"), what a test
  is "for" when two words follow ("schedule a test for login at 3, sorry,
  4"), and a correction followed in its sentence by a mark of literal
  fidelity ("the box arrived Monday, sorry, Tuesday intact"). An
  instrument's reading is not speech: "my watch says 48, sorry, 49" is
  fixed.
- **A doubled code literal**: "git commit -m revert revert" loses a "revert".
- **Inside a spoken quotation** ("and I quote the plan plan is set unquote")
  the rules take nothing, but the filler strip still collapses a doubled "the",
  "I" or "we" there, as it did before the rules; the same holds in any
  description T17 keeps. A written quotation is never touched.
- **A retraction across a layout marker** is kept whole ("Buy milk. Scratch
  that, new line buy eggs"), so "Scratch that," stays in the text.
- **A particle and the same preposition** is kept only after a verb that
  takes the particle, with a time after it or a noun phrase after the verb's
  object (T19). Still taken: "log out out of the admin panel" ("log out of"
  reads the same), "he logged out out of habit", a verb not listed ("we
  moved over over the summer"), and a place right after the verb's particle
  ("come over over here" — the same shape as the stutter "we went over over
  these numbers"). At both levels.
- **The doubles guards' own costs** (T3, T18), measured in on purpose: a
  stutter on a word with an accent is kept ("the café café"), so is a list
  item stuttered at a sentence edge ("Milk milk, eggs and bread.", "we need
  eggs, bread, milk milk."), and a stuttered "via via". After a "bullet
  point" marker an item said twice always loses a copy; after a "new line"
  marker one at the text's start or end, or written as a sentence of its
  own — a stop before or after it, on a word or on the marker itself — is
  kept ("to do new line rent rent" reads like "new line hugs hugs", "To do.
  New line. Invoices invoices." like "Hugs hugs."). A stutter on a word
  of T3's second list is kept too. The list leaves out English look-alikes,
  but for 13 Italian words English holds only as a borrowed term of music,
  art or a name — piccolo, dolce, forte, fresco, alto, basso, bassi, largo,
  tondo, breve, allegro, carina, testa — listed on purpose, so a stutter on
  one of them ("the forte forte section") is kept as well. Neither the
  maintainer's dictations nor the five eval sets hold one.
- **A double of another language's word that T3 does not list loses a
  copy**, at both levels: "the sea was cristallino cristallino today" →
  "the sea was cristallino today", and so does an English look-alike the
  list leaves out on purpose ("gelato gelato", "solo solo"). The list holds
  the everyday words; with the AI rewrite on, the model can still merge
  one it keeps (§6).
- **A two-word double still loses a copy** ("Va bene va bene, I'll call her
  tonight after dinner", "Thank you thank you!", "Try it try it, you'll like
  it": R1 takes a repeated pair, R2 a restart), as does an everyday English
  word doubled for emphasis inside a sentence ("a great great idea"; on its
  own, "Great great, let's do it.", it stays). "All it is is a typo", and a
  wh-word more than four words back ("what the root cause of it is is"),
  lose an "is". A wh-phrase reads as the subject, so "What time are are we
  leaving?" and "How many are are left?" keep their stutter (T19); and since
  T22 a wh-clause with no subject loses a copy: "Whatever is is right." →
  "Whatever is right."
- "you and I, I think" fires ("I, I" is also the commonest real stutter).
- T1 covers only auxiliary + determiner + the double: "Does the new build
  build", "Let the cache cache" still fire, and inside the frame a real noun
  stutter is kept ("Did the client client sign?").
- At Standard, R3 deletes lower-case two-letter abbreviations ("the gm said",
  "please cc me"). The recogniser writes abbreviations in capitals, which R3
  never touches; a one-letter-only R3 would cost real fixes. At Fillers it no
  longer runs that part. It keeps the short words of other languages and of
  English that it lists (T20) — every one- and two-letter string the macOS
  spelling checkers of Italian, Spanish, French, Portuguese and German
  accept as a word of its language — and still takes the letters,
  abbreviations, numerals and chat shorthand they also accept, "fo", and a
  word of a language they do not cover: "We learned the motto ua mau ke ea
  at school." loses Hawaiian "ua".
- **"Scratch that" before a noun phrase** (T21) swaps the noun phrase that
  ends at the cue. A correction meant for an earlier phrase is kept both ways
  when the two heads are of different kinds ("I want the report by Friday,
  scratch that, the summary"), and goes to the wrong phrase when they are
  not: "Email the slides to the team, scratch that, the notes" → "Email the
  slides to the notes" (before T21: "The notes."). The verbs and nouns are
  NLTagger's, and a verb it reads as a noun makes the clause look verbless,
  so the whole clause goes as before: "When you land, book a window seat,
  scratch that, an aisle seat, please." → "When you land, an aisle seat,
  please."; "Order 3 chairs, scratch that, two tables." → "Two tables." (with
  "Please order", "Please order two tables."). Since v12 a phrase that
  opens with no determiner or adjective and says the noun phrase before the
  cue again takes no slot: its first word is a new verb, and the slot would
  leave the old one before it ("Send old log files, scratch that, forward
  old log files." keeps both; v8 to v11 "Send forward old log files."). A
  verb NLTagger reads as an adjective still takes the slot, as in v8
  ("Delete broken chair, scratch that, archive broken chair." → "Delete
  broken archive broken chair."): 39 of the reviewers' 730 such rows.
- **A verb after the cue that the rules cannot see is one** (T24) still
  takes the noun's place when NLTagger reads it as a noun and no object or
  particle follows it: a preposition and a bare noun ("Merge the branch, I
  mean, rebase onto main" → "Merge the rebase onto main"), an object that is
  a time ("Drop the plan, I mean, schedule the weekend" → "Drop the
  schedule the weekend": "the weekend" reads as "salad this time" does),
  a particle NLTagger reads as a preposition before a new object ("Delete
  the draft, I mean, print out a copy" → "Delete the print out a copy";
  with the object said again both are kept since v9) or before an adverb
  ("Close the store, I mean, cash out first" → "Close the cash out
  first"), or a noun before the cue with no opener before it and a new
  object after the verb ("Delete logs, I mean, archive the files" →
  "Delete archive the files"; after a bare verb a verb NLTagger misreads
  looks the same, and "Please fork, I mean, clone the repo" is a verb swap
  that must go through). And a noun followed by its own indirect object
  is kept both ways ("Send the team, I mean, client the slides"), after
  "scratch that" too since v9. Reading a preposition and a bare word after
  the cue's word as a verb phrase too was measured and not applied: it
  fixes "rebase onto main", but keeps 5 of 6 everyday noun swaps with such
  a tail both ways ("Take the train, I mean, bus at noon", "Order the
  soup, I mean, salad for lunch"); so was reading a closed set of
  particles as a verb's whatever NLTagger says (§3).
- **A noun's own phrase in in, on, off or over saying the noun again**
  (T24, since v10) is kept both ways, after "scratch that" too: "Read the
  email, I mean, attachment in the email", "Fix the door, scratch that,
  lock on the door" (v8 swapped them right; v9 kept the first and took the
  second's verb: "Lock on the door."), and since v11 also when the phrase
  runs on into a clause of its own ("Can you check the tires, scratch that,
  pressure in the tires before we leave?"; v10 took the whole clause). A
  phrasal verb reads the same ("Pack the charger, I mean, plug in the
  charger", which v8 garbled), and the rules cannot tell the two apart; so
  a phrasal verb NLTagger reads as a noun, with a run after it, keeps both
  as well ("Pack the charger, scratch that, plug in the charger before we
  leave."; v10 "Plug in the charger before we leave."). A verb right after
  the noun said again makes the phrase a subject, and the clause goes
  ("I'll fix the door, scratch that, lock on the door is broken." → "Lock on
  the door is broken."), but not a verb NLTagger reads as a noun ("rack in
  the oven needs scrubbing" keeps both). Telling them apart by a list of the verbs
  that take in, on, off or over as a particle (plug in, turn off, go over
  …) was measured and not applied: it swaps those 13 development sentences
  right again, and garbles a phrasal verb not on the list ("Mop the floor,
  no wait, dry off the floor" → "Mop the dry off the floor").
- **A word after "scratch that" that NLTagger misreads** (T24): where a
  verb with its object and a noun with its own object look alike, the
  rules go by NLTagger's word class and a verb's evidence. A noun it reads
  as a verb still takes the clause before the cue back, as in v7 and v8:
  "Pay the contractor, scratch that, painter his deposit." → "Painter his
  deposit." (three of the five such nouns written before the v9 code); a
  word it reads as an adverb is taken for a bare noun phrase, which takes
  the slot of the one before the cue: "Email the vendor, scratch that,
  supplier our invoice." → "Email supplier our invoice.", and so is a verb:
  "Stop the music, scratch that, lower it." → "Stop lower it.". A verb it
  reads as a noun, with a new object and no object pronoun — it, them,
  him, me, us, or (since v10) "her" ending the phrase or before "tonight"
  and the like — keeps both since v9 ("Move the call, scratch that, book a
  room."; v8 took the clause back; "you" is no such pronoun: "Ping the
  agent, scratch that, text you later." → "Ping the text you later.", as
  in v8),
  and two verbs after "let's" that it tags differently are not swapped
  ("Let's archive, I mean, delete the old branches." keeps both). And a
  verb particle right after the word after the cue stops the swap of the
  noun a split phrasal verb corrects: "Pick the kids, I mean, dog up at
  five" keeps both (v7 swapped it). Reading the particle as a verb's only
  with an object after it was measured and not applied: it fixes 9 more of
  19 such probes, but makes "Shut the laptop, I mean, power down" into
  "Shut the power down". Since v12 a phrase that opens with a name (a
  capitalised word inside its sentence), has an inflected word after its
  first (-ed, -s or an irregular past) or opens with a word modifying a
  possessive shows no verb after "scratch that": as a bare noun phrase it
  takes the slot of the noun phrase before the cue, as in v8 ("Can you
  send the invoice, scratch that, Dana Smith the invoice?" → "Can you send
  Dana Smith the invoice?"; v11 "Can you Dana Smith the invoice?"), and
  read as a clause it goes whole only where a name opens it and v11 took
  the whole clause too ("Call the vendor, scratch that, Sam called the
  vendor." → "Sam called the vendor."; with a lead-in, "We need to call the
  vendor, scratch that, Sam called the vendor." keeps both, where v11 made
  it "We need to Sam called the vendor."). With a lead-in, v8's whole
  clause would take the lead-in v11 kept, so both are kept: of the
  reviewers' 700 such rows v8 got 623 right, v12 and v11 30 (v11 garbled
  the other 670). The price: a subject in lower case is no subject ("Call
  the vendor, scratch that, mom called the vendor." keeps both; v8 and v11
  "Mom called the vendor."), nor is a plural noun phrase that reads like
  one ("Send the contract, scratch that, team leads the contract." keeps
  both); a verb written with a capital inside a sentence reads as a name;
  where NLTagger reads a name's own verb as a noun and the verb is not
  inflected, the noun phrase's slot garbles as in v8; and a verb it reads as
  an adjective before a possessive is read as the possessive's modifier
  ("Sign Sam's old laptop, scratch that, scan Sam's old laptop." → "Sign
  scan Sam's old laptop.", as in v8; v11 "Scan Sam's old laptop."; 2 of
  the reviewers' sentences). And a name NLTagger reads as a verb still
  opens a clause of its own: "Can you send the contract, scratch that, Rose
  the contract?" → "Can you Rose the contract?", as in v11 (288 of the
  reviewers' 1,440 one-word-name rows: 184 as v11, 104 as v8 and v11).
  Reading a capitalised word with a determiner after it as no verb at all
  was measured and not applied: it fixes those rows, but takes a verb
  written with a capital after the cue for a name ("Can you book the
  contract, Scratch that, Print the contract again?" → "Can you book Print
  the contract again?").
- **A compound's head corrected alone** (T25) is kept both ways ("Send the
  sales report, I mean, summary"; v8 swapped it right, and one synthetic
  row lost its fix so, §5): the rules cannot tell it from a modifier
  corrected alone, which v8 garbled. So is a verb's second object
  corrected after its first: "Send Sam updates, I mean, notes", "Give the
  dog treats, I mean, food" read as compounds (v8 "Send Sam notes."; 14 of
  14 such development sentences and 3 of 3 held out keep both). Exempting a
  modifier with no determiner after a verb was measured and not applied —
  it garbles the compounds read without one ("Restart staging server, I
  mean, prod" → "Restart staging prod.") — and so was exempting a name
  there: it fixes "Send Sam updates" and garbles "Use Google account, I
  mean, work" ("Use Google work."). A modifier corrected with a
  determiner before it keeps both, as before ("Use the staging bucket, I
  mean, the prod bucket"), and the weak cues never widen a swap ("Check
  the credit card, sorry, debit card" keeps both). Still garbled, as in
  v8: with no determiner, a sentence-initial verb NLTagger reads as an
  adjective hides the compound ("Open kitchen window, I mean, bedroom
  window." → "Open kitchen bedroom window.", "Update iOS app, I mean, web
  app." → "Update iOS web app."; the no-determiner reading needs NLTagger
  to see the verb), and after "scratch that" the clause then reads verbless
  and goes whole ("Clean guest bathroom, scratch that, main bathroom." →
  "Main bathroom."); an adjective corrected alone after "scratch that"
  takes the whole noun phrase's slot (T21: "Grab the small box, scratch
  that, large." → "Grab large.", "Use the old charger, scratch that, new."
  → "Use new."), and after "I mean" the head's ("Call the front desk, I
  mean, help." → "Call the front help."). Since v12 a possessive said with
  the head again keeps both, after every cue and on every path: "Use the
  shared folder, I mean, Sam's folder." stays (v10 and v11 "Use Sam's
  folder."), and so do "Use my notes, scratch that, Sam's notes." and
  "Use the big room, scratch that, the client's room." (v8 to v11 "Use
  Sam's notes.", "Use the client's room."). That is the valve's largest
  price (§3): v10's and v11's fixes of the shape go, and v8's own after
  "scratch that", where T21's slot was right as often as it walked across
  an indirect object ("Send my manager sales reports, scratch that,
  Dana's reports." → v8 "Send Dana's reports."; "Give the kids draft
  plans, scratch that, the manager's plans." → v8 "Give the manager's
  plans."). On the reviewers' batteries that is 60,120 rows v11 got right
  and 11,203 v8 got right, against 71,761 and 89,241 they garbled; after
  "scratch that" a possessive said again before a verb of its own keeps
  both too, where v8 took the clause back ("Book the corner table,
  scratch that, Sam's table is free."; v8 right in 66 of 300 such rows).
  A possessive whose possessor ends in "s" and is written with the
  apostrophe alone counts too ("James' folder"), and so does one with a
  determiner of its own ("the manager's", "our team's"); a determiner
  said again before it is still the onset of a restart, as in v8 ("Use
  the folder, scratch that, the team's folder." → "Use the team's
  folder."). A new modifier said with the head again is still swapped, a
  recipient left in place ("Send the team updated numbers, I mean, final
  numbers." → "Send the team final numbers."), and so after a verb that
  takes two objects, as in v9 ("Give the dog treats, I mean, cat treats."
  → "Give the cat treats."). A verb right after a noun is read as that
  noun's verb, so an irregular participle there loses the modifier reading
  v9 and v10 gave it: "Pass the kids lost numbers, I mean, final numbers."
  keeps both (v10 "Pass the kids final numbers."). With the AI rewrite on,
  the model may resolve a pair T25 kept, sometimes wrongly: through the
  app's text path at Standard, "Open the kitchen window, I mean, door."
  came out "Open the door." (the rules keep both; v8's rules gave "Open
  the kitchen door.").
- **What a refused correction reads stays as said** (v12). No later fire
  takes a word of the phrase after a cue a v12 refusal declined, or a word
  before it that v11's fire for that cue could have taken, and no repeat,
  restart or cut-off word is fixed where the copy, head or word it keeps
  lies there: "We need to call the vendor, scratch that, Sam called the
  vendor, I mean, supplier." keeps all of it (v8 "Sam called the
  supplier.", v11 "We need to Sam called the supplier."), and "Use the
  updated budget budget, I mean, Sam's budget." keeps the stutter (v8
  "Use the updated budget, I mean, Sam's budget.", v11 "Use Sam's
  budget."). Over all 781,301 rows that gives back 43 repeats, restarts
  and cut-off words v11 fixed, all in seeded rows (28 of ours, 15 of the
  reviewers'). Without it a later cue or pass read the refused cue again
  on other words, or a repeat lost the copy v11 had kept, and v12 took
  words v11 kept (§3).
- **What the valve leaves half-repaired** (v13). Where v11 corrects and
  v13 does not, or v13's correction is the shorter, the words v11 took and
  v13 keeps are kept from every later fire, and a repeat, a restart, a
  cut-off word or a later correction inside them is left as said: "We need
  to give to give the plants, scratch that, Dana the plants." → "We need to
  give to give Dana the plants." (v12 "We need to give Dana the plants.",
  which took a "to" v11 kept). And the v11 run drops any fire that deletes
  a word it keeps, which can leave a repair v12 made undone: "Remember to
  sign shared to sign shared files, no wait, scan shared files!" stays (v12
  took the first "to sign shared", v11's restart "sign shared to", across
  the two copies). Over every input of v13's check v13 deletes less than
  v12 in 216,872 runs at Standard and none at Fillers; such a row's output
  can fire again (§4).
- **A name in lower case after "scratch that"** still reads as a new verb
  when a determiner and the object said again follow: "Can you send the
  invoice, scratch that, nora another invoice?" → "Can you nora another
  invoice?", as in v11 (v8 "Can you send the nora another invoice?"). Of
  the review's 125 such rows, v12 and v13 get none right, keep 25 and
  garble 100, and 25 of those delete a word v8 kept. Reading a lower-case
  word NLTagger tags as a noun before a determiner as no verb was measured
  and not applied: it gets 23 of the 125 right, but NLTagger tags most
  verbs there as nouns, and it keeps both in 594 battery rows v13 gets
  right ("Delete the logs, scratch that, archive the logs.").
- **Where v13 takes a word v8 kept.** On the 686,720 distinct inputs v12's
  check read, v13 deletes a word v8 kept in the same 8,942 as v12 (10,466
  rows), at Standard, and in none at Fillers — by the code path that took
  it (a row can count twice): v9's compound swap in 4,606, a verb phrase
  after "scratch that" in 1,379, the whole clause by T26 (below) in 847,
  T21's slot in 1,112, the clause in 629, a word swap in 310, and R1 in
  126, a word said twice right before the cue, where v8 swapped one copy
  and kept the other and the rules take that one. Most have no ideal; of
  the 3,631 battery rows among them that have one, 3,607 come out right.
  Over all 7,960,052 inputs of v13's check, 167,370 (v12 214,275), most of
  them perturbations: R1 in 67,377 (the same double), the compound swap in
  53,617, T21's slot in 18,053, a verb phrase in 12,695, the whole clause
  by T26 in 8,922, the clause in 5,514, a word swap in 2,298, the restart
  onset in 718, R3 in 349, R2 in 102, R5 in 14 and R1B in 9.
- **"Scratch that" takes the whole clause** (T26) when nothing that can
  stay stands before X's verb: a subject and a finite verb ("We pushed the
  branch, scratch that, open a PR." → "Open a PR."), a conjunct with a noun
  subject ("We tested it and Sam deleted the logs, scratch that, archived
  them." → "Archived them."), or a verb NLTagger reads as a noun ("Let's
  print, scratch that, share the slides." → "Share the slides."). Since
  v10 it takes the whole clause after a relative word too, which is right
  for a relative clause and costs two look-alikes: "that" after a noun
  opening a complement ("Tell the team that we should ship it, scratch
  that, delay it." → "Delay it.", as in v8; v9 "Tell the team that we
  should delay it.") and who or which opening an embedded question ("Ask
  who can drive us, scratch that, host us." → "Host us."; v9 "Ask who can
  host us."). Reading who and which as relative only right after a noun
  was measured and not applied: NLTagger misses nouns ("Pay the cleaner
  who will come Friday" — "cleaner" read as an adverb — would graft the
  correction onto the relative clause again). "Where" after a noun is read
  as a relative word, also where it opens an embedded question after an
  indirect object ("Ask the driver where we can park it, scratch that,
  leave it." → "Leave it."; v9 "Ask the driver where we can leave it.");
  "when" only after "a" or "the" and a time noun since v11. A relative
  clause in the subject resumes the scan at the main clause since v11, but
  a main verb with no lead-in before it still takes the whole clause ("The
  guy who wants to help called us, scratch that, emailed us." → "Emailed
  us."), and a relative clause after a verb is taken whole even when the
  main clause runs on after it ("I think the thing that we should do is
  call him, scratch that, email him." → "Email him."; v9 kept "I think the
  thing that we should do is"). A subordinate clause (so, if, when, because)
  is read like any other: its verb phrase is taken back
  when an auxiliary or "to" stands before its verb — right when the
  correction is for it ("Ping me if you can review it, scratch that, merge
  it." → "Ping me if you can merge it.") and wrong when it is for the main
  verb ("Text the landlord so she can fix it, scratch that, call her." →
  "Text the landlord so she can call her."; v8 "Call her."): 2 of 6
  development sentences and 0 of 3 held out came out right (v8 5 and 2).
  Stopping at a subordinator too was measured and not applied: it gets 5
  of the 6, but "so" also joins two clauses ("It was late so we called the
  vendor, scratch that, emailed them." → "It was late so we emailed
  them." would lose "It was late so we"). And a verb with no object of its
  own before the cue is swapped for one with an object, as before: "The
  printer jammed, scratch that, restart it." → "The printer restart it.".
- Onomatopoeia that is not listed ("boing boing" inside a sentence), a
  question answered by its speaker ("Was it red? No, blue." → "Was it
  blue."), two true numbers ("I'm 34, actually 35 next week"), an "I mean"
  that adds rather than corrects ("Keep the header, I mean, keep the footer
  too" → "Keep the footer too", "We can meet Monday, I mean, Tuesday works
  too." → "We can meet Tuesday works too."), and a name taken back ("Call
  Sarah, I mean, call her tomorrow" → "Call her tomorrow"). Since v11 an
  addition keeps both where a modifier or a possessive is said with the
  head again and the phrase ends with "too", "either" or "as well", or
  holds "also" ("We can use the shared folder, I mean, Sam's folder works
  too."; v10 "We can use Sam's folder works too."; 1,152 of 1,152 such
  rows); a "too" before more words is not read as one, but since v12 a
  possessive said with the head again, and a new modifier said with it
  before a verb of its own, keep both anyway ("Sam's folder works too
  tonight", "prod bucket works too tonight").
- A dictionary term is protected from R3 only: a short lower-case term can
  still go as the abandoned word of a restart ("check zq check the logs" →
  "check the logs" with "zq" in the dictionary). The reference does the same;
  the port keeps parity with it.
- Uncued corrections mostly stay: a bare word swap has no rule (0 of 2 in the
  maintainer's dictations), and a restart is caught only when it restates its
  start. Those are what remain of the 33.
- English only, by design.
- Character classes come from the OS's Unicode tables; the reference ran on
  Python 3.14's Unicode 16.0. The only differences are the characters Unicode
  17 added and three letters whose case it changed; none occurs in any set.
  The layout markers are found on the reference's whitespace split, which
  also splits at U+001C–U+001F; `SpokenStructure` does not, so a marker word
  with one of those controls inside it is a marker there and not here (no
  recogniser writes one).

## 8. Byte parity, and how to run it

The port follows the reference line by line: the same passes and order, the
same break model, quotation and bracket pairing, layout markers, mentions,
guards, number grammar and word lists, and Python's own string semantics
(`str.split`, `isalnum`, `lower`; `SelfRepairText.swift`) — Swift compares
strings by canonical equivalence, Python by code point, so every word is
compared by code point. The word-class test calls `NLTagger` exactly as the
reference's helper does.

Checked on every row, at both levels that run the rules (Standard, and
Fillers and repeats):

| Rows | Output identical | Fires identical |
|---|---|---|
| the maintainer's own dictations, 121 | 121, 121 | 121, 121 |
| synthetic, 623 | 623, 623 | 623, 623 |
| public, 57 | 57, 57 | 57, 57 |
| red team, 858 | 858, 858 | 858, 858 |
| holdout, 139 | 139, 139 | 139, 139 |
| written English corpus, 40,509 | 40,509, 40,509 | 40,509, 40,509 (Standard: R1 61, R2 2, R3 23, R4 26, R4S 1; Fillers: R1 63, R3 3) |
| seeded synthetic rows, 260,000: 20,000 aimed at v12's refusals, 20,000 at v11's changes, 20,000 at v10's, 20,000 at v9's, 20,000 at v8's, 20,000 at v7's, 20,000 at T19–T22, 20,000 at the doubles guards, 20,000 at T17's frames, 20,000 at layout and v3's mentions, 30,000 noisy (control-character whitespace, mixed scripts, case oddities), 30,000 structured | 260,000, 260,000 | 260,000, 260,000 |
| the reviewers' own seeded rows, 156,000 | 156,000, 156,000 | 156,000, 156,000 |
| invented probes and batteries: every probe of every round, the batches held out included (2,337), the carrier batteries of v10's review (5,000), the integration reviews' batteries (17,582), the other reviewers' batteries (268,537) and v11's own ten (29,538) | 323,994, 323,994 | 323,994, 323,994 |
| v13's check, every input above and the v12 review's: its whole collection, fresh batteries, ablation inputs, 300,000 random and 869,328 aimed perturbations, and 6,071,337 perturbations of our own — 7,960,052 distinct | 7,960,052, 7,960,052 | 7,960,052, 7,960,052 |
| the v12 review's fixed-point inputs this work could trace to an input that is not held out — 241,391 distinct | 241,391, 241,391 | 241,391, 241,391 |
| the v12 review's ideal outputs, run as inputs — 47,134 distinct | 47,134, 47,134 | 47,134, 47,134 |

In the 20,000 rows aimed at T17's frames, 14,277 hold a mention, T17 changes
the output of 11,325, and every frame marks words in at least 147 of them.
In the 20,000 aimed at the doubles guards (other languages' doubles, accents
precomposed and decomposed, other scripts, doubles at every sentence and
clause edge, particles with every kind of phrase after them, wh-words near
and far), the output differs from v4's in 5,185 at Standard and 5,124 at
Fillers; with T3 off 2,061 change, with T18 off 447, with T19 off 2,157
(Standard). In the 20,000 aimed at T19–T22 (a double right after a wh-word,
after a wh-word and a subject, after a wh-word and an auxiliary, near and
far; "scratch that" before every kind of noun phrase and clause; short words
of other languages and junk next to numbers, capitals and stops), the output
differs from v5's in 5,861 at Standard and 3,348 at Fillers; with T19 off
618 change, with T20 off 2,002, with T21 off 844, with T22 off 1,818
(Standard). In the 20,000 aimed at v7's changes (one-word items said once,
twice or three times between layout markers of every kind, at the text's
edges and beside stops, commas and fillers; other languages' words doubled
inside sentences and at their edges, beside English look-alikes, accented
and capitalised; "W a W" and "W e W" idioms beside English restarts; the
new short words beside junk), the output differs from v6's in 8,510 at
Standard and 5,519 at Fillers; with T3 off 5,029 change, with T18 off
2,199, with T20 off 2,440, with T23 off 1,593 (Standard). In the 20,000
aimed at v8's changes ("X, cue, Y" with every kind of X — a noun phrase, a
bare noun, a verb slot — every cue and its punctuation, and Y a verb or a
noun-verb word with an object, a particle, a preposition and a bare noun,
a time, an indirect object, or an adverb before a determiner; layout
markers carrying their own punctuation, with doubles after them; the new
short words and the strings left to R3 beside numbers, capitals and
stops), the output differs from v7's in 5,533 at Standard and 1,942 at
Fillers; with T24 off 605 change, with the markers' own punctuation not
counted 1,942, with the 16 new short words off 3,283 (Standard). Over the
other 160,000 seeded rows v8 changes 465 at Standard (190 by the markers'
punctuation, 266 by the short words, 9 by T24) and 190 at Fillers. In the
20,000 aimed at v9's changes ("X, scratch that, Y" and the other cues,
with X an imperative, a subject and an auxiliary or modal, "can you",
"let's", "please", a coordinated clause, a clause with no verb, or a
noun phrase with a compound, an adjective, a number or a possessive, and
Y a noun with a determiner object, an indirect object or a reduced
relative, a verb with its object said again, an object pronoun (after a
particle and a preposition too, and after an adverb with a particle after
it), a particle and what follows it, a full noun phrase, a modifier with
the head said again or alone, a clause with its own subject), the output
differs from v8's in 3,285 at Standard and none at Fillers; with T24 off
1,433 change, with T25 off 1,752, with T26 off 942 (Standard). Over the
other 180,000 seeded rows v9 changes 200 at Standard (T25 off undoes 113
of them, T26 off 37, T24 off 16, two of them either of the last two; no
single switch undoes the other 36) and none at Fillers, and it never
deletes a token there that v8 kept. In the 20,000 aimed at v10's changes
(the noun before the cue said again after the cue's word across every kind
of connector — a preposition, "and" or "or", in, on, off or over, a
particle, a determiner, a possessive, a modifier, a number — after every
cue; "scratch that" and the other cues after relative clauses, subordinate
clauses and embedded questions, with lead-ins in both clauses; a possessive
said with the head again after every opener, a number and an ordinal;
compound modifiers of different closed kinds; a verb's two objects), the
output differs from v9's in 2,729 at Standard and none at Fillers: the
restatement read as v9 read it undoes 1,403 of them, no relative-clause
stop 634, no possessive phrase start 613, "her" read as v9 read it 14, and
no single change undoes the other 65. Against v8, v10 deletes a token v8 kept in 1,317 of
them, by the code path that took it (a row can count twice): T25's
compound swap in 685 (v9's), its possessive phrase in 548 (v10's), a
"scratch that" clause or verb phrase in 82 (72 of those rows come out as
v9's), T21's slot in 15, a word swap in 1 and a repeat across a filler in
4 (v8's retraction had taken the repeat with its clause); and a token v8
and v9 both kept in 427: the possessive phrase's own determiner or old modifier in all but 3,
where a phrase in in, on, off or over runs on into a clause after "scratch
that" and the clause goes whole ("can you Print in the sink, scratch that,
pots off sink first" loses "can you", which v9's verb-phrase reading kept).
That held on these seeded rows only: the reviewers' batteries found v10's
phrase start also taking a subject and its verb or an indirect object, a
common-noun possessor's determiner, and, in a run after in, on, off or over,
the verb v8 had kept; v11 does none of these (§3).
Over the other 200,000 seeded rows v10 changes 20 at Standard ("her" 11,
the relative-clause stop 4, the restatement 5) and none at Fillers; one of
them deletes tokens v8 and v9 both kept (a "that's" after a noun stops the
verb-phrase scan, and "half the account that's" goes with the clause). In
the 20,000 aimed at v11's changes (a possessive said with the head again
after every kind of opener — an article, a possessive, a quantifier, a
preposition, a number, none — with one or two modifiers of every word
class, after a subject and its verb, an indirect object, a verb that takes
two objects or an imperative NLTagger reads as a noun, possessors of every
kind, and a run after the head said again or an addition; the object said
again after a two-word verb or a modifier; in, on, off or over runs after
"scratch that" opening with every kind of word; "when" and "where" after
nouns, pronouns and time words; relative clauses in the subject and the
object), the output differs from v10's in 3,849 at Standard and none at
Fillers: the possessive start as v10 had it undoes 1,181 of them, the
restatement as v10 read it 751, the run-on 413, "when" as v10 read it 380,
the subject's relative clause 290, the addition 246 and the double object
29, and no single change the other 588. v11 deletes a token v10 kept in 269
of them: 252 the object said again after a modifier or a two-word verb,
taken back after "scratch that" as v9 did; 12 a possessive whose walk stops
at a word that is no modifier before a number it would have met (v10 kept
both; v11 takes the modifier and keeps the number); and 5 rows of several
repairs where one v10 made no longer happens and another takes its place
(three repeats, a clause and a swap). Against v8 and v9 together, v11 takes
a token both kept in 1,224 of them: the old determiner with a name-like
possessor in 1,066 (v10's reading, which the development probes call right:
"Use the shared folder, I mean, Sam's folder." → "Use Sam's folder."), a
whole clause after in, on, off or over with a verb right after the noun said
again in 160 ("lock on the door is broken", v10's too; three rows have both),
and a verb phrase in 1. Over the other 220,000 seeded
rows v11 changes 181 at Standard — 147 aimed at v10 (undone by the
restatement in 65, "when" in 51, the possessive start in 24, the run-on in
6, the double object in 3 and the finite verb in 1; a row can count twice)
and 34 aimed at v9, each an addition now kept both ways — and
none at Fillers; it deletes a token v10 kept in 19 of them, 18 the object
said again after a modifier and 1 a possessive's walk stopping before a
number. In the 20,000 aimed at v12's refusals (a possessive said with the
head again in every frame, after every cue, with every kind of possessor
and its own determiner or none, and the phrase running on into a verb,
"please" or an addition; after "scratch that" a phrase opening with a
name, a full name, a title and a name, a name's possessive, a name and a
verb in every form, a verb written with a capital, or a noun in lower case
before an inflected verb, with and without a lead-in; a possessive opened
by an adjective or a noun; the object said again with no determiner; a
modifier said with the head again before a verb), the output differs from
v11's in 6,546 at Standard and none at Fillers; over the other 240,000
seeded rows v12 changes 3,895 at Standard (2,961 of those aimed at v11,
862 at v10, 66 at v9, 3 at v8, 2 at T19–T22 and 1 structured) and none at
Fillers, and over the reviewers' own 156,000 rows 3,326 at Standard and
none at Fillers. In every one of them v12 deletes less than v11, and in no
row of all 781,301 a word v11 kept (§3). Against v8, v12 deletes a token v8 kept in 10,466 of the 781,301 rows at
Standard and in none at Fillers — by the code path that took it, v9's
compound swap in 5,195, a verb phrase after "scratch that" in 1,831 (v9's
T24) and 1,140 (T26), T21's slot in 1,096 (the names of §3), the clause in
618, a word swap in 395, and R1 in 124, a word said twice right before
the cue (T25 reads the double as a compound and stops the swap, R1 takes
one copy, and the second pass swaps the other; v8 swapped one copy and
kept the first), as in v9 to v11 (a row can count twice); of the 3,631 of
them with an ideal, 3,607 are right (§3). The port also
matches the reference with T21, T24, T25 or T26 switched off, on the
20,000 rows aimed at v12, the 20,000 aimed at v11, every probe and v11's
batteries.

v13 changes 3 of the seeded rows against v12, every one by
deleting less, and none at Fillers (§3, "The valve, by construction"); the
port matches it with T21, T24, T25 or T26 switched off too, on the v12
review's 102,798 ablation inputs at both levels.

End to end, the five sets replayed through the app's pipeline compiled from
this code, rules only, give the scores in §5; against the same replay of the
version before the doubles guards, only the holdout's seven look-alike rows
differ, at both levels; against the version before T19's subject test and
T20–T22, against the version before v7's changes (6ba8a15) and against
the version before v8's (a4d826d), no row differs; against the version
before v9's (38adf08), one synthetic row differs at Standard (s0296, a
compound's head corrected alone, now kept both ways); against the version
before v10's (e104c0c), the version before v11's (d003b55), the version
before v12's (11ff354) and the version before v13's (1c0d89c), no row
differs; with the formatter on, the maintainer's dictations come out as
they did at 11ff354, every one, at both levels.

To run it:

1. Write the reference run with the reference implementation (kept with the
   private eval): `python3 rules.py --set set.json --out reference.jsonl`
   (`--level fillers` for that level's rules). It writes `{"id", "output",
   "fires": [["R1", [3, 4]], …]}` per row.
2. `whispr-bench repairs --in set.json --out port.jsonl --compare reference.jsonl`
   (`--rules level:fillers` likewise) prints identical outputs and fires out
   of the rows compared, the per-rule fire counts on both sides and the ids
   that differ, and exits 1 on any difference. `--field` / `--variant` read a
   run file that holds several. Every string is read exactly — Foundation's
   `JSONSerialization` drops a U+FEFF that opens a string, so the loaders
   read strings with `JSONDecoder`.
3. Give both sides the same dictionary terms: the reference reads the
   `to = "…"` lines of `config.toml`, the bench the app's dictionary; pass
   `--no-dict` (and the reference's `--no-dict`) to run without them.

The reference's own test cases are in the tree:
`Tests/WhisprBroCoreTests/Fixtures/self-repair-fixtures.json` (591 invented
cases, written by its test suite), run by `SelfRepairTests`.
