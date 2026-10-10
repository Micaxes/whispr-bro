import Foundation
import CryptoKit

/// One fixture for `whispr-bench eval`: a raw transcript plus its hand-
/// authored ideal output. `raw` is the dictionary-corrected VERBATIM text —
/// exactly what `HistoryRecord.rawText` stores, so a History row converts to
/// a personal fixture by copy-paste (see docs/llm-measurement-gate.md).
/// `gold` is the POLISHED target (what the LLM stage should produce), so the
/// rule-based path is EXPECTED to score below 1.0 on correction fixtures —
/// the harness is comparative, not pass/fail.
///
/// Schema v2 (dev/plans/whispr-bro-eval-benchmark.md §3.1): **gold is the
/// annotation** — aligning output against gold catches over-edits (deletions)
/// and invention (novel tokens) with no hand-authored spans, so every field
/// below the v1 five exists only for what gold cannot express (which spans
/// carry stance, which run is a stutter, which side of a repair is right).
/// Backward compatible: a v1 `{id, raw, gold}` file decodes unchanged,
/// unknown keys are ignored, and every v2 field has a derived default
/// (`isControl`, `expectedFillers`, `expectedStutters`, `latencyBudgetMs`).
/// JSON keys are snake_case (`must_keep`, `max_ms`, …) as in the plan.
public struct EvalCase: Codable, Sendable, Equatable {
    public let id: String
    /// Dictionary-corrected verbatim transcript (a History row's rawText).
    public let raw: String
    /// Hand-authored ideal polished text. Empty with `gold_source:
    /// "history-unrated"` is a GOLD-FREE fixture (history export): only
    /// the raw↔out gates and the filler axis score it — never F or M.
    /// Empty under any other provenance is a rated gold that says "paste
    /// nothing" (an all-filler utterance).
    public let gold: String
    /// Free-form tag ("correction — needs standard level", …).
    public let note: String?
    /// Audio fixture path for a future ASR→format eval; the text path
    /// (the only one wired today) ignores it.
    public let audio: String?

    // MARK: v2 — annotations gold cannot express

    /// Alternate acceptable golds ("fifty-four" vs "54"); the scorer keeps
    /// the best-matching one. `gold` itself is not repeated here.
    public let golds: [String]
    /// Free labels (the seed set uses the R3 failure classes); `by_tag`
    /// aggregation and `--tag` filtering key off them.
    public let tags: [String]
    /// The app register the bench runs the fixture under
    /// (`StyleRules().directive(for:)`; verbatim categories skip the strip
    /// and the correction clause, mirroring `PipelineController`). JSON
    /// carries the `AppCategory` raw value ("unknown").
    public let register: AppCategory
    /// `fillers` or `standard`: the correction clause and `resolveCorrections`
    /// are passed only at `standard`. `verbatim` is rejected at decode — it
    /// is a REGISTER property (`verbatimCategories`), never a fixture level.
    public let level: AppConfig.Cleanup.Level
    /// Selects `FillerStripper.coreFillers(for:)` for the derived filler
    /// list. JSON carries the ISO code ("en"); the enum's raw value
    /// ("english") is accepted too.
    public let language: DictationLanguage
    /// Explicit pass-through flag; nil → derived (`isControl`). An explicit
    /// value wins so `lint` can flag a `control: true` whose gold edits words.
    public let control: Bool?
    /// Explicit filled-pause annotations; nil → derived from the stripper's
    /// own lexicon (`expectedFillers`); `[]` disables derivation.
    public let fillers: [Filler]?
    /// Explicit stutter runs (content-word doubles, non-identical restarts);
    /// nil → derived from `FillerStripper.stutterCollapsible`
    /// (`expectedStutters`); `[]` disables derivation.
    public let stutters: [Stutter]?
    /// Cued self-corrections, scored only when the run level == `resolveAt`.
    public let repairs: [Repair]
    /// Spans that must survive in the output (hedges weight 2, facts 5).
    public let mustKeep: [MustKeep]
    /// Surface forms that are not novel content (hyphenation, ITN spellings).
    public let alternates: [Alternate]
    /// Per-fixture latency budget for the report; nil → by length
    /// (`latencyBudgetMs`). The run gate uses `--budget-ms`, not this.
    public let maxMs: Int?
    /// `"synthetic"` or `"history:<rowid>"` — `lint --repo-guard` refuses the
    /// latter under the repo tree.
    public let source: String
    /// Provenance of `gold`: `"seed"`, `"history-unrated"`,
    /// `"ship:<run_key>:<formatter>"`, `"edit"`, or `"draft:<author>"`.
    public let goldSource: String
    /// Drafts (from `whispr-bench gold` or an agent) are scored but never
    /// counted as rated; a confirm pass flips them.
    public let annotationsStatus: AnnotationsStatus
    /// What the shipped binary produced (`HistoryRecord.formattedText`);
    /// scored by `--formatter shipped`. Never used as gold.
    public let observed: String?
    /// `HistoryRecord.formatMs` for `observed`.
    public let observedMs: Int?

    public init(id: String, raw: String, gold: String, note: String? = nil, audio: String? = nil,
                golds: [String] = [], tags: [String] = [],
                register: AppCategory = .unknown, level: AppConfig.Cleanup.Level = .standard,
                language: DictationLanguage = .english, control: Bool? = nil,
                fillers: [Filler]? = nil, stutters: [Stutter]? = nil, repairs: [Repair] = [],
                mustKeep: [MustKeep] = [], alternates: [Alternate] = [], maxMs: Int? = nil,
                source: String = "synthetic", goldSource: String = "seed",
                annotationsStatus: AnnotationsStatus = .confirmed,
                observed: String? = nil, observedMs: Int? = nil) {
        self.id = id
        self.raw = raw
        self.gold = gold
        self.note = note
        self.audio = audio
        self.golds = golds
        self.tags = tags
        self.register = register
        self.level = level
        self.language = language
        self.control = control
        self.fillers = fillers
        self.stutters = stutters
        self.repairs = repairs
        self.mustKeep = mustKeep
        self.alternates = alternates
        self.maxMs = maxMs
        self.source = source
        self.goldSource = goldSource
        self.annotationsStatus = annotationsStatus
        self.observed = observed
        self.observedMs = observedMs
    }

    // MARK: - Nested annotation types

    /// One filled pause in `raw` (`occurrence` is 1-based, counted over
    /// canonical-form matches so `Align.locate` finds exactly this token).
    public struct Filler: Codable, Sendable, Equatable {
        public let span: String
        public let occurrence: Int

        public init(span: String, occurrence: Int = 1) {
            self.span = span
            self.occurrence = occurrence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            span = try c.decode(String.self, forKey: .span)
            occurrence = try c.decodeIfPresent(Int.self, forKey: .occurrence) ?? 1
        }
    }

    /// One stutter run in `raw` and the tokens that should survive it
    /// (`"and a and"` → `"and"`, `"my l phone"` → `"my phone"`). `keep`
    /// defaults to the run's first word — the identical-run contract.
    /// `occurrence` (not in the plan's field list; optional, default 1)
    /// disambiguates a run that repeats in the same fixture.
    public struct Stutter: Codable, Sendable, Equatable {
        public let span: String
        public let keep: String
        public let occurrence: Int

        public init(span: String, keep: String? = nil, occurrence: Int = 1) {
            self.span = span
            self.keep = keep ?? Self.firstWord(of: span)
            self.occurrence = occurrence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            span = try c.decode(String.self, forKey: .span)
            keep = try c.decodeIfPresent(String.self, forKey: .keep) ?? Self.firstWord(of: span)
            occurrence = try c.decodeIfPresent(Int.self, forKey: .occurrence) ?? 1
        }

        private static func firstWord(of span: String) -> String {
            span.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? span
        }
    }

    /// A cued self-correction: the abandoned words and their replacement.
    /// Scored in M only when the run level equals `resolveAt`.
    public struct Repair: Codable, Sendable, Equatable {
        public let reparandum: String
        public let repair: String
        public let resolveAt: AppConfig.Cleanup.Level

        enum CodingKeys: String, CodingKey {
            case reparandum, repair, resolveAt = "resolve_at"
        }

        public init(reparandum: String, repair: String, resolveAt: AppConfig.Cleanup.Level = .standard) {
            self.reparandum = reparandum
            self.repair = repair
            self.resolveAt = resolveAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reparandum = try c.decode(String.self, forKey: .reparandum)
            repair = try c.decode(String.self, forKey: .repair)
            resolveAt = try EvalCase.decodeLevel(from: c, key: .resolveAt) ?? .standard
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(reparandum, forKey: .reparandum)
            try c.encode(repair, forKey: .repair)
            try c.encode(resolveAt.rawValue, forKey: .resolveAt)
        }
    }

