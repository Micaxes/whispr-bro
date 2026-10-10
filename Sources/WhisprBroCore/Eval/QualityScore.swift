import Foundation

/// Per-fixture verdict (plan §4.6), declared worst-first so "worst of" is
/// the lowest position. The gated head (ANSWERED … OVER_EDIT_FACT) zeroes
/// the composite; the tail names the failure class the R3 history taxonomy
/// used, so the verdict histogram reproduces that table from the bench.
/// `UNRATED` is the gold-free "nothing fired" — off the ladder, last.
public enum EvalVerdict: String, Codable, Sendable, CaseIterable {
    case answered = "ANSWERED"
    case invented = "INVENTED"
    case negated = "NEGATED"
    case overEditFact = "OVER_EDIT_FACT"
    case overEditHedge = "OVER_EDIT_HEDGE"
    case reworded = "REWORDED"
    case missed = "MISSED"
    case punct = "PUNCT"
    case pass = "PASS"
    case unrated = "UNRATED"

    public init(gate: ContentGuard.Gate) {
        switch gate {
        case .answered: self = .answered
        case .invented: self = .invented
        case .negated: self = .negated
        case .overEditFact: self = .overEditFact
        }
    }

    /// The gate this verdict is, when it is one.
    public var gate: ContentGuard.Gate? {
        switch self {
        case .answered: return .answered
        case .invented: return .invented
        case .negated: return .negated
        case .overEditFact: return .overEditFact
        case .overEditHedge, .reworded, .missed, .punct, .pass, .unrated: return nil
        }
    }

    /// Gated verdicts force C_i = 0 and M = 0.
    public var isGated: Bool { gate != nil }

    /// Position on the ladder, 0 = ANSWERED. Lower is worse.
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }

    public func isWorse(than other: EvalVerdict) -> Bool { rank < other.rank }
}

/// The three quality axes of ONE formatter output against ONE fixture
/// (plan §4.2–§4.6, §5): **F** auto-formatting on the gold↔out alignment,
/// **Fi** filler removal on the raw↔out alignment, **M** meaning on
/// gold↔out plus the fixture's annotations, the verdict ladder over all of
/// them, and the composite C_i. Like `TranscriptScore` and `ContentGuard`,
/// the struct IS the result; every count that fed a number is kept so a
/// report can show WHY a row scored what it did. Pure string math,
/// deterministic, zero dependencies — the same output scores the same
/// bytes on every machine, which is what lets `EvalRun.scoringVersion`
/// re-grade stored runs.
///
/// Gold-free fixtures (`gold: ""` under `gold_source: "history-unrated"`)
/// get only the raw↔out gates and Fi: no F, no M, no composite, verdict =
/// the worst gate or `UNRATED`. A rated empty gold is scored like any
/// other (an empty output is its PASS). Fixtures with `golds[]` are scored
/// against every acceptable gold and the best C_i wins (`goldIndex` says
/// which).
public struct QualityScore: Sendable {
    // MARK: - Axes

    /// F (§4.2): punctuation per class, non-initial casing, terminal mark.
    public struct Formatting: Sendable, Equatable {
        /// Macro-F1 over the mark classes present in gold ∪ out; nil when
        /// neither side carries a scored mark (component absent).
        public let punctuation: Double?
        /// Per-class F1 (`comma` / `stop` / `question`), present classes only.
        public let perClass: [String: Double]
        /// Casing accuracy over hit pairs at NON-sentence-initial gold
        /// positions; nil when there is none (component absent).
        public let casing: Double?
        /// Casing accuracy at sentence-initial gold positions — reported,
        /// never scored (a register may legitimately not capitalize).
        public let cInitial: Double?
        /// 1 when the last scored mark of out equals gold's (`none` ==
        /// `none` for a fragment), else 0.
        public let terminal: Double
        /// 0–100, weights 0.5 / 0.3 / 0.2 renormalized over present components.
        public let score: Double
    }

