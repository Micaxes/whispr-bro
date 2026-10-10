import Foundation

/// Hard-fail gates read off the raw↔out alignment ALONE — no gold, no
/// fixture — so the same code grades a gold-free history row in the bench
/// today and guards the live macOS llama path tomorrow (plan §4.5; §10.3
/// rank 1). Each gate reproduces a real failure a WER cannot tell from a
/// harmless edit: ANSWERED is history row 70 (a markdown reply pasted into
/// a prompt), INVENTED is row 54 (a total nobody said), NEGATED is a polarity
/// flip ("do not push" → "push"), OVER_EDIT_FACT here is the wholesale drop
/// (an empty or half-length output). The gold-scored deletion triggers
/// (`must_keep` weight 5, D/N_g) belong to the quality scorer, which owns
/// the gold↔out alignment; `gold` is accepted only to widen the novelty
/// vocabulary (§4.4), so a gold-scored row and a gold-free one share one
/// gate implementation.
///
/// Like `TranscriptScore`, the struct IS the result: the fired `triggers`
/// (the WHY the report prints), the `gates` they map to worst-first, and
/// the diagnostics that drive the rating queue (`droppedContent`, `ratio`).
/// Pure string math, deterministic, zero dependencies.
public struct ContentGuard: Sendable {
    /// Which side of the split a check grades — the ONE knob that separates
    /// the BENCH grader from the LIVE dictation gate.
    ///
    /// The two sides answer different questions, and four verifier rounds
    /// proved that one rule set cannot serve both. The bench grades EDIT
    /// QUALITY: a miss costs a wrong number on a leaderboard row, so every
    /// rule stays strict (row 54's invented total must gate, and a
    /// spelled number the canonicalizer cannot resolve is an invented one
    /// until a fixture annotates it). The live gate has ONE job — catch a
    /// CATASTROPHE before it lands in his editor. There a refusal costs him
    /// a real improvement (the dictation falls back to rules output, i.e.
    /// the unresolved raw), and edit quality is what the benchmark measures
    /// and what the register wording and the prompt delimiters (plan §10.3
    /// follow-ups 2 and 3) fix — not what a lexical gate can referee.
    ///
    /// **`.live` is SIX rules and nothing else.** Three rounds of patching
    /// each traded one false positive for a new hole (the last one: the
    /// opener rule's whole-raw echo fix disabled the rule on 3 of his 70 real
    /// rows), so the answer is to delete rather than to add — and where the
    /// 2-column measurement then disagreed with a threshold, the threshold
    /// moved rather than the rule set growing. IN is the text the model was
    /// given (dictionary applied, fillers stripped), OUT the sanitized,
    /// punctuation-repaired reply, atoms are this file's canonical tokens:
    ///
    ///  - **L1 STRUCTURE** — more non-empty lines in OUT than in IN, or a
    ///    markdown structure marker OUT carries and IN does not
    ///    (`multiLine`, `markdown`);
    ///  - **L2 RUNAWAY** — atoms(OUT) > 1.5 × atoms(IN), atoms(IN) ≥ 6
    ///    (`lengthRatio`);
    ///  - **L3 WHOLESALE LOSS** — atoms(OUT) < 0.25 × atoms(IN), atoms(IN) ≥ 12
    ///    (`wholesaleLoss`). Read against IN itself, not against the length a
    ///    perfect strip would leave: one length band, one place. A quarter,
    ///    not a half — at a half it refused a legitimate long cued correction
    ///    at his median dictation length, and the catastrophe it exists for
    ///    (22 atoms back as "Revenue grew.") sits at 0.09;
    ///  - **L4 WORDLESS** — no letter and no digit in OUT. Lives in
    ///    `TextFormatter.implausibility`, the only one of the six that
    ///    needs no alignment;
    ///  - **L5 INVENTED NUMERAL** — a digit run in OUT that IN's numbers,
    ///    written or spoken, cannot witness (`novelNumeral`). Permissive by
    ///    construction: its failure mode has to be letting a number through,
    ///    never refusing one the speaker said;
    ///  - **L6 INVENTED CONTENT** — ≥ 3 novel content words on an output of
    ///    ≥ 10 atoms (`novelCount`). A novel content word CARRIES A LETTER OF
    ///    ITS OWN: a dash invents no content, and neither does any piece of a
    ///    number L5's WITNESS TEST accepts — the "th" of "the 9th" and the "am"
    ///    of "9am" or of "9:30am" are the canonicalizer's letters, not the
    ///    speaker's, and the tokenizer splits the spaced forms ("the 9 th",
    ///    "9 am", "9:30 am") into a number and a bare suffix atom that are
    ///    still the one number, whatever separator runs through it. So
    ///    L6 runs L5's witness test and skips everything it accepts, digit
    ///    run and suffix atom alike (`witnessedNumbers`): the two INVENTED
    ///    rules share ONE test for whether he SAID a number, though the
    ///    witness READS more forms than L5 GATES on (gap 6). The bench's
    ///    own count with a length floor under it: the FLOOR is the
    ///    relaxation, and at 4 two in-band answers landed that the bench then
    ///    graded INVENTED — the exact class the rule is for.
    ///
    /// Gone from live, each one measured refusing legitimate cleanups: the
    /// answer-opener rule in every form (whole-raw echo, interrogative
    /// opener, window), `novelShare` with its slip-fix edit-distance
    /// discount, every cue lexicon, the alignment-driven negation rules, and
    /// the POLARITY COUNT — the rule that used to be L7. The count went on
    /// measurement, like the rest: it refused a correctly resolved correction
    /// on BOTH model columns ("send it monday no wait tuesday" → "Send it
    /// Tuesday."), costing 3 of the 81 seed golds and 2.3 composite on llama,
    /// while the shapes it guards — a dropped or an inserted polarity word —
    /// are measured at ZERO across his 70 real dictations and all 81 seeds.
    /// A rule whose false positives are measured and whose true positives are
    /// not does not earn a place on a shipping path. The BENCH still scores
    /// and reports NEGATED, so an inversion that does happen to him appears
    /// in the leaderboard.
    ///
    /// Known and accepted gaps, pinned as rows in `OutputGateTests` and
    /// stated in docs/llm-measurement-gate.md rather than left silent: an
    /// in-band answer built from fewer than 3 novel words; a question
    /// rewritten as a statement; a fabricated date whose digits the speaker
    /// did say; a polarity inversion (live does not refuse it, the bench
    /// scores it); a wholesale drop of an 11-atom-or-shorter dictation; a
    /// LETTERLESS number form L5 waves through — a decimal, a clock time, a
    /// price — which nothing on this path bounds beyond L1-L4, because L6
    /// counts letter-carrying words and those forms carry none. (The WITNESS
    /// reads those forms, so the suffix atom after one is his number's and
    /// not invented content; what L5 gates on is unchanged, which is what
    /// leaves the gap open.) And a number whose digit RUNS the raw witnesses
    /// SEPARATELY: the witness reads each run of a form on its own and asks
    /// the WHOLE dictation for it (`isReachable`), so "9:30" asks for a 9 and
    /// for a 30 and never for the two together — a raw that says "nine of us
    /// are going" and "thirty people signed up" witnesses a 9:30 nobody said,
    /// and the "am" the model wrote after it is then his number's letters
    /// rather than a novel word. It STAYS that way: the gap lets a number
    /// through, it does not refuse one he said, which is the direction this
    /// gate is built to fail in — three rounds of patching these rules each
    /// traded one false positive for a new hole, and every round since the
    /// freeze has moved them the other way, because what they refused was his
    /// own register: dates, times and prices. What bounds it is the text
    /// AROUND the number, which the other four rules read: the reply cannot
    /// gain a line or a marker (L1), grow past 1.5× (L2), collapse to a
    /// quarter (L3) or carry 3 novel content words of its own (L6). The
    /// MERGED spelling is one run and is unaffected — "9:30am" canonicalizes
    /// to "930am", which has to be spoken whole or spelled by consecutive
    /// words — so the same reply gates or lands on how the model spaced it.
    /// Each rule fails toward permissiveness, which on a shipping path is
    /// the correct direction: a refusal costs a real improvement, a miss
    /// costs one bad dictation the benchmark will show.
    ///
    /// One gap runs the OTHER way, and it is the price of the 3: THREE ASR
    /// slip fixes on a ≥ 10-atom output are refused ("we should of shipped
    /// the fix befour the standup with there approval today" → "We should
    /// have shipped the fix before the standup with their approval today."),
    /// and the prompt commissions exactly that edit. Three slip fixes are
    /// three novel content words and nothing on this path tells them from
    /// three invented ones — the discount that tried to (`novelShare`'s
    /// edit-distance licence) is deleted, and the measurement priced the
    /// count at 4, which let two in-band answers the bench graded INVENTED
    /// into his editor. So the refusal is bought deliberately: it costs one
    /// dictation the rules output still cleans up, while two slips at any
    /// length and three below the floor land (`OutputGateTests` F4). It is
    /// pinned as a refusal row rather than argued.
    ///
    /// `.bench` is the default and is BYTE-IDENTICAL to what it has always
    /// been — it is a scoring axis, not a refusal — so every existing call
    /// site (the quality scorer, the lint, every test) keeps its exact
    /// behaviour; the two model stages pass `.live` through
    /// `TextFormatter.gateModelOutput`.
    public enum Profile: String, Sendable, CaseIterable {
        case bench
        case live
    }