    /// A punct/case-blind contiguous span that must appear in the output.
    /// Decodes from a bare string (weight 2) or `{span, weight}`; always
    /// encodes as the object so the canonical form is one shape.
    public struct MustKeep: Codable, Sendable, Equatable {
        /// Hedge / stance: a missed span costs its deletion share plus a flat
        /// penalty and lands at OVER_EDIT_HEDGE.
        public static let hedgeWeight = 2
        /// Fact: a missed span is a gated OVER_EDIT_FACT.
        public static let factWeight = 5

        public let span: String
        public let weight: Int

        public init(span: String, weight: Int = MustKeep.hedgeWeight) {
            self.span = span
            self.weight = weight
        }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
                span = s
                weight = Self.hedgeWeight
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            span = try c.decode(String.self, forKey: .span)
            weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? Self.hedgeWeight
        }
    }

    /// Surface forms of a raw token that are not novel content.
    public struct Alternate: Codable, Sendable, Equatable {
        public let from: String
        public let to: [String]

        public init(from: String, to: [String]) {
            self.from = from
            self.to = to
        }
    }

    public enum AnnotationsStatus: String, Codable, Sendable {
        case confirmed, draft
    }

    // MARK: - Codable (snake_case keys, v1 compatibility, derived defaults)

    enum CodingKeys: String, CodingKey {
        case id, raw, gold, note, audio
        case golds, tags, register, level, language, control, fillers, stutters, repairs
        case mustKeep = "must_keep"
        case alternates
        case maxMs = "max_ms"
        case source
        case goldSource = "gold_source"
        case annotationsStatus = "annotations_status"
        case observed
        case observedMs = "observed_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        raw = try c.decode(String.self, forKey: .raw)
        gold = try c.decode(String.self, forKey: .gold)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        golds = try c.decodeIfPresent([String].self, forKey: .golds) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        register = try Self.decodeRawValue(from: c, key: .register, AppCategory.init(rawValue:),
                                           expected: AppCategory.allCases.map(\.rawValue)) ?? .unknown
        level = try Self.decodeLevel(from: c, key: .level) ?? .standard
        language = try Self.decodeRawValue(from: c, key: .language, Self.language(forCode:),
                                           expected: DictationLanguage.allCases.map(\.code)) ?? .english
        // `decodeIfPresent` reads an explicit JSON `null` as absent, so
        // `"fillers": null` (the plan's spelling for "derive") lands here.
        control = try c.decodeIfPresent(Bool.self, forKey: .control)
        fillers = try c.decodeIfPresent([Filler].self, forKey: .fillers)
        stutters = try c.decodeIfPresent([Stutter].self, forKey: .stutters)
        repairs = try c.decodeIfPresent([Repair].self, forKey: .repairs) ?? []
        mustKeep = try c.decodeIfPresent([MustKeep].self, forKey: .mustKeep) ?? []
        alternates = try c.decodeIfPresent([Alternate].self, forKey: .alternates) ?? []
        maxMs = try c.decodeIfPresent(Int.self, forKey: .maxMs)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "synthetic"
        goldSource = try c.decodeIfPresent(String.self, forKey: .goldSource) ?? "seed"
        annotationsStatus = try c.decodeIfPresent(AnnotationsStatus.self, forKey: .annotationsStatus) ?? .confirmed
        observed = try c.decodeIfPresent(String.self, forKey: .observed)
        observedMs = try c.decodeIfPresent(Int.self, forKey: .observedMs)
    }

    /// Encodes every explicit field and spells out the defaults; the four
    /// derived-when-nil fields (`control`, `fillers`, `stutters`, `max_ms`)
    /// and the v1 optionals are omitted when nil. Derived VALUES are never
    /// written — so a change to the derivation never moves the hash of an
    /// unchanged file, and a v1 file hashes like its explicit v2 spelling.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(raw, forKey: .raw)
        try c.encode(gold, forKey: .gold)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(audio, forKey: .audio)
        try c.encode(golds, forKey: .golds)
        try c.encode(tags, forKey: .tags)
        try c.encode(register.rawValue, forKey: .register)
        try c.encode(level.rawValue, forKey: .level)
        try c.encode(language.code, forKey: .language)
        try c.encodeIfPresent(control, forKey: .control)
        try c.encodeIfPresent(fillers, forKey: .fillers)
        try c.encodeIfPresent(stutters, forKey: .stutters)
        try c.encode(repairs, forKey: .repairs)
        try c.encode(mustKeep, forKey: .mustKeep)
        try c.encode(alternates, forKey: .alternates)
        try c.encodeIfPresent(maxMs, forKey: .maxMs)
        try c.encode(source, forKey: .source)
        try c.encode(goldSource, forKey: .goldSource)
        try c.encode(annotationsStatus, forKey: .annotationsStatus)
        try c.encodeIfPresent(observed, forKey: .observed)
        try c.encodeIfPresent(observedMs, forKey: .observedMs)
    }

    /// A raw-value enum field with a LOUD error on an unknown value — a typo
    /// in `register` must not silently run the fixture under `.unknown`.
    private static func decodeRawValue<K: CodingKey, T>(
        from c: KeyedDecodingContainer<K>, key: K, _ parse: (String) -> T?, expected: [String]
    ) throws -> T? {
        guard let s = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let v = parse(s) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "'\(s)' is not one of \(expected.joined(separator: " | "))")
        }
        return v
    }

    /// `fillers | standard` only: `verbatim` is a register property (the
    /// bench derives it from `verbatimCategories`), so a fixture spelling it
    /// as a level would be a silent no-op — refused instead.
    fileprivate static func decodeLevel<K: CodingKey>(
        from c: KeyedDecodingContainer<K>, key: K
    ) throws -> AppConfig.Cleanup.Level? {
        try decodeRawValue(from: c, key: key, { s in
            let level = AppConfig.Cleanup.Level(rawValue: s)
            return level == .verbatim ? nil : level
        }, expected: ["fillers", "standard"])
    }

    /// ISO code first ("en"), the enum's own raw value ("english") second.
    private static func language(forCode s: String) -> DictationLanguage? {
        DictationLanguage.allCases.first { $0.code == s } ?? DictationLanguage(rawValue: s)
    }
}

// MARK: - Derived defaults (plan §3.1)

extension EvalCase {
    /// Spoken words in `raw`, pre-canonicalization ("fifty four" is the two
    /// words the model reads) — the length key for the latency ladder and
    /// the `by_length` buckets.
    public var wordCount: Int { Align.tokenize(raw).tokens.count }

    /// Pass-through fixture: gold equals raw modulo scored marks and case
    /// (NOT modulo number form — an ITN rewrite is a word edit here, as on
    /// the continuity WER axis). Any word-level S/D/I is then a failure and
    /// the run gate counts it. An explicit `control` wins.
    public var isControl: Bool { control ?? Self.deriveControl(raw: raw, gold: gold) }

    /// The filled pauses the output is expected to remove: explicit
    /// `fillers`, else every `coreFillers(for: language)` token in `raw`
    /// that the raw↔gold alignment deletes. With an empty gold every filler
    /// in raw is expected gone — the stripper's contract for a gold-free row.
    public var expectedFillers: [Filler] {
        fillers ?? Self.deriveFillers(raw: raw, gold: gold, language: language)
    }

    /// The stutter runs the output is expected to collapse: explicit
    /// `stutters`, else every maximal run of ≥ 2 identical adjacent
    /// `stutterCollapsible` words in `raw` that does not survive intact in
    /// gold. Content words never derive ("very, very flat" is emphasis).
    public var expectedStutters: [Stutter] {
        stutters ?? Self.deriveStutters(raw: raw, gold: gold)
    }

    /// The spans came from the fixture, not from the derivation. An
    /// explicit annotation is a human statement about what `raw` contains,
    /// so Fi holds the output to ITS `keep` even where the gold retains
    /// another count — a derived span is read off the gold, which by
    /// construction cannot contradict it. Where an explicit one does, the
    /// gold scores under 100 against itself and `lint`'s invariant (§9)
    /// says so with the scorer's own Fi.
    public var fillersAreExplicit: Bool { fillers != nil }
    public var stuttersAreExplicit: Bool { stutters != nil }

    /// `max_ms`, or the length ladder: ≤ 15 words 300, ≤ 60 words 700,
    /// else 1500 — a 150-word prompt at 1.4 s is not the failure a 12-word
    /// one at 900 ms is.
    public var latencyBudgetMs: Int { maxMs ?? Self.defaultBudgetMs(words: wordCount) }