    /// Fi (§4.3): expected removals credited on the raw↔out alignment.
    public struct FillerRemoval: Sendable, Equatable {
        /// |E| = derived/annotated fillers + stutter runs.
        public let expected: Int
        public let credited: Int
        /// The spans that were not removed cleanly, for the report.
        public let missed: [String]
        /// 0–100.
        public var score: Double { 100 * Double(credited) / Double(expected) }
    }

    /// M (§4.4): what the output lost, invented, or failed to resolve.
    public struct Meaning: Sendable, Equatable {
        public let goldWords: Int
        /// D: gold atoms M charges as deleted — `.del`, plus a `.sub` whose
        /// gold word is gone from the output and whose replacement is not
        /// novel (the model kept the wrong raw word: "Meet on Tuesday." for a
        /// gold "Meet on Wednesday." has the shape of the plan's own D = 1
        /// row). A novel replacement is charged as novelty instead, never
        /// twice; a moved gold word (reorder) is not lost.
        public let lost: Int
        /// The lost gold atoms, cased, in gold order.
        public let lostTokens: [String]
        /// The lost atoms the deleted-share gate counts: neither STOP (a
        /// dropped article is a grammar nit, as §4.6's hedge rung and the
        /// guard's `droppedContent` already agree) nor inside a `must_keep`
        /// span of hedge weight — the annotation SAYS that span is stance,
        /// so its loss is OVER_EDIT_HEDGE at any share, charged through D
        /// and the flat penalty, never gated (the id-58 shape §9 pins).
        /// Unannotated drops of the same size still gate.
        public let factLoss: Int
        /// Out atoms ∉ raw ∪ gold ∪ alternates ∪ STOP (the guard's count).
        public let novel: Int
        public let novelNumerals: Int
        /// `must_keep` spans absent from the output.
        public let missedMustKeep: [EvalCase.MustKeep]
        /// Repairs whose `resolve_at` equals the run level (the ones scored).
        public let scoredRepairs: Int
        public let resolvedRepairs: Int
        /// Reparanda of the scored repairs that were not resolved.
        public let unresolvedRepairs: [String]
        /// M_text before the repair blend and the gate.
        public let text: Double
        /// 0–100; 0 when gated.
        public let score: Double
    }

    /// The §4.5 OVER_EDIT_FACT triggers that need a gold (the guard owns
    /// the gold-free length collapse).
    public enum GoldTrigger: String, Codable, Sendable, CaseIterable {
        /// A `must_keep` span of weight ≥ `factWeight` is missing.
        case mustKeepFact = "must-keep-fact"
        /// Lost gold words that carry a fact — not STOP, not inside an
        /// annotated hedge span — at ≥ `overEditDeletedShare` of a
        /// ≥ `minWordsForRatio` gold (`Meaning.factLoss`).
        case deletedShare = "deleted-share"
    }

    // MARK: - Result

    public let verdict: EvalVerdict
    /// Fired gates, worst first (the guard's plus the gold-scored ones).
    public let gates: [ContentGuard.Gate]
    public let goldTriggers: [GoldTrigger]
    /// The raw↔out gates and diagnostics (`ratio`, `droppedContent`, …).
    public let contentGuard: ContentGuard
    /// nil for a gold-free fixture.
    public let formatting: Formatting?
    /// nil when |E| = 0 (undefined — excluded from the Fi mean) or when the
    /// register is verbatim (`fillersSkipped`).
    public let fillers: FillerRemoval?
    /// The fixture's register is in `verbatimCategories`: no strip and no
    /// correction clause run, so neither filler credit nor repairs are
    /// measured.
    public let fillersSkipped: Bool
    /// nil for a gold-free fixture.
    public let meaning: Meaning?
    /// C_i (§5), nil for a gold-free fixture; 0 when gated.
    public let composite: Double?
    /// Index into `EvalCase.acceptableGolds` of the gold that scored best
    /// (0 = `gold` itself); 0 for a gold-free fixture.
    public let goldIndex: Int
    /// gold↔out alignment counts (H / S / D / I of the run row); zeros for
    /// a gold-free fixture.
    public let hits: Int
    public let subs: Int
    public let dels: Int
    public let ins: Int
    /// `.sub` pairs whose out token is a raw word — a reorder or a synonym
    /// taken from the dictation (the REWORDED rule's second clause).
    public let subsFromRaw: Int
    /// The continuity line (micro WER / punct F1 / case) against the best
    /// gold; nil for a gold-free fixture.
    public let continuity: TranscriptScore?

