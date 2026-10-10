import Foundation

/// `whispr-bench lint` (plan §3.1, §9): every rule a fixture file must clear
/// before its numbers mean anything, as data — one `Issue` per finding,
/// errors and warnings apart — so the CLI's exit code and CI's repo guard
/// read the same list the tests pin.
///
/// Three tiers, and the middle one is the whole design. **Errors** are
/// structural: a span that is not where the annotation says it is, a
/// must-keep no acceptable gold could satisfy, a flag its own text
/// contradicts, a duplicate id, the set-level floors. Every one of them is
/// a fact about the text, decidable without a tie-break, and they are the
/// only findings that block a write. **The invariant** is the consistency
/// check between an annotation and its gold, and it is not hand-written:
/// the scorer is run with hypothesis = gold and the gold must come back
/// 100 (§9 — "any seed whose gold fails its own scorer is a broken
/// fixture"). A filler the gold retains lands on Fi, a must-keep it drops
/// on M, a repair it leaves standing on M, a gate on C — every
/// contradiction surfaces on the axis it would have corrupted, quoted in
/// the scorer's own numbers, and the check can never drift from the scorer
/// because it IS the scorer. **Warnings** never block: a core filler a gold
/// retains that nothing annotates, a draft gold, and the invariant on an
/// alternate gold rather than the primary one.
///
/// Nothing here re-derives what the scorer computes. The rules that did —
/// occurrence arbitration, unnamed-copy accounting, the union of every
/// gold's reading — grew an exception per fixture shape and broke twice;
/// they are gone.
public enum EvalLint {
    public enum Severity: String, Sendable, Equatable {
        case error, warning
    }

    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public let severity: Severity
        /// nil for a set-level finding.
        public let id: String?
        public let message: String

        public init(_ severity: Severity, id: String? = nil, _ message: String) {
            self.severity = severity
            self.id = id
            self.message = message
        }