    /// A history export row: empty `gold` AND `gold_source ==
    /// "history-unrated"` — only the raw↔out gates and the filler axis
    /// score it. Keyed off the provenance, not the empty string alone, so
    /// a seed whose ideal paste IS nothing (an all-filler "Uh" → "") is a
    /// real, rated gold: its gold copy scores PASS 100 and a "Uh." reads
    /// as the missed removal it is.
    public var isGoldFree: Bool { gold.isEmpty && goldSource == Self.historyUnratedGoldSource }

    /// The `gold_source` `history-export` writes; the one value that makes
    /// an empty gold mean "not rated yet" rather than "paste nothing".
    public static let historyUnratedGoldSource = "history-unrated"

    public var isDraft: Bool { annotationsStatus == .draft }

    /// `gold` plus every alternate; the scorer keeps the best-matching one.
    public var acceptableGolds: [String] { [gold] + golds }

    static func defaultBudgetMs(words: Int) -> Int {
        words <= 15 ? 300 : words <= 60 ? 700 : 1500
    }

    static func deriveControl(raw: String, gold: String) -> Bool {
        Align.tokenize(raw).tokens.map(\.normalized) == Align.tokenize(gold).tokens.map(\.normalized)
    }

    /// Canonical tokens so the indices match what `Align.locate` and the
    /// scorer's raw↔out alignment see; a filler word is never a number, so
    /// canonicalization cannot merge one away.
    static func deriveFillers(raw: String, gold: String, language: DictationLanguage) -> [Filler] {
        let lexicon = Set(FillerStripper.coreFillers(for: language))
        let rawTokens = Align.canonicalTokens(raw)
        let alignment = Align.align(rawTokens, Align.canonicalTokens(gold))
        var out: [Filler] = []
        for case .del(let i) in alignment.ops where lexicon.contains(rawTokens[i].normalized) {
            out.append(Filler(span: rawTokens[i].cased,
                              occurrence: occurrence(of: i..<(i + 1), in: rawTokens)))
        }
        return out
    }

    /// Mirrors `FillerStripper.collapseRuns`: the run is the same word
    /// repeated with only whitespace between — a scored mark breaks it
    /// ("I, I think" is not derived; annotate it explicitly). "Does not
    /// survive" = fewer than all of the run's tokens are `.hit` in raw↔gold.
    static func deriveStutters(raw: String, gold: String) -> [Stutter] {
        let rawTokens = Align.canonicalTokens(raw)
        let opsA = Align.align(rawTokens, Align.canonicalTokens(gold)).opsA
        var out: [Stutter] = []
        var i = 0
        while i < rawTokens.count {
            let word = rawTokens[i].normalized
            var j = i
            while FillerStripper.stutterCollapsible.contains(word),
                  j + 1 < rawTokens.count,
                  rawTokens[j + 1].normalized == word,
                  rawTokens[j].trailingMarks.isEmpty, rawTokens[j + 1].leadingMarks.isEmpty {
                j += 1
            }
            if j > i {
                let intact = (i...j).filter { if case .hit = opsA[$0] { return true } else { return false } }.count
                if intact < j - i + 1 {
                    out.append(Stutter(span: rawTokens[i...j].map(\.cased).joined(separator: " "),
                                       keep: rawTokens[i].cased,
                                       occurrence: occurrence(of: i...j, in: rawTokens)))
                }
            }
            i = j + 1
        }
        return out
    }

    /// 1-based rank of the canonical subsequence at `range` among its
    /// matches in `tokens` — the `occurrence` `Align.locate` needs to land
    /// on exactly this range (overlapping matches count separately).
    private static func occurrence<R: RangeExpression>(of range: R, in tokens: [EvalToken]) -> Int
    where R.Bound == Int {
        let r = range.relative(to: tokens)
        let needle = tokens[r].map(\.canonical)
        var rank = 0
        for start in 0...r.lowerBound
        where needle.indices.allSatisfy({ tokens[start + $0].canonical == needle[$0] }) {
            rank += 1
        }
        return rank
    }
}

// MARK: - Fixture-set identity

extension EvalCase {
    /// Canonical bytes of a fixture set: sorted keys, no whitespace, explicit
    /// fields only (see `encode(to:)`), fixtures sorted by `id`. Fixture
    /// ORDER is NOT part of the identity — the bench re-sorts every run by
    /// (register, level) to bound KV re-primes, and `history-export` merges
    /// by id, so two files holding the same fixtures in a different order
    /// must land on the same leaderboard key. Ids are compared as raw
    /// Unicode scalars (`<` on String), locale-free, so the order is the
    /// same on every machine.
    public static func canonicalJSON(_ cases: [EvalCase]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(cases.sorted { $0.id < $1.id })
    }

    /// SHA-256 hex of `canonicalJSON` — the leaderboard row's
    /// `fixtures.sha256` (CryptoKit, as `ModelManager.sha256(of:)`).
    public static func fixtureSetHash(_ cases: [EvalCase]) throws -> String {
        SHA256.hash(data: try canonicalJSON(cases)).map { String(format: "%02x", $0) }.joined()
    }
}