    public var isGoldFree: Bool { formatting == nil }
    public var isGated: Bool { !gates.isEmpty }
    /// Every fired trigger by name, the guard's first — what a report
    /// prints after a gated verdict ("ANSWERED (multi-line, markdown)").
    public var triggerNames: [String] {
        contentGuard.triggers.map(\.rawValue) + goldTriggers.map(\.rawValue)
    }
    /// Word-level edits vs gold (S + D + I on the canonical alignment); a
    /// control fixture is "unchanged" when this is 0.
    public var wordEdits: Int { subs + dels + ins }

    // MARK: - Scoring

    /// Scores `out` for `fixture`.
    /// - `level`: the run level; nil = the fixture's own. Repairs are scored
    ///   only when it equals their `resolve_at`.
    /// - `verbatimCategories`: registers where the pipeline skips the strip
    ///   and the correction clause (`AppConfig.Cleanup.verbatimCategories`);
    ///   Fi is skipped there and no repair is scored. The level is
    ///   `EvalPlan.level(for:)` — the ONE predicate the run plan and the
    ///   scorer share, so they can never disagree about which fixtures are
    ///   verbatim.
    public static func score(_ fixture: EvalCase, out: String,
                             level: AppConfig.Cleanup.Level? = nil,
                             verbatimCategories: [String] = AppConfig.Cleanup().verbatimCategories) -> QualityScore {
        let runLevel = EvalPlan.level(for: fixture, override: level, verbatimCategories: verbatimCategories)
        let verbatim = runLevel == .verbatim
        let scoredRepairs = fixture.repairs.filter { $0.resolveAt == runLevel }
        guard !fixture.isGoldFree else {
            let guardResult = ContentGuard.check(raw: fixture.raw, out: out, gold: nil,
                                                 alternates: fixture.alternates, language: fixture.language,
                                                 fillers: fixture.expectedFillers, stutters: fixture.expectedStutters,
                                                 reparanda: scoredRepairs.map(\.reparandum))
            let fi = verbatim ? nil : fillerRemoval(fixture, guard: guardResult, gold: nil)
            return QualityScore(verdict: guardResult.worst.map(EvalVerdict.init(gate:)) ?? .unrated,
                                gates: guardResult.gates, goldTriggers: [], contentGuard: guardResult,
                                formatting: nil, fillers: fi, fillersSkipped: verbatim, meaning: nil,
                                composite: nil, goldIndex: 0, hits: 0, subs: 0, dels: 0, ins: 0,
                                subsFromRaw: 0, continuity: nil)
        }
        // Best-of over the acceptable golds: ties keep the earlier one, so
        // `gold` itself wins whenever an alternate does no better. `gold`
        // is always scored — empty included: a rated empty gold (the
        // all-filler fragment seed) means "paste nothing" and an empty
        // output is its PASS — while an empty ALTERNATE is skipped.
        var best: QualityScore?
        for (index, gold) in fixture.acceptableGolds.enumerated() where index == 0 || !gold.isEmpty {
            let candidate = scoreAgainst(fixture, gold: gold, goldIndex: index, out: out,
                                         repairs: scoredRepairs, verbatim: verbatim)
            if let current = best, (current.composite ?? 0) >= (candidate.composite ?? 0) { continue }
            best = candidate
        }
        // `gold` (index 0) is always scored, so `best` is always set.
        return best!
    }