    /// The four gated verdicts, declared worst-first — the top of the §4.6
    /// ladder (ANSWERED > INVENTED > NEGATED > OVER_EDIT_FACT).
    public enum Gate: String, Codable, Sendable, CaseIterable {
        case answered = "ANSWERED"
        case invented = "INVENTED"
        case negated = "NEGATED"
        case overEditFact = "OVER_EDIT_FACT"
    }

    /// One row of the §4.5 trigger table. Kept apart from `Gate` so a
    /// report can say "ANSWERED (multi-line, markdown, opener)" instead of
    /// making him re-read the output to guess which rule fired. Which of
    /// them a profile RUNS is `Profile`'s business: the bench runs every
    /// one except `wholesaleLoss`, live runs L1, L2, L3, L5 and L6 and
    /// nothing else.
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        /// L1. More non-blank lines in out than in raw.
        case multiLine = "multi-line"
        /// L1. A markdown marker in out (`**`, line-initial `- ` / `* ` /
        /// `1. `) that raw does not carry.
        case markdown
        /// BENCH. Out starts with an assistant opener the raw did not start
        /// with.
        case opener
        /// L2. N_out / N_raw above `answeredLengthRatio` on a ≥ 6-word raw.
        case lengthRatio = "length-ratio"
        /// BENCH. A question answered in band: raw opens with a wh-word or
        /// an auxiliary, out opens with neither it nor a question mark, and
        /// nothing is novel.
        case answerShape = "answer-shape"
        /// L5. A numeric atom the speaker never said (live: whose digits the
        /// raw cannot witness).
        case novelNumeral = "novel-numeral"
        /// L6. Novel content tokens: `inventedNovelTokens` on the bench at
        /// any length, `liveInventedNovelTokens` letter-carrying ones — no
        /// piece of a number L5 witnessed counts, merged ("9am", "9:30am") or
        /// spaced ("9 am", "9:30 am") — on a ≥ 10-atom output live: the same
        /// count, with a length floor.
        case novelCount = "novel-count"
        /// BENCH. Novel share of a ≥ 10-word output above
        /// `inventedNovelShare`.
        case novelShare = "novel-share"
        /// BENCH. A raw negation deleted (or rewritten to a non-negation)
        /// while the content word it governed survived in the output.
        case negationDropped = "negation-dropped"
        /// BENCH. A negation the speaker never said, inside surviving raw
        /// words.
        case negationInserted = "negation-inserted"
        /// BENCH. N_out / `expectedWords` below `overEditLengthRatio` on a
        /// ≥ 6-word raw.
        case lengthCollapse = "length-collapse"
        /// L3. N_out / N_raw below `liveWholesaleLossRatio` on a ≥ 12-atom
        /// raw.
        case wholesaleLoss = "wholesale-loss"