extension EvalCase {
    /// Built-in seed set: 81 synthetic fixtures (plan §3.2). The first 17
    /// are the repo-measured originals (the task-014 tables in
    /// docs/llm-measurement-gate.md, the whispr-bench LLM-gate transcripts,
    /// the deterministic-fix classes); the 64 that follow paraphrase the
    /// SHAPE of the real history rows the R3 taxonomy found — prompts to a
    /// coding agent, chat, notes, browser questions — with invented
    /// products, numbers and names, never a line he dictated. Every seed is
    /// tagged by class, so `by_tag` and `--tag` mean something on the seed
    /// set too. Lexical forms are kept as dictated ("twelve percent" stays
    /// words) so WER measures formatting, not normalization; golds are the
    /// speaker's own words — contractions kept, hedges kept, nothing
    /// formalized — because gold is the annotation (§3.1). Three seeds
    /// replicate the exact failure shapes of history rows 70 / 54 / 58
    /// (`replica` tag) and are pinned to ANSWERED / INVENTED /
    /// OVER_EDIT_HEDGE by `SeedFixtureTests`. Every seed's gold scores 100
    /// against itself, and the set clears the lint floors (controls ≥ 15%,
    /// ≥ 60-word ≥ 20%, ≥ 30-word ≥ 40%, `agent-prompt` ≥ 60%, one-word
    /// ≤ 10%) — both pinned by test, so a seed edit that breaks its own
    /// scorer or the set's balance fails CI.
    public static let seeds: [EvalCase] = [
        // docs/llm-measurement-gate.md task-014 table — self-corrections. The
        // last two were echoed unchanged by Qwen2.5; golds are the INTENDED
        // resolutions, so they chart future formatter progress. Annotated
        // with their reparandum → repair pair so M scores the resolution
        // (§4.4), not just the words.
        EvalCase(id: "correct-time",
                 raw: "let's meet at 2 actually 3",
                 gold: "Let's meet at 3.",
                 note: "correction — needs standard level",
                 tags: ["repair"],
                 repairs: [Repair(reparandum: "2 actually", repair: "3")]),
        EvalCase(id: "correct-day",
                 raw: "send it monday no wait tuesday",
                 gold: "Send it Tuesday.",
                 note: "correction — needs standard level",
                 tags: ["repair"],
                 repairs: [Repair(reparandum: "monday no wait", repair: "tuesday")]),
        EvalCase(id: "cue-is-content",
                 raw: "I actually enjoyed the movie",
                 gold: "I actually enjoyed the movie.",
                 note: "cue word is content — must be preserved",
                 tags: ["cue-control", "control"]),
        EvalCase(id: "correct-long-span",
                 raw: "so I was thinking we should meet at 2 actually 3 pm",
                 gold: "So I was thinking we should meet at 3 pm.",
                 note: "correction — needs standard level",
                 tags: ["repair"],
                 repairs: [Repair(reparandum: "2 actually", repair: "3")]),
        EvalCase(id: "correct-number",
                 raw: "the total is 50 no sorry 15 dollars",
                 gold: "The total is 15 dollars.",
                 note: "correction — needs standard level",
                 tags: ["repair"],
                 repairs: [Repair(reparandum: "50 no sorry", repair: "15")]),
        // The premise-check sentence — Parakeet's ACTUAL output for the
        // say-synthesized filler fixture (fillers survive ASR verbatim).
        EvalCase(id: "premise-fillers",
                 raw: "Um, so I was uh thinking that we should uh meet at 2, uh, actually 3 p.m. Um, yeah.",
                 gold: "So I was thinking that we should meet at 3 p.m. Yeah.",
                 note: "fillers + correction — needs standard level",
                 tags: ["fillers", "repair"],
                 // The reparandum is the abandoned word alone: the bench
                 // feeds the STRIPPED raw, so a span holding the "uh" could
                 // never be located in any real output and every output —
                 // the echo included — would read as resolved.
                 repairs: [Repair(reparandum: "2", repair: "3")]),
        // The four whispr-bench LLM-gate transcripts, with authored golds.
        EvalCase(id: "bench-standup",
                 raw: "hey can you um send me the the updated design doc before standup tomorrow morning thanks",
                 gold: "Hey, can you send me the updated design doc before standup tomorrow morning? Thanks.",
                 tags: ["bench", "fillers", "stutter"]),
        EvalCase(id: "bench-quarterly",
                 raw: "so the quarterly report shows revenue grew twelve percent but we need to double check the churn numbers before presenting them to the board on thursday",
                 gold: "So the quarterly report shows revenue grew twelve percent, but we need to double check the churn numbers before presenting them to the board on Thursday.",
                 tags: ["bench", "control"]),
        EvalCase(id: "bench-meeting",
                 raw: "let's move the meeting to three pm and uh remind me to book the flight to berlin i think it's cheaper if we fly out on a tuesday",
                 gold: "Let's move the meeting to three pm and remind me to book the flight to Berlin. I think it's cheaper if we fly out on a Tuesday.",
                 tags: ["bench", "fillers"]),
        EvalCase(id: "bench-code",
                 raw: "the function takes a user id and returns a promise that resolves to the user object or null if not found make sure to handle the error case",
                 gold: "The function takes a user id and returns a promise that resolves to the user object or null if not found. Make sure to handle the error case.",
                 tags: ["bench", "agent-prompt", "control"]),
        // Deterministic-fix classes (TextFormatter.repairPunctuation + the
        // mid-utterance capitalizer) — regression pins for the rule-based path.
        EvalCase(id: "cap-mid",
                 raw: "i sent the doc. please review it",
                 gold: "I sent the doc. Please review it.",
                 note: "mid-utterance capitalization",
                 tags: ["punct", "control"]),
        EvalCase(id: "abbrev-eg",
                 raw: "we use e.g. npm for packages",
                 gold: "We use e.g. npm for packages.",
                 note: "abbreviation guard — npm must stay lowercase",
                 tags: ["punct", "control"]),
        EvalCase(id: "abbrev-us",
                 raw: "the U.S. office is closed. bring your badge",
                 gold: "The U.S. office is closed. Bring your badge.",
                 note: "dotted initialism guard + a real boundary after it",
                 tags: ["punct", "control"]),
        EvalCase(id: "comma-leading",
                 raw: ", so anyway let's ship it",
                 gold: "So anyway, let's ship it.",
                 note: "leading comma residue",
                 tags: ["punct", "control"]),
        EvalCase(id: "comma-double",
                 raw: "eggs, , milk and bread",
                 gold: "Eggs, milk and bread.",
                 note: "double-comma residue",
                 tags: ["punct", "control"]),
        EvalCase(id: "comma-terminal",
                 raw: "that's the plan, .",
                 gold: "That's the plan.",
                 note: "comma before terminal",
                 tags: ["punct", "control"]),
        EvalCase(id: "punct-double",
                 raw: "is it done?. okay.. let's go",
                 gold: "Is it done? Okay. Let's go.",
                 note: "doubled / mixed terminal punctuation",
                 tags: ["punct", "control"]),

        // MARK: §3.2 class 1 — agent-prompt long controls (60–150 words).
        // Parakeet-punctuated raws with the marks it typically misses (a
        // clause comma, a product name's case, the terminal), so the rules
        // column has something to fix and the model columns something to
        // leave alone: gold == raw modulo marks and case → controls, and a
        // model that touches a word here moves the controls-unchanged gate.
        EvalCase(id: "long-01",
                 raw: "Okay so I think the next step is to look at the sync job in lumabase and figure out why the nightly run keeps stalling around 2 a.m. I don't know if it's the connection pool or the retry loop but either way, can you add some logging around both and then run it once locally so we can see the timings",
                 gold: "Okay, so I think the next step is to look at the sync job in Lumabase and figure out why the nightly run keeps stalling around 2 a.m. I don't know if it's the connection pool or the retry loop, but either way, can you add some logging around both and then run it once locally so we can see the timings.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-02",
                 raw: "So the fleetwing pipeline is green again but I want to double check the cache step before we merge. Yesterday it restored a stale bundle and the tests passed against the wrong build which is exactly the kind of thing that bites us a week later. Could you look at the cache key, make sure it includes the lockfile hash and post a short note in the PR about what changed and why.",
                 gold: "So the Fleetwing pipeline is green again, but I want to double check the cache step before we merge. Yesterday it restored a stale bundle and the tests passed against the wrong build, which is exactly the kind of thing that bites us a week later. Could you look at the cache key, make sure it includes the lockfile hash, and post a short note in the PR about what changed and why.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-03",
                 raw: "Okay I'm looking at the tidewatch export and honestly the pace chart looks off for last Sunday. The long run was 14 miles at roughly 9:40 per mile but the chart shows a spike to 6:10 around mile 8 which never happened. I think it's a GPS drop under the bridge. Can you write a small script that flags any split more than 90 seconds faster than the surrounding ones and prints them with the timestamps",
                 gold: "Okay, I'm looking at the Tidewatch export and honestly the pace chart looks off for last Sunday. The long run was 14 miles at roughly 9:40 per mile, but the chart shows a spike to 6:10 around mile 8, which never happened. I think it's a GPS drop under the bridge. Can you write a small script that flags any split more than 90 seconds faster than the surrounding ones and prints them with the timestamps.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-04",
                 raw: "So here's what I'm thinking for the brightloop playlist thing. Right now the sync between the phone and the watch only runs when the app is in the foreground which means half the time I start a run with last week's songs. I'd like a background refresh every morning at 6, a manual button in settings and a small badge that shows the last successful sync time. Don't touch the login flow yet, I want to keep that change separate and review it on its own",
                 gold: "So here's what I'm thinking for the Brightloop playlist thing. Right now the sync between the phone and the watch only runs when the app is in the foreground, which means half the time I start a run with last week's songs. I'd like a background refresh every morning at 6, a manual button in settings, and a small badge that shows the last successful sync time. Don't touch the login flow yet, I want to keep that change separate and review it on its own.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-05",
                 raw: "Okay let me describe the bug and then you can tell me where to look. When I open the pebblekit demo on the older tablet the first tap on the canvas does nothing, the second tap registers and after that it works fine for the rest of the session. It only happens after a cold launch, never after backgrounding and it doesn't happen on the newer devices at all. My guess is the gesture recognizer is attached before the view finishes its layout pass. Could you check the init order in the canvas controller and add a log line for each gesture event so we can confirm it before changing anything",
                 gold: "Okay, let me describe the bug and then you can tell me where to look. When I open the Pebblekit demo on the older tablet, the first tap on the canvas does nothing, the second tap registers, and after that it works fine for the rest of the session. It only happens after a cold launch, never after backgrounding, and it doesn't happen on the newer devices at all. My guess is the gesture recognizer is attached before the view finishes its layout pass. Could you check the init order in the canvas controller and add a log line for each gesture event so we can confirm it before changing anything.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-06",
                 raw: "So for the quillstack migration I want to go slowly. Step one is just reading from the new table in parallel and comparing results in the logs, no writes at all. Step two, once we've had a week of matching output is to flip reads over behind a feature flag that we can turn off in a minute if something looks wrong. Step three is moving writes and that one I want to do on a Tuesday morning when everyone is around, not on a Friday. Can you draft the plan as a checklist with an owner and a rollback note for each step and keep it under a page so people actually read it",
                 gold: "So for the Quillstack migration I want to go slowly. Step one is just reading from the new table in parallel and comparing results in the logs, no writes at all. Step two, once we've had a week of matching output, is to flip reads over behind a feature flag that we can turn off in a minute if something looks wrong. Step three is moving writes, and that one I want to do on a Tuesday morning when everyone is around, not on a Friday. Can you draft the plan as a checklist with an owner and a rollback note for each step, and keep it under a page so people actually read it.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-07",
                 raw: "Okay quick context before the actual ask. The marlowe summarizer has been rewriting paragraphs instead of trimming them, which is not what we want and I think the reason is that the input block has no boundary markers, so the model treats the whole page as a request. What I'd like you to do is wrap the paragraph in explicit start and end markers, add two short examples that show a paragraph being shortened rather than rephrased and then rerun the ten samples we have and paste the before and after outputs side by side. Don't change the instruction wording itself yet, I want to isolate the effect of the markers first and if that alone fixes it we stop there and write it up",
                 gold: "Okay, quick context before the actual ask. The Marlowe summarizer has been rewriting paragraphs instead of trimming them, which is not what we want, and I think the reason is that the input block has no boundary markers, so the model treats the whole page as a request. What I'd like you to do is wrap the paragraph in explicit start and end markers, add two short examples that show a paragraph being shortened rather than rephrased, and then rerun the ten samples we have and paste the before and after outputs side by side. Don't change the instruction wording itself yet, I want to isolate the effect of the markers first, and if that alone fixes it we stop there and write it up.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-08",
                 raw: "So I've been going back and forth on the halyard deploy setup and I think I finally have an opinion. The current script does the build, the upload and the restart in one go, which is nice when it works and terrible when it doesn't, because a failed restart leaves the old binary gone and the new one half started. I'd rather split it into three commands that each check their own preconditions and print exactly what they're about to do, with a dry run flag on every one. The upload should verify the checksum after the transfer, the restart should wait for the health endpoint to come back for up to 30 seconds and if anything fails it should leave the previous version in place and say so loudly. Can you sketch that as a shell script with comments, nothing fancy and I'll review it tonight",
                 gold: "So I've been going back and forth on the Halyard deploy setup and I think I finally have an opinion. The current script does the build, the upload, and the restart in one go, which is nice when it works and terrible when it doesn't, because a failed restart leaves the old binary gone and the new one half started. I'd rather split it into three commands that each check their own preconditions and print exactly what they're about to do, with a dry run flag on every one. The upload should verify the checksum after the transfer, the restart should wait for the health endpoint to come back for up to 30 seconds, and if anything fails it should leave the previous version in place and say so loudly. Can you sketch that as a shell script with comments, nothing fancy, and I'll review it tonight.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-09",
                 raw: "Okay this is a longer one, bear with me. The coppermine dashboard is showing weekly active users going up while sessions per user are going down and the product team is reading that as growth, but I'm not convinced. My guess is that the new onboarding email is pulling in people who open the app once, poke around for a minute and never come back, which would inflate the first number and drag the second. What I'd like is a cohort view that splits users by the week they signed up and shows retention at day 1, day 7 and day 30 for each cohort so we can see whether the recent cohorts actually stick or just show up once. If you can also overlay the date the email went out as a vertical line, that would make the story obvious",
                 gold: "Okay, this is a longer one, bear with me. The Coppermine dashboard is showing weekly active users going up while sessions per user are going down, and the product team is reading that as growth, but I'm not convinced. My guess is that the new onboarding email is pulling in people who open the app once, poke around for a minute, and never come back, which would inflate the first number and drag the second. What I'd like is a cohort view that splits users by the week they signed up and shows retention at day 1, day 7, and day 30 for each cohort, so we can see whether the recent cohorts actually stick or just show up once. If you can also overlay the date the email went out as a vertical line, that would make the story obvious.",
                 tags: ["agent-prompt", "long", "control"]),
        EvalCase(id: "long-10",
                 raw: "So I want to talk through the training plan before you change anything in the calendar. The block we're on has me at four sessions a week, one long, one hard, two easy and the total is supposed to climb from about 28 miles now to around 42 by the peak week in late February. The problem is that the last three weeks I only managed about 60 percent of that because of travel and one bad night of sleep, so the plan as written is now too aggressive for where I actually am. I don't want to just shift everything by a week because the race date is fixed. Can you rewrite the next 14 days so the long session progression stays as it is, the hard sessions drop by 20 percent and any day where the total jumps more than 10 percent over the previous week gets flagged",
                 gold: "So I want to talk through the training plan before you change anything in the calendar. The block we're on has me at four sessions a week, one long, one hard, two easy, and the total is supposed to climb from about 28 miles now to around 42 by the peak week in late February. The problem is that the last three weeks I only managed about 60 percent of that because of travel and one bad night of sleep, so the plan as written is now too aggressive for where I actually am. I don't want to just shift everything by a week, because the race date is fixed. Can you rewrite the next 14 days so the long session progression stays as it is, the hard sessions drop by 20 percent, and any day where the total jumps more than 10 percent over the previous week gets flagged.",
                 tags: ["agent-prompt", "long", "control"]),

        // MARK: §3.2 class 2 — agent-prompt medium (16–60 words): one to
        // three um/uh, and one sentence the ASR split with a period that
        // the gold rejoins with a comma (the "press escape. Escape" shape),
        // so the casing axis catches the stray capital.
        EvalCase(id: "medium-01",
                 raw: "Okay, so, um, the Lumabase nightly job stalled again last night around 2 a.m. Which is the third time this month. Can you add a timeout on the pool checkout, uh, and log which query was holding the connection when it fired",
                 gold: "Okay, so the Lumabase nightly job stalled again last night around 2 a.m., which is the third time this month. Can you add a timeout on the pool checkout and log which query was holding the connection when it fired?",
                 tags: ["agent-prompt", "medium", "fillers"]),
        EvalCase(id: "medium-02",
                 raw: "So I looked at the Tidewatch export and, um, the splits are fine except mile 8. Where the GPS dropped under the bridge for about 90 seconds. Can you flag any split that's more than a minute faster than its neighbours and print the timestamps next to it",
                 gold: "So I looked at the Tidewatch export and the splits are fine except mile 8, where the GPS dropped under the bridge for about 90 seconds. Can you flag any split that's more than a minute faster than its neighbours and print the timestamps next to it?",
                 tags: ["agent-prompt", "medium", "fillers"]),
        EvalCase(id: "medium-03",
                 raw: "Uh, before you merge the Fleetwing change, can you run the full suite twice. Because the cache test is flaky and I want to see if it fails the same way both times, um, and paste both outputs in the PR",
                 gold: "Before you merge the Fleetwing change, can you run the full suite twice, because the cache test is flaky and I want to see if it fails the same way both times, and paste both outputs in the PR?",
                 tags: ["agent-prompt", "medium", "fillers"]),
        EvalCase(id: "medium-04",
                 raw: "Okay, the Brightloop widget is blank on the lock screen, um, only after a reboot. Never after a normal restart of the app. Can you check the data provider timeline and, uh, add a log line for each refresh so we can see what fires first",
                 gold: "Okay, the Brightloop widget is blank on the lock screen, only after a reboot, never after a normal restart of the app. Can you check the data provider timeline and add a log line for each refresh so we can see what fires first?",
                 tags: ["agent-prompt", "medium", "fillers"]),
        EvalCase(id: "medium-05",
                 raw: "So for the Quillstack reads, um, I want the flag off by default. And only on for the two internal accounts until Friday. Can you wire that up and, uh, add a line in the runbook that says how to flip it",
                 gold: "So for the Quillstack reads, I want the flag off by default, and only on for the two internal accounts until Friday. Can you wire that up and add a line in the runbook that says how to flip it?",
                 tags: ["agent-prompt", "medium", "fillers"]),
        EvalCase(id: "medium-06",
                 raw: "Um, the Coppermine cohort query is timing out on the big accounts. Which I think is the join on the events table. Can you add an index on the user id and the week columns, uh, and rerun it for the March cohort so we can compare the timings",
                 gold: "The Coppermine cohort query is timing out on the big accounts, which I think is the join on the events table. Can you add an index on the user id and the week columns and rerun it for the March cohort so we can compare the timings?",
                 tags: ["agent-prompt", "medium", "fillers"]),

        // MARK: §3.2 class 3 — questions to the agent. Gold = the question,
        // punctuated; any content token the speaker did not say is novel.
        // question-01 replicates history row 70's shape (a how-does-it-work
        // question the model answered in markdown).
        EvalCase(id: "question-01",
                 raw: "could you explain how the brightloop playlist sync between the phone and the watch actually works step by step, I added four songs on the phone last night and this morning the watch only had two of them, then the other two showed up halfway through the run which makes me think there's a second sync happening in the background that nobody told me about",
                 gold: "Could you explain how the Brightloop playlist sync between the phone and the watch actually works, step by step? I added four songs on the phone last night, and this morning the watch only had two of them, then the other two showed up halfway through the run, which makes me think there's a second sync happening in the background that nobody told me about.",
                 note: "replica of the row-70 shape: a question the formatter must not answer",
                 tags: ["agent-prompt", "question", "replica", "control"]),
        EvalCase(id: "question-02",
                 raw: "what's the mechanism behind the fleetwing cache restore, um, when two jobs run at the same time. I saw the second job pull a bundle that the first one was still writing and the tests passed against a half written artifact, so either there's a lock I'm not seeing or the key is shared between branches. which one is it and where in the config would I change that",
                 gold: "What's the mechanism behind the Fleetwing cache restore when two jobs run at the same time? I saw the second job pull a bundle that the first one was still writing, and the tests passed against a half written artifact, so either there's a lock I'm not seeing or the key is shared between branches. Which one is it, and where in the config would I change that?",
                 tags: ["agent-prompt", "question", "fillers"]),
        EvalCase(id: "question-03",
                 raw: "am I using the pebblekit gesture API correctly here, I attach the recognizer in the view's init, uh, before the layout pass and the first tap on a cold launch gets swallowed every time. should it go in the did-appear callback instead",
                 gold: "Am I using the Pebblekit gesture API correctly here? I attach the recognizer in the view's init, before the layout pass, and the first tap on a cold launch gets swallowed every time. Should it go in the did-appear callback instead?",
                 tags: ["agent-prompt", "question", "fillers"]),
        EvalCase(id: "question-04",
                 raw: "I'm leaning toward keeping the lumabase schema as it is and adding a view for the report instead of a new table, it's less work now and easier to roll back but I might be missing a performance cost on the nightly job, what do you think",
                 gold: "I'm leaning toward keeping the Lumabase schema as it is and adding a view for the report instead of a new table. It's less work now and easier to roll back, but I might be missing a performance cost on the nightly job. What do you think?",
                 tags: ["agent-prompt", "question", "control"]),
        EvalCase(id: "question-05",
                 raw: "how does the tidewatch app decide which split is the fastest one, I have a run where the chart says mile 8 was the quickest but the raw data has a 90 second GPS gap right there, so is it reading the pace from the distance or from the timestamps",
                 gold: "How does the Tidewatch app decide which split is the fastest one? I have a run where the chart says mile 8 was the quickest, but the raw data has a 90 second GPS gap right there, so is it reading the pace from the distance or from the timestamps?",
                 tags: ["agent-prompt", "question", "control"]),

        // MARK: §3.2 class 4 — instruction-in-content traps. The dictation
        // TELLS the agent to compute, list, write, translate or summarize;
        // the formatter's only job is the punctuation. trap-01 replicates
        // history row 54's shape (two paired amounts and a request to total them).
        EvalCase(id: "trap-01",
                 raw: "okay so the glider is 40, then I've got a 12 on each wing and a 20 on each wing so add it up and put the total in the log",
                 gold: "Okay, so the glider is 40, then I've got a 12 on each wing and a 20 on each wing, so add it up and put the total in the log.",
                 note: "replica of the row-54 shape: a sum the formatter must not perform",
                 tags: ["agent-prompt", "trap", "numbers", "replica", "control"]),
        EvalCase(id: "trap-02",
                 raw: "before you touch the halyard script, list the steps you're going to take in the PR description because last time the restart happened before the upload finished and I had no idea what order things ran in",
                 gold: "Before you touch the Halyard script, list the steps you're going to take in the PR description, because last time the restart happened before the upload finished and I had no idea what order things ran in.",
                 tags: ["agent-prompt", "trap", "control"]),
        EvalCase(id: "trap-03",
                 raw: "write the function that parses the coppermine export, um, one row per line, tab separated, and returns a list of records with the date parsed as a real date, not a string and skip any row where the user id is empty",
                 gold: "Write the function that parses the Coppermine export, one row per line, tab separated, and returns a list of records with the date parsed as a real date, not a string, and skip any row where the user id is empty.",
                 tags: ["agent-prompt", "trap", "fillers"]),
        EvalCase(id: "trap-04",
                 raw: "translate this into Spanish for the parents' group and keep it short and warm but don't change any of the dates, the open day is on the 14th, sign up closes on the 21st and the first lesson is on the 28th",
                 gold: "Translate this into Spanish for the parents' group and keep it short and warm, but don't change any of the dates: the open day is on the 14th, sign up closes on the 21st, and the first lesson is on the 28th.",
                 tags: ["agent-prompt", "trap", "control"]),
        EvalCase(id: "trap-05",
                 raw: "summarize this for the standup, three bullets max, the quillstack read path is now behind the flag, the parallel comparison ran clean for six days and the write cutover is planned for Tuesday morning with a rollback note in the runbook",
                 gold: "Summarize this for the standup, three bullets max: the Quillstack read path is now behind the flag, the parallel comparison ran clean for six days, and the write cutover is planned for Tuesday morning with a rollback note in the runbook.",
                 tags: ["agent-prompt", "trap", "control"]),

        // MARK: §3.2 class 5 — hedges and stance that must survive, as
        // `must_keep` weight 2. Every hedge is under 15% of its gold, so an
        // UNANNOTATED drop of the same words would still read as the hedge
        // rung, not the fact gate. hedge-01 replicates history row 58's
        // shape ("I don't know," dropped from an agent prompt); hedge-02 is
        // the §9 forty-word row whose dropped hedge scores M = 77.
        EvalCase(id: "hedge-01",
                 raw: "I don't know, maybe dig into the Orbitr tab groups thing first and see what actually comes back before we change the sync at all",
                 gold: "I don't know, maybe dig into the Orbitr tab groups thing first and see what actually comes back before we change the sync at all.",
                 note: "replica of the row-58 shape: the opening hedge is stance, not filler",
                 tags: ["agent-prompt", "hedge", "replica", "control"],
                 mustKeep: [MustKeep(span: "I don't know,")]),
        EvalCase(id: "hedge-02",
                 raw: "i don't know have a look at the fleetwing cache keys and see what changed then write up the two options with their tradeoffs in a few lines and drop it in the channel before the standup tomorrow morning please",
                 gold: "I don't know, have a look at the Fleetwing cache keys and see what changed, then write up the two options with their tradeoffs in a few lines and drop it in the channel before the standup tomorrow morning, please.",
                 note: "§4.4 / §9 forty-word row: hedge dropped → M = 100·(1 − 6/40) − 8 = 77",
                 tags: ["agent-prompt", "hedge", "control"],
                 mustKeep: [MustKeep(span: "I don't know,")]),
        EvalCase(id: "hedge-03",
                 raw: "Yeah, um, for the naming let's keep the old prefix on the Lumabase tables for now and rename them in a separate pass once the parallel reads have been clean for a week, that way the diff stays readable",
                 gold: "Yeah, for the naming let's keep the old prefix on the Lumabase tables for now and rename them in a separate pass once the parallel reads have been clean for a week, that way the diff stays readable.",
                 tags: ["agent-prompt", "hedge", "fillers"],
                 mustKeep: [MustKeep(span: "Yeah,"), MustKeep(span: "let's")]),
        EvalCase(id: "hedge-04",
                 raw: "I don't really care, honestly, which library we use for the Coppermine export. I want the main thing to be that it finishes under a minute on the big accounts, so pick whichever one you've used before, wire it up behind the same interface and don't spend the whole afternoon comparing benchmarks that nobody will read",
                 gold: "I don't really care, honestly, which library we use for the Coppermine export. I want the main thing to be that it finishes under a minute on the big accounts, so pick whichever one you've used before, wire it up behind the same interface, and don't spend the whole afternoon comparing benchmarks that nobody will read.",
                 tags: ["agent-prompt", "hedge", "control"],
                 mustKeep: [MustKeep(span: "I don't really care,"), MustKeep(span: "honestly,"), MustKeep(span: "I want")]),
        EvalCase(id: "hedge-05",
                 raw: "Right now the Halyard rollout covers 12 regions, uh, soon to be 20, and honestly I might change my mind about the order once the first two are live, but for now keep the list exactly as it is, don't reshuffle anything, and if the health checks look fine after the first day we'll talk about pulling the next batch forward",
                 gold: "Right now the Halyard rollout covers 12 regions, soon to be 20, and honestly I might change my mind about the order once the first two are live, but for now keep the list exactly as it is, don't reshuffle anything, and if the health checks look fine after the first day we'll talk about pulling the next batch forward.",
                 tags: ["agent-prompt", "hedge", "fillers"],
                 mustKeep: [MustKeep(span: "soon to be 20,"), MustKeep(span: "might change my mind")]),

        // MARK: §3.2 class 6 — numbers. Spelled cardinals canonicalize
        // (§4.1) so "54" for "fifty four" is a hit, not an invention; the
        // ITN spellings a formatter may choose sit in `golds`. Times, dates
        // and ranges are digits in raw (Parakeet emits them so; a spoken
        // year would need `alternates`). The one weight-5 `must_keep` in
        // the set pins the fact gate.
        EvalCase(id: "numbers-01",
                 raw: "so the Lumabase export has the users table and a and sixty two other tables in it, can you list the ones over a hundred rows and skip the rest",
                 gold: "So the Lumabase export has the users table and 62 other tables in it, can you list the ones over a hundred rows and skip the rest.",
                 note: "spelled number behind a non-identical stutter",
                 golds: ["So the Lumabase export has the users table and sixty-two other tables in it, can you list the ones over a hundred rows and skip the rest."],
                 tags: ["agent-prompt", "numbers", "stutter"],
                 stutters: [Stutter(span: "and a and", keep: "and")]),
        EvalCase(id: "numbers-02",
                 raw: "we did twenty six K in the Coppermine import last night and it finished at 11:30, so the full run should be fine if we start it at 10 tonight",
                 gold: "We did twenty six K in the Coppermine import last night and it finished at 11:30, so the full run should be fine if we start it at 10 tonight.",
                 golds: ["We did 26K in the Coppermine import last night and it finished at 11:30, so the full run should be fine if we start it at 10 tonight."],
                 tags: ["agent-prompt", "numbers", "control"]),
        EvalCase(id: "numbers-03",
                 raw: "the open days are on the 14th, the 21st and the 28th, and we're expecting 790 or 800 sign ups total, so book the bigger room for the 28th please",
                 gold: "The open days are on the 14th, the 21st and the 28th, and we're expecting 790 or 800 sign ups total, so book the bigger room for the 28th, please.",
                 note: "date list + a fact span at weight 5",
                 tags: ["agent-prompt", "numbers", "control"],
                 mustKeep: [MustKeep(span: "790 or 800", weight: MustKeep.factWeight)]),
        EvalCase(id: "numbers-04",
                 raw: "the loop is 30-40 miles depending on the detour, and the climb at the end is about six hundred feet so plan the water stops for the longer version of the route",
                 gold: "The loop is 30-40 miles depending on the detour, and the climb at the end is about six hundred feet, so plan the water stops for the longer version of the route.",
                 golds: ["The loop is 30-40 miles depending on the detour, and the climb at the end is about 600 feet, so plan the water stops for the longer version of the route."],
                 tags: ["agent-prompt", "numbers", "control"]),

        // MARK: §3.2 class 7 — stutters beyond the stripper's identical-run
        // contract, annotated explicitly (an explicit list also carries the
        // identical runs, since it replaces derivation).
        EvalCase(id: "stutter-01",
                 raw: "I I think the like the retry logic in the Fleetwing client is swallowing the real error, can you check it",
                 gold: "I think the retry logic in the Fleetwing client is swallowing the real error, can you check it?",
                 note: "identical function-word run + restart after an article",
                 tags: ["agent-prompt", "stutter"],
                 stutters: [Stutter(span: "I I"), Stutter(span: "the like the")]),
        EvalCase(id: "stutter-02",
                 raw: "run the migration and then then then kick off the Halyard deploy, but only if the health check on the old box comes back green",
                 gold: "Run the migration and then kick off the Halyard deploy, but only if the health check on the old box comes back green.",
                 note: "content-word triple",
                 tags: ["agent-prompt", "stutter"],
                 stutters: [Stutter(span: "then then then")]),
        EvalCase(id: "stutter-03",
                 raw: "check that the Pebblekit demo builds on the older tablet and a and on the phone before you push, um, the last two times it broke on the tablet first",
                 gold: "Check that the Pebblekit demo builds on the older tablet and on the phone before you push, the last two times it broke on the tablet first.",
                 note: "non-identical run",
                 tags: ["agent-prompt", "stutter", "fillers"],
                 stutters: [Stutter(span: "and a and", keep: "and")]),
        EvalCase(id: "stutter-04",
                 raw: "send the alert to my l laptop if the Marlowe agent hangs again tonight, I I want to see the logs live this time",
                 gold: "Send the alert to my laptop if the Marlowe agent hangs again tonight, I want to see the logs live this time.",
                 note: "letter fragment (multi-token keep) + identical run",
                 tags: ["agent-prompt", "stutter"],
                 stutters: [Stutter(span: "my l laptop", keep: "my laptop"), Stutter(span: "I I")]),

        // MARK: §3.2 class 8 — cued self-corrections in real prose, and two
        // cue-is-content controls ("actually", "I mean" carrying meaning).
        EvalCase(id: "repair-01",
                 raw: "let's start the Quillstack cutover on Tuesday, I mean on Wednesday, after the parallel reads have been clean for the whole week",
                 gold: "Let's start the Quillstack cutover on Wednesday, after the parallel reads have been clean for the whole week.",
                 tags: ["agent-prompt", "repair"],
                 repairs: [Repair(reparandum: "on Tuesday, I mean", repair: "on Wednesday")]),
        EvalCase(id: "repair-02",
                 raw: "send the summary to the design channel no wait the platform channel, and tag the two people who own the Fleetwing config",
                 gold: "Send the summary to the platform channel, and tag the two people who own the Fleetwing config.",
                 tags: ["agent-prompt", "repair"],
                 repairs: [Repair(reparandum: "the design channel no wait", repair: "the platform channel")]),
        EvalCase(id: "repair-03",
                 raw: "the total for the Coppermine plan comes to 50, sorry I meant 15 a month, um, so it's well under what we budgeted",
                 gold: "The total for the Coppermine plan comes to 15 a month, so it's well under what we budgeted.",
                 tags: ["agent-prompt", "repair", "fillers"],
                 repairs: [Repair(reparandum: "50, sorry I meant", repair: "15")]),
        EvalCase(id: "cue-control-01",
                 raw: "the Pebblekit config doesn't actually allow nested groups, so we need a flat list with a parent id on each entry",
                 gold: "The Pebblekit config doesn't actually allow nested groups, so we need a flat list with a parent id on each entry.",
                 note: "\"actually\" is content — byte-preserved",
                 tags: ["agent-prompt", "cue-control", "control"]),
        EvalCase(id: "cue-control-02",
                 raw: "the Halyard deploy is actually today, not Friday, and I mean it when I say keep the branch green until it's out",
                 gold: "The Halyard deploy is actually today, not Friday, and I mean it when I say keep the branch green until it's out.",
                 note: "\"actually\" and \"I mean\" are content — byte-preserved",
                 tags: ["agent-prompt", "cue-control", "control"]),

        // MARK: §3.2 class 9 — clear STT slips on invented product names,
        // gold fixed. One novel token per fixture sits under every INVENTED
        // line, so "fix the obvious slip" is rewarded without licensing
        // invention. Each gold has ≥ 22 words so an echo of the slip still
        // keeps M_text ≥ 90 (one lost word).
        EvalCase(id: "asr-slip-01",
                 raw: "okay, so I signed into Loomabase again this morning and the nightly sync had stalled around 2 a.m., can you check the connection pool settings before we blame the retry loop",
                 gold: "Okay, so I signed into Lumabase again this morning and the nightly sync had stalled around 2 a.m., can you check the connection pool settings before we blame the retry loop.",
                 note: "letter-swap slip",
                 tags: ["agent-prompt", "asr-slip"]),
        EvalCase(id: "asr-slip-02",
                 raw: "the fleet wing cache step restored a stale bundle yesterday, so before we merge can you make sure the cache key includes the lockfile hash and post a note in the PR",
                 gold: "The Fleetwing cache step restored a stale bundle yesterday, so before we merge can you make sure the cache key includes the lockfile hash and post a note in the PR.",
                 note: "split-word slip (the merge is a hyphen-rule neighbour)",
                 tags: ["agent-prompt", "asr-slip"]),
        EvalCase(id: "asr-slip-03",
                 raw: "um, the orbiter tab groups keep losing the last group I made when the window is closed, can you look at when the save actually happens and whether there's a cap on the number of groups",
                 gold: "The Orbitr tab groups keep losing the last group I made when the window is closed, can you look at when the save actually happens and whether there's a cap on the number of groups.",
                 note: "real-word slip on a coined name",
                 tags: ["agent-prompt", "asr-slip", "fillers"]),

        // MARK: §3.2 class 10 — fragments the fast path must not "finish".
        // The all-filler raw has an EMPTY gold (a real gold, not gold-free:
        // `gold_source` is "seed"); the dangling article and the lone
        // conjunction carry no terminal mark.
        EvalCase(id: "fragment-01",
                 raw: "Uh",
                 gold: "",
                 note: "all-filler → nothing to paste; the fast path's \"Uh.\" is the failure",
                 tags: ["fragment", "all-filler", "fillers"]),
        EvalCase(id: "fragment-02",
                 raw: "Mm-hmm",
                 gold: "Mm-hmm.",
                 note: "backchannel — a word, not a filler",
                 tags: ["fragment", "backchannel", "control"]),
        EvalCase(id: "fragment-03",
                 raw: "Okay, and the um",
                 gold: "Okay, and the",
                 note: "dangling article: no terminal mark",
                 tags: ["fragment", "fillers"]),
        EvalCase(id: "fragment-04",
                 raw: "But",
                 gold: "But",
                 note: "lone conjunction: no terminal mark",
                 tags: ["fragment", "control"]),

        // MARK: §3.2 class 11 — punctuation repairs on otherwise clean prompts.
        EvalCase(id: "punct-01",
                 raw: "So when I hit the hotkey. The hotkey just beeps until I press it a second time",
                 gold: "So when I hit the hotkey, the hotkey just beeps until I press it a second time.",
                 note: "ASR sentence split rejoined",
                 tags: ["agent-prompt", "punct", "control"]),
        EvalCase(id: "punct-02",
                 raw: "can you check if the Fleetwing build passed on the release branch before I start the deploy",
                 gold: "Can you check if the Fleetwing build passed on the release branch before I start the deploy?",
                 note: "missing question mark",
                 tags: ["agent-prompt", "punct", "control"]),
        EvalCase(id: "punct-03",
                 raw: "for the demo box we need the runtime the sample data the license file and the two font packs installed before Monday",
                 gold: "For the demo box we need the runtime, the sample data, the license file and the two font packs installed before Monday.",
                 note: "four-item run-on list",
                 tags: ["agent-prompt", "punct", "control"]),

        // MARK: §3.2 class 12 — registers, run under the real directive by
        // the bench (`notes` is a verbatim category: no strip, no correction
        // clause, and the "concise notes" directive that over-edited both
        // real Notes rows).
        EvalCase(id: "register-messaging",
                 raw: "hey are you still coming tonight I'll be there around 8 let me know if you want me to grab anything on the way",
                 gold: "hey, are you still coming tonight? I'll be there around 8, let me know if you want me to grab anything on the way",
                 note: "casual message: lowercase start and no terminal are fine",
                 tags: ["register", "messaging", "control"],
                 register: .messaging),
        EvalCase(id: "register-notes",
                 raw: "notes for the mechanic. 2015 hatchback, about 84,000 miles, manual, second owner. oil changed in June, brakes done last spring, front pads only. there's a faint whine from the front left above 50 that goes away when I turn right and the clutch bites a bit higher than it used to. no warning lights. I'd rather keep it another two years than trade it so tell me what's worth doing now and what can wait",
                 gold: "Notes for the mechanic. 2015 hatchback, about 84,000 miles, manual, second owner. Oil changed in June, brakes done last spring, front pads only. There's a faint whine from the front left above 50 that goes away when I turn right, and the clutch bites a bit higher than it used to. No warning lights. I'd rather keep it another two years than trade it, so tell me what's worth doing now and what can wait.",
                 note: "profile dump: must not be compressed",
                 tags: ["register", "notes", "control"],
                 register: .notes),
        EvalCase(id: "register-browser",
                 raw: "I'm trying to understand how the orbitr tab groups actually work under the hood. When I close a window with three groups open and reopen it the next day, two of the groups come back and one doesn't and it's always the one I created last. Is there some limit on how many groups get saved or is it a timing thing where the last one hasn't been written yet. What's the mechanism here and am I using it wrong",
                 gold: "I'm trying to understand how the Orbitr tab groups actually work under the hood. When I close a window with three groups open and reopen it the next day, two of the groups come back and one doesn't, and it's always the one I created last. Is there some limit on how many groups get saved, or is it a timing thing where the last one hasn't been written yet? What's the mechanism here, and am I using it wrong?",
                 note: "browser chat question",
                 tags: ["register", "browser", "agent-prompt", "question", "control"],
                 register: .browser),

        // MARK: §3.2 class 13 — a continuation pair: the first utterance
        // stops mid-sentence (no forced period), the second picks up
        // lowercase.
        EvalCase(id: "continuation-01",
                 raw: "so the next thing I want you to look at is the retry logic in the Fleetwing client, specifically the part where",
                 gold: "So the next thing I want you to look at is the retry logic in the Fleetwing client, specifically the part where",
                 note: "ends mid-sentence: no terminal mark",
                 tags: ["agent-prompt", "continuation", "control"]),
        EvalCase(id: "continuation-02",
                 raw: "it swallows the timeout and returns an empty list, um, instead of raising, so the caller thinks the sync succeeded",
                 gold: "it swallows the timeout and returns an empty list instead of raising, so the caller thinks the sync succeeded.",
                 note: "continues the previous utterance: lowercase start",
                 tags: ["agent-prompt", "continuation", "fillers"]),

        // MARK: §3.2 class 14 — the latency ladder: one clean prompt cut at
        // sentence ends to exactly 10 / 30 / 60 / 100 / 150 spoken words;
        // raw is the words alone, gold the words punctuated. The ms/word and
        // by-length numbers come from these rows.
        EvalCase(id: "latency-010",
                 raw: "please add a retry to the lumabase client for timeouts",
                 gold: "Please add a retry to the Lumabase client for timeouts.",
                 tags: ["agent-prompt", "latency", "control"]),
        EvalCase(id: "latency-030",
                 raw: "please add a retry to the lumabase client for timeouts use a short backoff start at 200 milliseconds and double it and stop after five attempts so we never hang",
                 gold: "Please add a retry to the Lumabase client for timeouts. Use a short backoff, start at 200 milliseconds and double it, and stop after five attempts so we never hang.",
                 tags: ["agent-prompt", "latency", "control"]),
        EvalCase(id: "latency-060",
                 raw: "please add a retry to the lumabase client for timeouts use a short backoff start at 200 milliseconds and double it and stop after five attempts so we never hang log every attempt with the elapsed time and the error code but keep the log lines short because the nightly job already produces more output than anyone wants to read",
                 gold: "Please add a retry to the Lumabase client for timeouts. Use a short backoff, start at 200 milliseconds and double it, and stop after five attempts so we never hang. Log every attempt with the elapsed time and the error code, but keep the log lines short, because the nightly job already produces more output than anyone wants to read.",
                 tags: ["agent-prompt", "latency", "long", "control"]),
        EvalCase(id: "latency-100",
                 raw: "please add a retry to the lumabase client for timeouts use a short backoff start at 200 milliseconds and double it and stop after five attempts so we never hang log every attempt with the elapsed time and the error code but keep the log lines short because the nightly job already produces more output than anyone wants to read when the last attempt fails raise the original error rather than a wrapped one so the stack trace points at the call site and add a unit test that fakes three timeouts followed by a success and checks the wait",
                 gold: "Please add a retry to the Lumabase client for timeouts. Use a short backoff, start at 200 milliseconds and double it, and stop after five attempts so we never hang. Log every attempt with the elapsed time and the error code, but keep the log lines short, because the nightly job already produces more output than anyone wants to read. When the last attempt fails, raise the original error rather than a wrapped one, so the stack trace points at the call site, and add a unit test that fakes three timeouts followed by a success and checks the wait.",
                 tags: ["agent-prompt", "latency", "long", "control"]),
        EvalCase(id: "latency-150",
                 raw: "please add a retry to the lumabase client for timeouts use a short backoff start at 200 milliseconds and double it and stop after five attempts so we never hang log every attempt with the elapsed time and the error code but keep the log lines short because the nightly job already produces more output than anyone wants to read when the last attempt fails raise the original error rather than a wrapped one so the stack trace points at the call site and add a unit test that fakes three timeouts followed by a success and checks the wait also make sure the retry never wraps a request that already succeeded which happened once with the old client and put a note in the readme that explains the backoff numbers where they came from and how to change them safely if the service gets slower or noisier next year",
                 gold: "Please add a retry to the Lumabase client for timeouts. Use a short backoff, start at 200 milliseconds and double it, and stop after five attempts so we never hang. Log every attempt with the elapsed time and the error code, but keep the log lines short, because the nightly job already produces more output than anyone wants to read. When the last attempt fails, raise the original error rather than a wrapped one, so the stack trace points at the call site, and add a unit test that fakes three timeouts followed by a success and checks the wait. Also make sure the retry never wraps a request that already succeeded, which happened once with the old client, and put a note in the readme that explains the backoff numbers, where they came from, and how to change them safely if the service gets slower or noisier next year.",
                 tags: ["agent-prompt", "latency", "long", "control"]),
    ]
}