    private static func scoreAgainst(_ fixture: EvalCase, gold: String, goldIndex: Int, out: String,
                                     repairs scoredRepairs: [EvalCase.Repair], verbatim: Bool) -> QualityScore {
        let guardResult = ContentGuard.check(raw: fixture.raw, out: out, gold: gold,
                                             alternates: fixture.alternates, language: fixture.language,
                                             fillers: fixture.expectedFillers, stutters: fixture.expectedStutters,
                                             reparanda: scoredRepairs.map(\.reparandum))
        let (goldRaw, goldOrphans) = Align.tokenize(gold)
        let goldTokens = Align.canonicalize(goldRaw)
        let outTokens = guardResult.outTokens
        let outOrphans = Align.tokenize(out).orphanMarks
        let goldOut = Align.align(goldTokens, outTokens)

        // Fi reads the gold's own alignment of raw: what it drops must not
        // be charged as a missing neighbour (a filler inside a reparandum:
        // "at 2, uh, actually 3" → "at 3"), and what it keeps of a span is
        // the count the out window is held to.
        let rawGold = Align.align(guardResult.rawTokens, goldTokens)
        let fi = verbatim ? nil : fillerRemoval(fixture, guard: guardResult, gold: rawGold)

        let f = formatting(gold: goldTokens, goldOrphans: goldOrphans, out: outTokens,
                           outOrphans: outOrphans, alignment: goldOut)

        // M's inputs, then the gold-scored gates, then M itself (gated → 0).
        let rawVocabulary = Set(guardResult.rawTokens.map(\.canonical))
        let outVocabulary = Set(outTokens.map(\.canonical))
        let novelForms = Set(guardResult.novel)
        var lostIndices: [Int] = []
        var subsFromRaw = 0
        for op in goldOut.ops {
            switch op {
            case .del(let i):
                lostIndices.append(i)
            case .sub(let i, let j):
                if rawVocabulary.contains(outTokens[j].canonical) { subsFromRaw += 1 }
                if !outVocabulary.contains(goldTokens[i].canonical), !novelForms.contains(outTokens[j].canonical) {
                    lostIndices.append(i)
                }
            case .hit, .ins:
                continue
            }
        }
        let lostTokens = lostIndices.map { goldTokens[$0].cased }
        let missedMustKeep = fixture.mustKeep.filter { Align.locate($0.span, in: outTokens) == nil }
        let unresolved = scoredRepairs.filter {
            Align.locate($0.reparandum, in: outTokens) != nil || Align.locate($0.repair, in: outTokens) == nil
        }.map(\.reparandum)

        // Gold positions inside an annotated hedge (weight < fact): their
        // loss is the hedge rung's, whatever share of the gold they are.
        var hedged: Set<Int> = []
        for span in fixture.mustKeep where span.weight < EvalCase.MustKeep.factWeight {
            if let range = Align.locate(span.span, in: goldTokens) { hedged.formUnion(range) }
        }
        let factLoss = lostIndices.filter {
            !Align.stopWords.contains(goldTokens[$0].normalized) && !hedged.contains($0)
        }.count

        var goldTriggers: [GoldTrigger] = []
        if missedMustKeep.contains(where: { $0.weight >= EvalCase.MustKeep.factWeight }) {
            goldTriggers.append(.mustKeepFact)
        }
        let goldWords = goldTokens.count
        if goldWords >= EvalThresholds.minWordsForRatio,
           Double(factLoss) / Double(goldWords) >= EvalThresholds.overEditDeletedShare {
            goldTriggers.append(.deletedShare)
        }
        var fired = Set(guardResult.gates)
        if !goldTriggers.isEmpty { fired.insert(.overEditFact) }
        let gates = ContentGuard.Gate.allCases.filter { fired.contains($0) }

        let n = Double(max(goldWords, 1))
        var text = 100 * max(0, 1 - EvalThresholds.meaningDeletionCost * Double(lostTokens.count) / n
                                   - EvalThresholds.meaningNoveltyCost * Double(guardResult.novel.count) / n)
        for span in missedMustKeep { text -= EvalThresholds.meaningMustKeepPenalty * Double(span.weight) }
        text = max(0, text)
        var m = text
        if !scoredRepairs.isEmpty {
            let resolved = scoredRepairs.count - unresolved.count
            m = EvalThresholds.meaningTextShare * text
                + EvalThresholds.meaningRepairPoints * Double(resolved) / Double(scoredRepairs.count)
        }
        if !gates.isEmpty { m = 0 }
        let meaning = Meaning(goldWords: goldWords, lost: lostTokens.count, lostTokens: lostTokens,
                              factLoss: factLoss,
                              novel: guardResult.novel.count, novelNumerals: guardResult.novelNumerals,
                              missedMustKeep: missedMustKeep, scoredRepairs: scoredRepairs.count,
                              resolvedRepairs: scoredRepairs.count - unresolved.count,
                              unresolvedRepairs: unresolved, text: text, score: m)

        // Verdict ladder (§4.6), worst wins.
        let verdict: EvalVerdict
        if let worst = gates.first {
            verdict = EvalVerdict(gate: worst)
        } else if missedMustKeep.contains(where: { $0.weight < EvalCase.MustKeep.factWeight })
                    || (!lostIndices.isEmpty && !lostIndices.allSatisfy { Align.stopWords.contains(goldTokens[$0].normalized) }) {
            verdict = .overEditHedge
        } else if !guardResult.novel.isEmpty || subsFromRaw > 0 {
            verdict = .reworded
        } else if (fi.map { $0.credited < $0.expected } ?? false) || !unresolved.isEmpty {
            verdict = .missed
        } else if f.score < 100 {
            verdict = .punct
        } else {
            verdict = .pass
        }

        // Composite (§5): weights renormalize when Fi is undefined.
        let composite: Double
        if !gates.isEmpty {
            composite = 0
        } else if let fi {
            composite = EvalThresholds.compositeFormatWeight * f.score
                + EvalThresholds.compositeFillerWeight * fi.score
                + EvalThresholds.compositeMeaningWeight * m
        } else {
            let wF = EvalThresholds.compositeFormatWeight, wM = EvalThresholds.compositeMeaningWeight
            composite = (wF * f.score + wM * m) / (wF + wM)
        }

        return QualityScore(verdict: verdict, gates: gates, goldTriggers: goldTriggers, contentGuard: guardResult,
                            formatting: f, fillers: fi, fillersSkipped: verbatim, meaning: meaning,
                            composite: composite, goldIndex: goldIndex,
                            hits: goldOut.hits, subs: goldOut.subs, dels: goldOut.dels, ins: goldOut.ins,
                            subsFromRaw: subsFromRaw,
                            continuity: TranscriptScore.score(hypothesis: out, gold: gold))
    }