        public var gate: Gate {
            switch self {
            case .multiLine, .markdown, .opener, .lengthRatio, .answerShape: return .answered
            case .novelNumeral, .novelCount, .novelShare: return .invented
            case .negationDropped, .negationInserted: return .negated
            case .lengthCollapse, .wholesaleLoss: return .overEditFact
            }
        }
    }

    /// Fired triggers in table order.
    public let triggers: [Trigger]
    /// Distinct gates of `triggers`, worst first; empty = not gated.
    public let gates: [Gate]
    /// Canonical atoms in raw / out ("fifty four" is ONE atom, so an ITN
    /// rewrite never moves the ratios).
    public let rawWords: Int
    public let outWords: Int
    /// N_out / N_raw. An empty raw is counted as one word so the ratio
    /// stays finite (a fixture never has one; the live guard might).
    public let ratio: Double
    /// Raw atoms minus what a formatter is SUPPOSED to drop — fillers, the
    /// extra copies of a stutter run, and the reparanda of the repairs
    /// scored at the run level — i.e. the length a perfect output would
    /// have. The collapse gate reads N_out against THIS, not N_raw: against
    /// raw, a correctly resolved "meet on Tuesday, I mean on Wednesday" →
    /// "Meet on Wednesday." (3/7) and a clean strip of a filler-heavy
    /// utterance would both gate as wholesale drops (plan §4.4 rows 7–8
    /// vs §4.5). The ANSWERED ratio keeps N_raw — more words than were
    /// SAID is a reply whatever the fillers.
    public let expectedWords: Int
    /// Raw atoms with no counterpart in out (`.del`), all kinds.
    public let deleted: Int
    /// The deleted raw atoms that carry meaning — not a filler, not part of
    /// a stutter run, not a STOP word — in raw order, original casing.
    /// Reported, never scored: R1 measured that this alone flags both
    /// over-edit history rows, so it orders the rating queue.
    public let droppedContent: [String]
    /// Canonical forms of the out atoms not covered by raw ∪ gold ∪
    /// alternates ∪ STOP (nor hyphen-split into raw), in out order; the
    /// count is what the INVENTED triggers read.
    public let novel: [String]
    /// Numeric atoms among `novel`.
    public let novelNumerals: Int

    /// The raw↔out alignment and its token sequences, for the scorer's
    /// filler axis (same tokens, so credit and gates can never disagree
    /// about where a word is).
    let rawTokens: [EvalToken]
    let outTokens: [EvalToken]
    let alignment: Alignment

    public var worst: Gate? { gates.first }
    public var isGated: Bool { !gates.isEmpty }

    // MARK: - Check

    /// Runs every §4.5 trigger over raw↔out.
    /// - `gold`: widens the novelty vocabulary only (gold-scored mode);
    ///   nil = gold-free, novelty vs raw ∪ alternates.
    /// - `alternates`: surface forms that are not novel (ITN spellings,
    ///   hyphenation); every `to` form's atoms join the vocabulary.
    /// - `fillers` / `stutters`: the disfluencies `droppedContent` ignores.
    ///   nil derives them fixture-free from the stripper's own lexicon
    ///   (every core filler in raw; every identical run of
    ///   `stutterCollapsible` words) — the same answer `EvalCase` derives
    ///   for a gold-free row; an explicit list (a fixture's
    ///   `expectedFillers` / `expectedStutters`) overrides, `[]` disables.
    /// - `reparanda`: spans of raw the run level is expected to delete
    ///   (the scored repairs' reparanda); they only lower `expectedWords`.
    /// - `profile`: `.bench` (default) grades; `.live` guards a dictation —
    ///   see `Profile` for what the three relaxations are and why.
    public static func check(raw: String, out: String, gold: String? = nil,
                             alternates: [EvalCase.Alternate] = [],
                             language: DictationLanguage = .english,
                             fillers: [EvalCase.Filler]? = nil,
                             stutters: [EvalCase.Stutter]? = nil,
                             reparanda: [String] = [],
                             profile: Profile = .bench) -> ContentGuard {
        let rawTokens = Align.canonicalTokens(raw)
        let outTokens = Align.canonicalTokens(out)
        let alignment = Align.align(rawTokens, outTokens)
        let fillerLexicon = Set(FillerStripper.coreFillers(for: language))
        let rawN = rawTokens.count, outN = outTokens.count
        let ratio = Double(outN) / Double(max(rawN, 1))

        // Novelty: vocabulary = raw ∪ gold ∪ alternates ∪ STOP; a hyphenated
        // out token whose parts are all covered is a formatting choice.
        // Every raw atom is in the vocabulary, so "not covered" already
        // implies the token is an `.ins` or `.sub` — no op filter needed.
        var vocabulary = Set(rawTokens.map(\.canonical)).union(Align.stopWords)
        if let gold { vocabulary.formUnion(Align.canonicalTokens(gold).map(\.canonical)) }
        for alternate in alternates {
            for form in alternate.to { vocabulary.formUnion(Align.canonicalTokens(form).map(\.canonical)) }
        }
        // Both spellings of every contraction are one word: dictation says
        // "dont", the formatter writes "don't", and `Align.isCovered` strips
        // the mark off the OUT token before looking here. Teaching the
        // negation rules the unapostrophized forms was only half the class —
        // a restored contraction is still a novel atom against a raw one,
        // and three of them in an utterance trip the count rule at ANY
        // length (two of them the share rule on a 10-atom output).
        vocabulary.formUnion(vocabulary.map(Align.unapostrophized))
        let novelIndices = outTokens.indices.filter { !Align.isCovered(outTokens[$0], by: vocabulary) }
        let novelTokens = novelIndices.map { outTokens[$0] }
        let novel = novelTokens.map(\.canonical)
        let novelNumerals = novelTokens.filter(\.isNumeral).count
        // The novel tokens that are a SLIP FIX: substituted by the alignment
        // for a raw token they are a near neighbour of. Evidence, not a
        // list — a homophone lexicon sanctions the corruption direction as
        // readily as the fix, and this reads the word the model actually
        // replaced (`isNearNeighbour`). It discounts the SHARE rule and
        // nothing else, so it is not computed on the live path, where that
        // rule no longer runs: nothing outside L1-L6 executes there.
        let opsB = alignment.opsB
        let slipFixes = profile == .bench ? novelIndices.filter { j in
            guard case .sub(let i, _) = opsB[j] else { return false }
            return isNearNeighbour(rawTokens[i].normalized, outTokens[j].normalized)
        }.count : 0

        // Deletions, minus the disfluencies a formatter is SUPPOSED to drop.
        let (ignored, removals) = disfluencies(rawTokens, fillerLexicon: fillerLexicon,
                                               fillers: fillers, stutters: stutters, reparanda: reparanda)
        let expectedWords = max(rawN - removals, 0)
        var deleted = 0
        var droppedContent: [String] = []
        for case .del(let i) in alignment.ops {
            deleted += 1
            let token = rawTokens[i]
            guard !ignored.contains(i), !Align.stopWords.contains(token.normalized) else { continue }
            droppedContent.append(token.cased)
        }

        var triggers: [Trigger] = []
        // L1 STRUCTURE (both profiles) — id 70 trips both halves.
        if nonBlankLines(out) > max(nonBlankLines(raw), 1) { triggers.append(.multiLine) }
        if !markdownMarkers(out).subtracting(markdownMarkers(raw)).isEmpty { triggers.append(.markdown) }
        // BENCH ONLY from here to the length ratio: the opener rule is gone
        // from live in every form it was ever written in. Its last version
        // read the echo against the WHOLE raw, which disabled the rule on 3
        // of his 70 real rows (each says "sure" or "okay" somewhere), and the
        // window version before it refused the cleanup that moves a late
        // opener to the front. It survives as a SCORING axis, where a miss
        // costs a leaderboard number rather than a dictation.
        if profile == .bench, let first = outTokens.first,
           EvalThresholds.answerOpeners.contains(first.normalized) {
            // Charged only when the opener is a word the speaker never said.
            // The echo is read against the WHOLE raw, not against its first
            // two tokens: a dictation that says "okay" three words in ("um
            // yeah i mean okay lets just ship it") gets that "okay" moved to
            // the front by the very cleanup the model is asked for, and a
            // two-token window called the result an assistant opener. The
            // comparison drops apostrophes so "here is the thing" and
            // "Here's the thing" are one word. Every refusal row still fires
            // — "sure" and "yes" appear nowhere in those raws.
            let opener = openerKey(first.normalized)
            if !rawTokens.contains(where: { openerKey($0.normalized) == opener }) {
                triggers.append(.opener)
            }
        }
        // L2 RUNAWAY (both profiles).
        if rawN >= EvalThresholds.minWordsForRatio, ratio > EvalThresholds.answeredLengthRatio {
            triggers.append(.lengthRatio)
        }
        // BENCH ONLY. The in-band ANSWER: a reply that stays inside one line, inside every
        // length band and inside the speaker's own vocabulary, and answers him
        // anyway. Six opener words were the only detector, so the measured
        // failure ("is it done?. okay.. let's go" → "Yes, it is done…") was
        // caught by the word "Yes" alone and its opener-free sibling ("It is
        // done…") landed. His register is where this lives: 44 of 70 history
        // rows are prompts or questions to an agent (plan §2).
        //
        // The evidence is the question's own SHAPE, not a length: the raw
        // opens with a wh-word or an auxiliary, the output neither opens with
        // that word nor carries a question mark, and it introduces nothing
        // (novel content is the INVENTED rules' business, and a slip fix must
        // not read as an answer). So "which branch should i merge first, the
        // parser one or the config one" → "The parser one." gates, "are we
        // sure the migration is reversible" → "We are sure the migration is
        // reversible." gates — and a question the model merely formats keeps
        // its opener ("Can you check…?") or its mark, and lands.
        //
        // It is a BENCH rule now. On live it is the second half of the
        // deleted opener family: it reads a QUESTION where his register is
        // full of them (44 of 70 rows), and a question rewritten as a
        // statement is a named, accepted gap on the shipping path — one bad
        // dictation the benchmark shows, against a rule that refused
        // formatted imperatives every round it was widened.
        if profile == .bench, novel.isEmpty, !outTokens.contains(where: { $0.marks.contains("?") }),
           let opener = interrogativeOpener(rawTokens, fillerLexicon: fillerLexicon),
           let first = outTokens.first, first.normalized != opener {
            triggers.append(.answerShape)
        }
        // INVENTED — id 54 trips the numeral rule alone. LIVE reads the
        // numerals whose digits the speaker did NOT say: a spelled form the
        // canonicalizer could not resolve ("nineteen oh five" → 1905) is a
        // normalization the user asked for, not a made-up fact, and
        // refusing it hands him back the spelled words. The witness test
        // runs over the digits of a token whose DIGITS ARE THE FACT — a bare
        // numeral, an ordinal or a meridiem form — so a date is checked on
        // its number rather than waved through on its suffix ("the ninth" →
        // "the 9th" passes, "the ninth" → "the 22nd" does not), while every
        // other token that merely CONTAINS digits is not read here at all,
        // exactly as on the bench (`digitsAreTheFact`) — on the bench the
        // count and the share rules still see such a token, on live only L6
        // does and only if it carries a letter of its own, which a decimal, a
        // clock time and a price do not (gap 6). The WITNESS below is wider
        // than this gate on purpose (`isNumberMaterial`): it recognises those
        // forms, so the suffix atom the model spaced off one of them is his
        // number and not a word he never said. The reported `novelNumerals`
        // stays the measured count either way.
        let gatingNumerals: Int
        // The out tokens the witness test accepts as number material the
        // speaker SAID. Computed on the live branch because L6 reads the same
        // answer below: one notion of a number he said, two rules.
        var witnessedNumberTokens: Set<Int> = []
        switch profile {
        case .bench:
            gatingNumerals = novelNumerals
        case .live:
            let spoken = spokenNumbers(rawTokens)
            witnessedNumberTokens = witnessedNumbers(outTokens, spoken: spoken)
            gatingNumerals = novelTokens.filter { token in
                digitsAreTheFact(token.canonical) && !isReachable(token.canonical, from: spoken)
            }.count
        }
        if gatingNumerals >= EvalThresholds.inventedNovelNumerals { triggers.append(.novelNumeral) }
        // L6 INVENTED CONTENT. The bench gates at 3 novel tokens whatever the
        // length; live wants the same 3 on a ≥ 10-atom output. The floor is
        // the whole relaxation, and it is what protects the slip fix and the
        // grammar repair the system prompt COMMISSIONS — two of those in a
        // short utterance is the measured shape, and a short utterance is
        // where it lives. Going to 4 to protect a third one cost more than it
        // bought: the measured run let `numbers-01` and `repair-02` land as
        // in-band answers the bench then graded INVENTED, which is this
        // rule's own class of failure arriving in his editor.
        //
        // A novel CONTENT word carries a letter, which is the clause the
        // shipped code was missing: counting every novel token made the rule
        // fire on tokens that invent no content at all. Four em-dashes in a
        // sentence the model otherwise left alone ("… on Friday - if the
        // tests pass - …") refused a reply whose comma-punctuated twin
        // landed, and four denormalized numbers refused a reply L5 had
        // already witnessed digit by digit ("seven fifty one seven forty
        // eight …" → "7:51, 7:48, …", "nineteen oh five …" → "1905, …") —
        // the spelled→digit family the numeral rule is permissive to protect.
        //
        // A DENORMALIZED NUMBER is one of them whatever suffix it keeps and
        // HOWEVER THE MODEL SPACED IT: the "th" of "the 9th" and the "am" of
        // "9am" are the canonicalizer's letters, not the speaker's, and the
        // tokenizer splits the spaced twins ("the 9 th", "9 am", "9 a.m.")
        // into a number and a BARE suffix atom carrying nothing else.
        // Reading the shape of the canonical token caught only the merged
        // half: "the first the second and the third of october" → "the 1st,
        // the 2nd, and the 3rd" landed while the same reply spaced — "the 1
        // st, the 2 nd, and the 3 rd" — and "at 9 am … 2 pm … 4 pm" refused
        // on three atoms of pure ITN, in the register that is full of them.
        // Reading the number as a DIGIT RUN caught only half of that half:
        // "9:30" keeps its colon, so "at nine thirty in the morning" → "9:30
        // am" kept the "am" while "9:30am" was witnessed whole. Any number
        // material takes its suffix now (`isNumberMaterial`), separators and
        // all.
        //
        // So the test is not a shape but L5's own verdict: the witness test
        // runs FIRST, and every token it places inside a number the speaker
        // said — the digit run and its suffix atom alike — is out of this
        // count (`witnessedNumbers`). What the two INVENTED rules SHARE is
        // the test for whether he SAID a number — one `isReachable` over one
        // `spokenNumbers` — so neither can call the same digits witnessed
        // while the other calls them invented. What each reads AS a number is
        // where they PART: L5 gates only a token whose DIGITS ARE THE FACT (a
        // bare numeral, an ordinal, a meridiem form), while the witness
        // recognises number MATERIAL, wider by exactly the separated forms (a
        // clock time, a decimal, a price). So a form the witness refuses is
        // not automatically L5's row. An unwitnessed "9am" gates on L5 and
        // counts here as well; an unwitnessed "10:45" gates on NEITHER — L5
        // does not read it and it carries no letter of its own — and all that
        // is left of it on this path is the "am" the join was denied, which
        // is gap 6 seen from the counting side. Nothing is carved out for
        // "am" either way: a suffix atom is content exactly when the witness
        // refuses the number in front of it.
        //
        // A letterless novel token — and every piece of a witnessed number —
        // is still novel on the BENCH, where the count gates at 3 whatever
        // the token is.
        switch profile {
        case .bench:
            if novel.count >= EvalThresholds.inventedNovelTokens { triggers.append(.novelCount) }
        case .live:
            // The letter has to be the WORD's, not a number's: a token the
            // witness test placed inside a number he said invents nothing,
            // whether it is the whole form ("9am") or the suffix atom the
            // tokenizer split off it ("9 am").
            let novelContent = novelIndices.filter {
                outTokens[$0].canonical.contains(where: \.isLetter)
                    && !witnessedNumberTokens.contains($0)
            }.count
            // The length floor keeps a short reply with two or three honest
            // homophone fixes out of the gate. It also exempted a reply that
            // was ENTIRELY invented: "should i start a new paragraph here or
            // keep it as one block" came back as "I actually enjoyed the
            // movie." — a few-shot example from the correction clause, five
            // atoms long, three of them novel, and under the floor. So the
            // floor is waived when the invention DOMINATES the output: at that
            // share it is not a slip fix, it is a different sentence.
            // NO slip-fix discount here, deliberately. `isNearNeighbour` is an
            // edit distance, and as this file says at the top of `slipIndices`
            // it "sanctions the corruption direction as readily as the fix":
            // discounting it let "we will NOT ship on friday" → "We will now
            // shop on Sunday." through the last gate standing on that class
            // (live NEGATED is off by measured decision). A refused short
            // correction costs him the correction — the rule-based text, his
            // own words — which is the cheap side of this trade.
            let dominated = outN > 0
                && Double(novelContent) / Double(outN) >= EvalThresholds.liveInventedDominantShare
            if novelContent >= EvalThresholds.liveInventedNovelTokens,
               outN >= EvalThresholds.inventedMinOutWords || dominated {
                triggers.append(.novelCount)
            }
        }
        // BENCH ONLY. The SHARE rule reads the novel tokens minus the slip fixes: a novel
        // token substituted for a near neighbour of itself ("there" →
        // "they're", "befour" → "before") is the homophone / split-word
        // correction the system prompt COMMISSIONS, and two of them in one
        // short utterance — the two commonest Parakeet classes, in the same
        // sentence — put a 10-atom output at 0.20 and threw the model's
        // correct reply away. They stay in `novel` and in the count rule
        // (three novel tokens gate at any length); they just do not make a
        // density of invention on their own (`slipFixes`).
        if profile == .bench, outN >= EvalThresholds.inventedMinOutWords,
           Double(novel.count - slipFixes) / Double(outN) > EvalThresholds.inventedNovelShare {
            triggers.append(.novelShare)
        }
        // NEGATED — BENCH ONLY. The bench reads the ALIGNMENT: which negation
        // was dropped, whether the word it governed survived, which "no" is a
        // backchannel. LIVE reads nothing. Every heuristic that told a
        // correction cue from a polarity carrier by evidence read an inversion
        // as a correction in the round after it, so the live rule was reduced
        // to a COUNT — and the count was then measured refusing a correctly
        // resolved correction on both model columns ("send it monday no wait
        // tuesday" → "Send it Tuesday."), 3 of the 81 seed golds and 2.3
        // composite on llama, while a dropped or inserted polarity word
        // appears in 0 of his 70 real dictations and 0 of the 81 seeds. A
        // refusal costs a real improvement; a miss costs one bad dictation the
        // benchmark shows — and the benchmark is exactly where NEGATED still
        // lives, because these two rules are unchanged here.
        if profile == .bench {
            if negationDropped(rawTokens, outTokens, alignment, fillerLexicon: fillerLexicon,
                               rawVocabulary: Set(rawTokens.map(\.canonical))) {
                triggers.append(.negationDropped)
            }
            if negationInserted(rawTokens, outTokens, alignment) {
                triggers.append(.negationInserted)
            }
        }
        // OVER_EDIT_FACT — empty outputs, dropped clauses.
        //
        // BENCH: the scoring axis, unchanged — the floor stays on N_raw (the
        // plan's) and the ratio reads the EXPECTED length, so nothing
        // expected to survive (an all-filler raw) can collapse.
        //
        // LIVE (L3): one band of its own, in one place. It reads N_out
        // against N_raw — the text the model was actually given, already
        // dictionary-applied and filler-stripped — needs 12 atoms under it,
        // and sits at a QUARTER, not the bench's half. Both numbers are
        // measured: a resolved self-correction IS a shrink, and at a half the
        // rule refused one at his median dictation length ("i want to meet at
        // the coffee shop on castro street actually at the office", 15 atoms
        // → 7), while the catastrophe it exists for — 22 atoms back as
        // "Revenue grew." — is 0.09 and refuses either way. Below 12 atoms a
        // wholesale drop lands: that is the named gap, bought so that "meet at
        // the cafe scratch that at the office" → "Meet at the office." does
        // not cost him the resolution the prompt commissions.
        if profile == .bench, rawN >= EvalThresholds.minWordsForRatio, expectedWords > 0,
           Double(outN) / Double(expectedWords) < EvalThresholds.overEditLengthRatio {
            triggers.append(.lengthCollapse)
        }
        if profile == .live, rawN >= EvalThresholds.liveWholesaleLossMinWords,
           Double(outN) < EvalThresholds.liveWholesaleLossRatio * Double(rawN) {
            triggers.append(.wholesaleLoss)
        }

        let fired = Set(triggers.map(\.gate))
        return ContentGuard(triggers: triggers,
                            gates: Gate.allCases.filter { fired.contains($0) },
                            rawWords: rawN, outWords: outN, ratio: ratio, expectedWords: expectedWords,
                            deleted: deleted, droppedContent: droppedContent,
                            novel: novel, novelNumerals: novelNumerals,
                            rawTokens: rawTokens, outTokens: outTokens, alignment: alignment)
    }

    // MARK: - The witnessed numeral (LIVE)

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// Is this novel token one whose DIGITS are the whole fact — a bare
    /// numeral, or a numeral with an ordinal or meridiem suffix ("22nd",
    /// "9am")? Those are the date and quantity forms row 54 lives in, and
    /// the live rule reads their digits against what the speaker said.
    ///
    /// Every OTHER token that merely CONTAINS digits — a decimal, a clock
    /// time, a price, a version string — is not read here, because the BENCH
    /// does not read it either (`EvalToken.isNumeral` is false for "2.5" and
    /// "11:30", so `novelNumerals` never counts them) and the live gate is a
    /// SUBSET of the bench rules, never a re-tuning of them
    /// (`EvalThresholds`). Reading them made live STRICTER than the grader
    /// on the whole spelled→digit fraction / clock / currency family: "give
    /// me two and a half hours" → "Give me 2.5 hours." is the one novel token
    /// `ContentGuardTests` pins as clean on the bench, and the shipped gate
    /// refused it — nothing can witness the 5, because "half" is not a number
    /// word. Not READ is not the same as not RECOGNISED: the witness knows
    /// every one of those forms for a number (`isNumberMaterial`), because it
    /// has to know what "9:30" is to see that the "am" after it is the
    /// canonicalizer's letters and not a word he never said (L6). This
    /// narrower test is what L5 GATES on.
    ///
    /// What BOUNDS that permissiveness is not the same on the two profiles,
    /// and on live the honest answer is "almost nothing". The token is NOVEL
    /// on both. The BENCH then reads it twice — the count rule (3 novel
    /// tokens of any shape, at any length) and the share rule. LIVE runs
    /// neither over it: the share rule is off this path for good, and L6
    /// counts only novel words carrying a letter OF THEIR OWN, which "2.5",
    /// "11:30" and "19.99" do not (a version string canonicalizes to "v25"
    /// and does, so that one is counted). So beyond L1-L4 and L6's count of
    /// letter-carrying words, nothing on the shipping path bounds L5's
    /// permissiveness here: three fabricated decimals in one reply land. That
    /// is a named gap (docs/llm-measurement-gate.md, gap 6), and it is the
    /// price of the rule's direction — a refusal hands him back the spelled
    /// words.
    private static func digitsAreTheFact(_ canonical: String) -> Bool {
        let digits = canonical.prefix(while: isDigit)
        guard !digits.isEmpty else { return false }
        let suffix = canonical.dropFirst(digits.count)
        return suffix.isEmpty || numberSuffixes.contains(String(suffix))
    }

    /// The suffixes a denormalized number keeps ("the 22nd", "9am"). Read on
    /// the canonical form, where the tokenizer has already dropped interior
    /// dots ("3 p.m." is two atoms, "3p.m." is "3pm").
    private static let numberSuffixes: Set<String> = ["st", "nd", "rd", "th", "am", "pm"]

    /// Is this canonical form NUMBER MATERIAL — digits from the first
    /// character on, nothing between them but the separators the tokenizer
    /// keeps INSIDE a number (`Align.numericCore`: a decimal point, a time
    /// colon), and at most one suffix of its own? A bare numeral ("22"), an
    /// ordinal or meridiem form ("22nd", "930am"), a clock time ("9:30"), a
    /// decimal and a price ("2.5", "19.99") all are.
    ///
    /// A VERSION STRING is not, and that is the line the test draws: "v2.5"
    /// canonicalizes to "v25", and the "v" in front is the speaker's own word
    /// ("version") rather than two letters the canonicalizer added to his
    /// number — so L6 counts it as the novel content word it is. Neither is a
    /// word that merely ends in digits.
    ///
    /// WIDER than `digitsAreTheFact`, which every form here except the
    /// separated ones satisfies, and deliberately so: L5 must not READ a
    /// decimal, a clock time or a price (the bench does not, and live is a
    /// subset of the bench), while the witness must RECOGNISE one or the
    /// suffix atom the tokenizer splits off "9:30 am" reads as invented
    /// content.
    private static func isNumberMaterial(_ canonical: String) -> Bool {
        let body = canonical.prefix(while: { !$0.isLetter })
        let suffix = canonical.dropFirst(body.count)
        guard suffix.isEmpty || numberSuffixes.contains(String(suffix)),
              let first = body.first, isDigit(first), let last = body.last, isDigit(last)
        else { return false }
        return body.allSatisfy { isDigit($0) || $0 == "." || $0 == ":" }
    }

    /// Number material that has not taken a suffix of its own yet — the atom
    /// a bare suffix atom can join. "9", "9:30" and "19.99" can; "930am"
    /// carries its two letters already and cannot take a second pair.
    private static func takesSuffix(_ canonical: String) -> Bool {
        isNumberMaterial(canonical) && canonical.last.map(isDigit) == true
    }

    /// The out-token indices holding NUMBER MATERIAL THE SPEAKER WITNESSED —
    /// the witness test (`isNumberMaterial` + `isReachable`) run over the
    /// output once, so L6 can read the same verdict instead of a second
    /// opinion about what a number is.
    ///
    /// It returns INDICES because the evidence is a FORM and a form can be
    /// more than one atom. The model writes a denormalized number merged
    /// ("9am", "9:30am", "1st") or SPACED ("9 am", "9:30 am", "9 a.m.",
    /// "1 st"), and the tokenizer splits the spaced one into the number and a
    /// bare suffix atom — the same number, two atoms, and the second of them
    /// carries the canonicalizer's two letters and nothing else. Both pieces
    /// are marked, so neither can read as invented content. No lexicon beyond
    /// the suffixes `digitsAreTheFact` already reads.
    ///
    /// The atom that TAKES the suffix is any number material that has not
    /// taken one already — a clock time, a decimal and a price included, not
    /// only the bare digit runs `EvalToken.isNumeral` names. Reading
    /// `isNumeral` there was the last residue of the merged-only rule: a
    /// clock time keeps its colon on purpose, so it is not a numeral to the
    /// tokenizer, and "nine thirty in the morning" → "9:30 am" left the "am"
    /// counted as a novel content word while the merged twin "9:30am" — one
    /// atom, "930am" — was witnessed whole. Three times in one dictation is a
    /// refusal, and a dictation full of times is what a scheduling prompt IS.
    ///
    /// The join stops at a boundary mark, the rule the compound run obeys on
    /// the raw side (`SpokenNumbers.breaksRun`): "at 9, am I early" is a
    /// clause boundary and an auxiliary, not a meridiem.
    private static func witnessedNumbers(_ out: [EvalToken], spoken: SpokenNumbers) -> Set<Int> {
        var witnessed: Set<Int> = []
        for (j, token) in out.enumerated() {
            var suffix: Int?
            if takesSuffix(token.canonical), token.trailingMarks.isEmpty, j + 1 < out.count,
               out[j + 1].leadingMarks.isEmpty, numberSuffixes.contains(out[j + 1].canonical) {
                suffix = j + 1
            }
            let form = token.canonical + (suffix.map { out[$0].canonical } ?? "")
            guard isNumberMaterial(form), isReachable(form, from: spoken) else { continue }
            witnessed.insert(j)
            if let suffix { witnessed.insert(suffix) }
        }
        return witnessed
    }

    /// The number forms the speaker demonstrably SAID, two ways: as a SET
    /// (every maximal digit run of each raw ATOM's canonical form and those
    /// runs joined — a merged "2:30" says 2, 30 and 230 — an ordinal word
    /// read as its cardinal, a spoken "oh" as a zero, and every compound a
    /// consecutive run of number WORDS spells), and in raw ORDER, one entry
    /// per raw ATOM, `nil` for an atom that is not a number. The sequence is
    /// what a MULTI-part numeral has to be witnessed by; the set answers for
    /// a numeral that matches one spoken form whole.
    ///
    /// WHOLE ATOMS on both sides, which is the whole rule. Reading the words
    /// INSIDE a merged atom (and every prefix a compound run parses) let any
    /// component of a number the speaker said license a different number in
    /// the output: "december twenty twenty six" → "December 2020" and "i ran
    /// fifty four miles" → "50 miles" were ACCEPTED live while the bench
    /// gated them as invented — a wrong race date and a wrong weekly mileage,
    /// the exact class (history row 54) this gate exists to catch. "fifty
    /// four" → 54 still passes as one atom, and "nineteen oh five" → 1905
    /// still passes as three atoms spelled consecutively.
    private struct SpokenNumbers {
        let forms: Set<String>
        let sequence: [String?]
        /// Per atom: a boundary mark ends the run here, so "twenty, six"
        /// cannot spell 26 — the rule `Align.numberRun` already obeys on the
        /// grader's side.
        let breaksRun: [Bool]
    }

    private static func spokenNumbers(_ raw: [EvalToken]) -> SpokenNumbers {
        var forms: Set<String> = []
        var sequence: [String?] = []
        var words: [String?] = []
        var breaksRun: [Bool] = []
        for (i, token) in raw.enumerated() {
            let runs = token.canonical.split(whereSeparator: { !isDigit($0) }).map(String.init)
            var digits: String?
            if !runs.isEmpty {
                forms.formUnion(runs)
                digits = runs.joined()
            } else if token.normalized == "oh" || token.normalized == "o" {
                digits = "0"
            } else if !token.normalized.contains(" ") {
                // A single ORDINAL word, read as its cardinal.
                let canonical = NumberCanon.canonical(cardinalForm(token.normalized))
                if !canonical.isEmpty, canonical.allSatisfy(isDigit) { digits = canonical }
            }
            if let digits { forms.insert(digits) }
            sequence.append(digits)
            // A merged atom is already one number; only a single word can
            // extend a compound the canonicalizer could not merge.
            words.append(token.normalized.contains(" ") ? nil : cardinalForm(token.normalized))
            let next = i + 1 < raw.count ? raw[i + 1] : nil
            breaksRun.append(!token.trailingMarks.isEmpty || !(next?.leadingMarks.isEmpty ?? true))
        }
        forms.formUnion(compoundForms(words, breaksRun: breaksRun))
        return SpokenNumbers(forms: forms, sequence: sequence, breaksRun: breaksRun)
    }

    /// An ORDINAL word read as its cardinal, so the digits inside a
    /// denormalized ordinal have something to be witnessed by: "on the ninth"
    /// says 9, "on the twenty third" says 23. `NumberCanon` leaves ordinals
    /// out of the SHARED canon on purpose (it would move the grader), so the
    /// reading lives here, on the witness side of the live numeral rule
    /// alone, where it can only ever make the gate more permissive about
    /// digits the speaker did say. The suffix rules are safe on non-numbers
    /// ("month" → "mon", "both" → "bo" are not number words either), and
    /// "second" → "two" is accepted collateral: it costs at most a witnessed
    /// 2 in an utterance about seconds.
    private static func cardinalForm(_ word: String) -> String {
        if let irregular = ordinalCardinals[word] { return irregular }
        if word.hasSuffix("ieth") { return String(word.dropLast(4)) + "y" }
        if word.hasSuffix("th"), word.count > 3 { return String(word.dropLast(2)) }
        return word
    }

    private static let ordinalCardinals: [String: String] = [
        "first": "one", "second": "two", "third": "three", "fifth": "five",
        "eighth": "eight", "ninth": "nine", "twelfth": "twelve",
    ]

    /// The cardinal a CONSECUTIVE run of spoken words spells — the compound
    /// form `Align.canonicalize` could not merge into one atom because a word
    /// in the middle is not a cardinal. Without it "on the twenty third"
    /// witnesses 20 and 3, never 23, and the correct "on the 23rd" reads as
    /// an invented quantity.
    ///
    /// Only the MAXIMAL parse of a run is a witness. Recording every prefix
    /// too ("twenty third" witnessing 20 as well as 23) is the same hole as
    /// reading inside a merged atom: a prefix of the number he said is not a
    /// number he said. Every whole atom contributes its own value anyway, so
    /// nothing legitimate is lost. The run also stops at a boundary mark, the
    /// rule `Align.numberRun` obeys — "we ordered twenty, six of them" is a
    /// list, so it cannot witness 26.
    private static func compoundForms(_ words: [String?], breaksRun: [Bool]) -> Set<String> {
        var forms: Set<String> = []
        var i = 0
        while i < words.count {
            var run: [String] = []
            var j = i, last = i, parsed: String?
            while j < words.count, let word = words[j] {
                run.append(word)
                if let value = NumberCanon.parseAtom(run) {
                    parsed = value; last = j
                } else if !NumberCanon.mayContinue(run) {
                    break
                }
                if breaksRun[j] { break }
                j += 1
            }
            if let parsed { forms.formUnion(parsed.split(whereSeparator: { !isDigit($0) }).map(String.init)) }
            i = max(last, i) + 1
        }
        return forms
    }

    /// Is every digit run of `canonical` one the speaker can be SHOWN to
    /// have said? Read off the DIGITS of any token, so an ordinal, a
    /// meridiem or a unit suffix is stripped by construction ("22nd" asks
    /// about 22, "3pm" about 3) and never buys the token a pass of its own.
    /// A run that matches a spoken form whole is a normalization
    /// ("fifty four" → 54; a minute "05" is the "five" he said, leading
    /// zeros forgiven). A run assembled from SEVERAL forms must be witnessed
    /// by the raw — the forms have to appear as CONSECUTIVE raw words, in
    /// the same order — which is what makes "nineteen oh five" → 1905
    /// legitimate while a lone "five" cannot spell 55 and a "two" with a
    /// "five" four words later cannot spell 25. Set membership alone
    /// admitted both: any utterance with one number word admitted its
    /// doubled form, any two admitted their concatenation either way round.
    ///
    /// EACH RUN IS ASKED SEPARATELY, and of the whole dictation: "9:30" asks
    /// for a 9 and for a 30, never for the two together, so a raw that says
    /// both in unrelated places witnesses a time nobody spoke. That is the
    /// run-by-run gap in the list at the top of this file — pinned as rows,
    /// and left open because it errs toward letting a number through. A
    /// MERGED form is one run and is asked whole ("9:30am" canonicalizes to
    /// "930am", so the question is 930), which is the same reading from the
    /// other side: the spelling decides how many questions get asked.
    private static func isReachable(_ canonical: String, from spoken: SpokenNumbers) -> Bool {
        let runs = canonical.split(whereSeparator: { !($0.isASCII && $0.isNumber) })
        guard !runs.isEmpty else { return false }
        for run in runs {
            let digits = String(run)
            if spokenWhole(digits, spoken.forms) { continue }
            guard spelledConsecutively(digits, in: spoken) else { return false }
        }
        return true
    }

    private static func spokenWhole(_ digits: String, _ forms: Set<String>) -> Bool {
        if forms.contains(digits) { return true }
        let unpadded = String(digits.drop(while: { $0 == "0" }))
        return !unpadded.isEmpty && forms.contains(unpadded)
    }

    /// `digits` consumed left to right by two or more consecutive spoken
    /// number ATOMS, each whole and in the order it was said, unbroken by a
    /// boundary mark.
    private static func spelledConsecutively(_ digits: String, in spoken: SpokenNumbers) -> Bool {
        let sequence = spoken.sequence
        for start in sequence.indices {
            var remaining = Substring(digits)
            var i = start, used = 0
            while i < sequence.count, let form = sequence[i], remaining.hasPrefix(form), !remaining.isEmpty {
                remaining = remaining.dropFirst(form.count)
                used += 1
                if remaining.isEmpty || spoken.breaksRun[i] { break }
                i += 1
            }
            if remaining.isEmpty, used >= 2 { return true }
        }
        return false
    }

    // MARK: - NEGATED

    /// A raw negation whose op is `.del` or `.sub` to a non-negation, WHILE
    /// the next content token after it (not STOP, not a filler) — the word
    /// it governed — survived in the output. The survival condition is the
    /// whole rule: "I don't know, do…" → "Do…" deletes "know" with the
    /// "don't", so it is an over-edit (charged in M), not a flip. With no
    /// content token after the negation nothing can be shown to have
    /// survived, so it does not fire.
    ///
    /// "Survived" is read off the out tokens the alignment PAIRED with the
    /// raw span negation…governed word, not off the governed word's op: the
    /// backtrace prefers the diagonal on equal cost, so a resolved
    /// reparandum followed by one inserted word comes back as substitutions
    /// ("monday no wait tuesday" → "on Tuesday" pairs wait→on, and "wait"
    /// is gone), while a flip that moved the governed word into the
    /// negation's slot ("do not push" → "Push it") pairs not→push and the
    /// word is still there. Two "no"s are exempt (`isDiscourseNo`): the
    /// backchannel / stance "no" and the "no" → "know" slip fix.
    ///
    /// BENCH ONLY: the live path does not read polarity at all any more.
    /// The count that used to stand there refused a correctly resolved
    /// correction on both model columns, for a shape measured at zero.
    private static func negationDropped(_ raw: [EvalToken], _ out: [EvalToken], _ alignment: Alignment,
                                        fillerLexicon: Set<String>, rawVocabulary: Set<String>) -> Bool {
        let opsA = alignment.opsA
        for i in raw.indices where Align.isNegation(raw[i].normalized) {
            if isDiscourseNo(raw, at: i, fillerLexicon: fillerLexicon) { continue }
            let flipped: Bool
            switch opsA[i] {
            case .del:
                flipped = true
            case .sub(_, let j):
                // "no" rewritten to a word the speaker never said is the
                // homophone slip fix ("I no what you mean" → "I know…"),
                // charged as novelty, never a polarity call. Every other
                // negation rewritten to a non-negation is a flip ("we can't
                // ship" → "We can ship.").
                flipped = !Align.isNegation(out[j].normalized)
                    && (raw[i].normalized != "no" || rawVocabulary.contains(out[j].canonical))
            case .hit, .ins:
                flipped = false
            }
            guard flipped,
                  let next = raw.indices.first(where: { $0 > i && isContent(raw[$0], fillerLexicon) })
            else { continue }
            let paired = (i...next).compactMap { opsA[$0].bIndex }.map { out[$0].canonical }
            if paired.contains(raw[next].canonical) { return true }
        }
        return false
    }

    /// A "no" that is stance or backchannel, not polarity: it opens the
    /// utterance — past fillers, discourse openers and repeated "no"s ("no
    /// I think we should ship it", "yeah no that's fine", "no no no let's
    /// not") — or carries its own mark ("no, wait"). 19 of his 70 history
    /// rows are backchannels; dropping such a "no" is an over-edit M
    /// charges (or a PASS on a gold that drops it too), never a flip of
    /// the clause after it. A determiner "no" heading an utterance ("no
    /// pushing to main") is the accepted cost; calibration §7.4 check 3
    /// measures this gate's precision and recall against his tags.
    private static func isDiscourseNo(_ raw: [EvalToken], at i: Int, fillerLexicon: Set<String>) -> Bool {
        guard raw[i].normalized == "no" else { return false }
        if !raw[i].trailingMarks.isEmpty { return true }
        return raw[..<i].allSatisfy {
            $0.normalized == "no" || fillerLexicon.contains($0.normalized)
                || EvalThresholds.discourseOpeners.contains($0.normalized)
        }
    }

    /// A negation the speaker never said: an out negation `.ins`-ed between
    /// two aligned out neighbours (a negation heading a wholly inserted
    /// clause is the answer gate's business), or — the mirror of the drop
    /// rule's sub-to-non-negation — a `.sub` FROM a non-negation raw token
    /// ("I do want it" → "I don't want it").
    ///
    /// An apostrophe RESTORED onto the raw word itself ("mustnt" →
    /// "mustn't") is never that flip, whether or not the unapostrophized
    /// form is in `Align.unapostrophizedNegations`: the test is structural
    /// (`Align.isApostropheRestored`), so the class closes for every
    /// contraction instead of for the ones a hand list names.
    ///
    /// BENCH ONLY, and the only place an inserted negation is charged now:
    /// a leaderboard row, never a refusal.
    private static func negationInserted(_ raw: [EvalToken], _ out: [EvalToken],
                                         _ alignment: Alignment) -> Bool {
        let opsB = alignment.opsB
        for j in out.indices where Align.isNegation(out[j].normalized) {
            switch opsB[j] {
            case .ins:
                if j > 0, j + 1 < out.count, opsB[j - 1].isAligned, opsB[j + 1].isAligned { return true }
            case .sub(let i, _):
                if !Align.isNegation(raw[i].normalized),
                   !Align.isApostropheRestored(raw[i].normalized, as: out[j].normalized) { return true }
            case .hit, .del:
                continue
            }
        }
        return false
    }

    private static func isContent(_ token: EvalToken, _ fillerLexicon: Set<String>) -> Bool {
        !Align.stopWords.contains(token.normalized) && !fillerLexicon.contains(token.normalized)
    }

    // MARK: - Disfluencies

    /// Raw indices `droppedContent` ignores, and how many raw atoms a
    /// formatter is expected to remove (`expectedWords`' subtrahend).
    /// Derived (nil): every core filler, and every token of an identical
    /// adjacent run of `stutterCollapsible` words unbroken by a mark —
    /// `EvalCase`'s own derivation for a gold-free row. Explicit lists are
    /// located by span and occurrence, exactly as `Align.locate` finds them
    /// for Fi. Removals: every filler and reparandum atom once (a filler
    /// inside a reparandum is one atom, not two), plus a stutter run's
    /// length minus its `keep`.
    private static func disfluencies(_ raw: [EvalToken], fillerLexicon: Set<String>,
                                     fillers: [EvalCase.Filler]?,
                                     stutters: [EvalCase.Stutter]?,
                                     reparanda: [String]) -> (ignored: Set<Int>, removals: Int) {
        var gone: Set<Int> = []
        if let fillers {
            for f in fillers {
                if let r = Align.locate(f.span, in: raw, occurrence: f.occurrence) { gone.formUnion(r) }
            }
        } else {
            for i in raw.indices where fillerLexicon.contains(raw[i].normalized) { gone.insert(i) }
        }
        for span in reparanda {
            if let r = Align.locate(span, in: raw) { gone.formUnion(r) }
        }
        var ignored = gone
        var stutterExtras = 0
        if let stutters {
            for s in stutters {
                guard let r = Align.locate(s.span, in: raw, occurrence: s.occurrence) else { continue }
                ignored.formUnion(r)
                stutterExtras += max(r.count - Align.canonicalTokens(s.keep).count, 0)
            }
        } else {
            var i = 0
            while i < raw.count {
                let word = raw[i].normalized
                var j = i
                while FillerStripper.stutterCollapsible.contains(word),
                      j + 1 < raw.count, raw[j + 1].normalized == word,
                      raw[j].trailingMarks.isEmpty, raw[j + 1].leadingMarks.isEmpty {
                    j += 1
                }
                if j > i {
                    ignored.formUnion(i...j)
                    stutterExtras += j - i
                }
                i = j + 1
            }
        }
        return (ignored, gone.count + stutterExtras)
    }

    // MARK: - ANSWERED helpers

    /// The key the opener echo compares on: the word without its contraction
    /// tail, so "here's" and the "here is" a dictation actually produces are
    /// one opener and the restoration a formatter performs is not evidence
    /// of an assistant.
    private static func openerKey(_ normalized: String) -> String {
        String(normalized.prefix(while: { $0 != "'" }))
    }

    /// The wh-word or auxiliary the raw OPENS with (fillers skipped) — the
    /// token that makes an utterance a question to an agent — or nil when it
    /// opens with anything else. Read at the front only: an "is" in the
    /// middle of a statement asks nothing, and an imperative that happens to
    /// start with an auxiliary ("have a look at the retry path") keeps its
    /// opener in the output, which is what clears it.
    ///
    /// An opener followed by a NEGATION is the one imperative the shape
    /// cannot tell apart on its own: "do not push to main" is an order, and
    /// English has no question that inverts into "do not …". Without this
    /// exclusion a polarity flip ("do not push to main" → "Push to main.")
    /// reported as ANSWERED — the wrong rung of the ladder for the right
    /// refusal.
    private static func interrogativeOpener(_ raw: [EvalToken], fillerLexicon: Set<String>) -> String? {
        guard let index = raw.firstIndex(where: { !fillerLexicon.contains($0.normalized) }),
              EvalThresholds.interrogativeOpeners.contains(raw[index].normalized) else { return nil }
        if index + 1 < raw.count, Align.isNegation(raw[index + 1].normalized) { return nil }
        return raw[index].normalized
    }

    /// Is `out` a near neighbour of the raw word it replaced — the shape a
    /// speech-to-text slip fix has ("there" → "they're", "to" → "too",
    /// "befour" → "before", "double check" → "double-check")? Levenshtein on
    /// the unapostrophized forms, capped at `inventedSlipDistance` AND at
    /// half the longer word, so a two-edit licence never covers a short word
    /// outright ("of" → "have" is 4 and is not a slip; "fix" → "fox" is one
    /// edit of three letters and is, which is the accepted cost of reading
    /// evidence instead of a homophone list — it still counts toward the
    /// three novel tokens that gate at any length).
    private static func isNearNeighbour(_ raw: String, _ out: String) -> Bool {
        let a = Align.unapostrophized(raw), b = Align.unapostrophized(out)
        guard a != b else { return false }
        let distance = editDistance(Array(a), Array(b))
        return distance <= EvalThresholds.inventedSlipDistance && 2 * distance <= max(a.count, b.count)
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                (previous, row[j]) = (row[j], min(row[j] + 1, row[j - 1] + 1, previous + cost))
            }
        }
        return row[b.count]
    }

    private static func nonBlankLines(_ text: String) -> Int {
        text.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.count
    }

    /// The markdown a reply carries and a dictation never does: bold, and
    /// line-initial bullets / numbered items. Returned as a set so out is
    /// only charged for markers raw lacks.
    private static func markdownMarkers(_ text: String) -> Set<String> {
        var markers: Set<String> = []
        if text.contains("**") { markers.insert("**") }
        for line in text.split(separator: "\n") {
            let body = line.drop(while: \.isWhitespace)
            if body.hasPrefix("- ") { markers.insert("- ") }
            else if body.hasPrefix("* ") { markers.insert("* ") }
            else {
                let digits = body.prefix(while: \.isNumber)
                if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") { markers.insert("1. ") }
            }
        }
        return markers
    }
}