        public var description: String {
            "\(severity.rawValue): " + (id.map { "[\($0)] " } ?? "") + message
        }
    }

    /// Set-level floors (§3.1, seeds only): the share of the set each class
    /// must reach, and the one-word cap. Pinned by test.
    public static let minControlShare = 0.15
    public static let minSixtyWordShare = 0.20
    public static let minThirtyWordShare = 0.40
    public static let minAgentPromptShare = 0.60
    public static let maxOneWordShare = 0.10

    /// `source` values the repo guard refuses: a real dictation's row id.
    public static let historySourcePrefix = "history:"

    /// Floating-point slack on "scores 100": every axis is a sum of
    /// weighted ratios, so a perfect score can land a hair under.
    static let invariantSlack = 1e-9

    /// Lints `cases`.
    /// - `floors`: apply the set-level shares (the seed set; a personal
    ///   file is whatever his history is).
    /// - `repoGuard`: refuse `history:` sources and `observed` fields —
    ///   the fields only an export writes — so no personal row can be
    ///   committed under `Sources/` or `docs/`.
    public static func lint(_ cases: [EvalCase], floors: Bool = false, repoGuard: Bool = false) -> [Issue] {
        var issues: [Issue] = []
        var seen: Set<String> = []
        for c in cases {
            if !seen.insert(c.id).inserted {
                issues.append(Issue(.error, id: c.id, "duplicate id"))
            }
            issues += row(c)
            if repoGuard { issues += guardRow(c) }
        }
        if floors { issues += setLevel(cases) }
        return issues
    }

    public static func hasErrors(_ issues: [Issue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    // MARK: - Row rules

    /// One fixture: the structural errors, then the invariant, then the
    /// warnings.
    public static func row(_ c: EvalCase) -> [Issue] {
        var issues: [Issue] = []
        func error(_ message: String) { issues.append(Issue(.error, id: c.id, message)) }
        func warning(_ message: String) { issues.append(Issue(.warning, id: c.id, message)) }

        if c.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("empty raw")
        }
        let raw = Align.canonicalTokens(c.raw)
        let goldFree = c.isGoldFree
        /// Every gold the scorer would accept, labelled for a message. An
        /// empty alternate is named as the malformed field it is (below)
        /// and never read.
        let golds: [(label: String, text: String, tokens: [EvalToken])] =
            c.acceptableGolds.enumerated().compactMap { index, text in
                if index > 0, text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
                return (index == 0 ? "gold" : "golds[\(index - 1)]", text, Align.canonicalTokens(text))
            }
        /// What a gold-side miss is called when there is more than one.
        let everyGold = c.golds.isEmpty ? "gold" : "any acceptable gold"
        func inSomeGold(_ span: String) -> Bool {
            golds.contains { Align.locate(span, in: $0.tokens) != nil }
        }

        // Structural: a span is where the annotation says it is, or the
        // fixture is broken — on the SAME canonical tokens the scorer
        // aligns (`Align.locate`), so "not found in raw" here is exactly
        // the miss that would otherwise surface as a silent Fi < 100.
        for f in c.expectedFillers where Align.locate(f.span, in: raw, occurrence: f.occurrence) == nil {
            error("filler '\(f.span)' (occurrence \(f.occurrence)) not found in raw")
        }
        for s in c.expectedStutters {
            if Align.locate(s.span, in: raw, occurrence: s.occurrence) == nil {
                error("stutter '\(s.span)' (occurrence \(s.occurrence)) not found in raw")
            }
            // `keep` is an in-order subsequence of the run ("my l laptop"
            // keeps "my laptop"), not a contiguous span.
            var remaining = Align.canonicalTokens(s.span).map(\.canonical)[...]
            for kept in Align.canonicalTokens(s.keep).map(\.canonical) {
                guard let at = remaining.firstIndex(of: kept) else {
                    error("stutter keep '\(s.keep)' is not a subsequence of '\(s.span)'")
                    break
                }
                remaining = remaining[(at + 1)...]
            }
        }
        for r in c.repairs {
            if Align.locate(r.reparandum, in: raw) == nil {
                error("repair reparandum '\(r.reparandum)' not found in raw")
            }
            // The corrected side has to exist somewhere the scorer would
            // accept; WHICH gold keeps it, and whether the abandoned side
            // survives beside it, is the invariant's business.
            if !goldFree, !inSomeGold(r.repair) {
                error("repair '\(r.repair)' not found in \(everyGold)")
            }
        }
        for m in c.mustKeep {
            if Align.locate(m.span, in: raw) == nil {
                error("must_keep '\(m.span)' not found in raw")
            }
            if !goldFree, !inSomeGold(m.span) {
                error("must_keep '\(m.span)' not found in \(everyGold)")
            }
            if m.weight < 1 {
                error("must_keep '\(m.span)' weight \(m.weight) < 1")
            }
        }
        for a in c.alternates where a.from.trimmingCharacters(in: .whitespaces).isEmpty || a.to.isEmpty {
            error("alternate needs a non-empty 'from' and at least one 'to'")
        }
        for (i, alt) in c.golds.enumerated() where alt.trimmingCharacters(in: .whitespaces).isEmpty {
            error("golds[\(i)] is empty")
        }

        guard !goldFree else {
            if c.observed == nil { warning("gold-free fixture without an observed output scores nothing but Fi") }
            return issues
        }

        // Gold may not carry a number the speaker never said (§3.1):
        // cardinals canonicalize on their own, alternates cover the rest.
        var said = Set(raw.map(\.canonical))
        for a in c.alternates {
            for form in a.to { said.formUnion(Align.canonicalTokens(form).map(\.canonical)) }
        }
        for token in Align.canonicalTokens(c.gold) where token.isNumeral && !said.contains(token.canonical) {
            error("gold numeral '\(token.canonical)' is not in raw or alternates")
        }
        // A control is a pass-through: any word edit between raw and gold
        // contradicts the flag.
        if c.control == true {
            let edits = Align.align(raw, Align.canonicalTokens(c.gold)).errors
            if edits > 0 { error("control: true but raw→gold has \(edits) word edit(s)") }
        }

        // THE INVARIANT (§9). Every annotation-vs-gold rule this file used
        // to hand-write is this one line: score the gold as its own
        // hypothesis and demand 100. The primary gold blocks; an alternate
        // warns, because the scorer keeps the best gold and a fixture is
        // still well-formed when only its first reading is perfect.
        for gold in golds {
            guard let failure = invariantFailure(c, gold: gold.text, label: gold.label) else { continue }
            if gold.label == "gold" { error(failure) } else { warning(failure) }
        }

        // A core filler an acceptable gold retains that no annotation
        // mentions — asked of an explicit `fillers` list exactly as of a
        // derived one, and never an error: the fixture is often right (he
        // keeps the "um" on purpose, and `fillers: []` says so), and where
        // it is wrong the invariant above has already charged it on Fi.
        // What this line adds is the reading a human wants when the fixture
        // states neither.
        let lexicon = Set(FillerStripper.coreFillers(for: c.language))
        var mentioned: Set<Int> = []
        for f in c.expectedFillers {
            if let range = Align.locate(f.span, in: raw, occurrence: f.occurrence) { mentioned.formUnion(range) }
        }
        for s in c.expectedStutters {
            if let range = Align.locate(s.span, in: raw, occurrence: s.occurrence) { mentioned.formUnion(range) }
        }
        /// Raw indices each gold KEEPS — the words that survive it spelled
        /// the same (`AlignOp.survives`), the one definition `survivors`
        /// hands `retainedFillers` and `GoldDerivation`'s bend, so a warning
        /// here and a bend there can never disagree about what "kept" means. "Not deleted" is
        /// a different question: a filler the gold REPLACES aligns as a `.sub`
        /// and is absent from the gold, so warning that it is kept names a
        /// word the reader cannot find — and `EvalCase.deriveFillers`, which
        /// derives off `.del`, does not expect its removal either.
        let retained: [(label: String, kept: Set<Int>)] = golds.map { gold in
            var kept: Set<Int> = []
            for op in Align.align(raw, gold.tokens).ops where op.survives {
                if let i = op.aIndex { kept.insert(i) }
            }
            return (gold.label, kept)
        }
        var counts: [String: Int] = [:]
        for (i, token) in raw.enumerated() where lexicon.contains(token.normalized) {
            counts[token.normalized, default: 0] += 1
            guard !mentioned.contains(i), let keeper = retained.first(where: { $0.kept.contains(i) }) else { continue }
            warning("filler '\(token.cased)' (occurrence \(counts[token.normalized]!)) "
                    + "is kept in \(keeper.label) and not annotated")
        }
        if c.isDraft {
            warning("draft gold (\(c.goldSource)) — scored, not counted as rated")
        }
        return issues
    }

    // MARK: - The invariant

    /// `gold` scored as its own hypothesis: nil when it comes back 100 on
    /// every axis the fixture defines, else the scorer's numbers, its
    /// verdict and what it missed.
    ///
    /// The fixture is rescored against `gold` ALONE — the scorer's best-of
    /// would otherwise let a generous alternate mask a primary gold that
    /// contradicts its own annotations — with everything else about the
    /// fixture (register, level, alternates, spans) left exactly as it is,
    /// so the check is the run the bench would do, not a model of it. Fi is
    /// nil where the fixture expects no removal or the register is
    /// verbatim; that axis is simply not part of the claim there.
    static func invariantFailure(_ c: EvalCase, gold: String, label: String) -> String? {
        let q = QualityScore.score(alone(c, gold: gold), out: gold)
        let axes: [(String, Double?)] = [("F", q.formatting?.score), ("Fi", q.fillers?.score),
                                         ("M", q.meaning?.score), ("C", q.composite)]
        guard axes.contains(where: { $0.1.map { $0 < 100 - invariantSlack } ?? false }) else { return nil }
        var detail: [String] = []
        if !q.gates.isEmpty { detail.append("gated \(q.triggerNames.joined(separator: ", "))") }
        if let fillers = q.fillers, !fillers.missed.isEmpty {
            detail.append("Fi missed " + quoted(fillers.missed))
        }
        if let meaning = q.meaning {
            if !meaning.missedMustKeep.isEmpty { detail.append("must_keep missing " + quoted(meaning.missedMustKeep.map(\.span))) }
            if !meaning.unresolvedRepairs.isEmpty { detail.append("repair unresolved " + quoted(meaning.unresolvedRepairs)) }
            if !meaning.lostTokens.isEmpty { detail.append("gold words lost " + quoted(meaning.lostTokens)) }
            if meaning.novel > 0 { detail.append("novel \(meaning.novel)") }
        }
        return "\(label) does not score 100 against itself: "
            + axes.map { "\($0.0) \(EvalReport.number($0.1))" }.joined(separator: " ")
            + " [\(q.verdict.rawValue)]"
            + (detail.isEmpty ? "" : " — " + detail.joined(separator: "; "))
    }

    /// The fixture with `gold` as its one acceptable gold.
    private static func alone(_ c: EvalCase, gold: String) -> EvalCase {
        EvalCase(id: c.id, raw: c.raw, gold: gold, note: c.note, audio: c.audio, golds: [], tags: c.tags,
                 register: c.register, level: c.level, language: c.language, control: c.control,
                 fillers: c.fillers, stutters: c.stutters, repairs: c.repairs, mustKeep: c.mustKeep,
                 alternates: c.alternates, maxMs: c.maxMs, source: c.source, goldSource: c.goldSource,
                 annotationsStatus: c.annotationsStatus, observed: c.observed, observedMs: c.observedMs)
    }

    private static func quoted(_ items: [String]) -> String {
        items.map { "'\($0)'" }.joined(separator: ", ")
    }

    /// What a gold LEAVES of one annotated span: the raw indices inside the
    /// `occurrence`-th run of `span` whose word survives into it. Nil when
    /// raw does not carry the span there — a `lint` error of its own
    /// ("not found in raw"), never a reading to act on.
    ///
    /// This is the file's one definition of "kept", and everything that
    /// asks the question reads it: the retained-filler list below, and
    /// §7.3 rule 7's bend (`GoldDerivation.contradicts`), so the linter
    /// and the derivation cannot drift apart about what a gold keeps.
    /// Survival is `AlignOp.survives` — a hit, the word still there
    /// spelled the same — and never `isAligned`: a word the gold REPLACES
    /// is aligned and gone.
    ///
    /// The occurrence is a RAW index, followed through the raw→gold
    /// alignment rather than counted in the gold: the gold's own
    /// occurrences have already moved, so the second "you know" of a gold
    /// that dropped the first is the FIRST one there.
    static func survivors(of span: String, occurrence: Int, in rawTokens: [EvalToken],
                          opsA: [AlignOp]) -> [Int]? {
        guard let range = Align.locate(span, in: rawTokens, occurrence: occurrence),
              range.upperBound <= opsA.count else { return nil }
        return range.filter { opsA[$0].survives }
    }

    /// Every filled pause `gold` KEEPS that the row still expects the
    /// formatter to remove — an UNANNOTATED survivor (the warning above)
    /// and its mirror image, an ANNOTATED one, which `lint` accepts and Fi
    /// then scores the gold itself 0 on. One contradiction between a gold
    /// and an expectation, in two guises; §7.3's rule 7 bends both, and it
    /// is the only reading of "kept" in this file — the warning's own
    /// index set, `survivors` above and `GoldDerivation`'s bend all ask
    /// `AlignOp.survives`.
    ///
    /// "Keeps" is survival, not "was not deleted": a filler the gold
    /// REPLACES aligns as a `.sub`, is gone from the gold, and expects
    /// nothing of the formatter. `fillers: []` — the opt-out — returns
    /// nothing whatever the gold does.
    ///
    /// A marker keeps a COUNT of its copies, not all of them or none: a
    /// gold that drops the "know" and leaves the "you" of an annotated
    /// "you know" keeps one more than the row allows (Fi reads a filler's
    /// `keep` as `""`), and Fi charges that surplus against the gold
    /// itself. So an explicit entry is read at its own occurrence in RAW,
    /// exactly as the bend reads it, and never with "is this span anywhere
    /// in the gold" — which answers yes off an untouched copy elsewhere
    /// and no off a half-removed one.
    public static func retainedFillers(raw: String, gold: String, language: DictationLanguage,
                                       fillers: [EvalCase.Filler]?) -> [EvalCase.Filler] {
        guard fillers == nil || !fillers!.isEmpty else { return [] }
        let lexicon = Set(FillerStripper.coreFillers(for: language))
        let rawTokens = Align.canonicalTokens(raw)
        let opsA = Align.align(rawTokens, Align.canonicalTokens(gold)).opsA
        var counts: [String: Int] = [:]
        var retained: [EvalCase.Filler] = []
        for (i, token) in rawTokens.enumerated() where lexicon.contains(token.normalized) {
            counts[token.normalized, default: 0] += 1
            guard opsA[i].survives else { continue }
            retained.append(EvalCase.Filler(span: token.cased, occurrence: counts[token.normalized]!))
        }
        // An explicit entry need not be one of the lexicon's own words (the
        // opt-in extended set, a multi-word marker): the scan above walks
        // raw and so is at its own occurrence already, but it cannot see
        // that entry at all, so the same count is taken for it here.
        var seen = Set(retained.map(key))
        for entry in fillers ?? [] {
            let tokens = Align.canonicalTokens(entry.span)
            if tokens.count == 1, lexicon.contains(tokens[0].normalized) { continue }
            guard let kept = survivors(of: entry.span, occurrence: entry.occurrence,
                                       in: rawTokens, opsA: opsA),
                  !kept.isEmpty, seen.insert(key(entry)).inserted else { continue }
            retained.append(entry)
        }
        return retained
    }

    /// A filler's identity: the word and which of its occurrences in raw.
    private static func key(_ filler: EvalCase.Filler) -> String {
        "\(filler.span.lowercased())#\(filler.occurrence)"
    }

    /// A fixture only an export writes: a `history:` source or a shipped
    /// output. The repo guard refuses these in the tree, and the run-file
    /// refusal (`Leaderboard.refusesRunOutput`) keys off the same test.
    public static func carriesExportFields(_ c: EvalCase) -> Bool {
        c.source.hasPrefix(historySourcePrefix) || c.observed != nil || c.observedMs != nil
    }

    /// The repo guard: nothing an export writes may live in the tree.
    public static func guardRow(_ c: EvalCase) -> [Issue] {
        guardExportFields(id: c.id, source: c.source, observed: c.observed, observedMs: c.observedMs)
    }

    /// The guard on the three fields themselves, so a fixtures file of
    /// another shape (`FormatLint`) is refused by this rule and not a copy
    /// of it: a `history:` source or a shipped output is an error wherever
    /// it sits in the tree.
    public static func guardExportFields(id: String, source: String?, observed: String?,
                                         observedMs: Int?) -> [Issue] {
        var issues: [Issue] = []
        if let source, source.hasPrefix(historySourcePrefix) {
            issues.append(Issue(.error, id: id, "repo guard: source '\(source)' is a history row"))
        }
        if observed != nil || observedMs != nil {
            issues.append(Issue(.error, id: id, "repo guard: 'observed' / 'observed_ms' is shipped-binary output"))
        }
        return issues
    }

    // MARK: - Set level

    /// The §3.1 floors over the whole set.
    public static func setLevel(_ cases: [EvalCase]) -> [Issue] {
        guard !cases.isEmpty else { return [Issue(.error, "empty fixture set")] }
        let n = Double(cases.count)
        func share(_ count: Int) -> Double { Double(count) / n }
        func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
        var issues: [Issue] = []
        let controls = cases.filter(\.isControl).count
        let sixty = cases.filter { $0.wordCount >= 60 }.count
        let thirty = cases.filter { $0.wordCount >= 30 }.count
        let agent = cases.filter { $0.tags.contains("agent-prompt") }.count
        let oneWord = cases.filter { $0.wordCount == 1 }.count
        if share(controls) < minControlShare {
            issues.append(Issue(.error, "controls \(controls)/\(cases.count) (\(pct(share(controls)))) below \(pct(minControlShare))"))
        }
        if share(sixty) < minSixtyWordShare {
            issues.append(Issue(.error, "fixtures ≥ 60 words \(sixty)/\(cases.count) (\(pct(share(sixty)))) below \(pct(minSixtyWordShare))"))
        }
        if share(thirty) < minThirtyWordShare {
            issues.append(Issue(.error, "fixtures ≥ 30 words \(thirty)/\(cases.count) (\(pct(share(thirty)))) below \(pct(minThirtyWordShare))"))
        }
        if share(agent) < minAgentPromptShare {
            issues.append(Issue(.error, "agent-prompt \(agent)/\(cases.count) (\(pct(share(agent)))) below \(pct(minAgentPromptShare))"))
        }
        if share(oneWord) > maxOneWordShare {
            issues.append(Issue(.error, "one-word fixtures \(oneWord)/\(cases.count) (\(pct(share(oneWord)))) above \(pct(maxOneWordShare))"))
        }
        return issues
    }
}