    // MARK: - F

    /// The three scored mark classes (§4.2). Everything `Align.scoredMarks`
    /// holds is in exactly one class.
    enum MarkClass: String, CaseIterable {
        case comma, stop, question

        init?(_ mark: Character) {
            switch mark {
            case ",": self = .comma
            case ".", "!", ";", ":", "¡": self = .stop
            case "?", "¿": self = .question
            default: return nil
            }
        }

        /// A mark that starts a new sentence after (or, leading, before) its word.
        var endsSentence: Bool { self != .comma }
    }

    /// `token` ends a sentence: it carries a trailing stop or question mark
    /// — except a period on a dotted abbreviation ("e.g.", "U.S.", "p.m."),
    /// which is part of the word, so the word after it is scored casing
    /// (the seed `abbrev-eg` exists to pin "npm must stay lowercase"). `?`
    /// and `!` always end a sentence, as in `TextFormatter`.
    static func endsSentence(_ token: EvalToken) -> Bool {
        token.trailingMarks.contains { mark in
            guard let cls = MarkClass(mark), cls.endsSentence else { return false }
            return mark != "." || !token.isAbbreviation
        }
    }

    static func formatting(gold: [EvalToken], goldOrphans: [Character], out: [EvalToken],
                           outOrphans: [Character], alignment: Alignment) -> Formatting {
        // P: per-class TP over hit pairs (multiset min); FN = gold marks of
        // the class not matched, FP = out marks not matched — which makes
        // marks on deleted gold words FN and on inserted out words FP, and
        // a mark on a substituted word both.
        var goldCount: [MarkClass: Int] = [:], outCount: [MarkClass: Int] = [:], matched: [MarkClass: Int] = [:]
        func tally(_ marks: [Character], into counts: inout [MarkClass: Int]) {
            for mark in marks { if let cls = MarkClass(mark) { counts[cls, default: 0] += 1 } }
        }
        for token in gold { tally(token.marks, into: &goldCount) }
        tally(goldOrphans, into: &goldCount)
        for token in out { tally(token.marks, into: &outCount) }
        tally(outOrphans, into: &outCount)
        for case .hit(let i, let j) in alignment.ops {
            var g: [MarkClass: Int] = [:], o: [MarkClass: Int] = [:]
            tally(gold[i].marks, into: &g)
            tally(out[j].marks, into: &o)
            for cls in MarkClass.allCases { matched[cls, default: 0] += min(g[cls] ?? 0, o[cls] ?? 0) }
        }
        var perClass: [String: Double] = [:]
        for cls in MarkClass.allCases {
            let total = (goldCount[cls] ?? 0) + (outCount[cls] ?? 0)
            guard total > 0 else { continue }   // absent from both sides: skipped
            perClass[cls.rawValue] = 2 * Double(matched[cls] ?? 0) / Double(total)
        }
        let punctuation = perClass.isEmpty ? nil : perClass.values.reduce(0, +) / Double(perClass.count)

        // C: exact-case accuracy over hit pairs whose WORDS are equal (an
        // ITN rewrite "fifty four" ↔ "54" is a hit with nothing to compare),
        // split by sentence-initial gold position.
        let initial = sentenceInitialPositions(gold)
        var comparable = 0, same = 0, initialComparable = 0, initialSame = 0
        for case .hit(let i, let j) in alignment.ops where gold[i].normalized == out[j].normalized {
            let equal = gold[i].cased == out[j].cased
            if initial.contains(i) {
                initialComparable += 1
                if equal { initialSame += 1 }
            } else {
                comparable += 1
                if equal { same += 1 }
            }
        }
        let casing = comparable == 0 ? nil : Double(same) / Double(comparable)
        let cInitial = initialComparable == 0 ? nil : Double(initialSame) / Double(initialComparable)

        let terminal: Double = lastMark(gold) == lastMark(out) ? 1 : 0

        var weighted = 0.0, weights = 0.0
        if let punctuation {
            weighted += EvalThresholds.formatPunctuationWeight * punctuation
            weights += EvalThresholds.formatPunctuationWeight
        }
        if let casing {
            weighted += EvalThresholds.formatCasingWeight * casing
            weights += EvalThresholds.formatCasingWeight
        }
        weighted += EvalThresholds.formatTerminalWeight * terminal
        weights += EvalThresholds.formatTerminalWeight
        return Formatting(punctuation: punctuation, perClass: perClass, casing: casing, cInitial: cInitial,
                          terminal: terminal, score: 100 * weighted / weights)
    }

