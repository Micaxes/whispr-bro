import Foundation

/// What one `whispr-bench eval` run executes, in what order, under what
/// level (plan §6.1): the fixture subset (`--tag`, `--only`,
/// `--confirmed-only`), sorted by (register, level) so the llama prefix
/// re-primes at most once per group, with the first row of each group
/// marked `reprime` — it pays the KV re-prime inside its measured window
/// and is excluded from the percentiles. Each item carries the exact
/// pipeline decisions the bench mirrors from `PipelineController` /
/// `DictationPipeline`: a verbatim register (`verbatimCategories`) skips
/// the filler strip and the correction clause whatever the level; the
/// correction clause and `resolveCorrections` go out only at `standard`.
/// Pure data, so the order and the flags are pinned by test, not by a
/// model run.
public struct EvalPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let fixture: EvalCase
        /// The level the fixture runs at: `.verbatim` for a verbatim
        /// register, else the override or the fixture's own.
        public let level: AppConfig.Cleanup.Level
        /// First row of its (register, level) group.
        public let reprime: Bool

        public var verbatim: Bool { level == .verbatim }
        /// The filler pre-pass runs (`DictationPipeline`: not verbatim).
        public var stripFillers: Bool { !verbatim }
        /// The correction clause is appended and passed to the formatter
        /// (`PipelineController`: level == standard on a non-verbatim
        /// register).
        public var resolveCorrections: Bool { level == .standard }
    }

    public let items: [Item]
    /// `nil` = each fixture's own level ("fixture" in the run JSON).
    public let levelOverride: AppConfig.Cleanup.Level?

    /// The column's `level` field: the override's name, or `fixture`.
    public var levelName: String { levelOverride?.rawValue ?? "fixture" }

    public init(cases: [EvalCase], levelOverride: AppConfig.Cleanup.Level? = nil,
                verbatimCategories: [String] = AppConfig.Cleanup().verbatimCategories) {
        self.levelOverride = levelOverride
        // Stable sort: ties keep file order, so a fixture file's own order
        // still shows inside a group.
        let keyed = cases.enumerated().map { (index: $0.offset, fixture: $0.element,
                                              level: Self.level(for: $0.element, override: levelOverride,
                                                                verbatimCategories: verbatimCategories)) }
        let sorted = keyed.sorted {
            let a = ($0.fixture.register.rawValue, $0.level.rawValue, $0.index)
            let b = ($1.fixture.register.rawValue, $1.level.rawValue, $1.index)
            return a < b
        }
        var items: [Item] = []
        var previous: (String, String)?
        for entry in sorted {
            let group = (entry.fixture.register.rawValue, entry.level.rawValue)
            let reprime = previous.map { $0 != group } ?? true
            previous = group
            items.append(Item(fixture: entry.fixture, level: entry.level, reprime: reprime))
        }
        self.items = items
    }

    /// The level a fixture runs at — the one predicate `QualityScore.score`
    /// reads too. The config's category names are matched
    /// case-insensitively (`config.toml` is hand-written).
    public static func level(for fixture: EvalCase, override: AppConfig.Cleanup.Level?,
                             verbatimCategories: [String] = AppConfig.Cleanup().verbatimCategories)
        -> AppConfig.Cleanup.Level {
        if verbatimCategories.contains(where: { $0.lowercased() == fixture.register.rawValue }) { return .verbatim }
        return override ?? fixture.level
    }

    /// The provenance the shipped column infers for a history row. The
    /// production binary records none (`HistoryRecord` has no source
    /// column), so the bench decides as `TextFormatter.formatDetailed` and
    /// `FoundationModelsFormatter` decide: the model ran unless the
    /// stripped text is under the fast-path word limit AND carries no
    /// plausible correction cue at a level that resolves corrections —
    /// the cue bypass production takes on "send it monday no wait
    /// tuesday". Only a `.model` row's `observed_ms` is model latency.
    /// Raw mode (the LLM toggled off for a dictation) leaves no trace in
    /// history either and is not inferred: such a row reads as `.model`
    /// with a rules-path latency, the one provenance this column cannot
    /// see. `ceilingWords`, when given, is the count the long-utterance
    /// ceiling applies to (`DictationPipeline.FormatterInput.ceilingWords`:
    /// the row before the self-repair rules).
    public static func shippedSource(
        stripped: String, item: Item,
        fastPathWordLimit: Int = TextFormatter.Config().fastPathWordLimit,
        llmWordLimit: Int = TextFormatter.Config().llmWordLimit,
        ceilingWords: Int? = nil
    ) -> FormatterSource {
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .fallback(.fastPath) }
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        let cueBypass = item.resolveCorrections
            && CorrectionCues.plausibleCorrection(in: trimmed, language: item.fixture.language)
        if words < fastPathWordLimit && !cueBypass { return .fallback(.fastPath) }
        // The long-utterance ceiling is a production skip too, so a long row is
        // rules output in history — never a model row.
        if max(words, ceilingWords ?? 0) > llmWordLimit { return .fallback(.tooLong) }
        return .model
    }

    /// The provenance of a history row when the binary that recorded it is
    /// not known — `HistoryRecord` carries no version, and what the formatter
    /// saw depends on it: the filler strip alone before the self-repair rules,
    /// the rules and then the strip after. `candidates` are those pre-pass
    /// texts; the source is kept only when every one of them gives the same
    /// answer. When they differ (the rules took out the correction cue that
    /// kept a short row off the fast path, say) the row has no provenance —
    /// nil — and its `observed_ms` is not counted as model time. Every
    /// binary applies the length ceiling to the longest of them, the row
    /// before the rules (`DictationPipeline.FormatterInput.ceilingWords`),
    /// so the rules taking a long row under it never splits the answer.
    public static func shippedSource(
        candidates: [String], item: Item,
        fastPathWordLimit: Int = TextFormatter.Config().fastPathWordLimit,
        llmWordLimit: Int = TextFormatter.Config().llmWordLimit
    ) -> FormatterSource? {
        let ceiling = candidates.map(DictationPipeline.wordCount).max()
        let sources = candidates.map {
            shippedSource(stripped: $0, item: item, fastPathWordLimit: fastPathWordLimit, llmWordLimit: llmWordLimit,
                          ceilingWords: ceiling)
        }
        guard let first = sources.first, sources.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// The directive the llama / foundation stage receives for an item:
    /// the register's `StyleRules` line, plus the correction clause at
    /// `standard` — `PipelineController.effectiveStyleDirective` without
    /// the dictionary allowlist (the bench has no personal dictionary).
    public static func directive(for item: Item, rules: StyleRules = StyleRules()) -> String {
        var parts = [rules.directive(for: item.fixture.register)]
        if item.resolveCorrections {
            parts.append(PromptBuilder.correctionClause(for: item.fixture.language))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Number of (register, level) groups — how many re-primes a run pays.
    public var groups: Int { items.filter(\.reprime).count }

    // MARK: - Selection

    /// `--only`: which fixtures a run takes.
    public enum Only: String, Sendable, CaseIterable {
        case all
        /// Fixtures whose `observed` output (the shipped binary's) trips
        /// a gate.
        case gated
        /// Gated, or `dropped_content` ≥ `EvalThresholds.flaggedDroppedContent`
        /// on the observed output — the rating queue's order (§7.1).
        case flagged
        /// Gold-free fixtures.
        case unrated
    }

    /// Applies `--tag` (any of), `--only`, and `--confirmed-only` (drops
    /// draft golds; gold-free rows are not drafts and stay).
    public static func select(_ cases: [EvalCase], tags: [String] = [], only: Only = .all,
                              confirmedOnly: Bool = false,
                              verbatimCategories: [String] = AppConfig.Cleanup().verbatimCategories) -> [EvalCase] {
        cases.filter { c in
            if !tags.isEmpty, !tags.contains(where: { c.tags.contains($0) }) { return false }
            if confirmedOnly, !c.isGoldFree, c.isDraft { return false }
            switch only {
            case .all:
                return true
            case .unrated:
                return c.isGoldFree
            case .gated, .flagged:
                // Only an observed output can be gated; a fixture without
                // one has nothing to flag.
                guard let observed = c.observed else { return false }
                let score = QualityScore.score(c, out: observed, verbatimCategories: verbatimCategories)
                if score.isGated { return true }
                return only == .flagged
                    && score.contentGuard.droppedContent.count >= EvalThresholds.flaggedDroppedContent
            }
        }
    }
}