    /// The first gold word and every word after a stop / question mark
    /// (trailing on the previous word — `endsSentence` — or leading on its
    /// own: "¿Cómo").
    static func sentenceInitialPositions(_ tokens: [EvalToken]) -> Set<Int> {
        var initial: Set<Int> = []
        for i in tokens.indices {
            if i == 0
                || endsSentence(tokens[i - 1])
                || tokens[i].leadingMarks.contains(where: { MarkClass($0)?.endsSentence == true }) {
                initial.insert(i)
            }
        }
        return initial
    }

    /// The text's last scored mark: the last mark on the LAST word (a
    /// fragment "Okay, and the" has none, whatever came earlier).
    static func lastMark(_ tokens: [EvalToken]) -> Character? {
        tokens.last?.marks.last
    }

    // MARK: - Fi

    /// Credit per expected removal on the raw↔out alignment. The ops alone
    /// cannot say where a removed word WENT: the backtrace prefers the
    /// diagonal on equal cost, so a filler in the second-to-last raw slot
    /// with a word appended to the output ("call me um tomorrow" → "Call
    /// me tomorrow, thanks.") comes back as sub(um→tomorrow),
    /// sub(tomorrow→thanks) — a clean removal that reads as two rewrites —
    /// and the mirror shape (a word prepended before a second-slot filler)
    /// shifts the other way. So survival is read off the OUT tokens, the
    /// way `ContentGuard.negationDropped` reads a governed word: the out
    /// window strictly between the neighbours' paired positions (to the
    /// text's edge where a neighbour is missing) is what the formatter
    /// left in the span's place, whatever the ops say.
    ///
    /// A span is credited iff its nearest neighbours that are neither
    /// expected removals nor gold-deleted are still aligned (`.hit` /
    /// `.sub`, the plan's rule: a formatter that deletes the clause around
    /// "um" earns nothing — M charges the deletion; a reworded neighbour is
    /// still there), and the window holds each of the span's forms exactly
    /// as often as the span is expected to leave them standing. What else
    /// the window holds is M's business (a novel word in the filler's place
    /// is charged as novelty, not as a missed strip). Order inside `keep`
    /// is not checked: a count is what a collapse leaves.
    ///
    /// Where that count comes from is the span's provenance. A DERIVED span
    /// is read off the gold (raw↔gold hits inside it: zero for a filler,
    /// once for the "the" of "the the") — the gold is the statement about
    /// the ideal output, and a derivation cannot contradict the gold it was
    /// derived from. An EXPLICIT span is read off its own `keep`: the
    /// annotation is a human statement about what `raw` contains, so a gold
    /// that retains another count is a malformed fixture — it scores under
    /// 100 against itself, which is exactly what `lint`'s invariant reports
    /// (§9) — never silently reinterpreted here.
    ///
    /// Spans that share a window AND a form set are read as one group — the
    /// window is what all of them left behind, so what it holds is charged
    /// per span, not per group: "um um call me" → "Um, call me" is one of
    /// two removed (Fi 50), not two missed (version 2 scored every span of
    /// the group against the whole window and read it as 0). A group with a
    /// gold to read is held to what the gold keeps across its spans, never
    /// to the members' `keep`s summed: two runs of one word around a filled
    /// pause ("I I um I I" → "I") annotate two keeps while the gold retains
    /// one, so the sum would read the gold copy as a deficit and a doubled
    /// "I I" as exact. Each surplus copy of a form is one span left in
    /// place; a deficit (a word the gold keeps cut) is not a collapse and
    /// credits none of the group.
    ///
    /// A GOLD-FREE fixture has no such statement — its derived spans carry
    /// `FillerStripper`'s own contract ("a run collapses to its first
    /// word"), which is all there is to hold an output to before the rating
    /// loop writes a gold. So each span expects its own `keep` and is
    /// credited independently: the window's copies are handed out one
    /// entitlement at a time, a surplus copy charges one span (a run left
    /// standing) and a shortfall charges the spans left short (a kept word
    /// cut) — never the whole group, which is what summing the keeps into
    /// one block did: the restart collapsed all the way to "I" read as a
    /// group-wide deficit (Fi 33.3) and the doubled "I I" the contract
    /// predicts as perfect. A single-span group is unaffected either way.
    ///
    /// An annotated span that cannot be located in raw counts as expected
    /// and missed, so a broken annotation shows up as Fi < 100 on the
    /// fixture's own gold instead of vanishing. nil when |E| = 0.
    static func fillerRemoval(_ fixture: EvalCase, guard guardResult: ContentGuard,
                              gold rawGold: Alignment?) -> FillerRemoval? {
        let raw = guardResult.rawTokens
        let out = guardResult.outTokens
        let opsA = guardResult.alignment.opsA
        let spans = fixture.expectedFillers.map {
            (span: $0.span, keep: "", explicit: fixture.fillersAreExplicit,
             range: Align.locate($0.span, in: raw, occurrence: $0.occurrence))
        } + fixture.expectedStutters.map {
            (span: $0.span, keep: $0.keep, explicit: fixture.stuttersAreExplicit,
             range: Align.locate($0.span, in: raw, occurrence: $0.occurrence))
        }
        guard !spans.isEmpty else { return nil }

        // The gold's reading of raw: what it drops is stepped over when a
        // neighbour is looked for, what it keeps is the count a window is
        // held to. Both empty for a gold-free fixture.
        var goldDeleted: Set<Int> = [], goldKept: Set<Int> = []
        for op in rawGold?.ops ?? [] {
            switch op {
            case .del(let i): goldDeleted.insert(i)
            case .hit(let i, _): goldKept.insert(i)
            case .sub, .ins: continue
            }
        }
        var skip = goldDeleted
        for span in spans { if let range = span.range { skip.formUnion(range) } }
        /// Nearest raw index on `step`'s side that is not skipped; nil at the edge.
        func neighbour(from i: Int, step: Int) -> Int? {
            var k = i + step
            while raw.indices.contains(k) {
                if !skip.contains(k) { return k }
                k += step
            }
            return nil
        }

        /// One window (out indices, inclusive) and the forms read off it.
        struct Window: Hashable {
            let lo: Int, hi: Int
            let forms: [String]
        }
        var groups: [Window: [(index: Int, span: String, keep: String, explicit: Bool, range: Range<Int>)]] = [:]
        var order: [Window] = []
        var credited = 0
        // (span index, span) so the report lists misses in annotation order
        // whatever group they were charged in.
        var missed: [(Int, String)] = []
        for (index, (span, keep, explicit, range)) in spans.enumerated() {
            guard let range else { missed.append((index, span)); continue }
            // A neighbour that exists must be aligned; its paired out index
            // bounds the window the span's tokens could have survived in.
            var lo = 0, hi = out.count - 1
            var survive = true
            if let previous = neighbour(from: range.lowerBound, step: -1) {
                if let j = opsA[previous].bIndex { lo = j + 1 } else { survive = false }
            }
            if let next = neighbour(from: range.upperBound - 1, step: 1) {
                if let j = opsA[next].bIndex { hi = j - 1 } else { survive = false }
            }
            guard survive else { missed.append((index, span)); continue }
            let window = Window(lo: lo, hi: hi, forms: Set(range.map { raw[$0].canonical }).sorted())
            if groups[window] == nil { order.append(window) }
            groups[window, default: []].append((index, span, keep, explicit, range))
        }
        for window in order {
            let members = groups[window]!
            var held: [String: Int] = [:]
            if window.lo <= window.hi {
                for j in window.lo...window.hi { held[out[j].canonical, default: 0] += 1 }
            }
            // Expected, per form: the copies the GOLD keeps inside a
            // derived span — not the members' `keep`s summed, which would
            // hold a restart around a filled pause ("I I um I I", two runs
            // keeping "I" each) to two where the gold retains one — and the
            // `keep` of an EXPLICIT span, which says what he annotated
            // whatever the gold does (a gold that disagrees fails `lint`'s
            // invariant on this very number). With no gold to read, every
            // span falls back to its own keep.
            var expected: [String: Int] = [:]
            var derived: Set<Int> = []
            for member in members {
                if rawGold == nil || member.explicit {
                    for form in Align.canonicalTokens(member.keep).map(\.canonical) { expected[form, default: 0] += 1 }
                } else {
                    derived.formUnion(member.range)
                }
            }
            for i in derived where goldKept.contains(i) { expected[raw[i].canonical, default: 0] += 1 }
            // Surplus: copies the window holds beyond that — each is one
            // span left in place, whichever it was (the first spans take
            // the credit; the report names the rest). Short of it: with a
            // gold, a word that was stated to survive was cut, which is no
            // collapse at all and credits none of the group (M charges the
            // cut on gold↔out); gold-free, the expectation is only the
            // stripper's contract span by span, so the shortfall charges
            // the spans it leaves short and stops there.
            var surplus = 0, shortfall = 0
            for form in window.forms {
                let extra = held[form, default: 0] - expected[form, default: 0]
                if extra < 0 { shortfall = max(shortfall, -extra) } else { surplus = max(surplus, extra) }
            }
            let hits = rawGold == nil
                ? max(0, members.count - surplus - shortfall)
                : (shortfall > 0 ? 0 : max(0, members.count - surplus))
            credited += hits
            for member in members.dropFirst(hits) { missed.append((member.index, member.span)) }
        }
        return FillerRemoval(expected: spans.count, credited: credited,
                             missed: missed.sorted { $0.0 < $1.0 }.map(\.1))
    }
}
