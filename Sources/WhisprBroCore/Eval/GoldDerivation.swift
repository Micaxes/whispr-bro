import Foundation

/// `whispr-bench gold` (plan §7.3): his ratings become golds and
/// annotations. Pure — fixtures and ratings in, a new fixture array plus a
/// readable diff out — so every rule below is pinned by test and the bench
/// only prints and writes.
///
/// The rules, in the order they apply to one fixture:
/// 1. **SHIP** on an output makes that output the `gold`
///    (`gold_source: "ship:<run_key>:<formatter>"`); a second, differing
///    SHIP is appended to `golds[]`, as is every `=` ("also fine"). A SHIP
///    is a verdict on an OUTPUT, so it leaves `annotations_status` where
///    it was — §7.3.4 flips it on `y` or an edit, and nothing else.
/// 2. A **`gold_edit`** wins over a SHIP — it is his own text, not a
///    formatter's — and sets `gold_source: "edit"` and
///    `annotations_status: "confirmed"`. The record's normalised
///    word-level edit distance from the output it was edited from (HTER)
///    comes back in the result, for calibration and for him.
/// 3. **`y`** confirms the fixture's annotations as they stand:
///    `annotations_status: "confirmed"`, and the `unrated` tag drops.
/// 4. A **WRONG tagged `dropped-fact` / `dropped-hedge`** turns that
///    candidate's raw→output deletions into `must_keep` drafts (weight 5 /
///    2) — unless he marked spans himself with `k`/`K`, which override.
/// 5. A deletion **adjacent to a correction cue** (`CorrectionCues`) drafts
///    a `repairs` entry.
/// 6. Fillers, stutters and `control` stay DERIVED — never written, so a
///    change to the derivation never silently moves his file's hash.
/// 7. Where a gold he accepted and a disfluency annotation DISAGREE, the
///    annotation bends to the gold, because his gold is the ground truth
///    — in either direction. A gold that keeps a run the row expects
///    collapsed contradicts it, and so does one that collapses past what
///    the row says it keeps; Fi charges the surplus copy and the missing
///    one alike, so both score the gold he just settled 0 on that axis.
///    The bend is all of the annotation: Fi's expected set is `fillers` ∪
///    `stutters`, so half a bend leaves the axis on and scores his own
///    gold 0 on the half still standing. A retained filler writes
///    `fillers: []` (`lint`'s own opt-out, which is all-or-nothing); a
///    contradicted stutter run drops that entry and leaves the rest of
///    his list. What a gold keeps is a COUNT of the copies it leaves of
///    the run, read at the occurrence the annotation names, so a gold
///    that collapses the run exactly as annotated — or removes the very
///    copy he marked and keeps another one of the same words — bends
///    nothing. The diff says what the gold left against what the
///    annotation asked for, and the bend — a machine's decision about his
///    annotations — drafts them.
///
/// Two refusals hold the whole thing honest: a **confirmed** gold or
/// annotation is never overwritten (a differing SHIP can only append to
/// `golds[]`), and two different edits for one fixture are a **conflict**
/// — listed, and that fixture left exactly as it was. A **draft**
/// annotation refuses nothing: where his new gold contradicts one, the
/// draft is dropped and named in the diff, because a gold he typed
/// outranks a span an agent guessed. "Confirmed" there is the
/// ANNOTATIONS' own status and nothing else: a gold-free row can carry
/// annotations he confirmed, and they are protected exactly as a seed's
/// are. Everything drafted lands as
/// `annotations_status: "draft"`, so `lint` warns and the report's
/// `DRAFT GOLDS: n/N` line never lets a draft read as validated.
public enum GoldDerivation {
    /// The text behind an `output_sha`. A rating record pins the output by
    /// digest, not by value (§7.2), so the derivation needs the runs he
    /// rated — or the fixtures' own `observed` column, which is the
    /// shipped output by construction.
    public struct Outputs: Sendable {
        private var byKey: [String: String] = [:]

        public init(runs: [EvalRun] = [], fixtures: [EvalCase] = []) {
            for run in runs {
                for column in run.columns {
                    for row in column.rows { add(fixtureId: row.id, text: row.out) }
                }
            }
            for c in fixtures {
                if let observed = c.observed { add(fixtureId: c.id, text: observed) }
                if !c.gold.isEmpty { add(fixtureId: c.id, text: c.gold) }
            }
        }

        public mutating func add(fixtureId: String, text: String) {
            byKey[Self.key(fixtureId, Rating.outputSha(text))] = text
        }

        public func text(fixtureId: String, outputSha: String) -> String? {
            byKey[Self.key(fixtureId, outputSha)]
        }

        public var count: Int { byKey.count }

        private static func key(_ id: String, _ sha: String) -> String { id + "\n" + sha }
    }

    /// One fixture's before / after plus the lines the dry-run prints.
    public struct Change: Sendable, Equatable {
        public let id: String
        public let before: EvalCase
        public let after: EvalCase
        public let notes: [String]
    }

    /// A fixture left untouched, and why.
    public struct Blocked: Sendable, Equatable {
        public let id: String
        public let reason: String
    }

    /// A record whose output could not be resolved (the run file it was
    /// rated from was not passed): nothing is derived from it.
    public struct Unresolved: Sendable, Equatable {
        public let id: String
        public let outputSha: String
        public let formatter: String
    }

    /// §7.3 rule 2's HTER: how far his edit moved the output.
    public struct EditDistance: Sendable, Equatable {
        public let id: String
        public let formatter: String
        public let outputSha: String
        /// (S + D + I) / N over canonical words, N = the GOLD's words —
        /// HTER's own denominator is the post-edit reference. A gold much
        /// shorter than the output can therefore push it above 1, which is
        /// why `outputWords` is carried and printed beside it.
        public let hter: Double
        public let edits: Int
        public let goldWords: Int
        public let outputWords: Int
    }

    public struct Result: Sendable, Equatable {
        public let cases: [EvalCase]
        public let changes: [Change]
        public let conflicts: [Blocked]
        public let protected: [Blocked]
        public let unresolved: [Unresolved]
        public let editDistances: [EditDistance]

        public var isEmpty: Bool { changes.isEmpty }

        /// The per-fixture before/after the dry run prints (`--write`
        /// prints the same thing and then writes it).
        public func render() -> String {
            var lines: [String] = []
            for change in changes {
                lines.append("\(change.id)")
                lines += change.notes.map { "  " + $0 }
            }
            if !conflicts.isEmpty {
                lines.append("")
                lines.append("conflicts (left untouched):")
                lines += conflicts.map { "  \($0.id): \($0.reason)" }
            }
            if !protected.isEmpty {
                lines.append("")
                lines.append("protected (confirmed already — not overwritten):")
                lines += protected.map { "  \($0.id): \($0.reason)" }
            }
            if !unresolved.isEmpty {
                lines.append("")
                lines.append("unresolved outputs (pass the run with --runs):")
                lines += unresolved.map { "  \($0.id): \($0.formatter) output_sha \($0.outputSha)" }
            }
            if !editDistances.isEmpty {
                lines.append("")
                lines.append("edit distance (HTER, his edit vs the output he edited):")
                lines += editDistances.map {
                    String(format: "  %@: %@ %.3f (%d edit(s) between a %d-word output and a %d-word gold)",
                           $0.id, $0.formatter, $0.hter, $0.edits, $0.outputWords, $0.goldWords)
                }
            }
            if lines.isEmpty { lines.append("no change") }
            return lines.joined(separator: "\n")
        }

        public var summary: String {
            "\(changes.count) fixture(s) changed · \(conflicts.count) conflict(s) · "
                + "\(protected.count) protected · \(unresolved.count) unresolved output(s)"
        }
    }

    /// What `gold --write` actually puts back, and what it holds. A
    /// derived annotation that fails `lint` is a scoring bug waiting to
    /// happen, so the plain `--write` refuses the whole file — but a
    /// rating session is 70 rows and one of them failing must not cost him
    /// the other 22 golds. `--skip-failing` writes every change that lints
    /// clean and hands back the rest, each with the error that holds it.
    public struct WriteSet: Sendable, Equatable {
        /// The whole file as it would go back: the derived fixture
        /// wherever it lints clean, the ORIGINAL row wherever it does not.
        public let cases: [EvalCase]
        /// The ids whose change is in `cases`.
        public let written: [String]
        /// The changes held back, with the lint error(s) that hold them.
        public let held: [Blocked]

        public init(cases: [EvalCase], written: [String], held: [Blocked]) {
            self.cases = cases
            self.written = written
            self.held = held
        }

        public func render() -> String {
            guard !held.isEmpty else { return "" }
            return (["held back (left exactly as they were — fix these by hand):"]
                    + held.map { "  \($0.id): \($0.reason)" }).joined(separator: "\n")
        }
    }

    /// Splits a derivation into what lints clean and what does not. A
    /// change is held back when its DERIVED row carries a `lint` error its
    /// ORIGINAL row did not: an error that was already in the file is not
    /// this pass's doing, and holding the change back would not fix it.
    public static func writable(_ result: Result) -> WriteSet {
        let byId = Dictionary(result.changes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cases: [EvalCase] = []
        var written: [String] = []
        var held: [Blocked] = []
        for c in result.cases {
            guard let change = byId[c.id] else { cases.append(c); continue }
            let before = Set(errors(change.before))
            let introduced = errors(change.after).filter { !before.contains($0) }
            if introduced.isEmpty {
                cases.append(c)
                written.append(c.id)
            } else {
                cases.append(change.before)
                held.append(Blocked(id: c.id, reason: introduced.joined(separator: " · ")))
            }
        }
        return WriteSet(cases: cases, written: written, held: held)
    }

    private static func errors(_ c: EvalCase) -> [String] {
        EvalLint.row(c).filter { $0.severity == .error }.map(\.message)
    }

    /// Whether `gold --write` writes the set `writable` handed it, and the
    /// lines it prints saying why. That sort IS the decision: a change
    /// THIS pass derived that fails `lint` is a scoring bug on its way
    /// into his file, so the write refuses and names the rows. An error
    /// the file already carried is not this pass's doing — holding a
    /// change back cannot fix a row the pass never touched, and refusing
    /// would cost him every gold that is clean for it (a `--skip-failing`
    /// re-run writes this same file, byte for byte). So that path writes,
    /// and prints the errors as the warnings they are.
    public struct WriteDecision: Sendable, Equatable {
        public let writes: Bool
        public let lines: [String]

        public init(writes: Bool, lines: [String]) {
            self.writes = writes
            self.lines = lines
        }

        public func render() -> String { lines.joined(separator: "\n") }
    }

    /// - Parameters:
    ///   - set: what `writable` sorted out of the derivation.
    ///   - issues: `lint` over `set.cases` — the file exactly as it would
    ///     go back, so every error here belongs to a row this pass left
    ///     alone.
    ///   - changes: how many fixtures the derivation changed at all.
    public static func writeDecision(_ set: WriteSet, issues: [EvalLint.Issue], changes: Int,
                                     skipFailing: Bool, lintPath: String) -> WriteDecision {
        guard set.held.isEmpty || skipFailing else {
            return WriteDecision(writes: false, lines:
                ["refusing to write: \(set.held.count) of \(changes) changed fixture(s) derive a lint error"]
                + set.held.map { "  \($0.id): \($0.reason)" }
                + ["re-run with --skip-failing to write the other \(set.written.count) "
                    + "and hold these back, or fix the rows by hand"])
        }
        let errors = issues.filter { $0.severity == .error }
        guard !errors.isEmpty else { return WriteDecision(writes: true, lines: []) }
        return WriteDecision(writes: true, lines:
            ["\(errors.count) lint error(s) this pass did not introduce — the "
                + "\(set.written.count) change(s) here are clean, so they are written:"]
            + errors.map { "  " + $0.description }
            + ["fix those rows by hand (`whispr-bench lint \(lintPath)`)"])
    }

    /// Applies §7.3 to a fixture set. `cases` keeps its order; only the
    /// fixtures with ratings can move.
    public static func derive(fixtures: [EvalCase], ratings: [Rating], outputs: Outputs) -> Result {
        var byFixture: [String: [Rating]] = [:]
        for rating in ratings where rating.isTriage { byFixture[rating.fixtureId, default: []].append(rating) }

        var cases: [EvalCase] = []
        var changes: [Change] = []
        var conflicts: [Blocked] = []
        var protected: [Blocked] = []
        var unresolved: [Unresolved] = []
        var distances: [EditDistance] = []

        for fixture in fixtures {
            guard let records = byFixture[fixture.id], !records.isEmpty else {
                cases.append(fixture)
                continue
            }
            let outcome = apply(fixture, records: records, outputs: outputs)
            cases.append(outcome.fixture)
            conflicts += outcome.conflicts
            protected += outcome.protected
            unresolved += outcome.unresolved
            distances += outcome.distances
            if outcome.fixture != fixture {
                changes.append(Change(id: fixture.id, before: fixture, after: outcome.fixture,
                                      notes: outcome.notes))
            }
        }
        return Result(cases: cases, changes: changes, conflicts: conflicts, protected: protected,
                      unresolved: unresolved, editDistances: distances)
    }

    // MARK: - One fixture

    private struct Outcome {
        var fixture: EvalCase
        var notes: [String] = []
        var conflicts: [Blocked] = []
        var protected: [Blocked] = []
        var unresolved: [Unresolved] = []
        var distances: [EditDistance] = []
    }

    private static func apply(_ fixture: EvalCase, records: [Rating], outputs: Outputs) -> Outcome {
        var out = Outcome(fixture: fixture)
        // A confirmed gold is his, already: it is never replaced, only
        // added to. A gold-free fixture has no gold to protect, whatever
        // its status says.
        let goldIsProtected = !fixture.isGoldFree && fixture.annotationsStatus == .confirmed
        // The ANNOTATIONS' status says nothing about the gold, so it
        // carries no `isGoldFree` clause: gold-free is exactly the
        // population this loop works on (a history export writes
        // `history-unrated` on every row), and a `must_keep` he CONFIRMED
        // on such a row is as much his as one on a seed. Reading the
        // GOLD's protection here is how a confirmed weight-5 span came to
        // be deleted as though it were a draft.
        let annotationsAreHis = fixture.annotationsStatus == .confirmed
        // Drafting INTO a fixture is the other direction and keeps the
        // gold's clause: `history-export` writes no `annotations_status`
        // at all, so a fresh export row reads `confirmed` (EvalCase's
        // default) while carrying no annotations to confirm — and a loop
        // that refused to draft a `must_keep` there would refuse it on
        // every row it exists for. An addition is named in the diff and
        // flips the status to `draft`; a deletion is not recoverable, so
        // only that side reads the annotations' status alone.
        let annotationsAreProtected = annotationsAreHis && !fixture.isGoldFree

        // Rule 2 first: two different edits for one fixture is a conflict,
        // and a conflict means this fixture does not move at all.
        let edits = uniqued(records.compactMap { $0.goldEdit?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        if edits.count > 1 {
            out.conflicts.append(Blocked(id: fixture.id,
                                         reason: "\(edits.count) different gold edits — "
                                             + edits.map { "\"\($0)\"" }.joined(separator: " vs ")))
            return out
        }

        var gold = fixture.gold
        var goldSource = fixture.goldSource
        var golds = fixture.golds
        var goldWasSet = false
        var drafted = false
        var confirmed = false

        /// Appends a second opinion to `golds[]` (never the gold itself).
        func alternate(_ text: String, source: String) {
            guard text != gold, !golds.contains(text) else { return }
            golds.append(text)
            out.notes.append("+ golds[] \(quote(text))  (\(source))")
        }

        /// One candidate gold, under the rules that decide whether it may
        /// become THE gold or only join `golds[]`. `confirms` is the §7.3.4
        /// list — an edit is his own text, so it confirms; a SHIP is a
        /// verdict on an OUTPUT and leaves `annotations_status` where it
        /// was (the loop has `y` for that act).
        func offer(_ candidate: String, source: String, note: String, confirms: Bool = false) {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // A gold carrying a numeral the speaker never said is a `lint`
            // error nothing can absorb — his call, so it is listed and
            // nothing moves.
            if let why = invention(fixture, candidate: text) {
                out.conflicts.append(Blocked(id: fixture.id,
                                             reason: "\(source) contradicts raw: \(why)"))
                return
            }
            // A CONFIRMED annotation outranks a rating: either the
            // annotation is wrong or the rating was a misclick, and both
            // are his to settle. A DRAFT one does not — §7.3.4 makes a
            // draft precisely the thing a human overrides — so the gold
            // wins and the contradicting drafts are dropped below.
            if annotationsAreHis, let why = annotationContradiction(fixture, candidate: text) {
                out.conflicts.append(Blocked(id: fixture.id,
                                             reason: "\(source) contradicts the fixture's annotations: \(why)"))
                return
            }
            // This pass already chose one (§7.3 rule 1: a second, differing
            // SHIP appends).
            if goldWasSet { return alternate(text, source: source) }
            // No gold at all: the first candidate is it.
            if fixture.isGoldFree {
                gold = text
                goldSource = source
                goldWasSet = true
                confirmed = confirmed || confirms
                out.notes.append(note)
                return
            }
            // A confirmed gold is never overwritten — only added to.
            if goldIsProtected {
                guard text != gold else { return }
                alternate(text, source: source)
                out.protected.append(Blocked(id: fixture.id,
                                             reason: "gold \(quote(gold)) is confirmed (\(fixture.goldSource)); "
                                                 + "\(source) appended to golds[]"))
                return
            }
            // A draft gold nobody has checked: his rating replaces it.
            guard text != gold else { return }
            out.notes.append("gold \(quote(gold)) → \(quote(text))  (\(fixture.goldSource) → \(source))")
            gold = text
            goldSource = source
            goldWasSet = true
            confirmed = confirmed || confirms
        }

        // The edit first, so a SHIP on the same fixture can only append.
        if let edit = edits.first {
            offer(edit, source: editSource, note: "gold ← edit \(quote(edit))", confirms: true)
            for record in records where record.goldEdit != nil {
                guard let from = outputs.text(fixtureId: fixture.id, outputSha: record.outputSha) else {
                    out.unresolved.append(Unresolved(id: fixture.id, outputSha: record.outputSha,
                                                     formatter: record.formatter))
                    continue
                }
                // Measured against the text HE wrote, not against whatever
                // the gold ended up being: a rejected edit still says how
                // much work the output cost him.
                out.distances.append(editDistance(id: fixture.id, formatter: record.formatter,
                                                  outputSha: record.outputSha, from: from, to: edit))
            }
        }
        // Rule 1: every SHIP, in the order he pressed them.
        for record in records where record.verdict == .ship {
            guard let text = outputs.text(fixtureId: fixture.id, outputSha: record.outputSha) else {
                out.unresolved.append(Unresolved(id: fixture.id, outputSha: record.outputSha,
                                                 formatter: record.formatter))
                continue
            }
            let source = shipSource(runKey: record.runKey, formatter: record.formatter)
            offer(text, source: source, note: "gold ← \(source) \(quote(text))")
        }
        // `=` — "also fine": an alternate gold, never the gold.
        for record in records {
            guard let alt = record.altGold?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty else { continue }
            if alt == gold || golds.contains(alt) { continue }
            golds.append(alt)
            out.notes.append("+ golds[] \(quote(alt))  (also fine)")
        }

        // Rule 4: his marks win; else the deletions of a WRONG candidate
        // he tagged as dropping something.
        var mustKeep = fixture.mustKeep
        var repairs = fixture.repairs
        // A gold he settled this pass outranks a DRAFT annotation nobody
        // checked (§7.3.4). The draft an agent guessed does not get to
        // refuse his text — it is dropped, named in the diff so he can put
        // it back, and the derived set still passes `lint`.
        if goldWasSet, !annotationsAreHis {
            let tokens = Align.canonicalTokens(gold)
            mustKeep.removeAll { keep in
                guard Align.locate(keep.span, in: tokens) == nil else { return false }
                out.notes.append("− must_keep \(quote(keep.span))  [draft; the new gold drops it]")
                return true
            }
            repairs.removeAll { repair in
                guard Align.locate(repair.repair, in: tokens) == nil
                        || Align.locate(repair.reparandum, in: tokens) != nil else { return false }
                out.notes.append("− repairs \(quote(repair.reparandum))  [draft; the new gold breaks it]")
                return true
            }
        }
        let marked = records.flatMap(\.mustKeep)
        var drafts: [EvalCase.MustKeep] = marked
        if drafts.isEmpty {
            for record in records where record.verdict == .wrong {
                let weight = record.tags.contains(droppedFactTag) ? EvalCase.MustKeep.factWeight
                    : record.tags.contains(droppedHedgeTag) ? EvalCase.MustKeep.hedgeWeight : nil
                guard let weight else { continue }
                guard let text = outputs.text(fixtureId: fixture.id, outputSha: record.outputSha) else {
                    out.unresolved.append(Unresolved(id: fixture.id, outputSha: record.outputSha,
                                                     formatter: record.formatter))
                    continue
                }
                for span in RatingScreen.droppedSpans(reference: fixture.raw, out: text) {
                    drafts.append(EvalCase.MustKeep(span: span, weight: weight))
                }
            }
        }
        let raw = Align.canonicalTokens(fixture.raw)
        let goldTokens = Align.canonicalTokens(gold)
        for draft in drafts {
            // A span `lint` could not find is a span the scorer could not
            // score: it never reaches his file.
            guard Align.locate(draft.span, in: raw) != nil else { continue }
            guard gold.isEmpty || Align.locate(draft.span, in: goldTokens) != nil else { continue }
            if let existing = mustKeep.firstIndex(where: { $0.span == draft.span }) {
                guard !annotationsAreProtected, mustKeep[existing].weight < draft.weight else { continue }
                out.notes.append("must_keep \(quote(draft.span)) w\(mustKeep[existing].weight) → w\(draft.weight)")
                mustKeep[existing] = draft
                drafted = true
                continue
            }
            guard !annotationsAreProtected else {
                out.protected.append(Blocked(id: fixture.id,
                                             reason: "annotations are confirmed; must_keep \(quote(draft.span)) not added"))
                continue
            }
            mustKeep.append(draft)
            out.notes.append("+ must_keep \(quote(draft.span)) (w\(draft.weight))"
                             + (marked.isEmpty ? "  [drafted from the deletions]" : "  [his mark]"))
            drafted = true
        }

        // Rule 5: a deletion beside a correction cue is a repair, drafted
        // from the raw→gold diff (so it only fires once a gold exists).
        if !gold.isEmpty, !annotationsAreProtected {
            for repair in draftRepairs(raw: fixture.raw, gold: gold, language: fixture.language)
            where !repairs.contains(where: { $0.reparandum == repair.reparandum }) {
                repairs.append(repair)
                out.notes.append("+ repairs \(quote(repair.reparandum)) → \(quote(repair.repair))  [drafted from a cue]")
                drafted = true
            }
        }

        // Rule 7: a gold he ACCEPTED against a disfluency annotation that
        // disagrees with it. His gold is the ground truth, so the
        // annotation bends to it and never the other way round — and the
        // WHOLE annotation bends, because Fi's expected set is `fillers` ∪
        // `stutters`: turning the filler half off while an annotated
        // stutter run the same gold contradicts stays on leaves the axis
        // on and scores his own gold 0 on that run.
        //
        // Disagreement is a COUNT of the copies the gold leaves, in BOTH
        // directions (`contradicts`): a gold that collapses "a like a
        // a" to "a like a" where the annotation keeps "like a"
        // holds one copy too many, one that collapses it to "a" holds
        // one too few, and Fi charges the surplus and the deficit alike.
        // A run collapsed exactly as annotated matches its `keep` and
        // bends nothing.
        //
        // The halves bend differently because `lint` is strict about only
        // one of them. A retained filler is a `lint` error whose only
        // opt-out is the empty list, so the filler half is all-or-nothing
        // (`fillers: []`, the fixture that keeps its "Uh" on purpose) —
        // without it one retained filler refuses the whole `--write`, 22
        // good golds lost to one "Uh". A retained stutter run breaks no
        // `lint` rule, so only that entry goes and the rest of his list
        // stands.
        //
        // An annotation he CONFIRMED never reaches here: `offer` refuses a
        // candidate that contradicts one and lists it as a conflict with
        // the row untouched. What is DERIVED is nobody's annotation — a
        // history export writes `confirmed` and no annotations at all — so
        // it bends whatever the status says.
        //
        // The bend is a MACHINE decision about his annotations, so it
        // drafts them (§7.3.4): an Fi axis a rating loop switched off has
        // not been checked by anyone, and leaving it `confirmed` would
        // read as though it had.
        var fillers = fixture.fillers
        var stutters = fixture.stutters
        if goldWasSet {
            let rawTokens = Align.canonicalTokens(fixture.raw)
            let opsA = Align.align(rawTokens, Align.canonicalTokens(gold)).opsA
            let keptFillers = EvalLint.retainedFillers(raw: fixture.raw, gold: gold,
                                                       language: fixture.language, fillers: fillers)
            let bentStutters = contradictedStutters(raw: fixture.raw, gold: gold, stutters: stutters)
            if !keptFillers.isEmpty {
                let expected = fillers ?? EvalCase.deriveFillers(raw: fixture.raw, gold: gold,
                                                                 language: fixture.language)
                // Counted on `lint`'s identity, not the synthesized one:
                // the kept list carries RAW's surface casing and his
                // annotation carries his own, so an "uh" he wrote against a
                // raw that spells it "Uh" reads as a second, different
                // filler — and the line below then names a removal the row
                // never lost.
                let kept = Set(keptFillers.map(fillerKey))
                let alsoLost = expected.filter { !kept.contains(fillerKey($0)) }.count
                fillers = []
                drafted = true
                // What the gold KEPT of each marker, not the span the
                // annotation named: half a marker bends too, and "this
                // gold keeps 'you know'" over a gold carrying only the
                // "you" names a phrase the diff's reader cannot find.
                out.notes.append("fillers: [] — this gold keeps "
                                 + "\(list(keptFillers, in: rawTokens, opsA: opsA)); "
                                 + "`lint`'s opt-out is the whole list, so "
                                 + (alsoLost == 0 ? "nothing else was expected here"
                                    : "the \(alsoLost) filler(s) it does remove stop being scored too"))
            }
            if !bentStutters.isEmpty {
                stutters = (stutters ?? []).filter { !bentStutters.contains($0) }
                drafted = true
                // What the gold left of the run against what the annotation
                // said it would leave — one line per entry, because that is
                // the only sentence true of all three shapes: a run left
                // standing, one half collapsed, and one collapsed past its
                // `keep`.
                for (i, run) in bentStutters.enumerated() {
                    let kept = EvalLint.survivors(of: run.span, occurrence: run.occurrence,
                                                  in: rawTokens, opsA: opsA) ?? []
                    out.notes.append("− stutters \(name(run))  [this gold keeps "
                                     + "\(phrase(kept, of: rawTokens)) where the annotation keeps "
                                     + "\(phrase(run.keep))]"
                                     + (i == bentStutters.count - 1 && stutters?.isEmpty == true
                                        ? "; stutters: [] — the list is empty now" : ""))
                }
            }
            if !keptFillers.isEmpty || !bentStutters.isEmpty {
                let left = (fillers ?? EvalCase.deriveFillers(raw: fixture.raw, gold: gold,
                                                              language: fixture.language)).count
                    + (stutters ?? EvalCase.deriveStutters(raw: fixture.raw, gold: gold)).count
                out.notes.append(left == 0
                                 ? "Fi is off for this row — nothing is expected removed any more"
                                 : "Fi still expects \(left) removal(s) this gold does make")
            }
        }

        // Rule 3: `y` — the annotations are right as they stand. A confirm
        // covers what he was LOOKING at, so it does not bless an
        // annotation this same pass drafted behind it.
        var tags = fixture.tags
        if records.contains(where: \.isConfirm) {
            confirmed = true
            if let at = tags.firstIndex(of: HistoryExport.unratedTag) {
                tags.remove(at: at)
                out.notes.append("− tag \(HistoryExport.unratedTag)  [confirmed]")
            }
            out.notes.append(drafted ? "confirm held — annotations drafted in this same pass" : "annotations confirmed")
        } else if goldWasSet, let at = tags.firstIndex(of: HistoryExport.unratedTag) {
            // A fixture with a gold is not unrated any more, whatever the
            // annotations still owe.
            tags.remove(at: at)
            out.notes.append("− tag \(HistoryExport.unratedTag)")
        }

        // Drafted annotations mean the ANNOTATIONS are drafts, even when
        // the gold itself came from a SHIP: the status is about what a
        // person has checked.
        var status = fixture.annotationsStatus
        if drafted {
            status = .draft
        } else if confirmed {
            status = .confirmed
        }
        if status != fixture.annotationsStatus {
            out.notes.append("annotations_status \(fixture.annotationsStatus.rawValue) → \(status.rawValue)")
        }

        let after = EvalCase(id: fixture.id, raw: fixture.raw, gold: gold, note: fixture.note,
                             audio: fixture.audio, golds: golds, tags: tags, register: fixture.register,
                             level: fixture.level, language: fixture.language, control: fixture.control,
                             fillers: fillers, stutters: stutters, repairs: repairs,
                             mustKeep: mustKeep, alternates: fixture.alternates, maxMs: fixture.maxMs,
                             source: fixture.source, goldSource: goldSource, annotationsStatus: status,
                             observed: fixture.observed, observedMs: fixture.observedMs)
        // `control`, `fillers` and `stutters` re-derive from raw and gold
        // and are never written as VALUES — the one exception is rule 7
        // above, which writes no derived list either: an opt-out, and his
        // own annotation minus the entries his gold contradicts. Saying
        // where a derived field changed keeps the diff honest.
        if after.isControl != fixture.isControl {
            out.notes.append("control (derived) \(fixture.isControl) → \(after.isControl)")
        }
        out.fixture = after
        return out
    }

    /// Why a candidate gold cannot be this fixture's gold, or nil when it
    /// can: the `lint` rules that read `gold` — every `must_keep` span
    /// must survive in it, a scored repair's `repair` must be in it with
    /// its `reparandum` gone, and it may carry no numeral the speaker did
    /// not say.
    ///
    /// Only the numeral rule is unconditional (`invention`). The annotation
    /// half (`annotationContradiction`) refuses a candidate only where the
    /// annotations are CONFIRMED: a draft that disagrees with his own gold
    /// is dropped, not obeyed.
    public static func contradiction(_ fixture: EvalCase, candidate: String) -> String? {
        annotationContradiction(fixture, candidate: candidate) ?? invention(fixture, candidate: candidate)
    }

    /// The `lint` rules a candidate gold breaks against the fixture's
    /// `must_keep` / `repairs`, or nil when it breaks none.
    public static func annotationContradiction(_ fixture: EvalCase, candidate: String) -> String? {
        let tokens = Align.canonicalTokens(candidate)
        for keep in fixture.mustKeep where Align.locate(keep.span, in: tokens) == nil {
            return "must_keep \(quote(keep.span)) is not in it"
        }
        for repair in fixture.repairs {
            if Align.locate(repair.repair, in: tokens) == nil {
                return "repair \(quote(repair.repair)) is not in it"
            }
            if Align.locate(repair.reparandum, in: tokens) != nil {
                return "the reparandum \(quote(repair.reparandum)) survives in it"
            }
        }
        // Fi's own contradiction: a candidate that keeps what the
        // annotation says must go would score itself 0 on that axis.
        // Only an annotation somebody WROTE counts here — `fillers` and
        // `stutters` derive from raw and gold when the field is absent,
        // and a derived expectation is nobody's to protect. Reading it
        // here would refuse his gold on every history row whose accepted
        // output keeps an "uh" (an export writes `confirmed` and no
        // annotations at all): the failure rule 7 exists to prevent.
        // The raw→candidate alignment is only wanted for the message —
        // a row with no annotation to contradict pays nothing for it.
        if fixture.fillers != nil,
           let filler = EvalLint.retainedFillers(raw: fixture.raw, gold: candidate,
                                                 language: fixture.language,
                                                 fillers: fixture.fillers).first {
            let rawTokens = Align.canonicalTokens(fixture.raw)
            return "it keeps the filler "
                + "\(list([filler], in: rawTokens, opsA: Align.align(rawTokens, tokens).opsA)) "
                + "the annotations expect removed"
        }
        if let run = contradictedStutters(raw: fixture.raw, gold: candidate,
                                          stutters: fixture.stutters).first {
            let rawTokens = Align.canonicalTokens(fixture.raw)
            let kept = EvalLint.survivors(of: run.span, occurrence: run.occurrence, in: rawTokens,
                                          opsA: Align.align(rawTokens, tokens).opsA) ?? []
            return "of the stutter run \(quote(run.span)) it keeps \(phrase(kept, of: rawTokens)) "
                + "where the annotations keep \(phrase(run.keep))"
        }
        return nil
    }

    // MARK: - What a gold contradicts, at the occurrence the annotation names

    /// The annotated stutter runs a candidate gold CONTRADICTS: the copies
    /// it leaves of the run are not the copies the entry's `keep` states,
    /// counted at the occurrence the entry names
    /// (`EvalCase.Stutter.occurrence` disambiguates a run that repeats).
    ///
    /// Read in the GOLD instead, the span alone cannot tell two runs of
    /// the same words apart: a row with two "and and" runs whose gold
    /// collapses the first and keeps the second reads as keeping both,
    /// drops both entries, and stops scoring the removal the gold made.
    static func contradictedStutters(raw: String, gold: String,
                                     stutters: [EvalCase.Stutter]?) -> [EvalCase.Stutter] {
        guard let stutters, !stutters.isEmpty, !gold.isEmpty else { return [] }
        let rawTokens = Align.canonicalTokens(raw)
        let opsA = Align.align(rawTokens, Align.canonicalTokens(gold)).opsA
        return stutters.filter {
            contradicts($0.span, keep: $0.keep, occurrence: $0.occurrence, in: rawTokens, opsA: opsA)
        }
    }

    /// A filler's identity as `lint` reads it: the word lowercased, and
    /// which of its occurrences in raw.
    private static func fillerKey(_ filler: EvalCase.Filler) -> String {
        "\(filler.span.lowercased())#\(filler.occurrence)"
    }

    /// Do the copies the gold leaves of `span`'s `occurrence`-th run in raw
    /// DIFFER from the copies `keep` states — the contradiction Fi
    /// charges, asked the way Fi asks it?
    ///
    /// Rule 7 exists so a gold HE accepted outranks an annotation that
    /// disagrees with it, and disagreement has two directions.
    /// `QualityScore.fillerRemoval` holds an EXPLICIT span to its own
    /// `keep`: a copy too many is a run left standing — the surplus it
    /// charges — and a copy too few is a word the annotation states
    /// survives that the gold cut, which is no collapse at all and credits
    /// the group nothing either. So a gold that collapses "a like a
    /// a" to "a like a" against a `keep` of "like a" contradicts
    /// the annotation, a gold that collapses it to "a" contradicts it
    /// just as much, and both score his own accepted gold 0 on Fi and fail
    /// `lint`'s invariant (§9) — which is how one row holds a whole 70-row
    /// `--write` back. "Did MORE survive than `keep` allows" bends the
    /// first and leaves the second standing exactly as before.
    ///
    /// So the copies are COUNTED, per form and on the canonical identity
    /// Fi counts them on; order is not part of the question, because a
    /// count is what a collapse leaves. A run the gold collapses exactly as
    /// annotated matches its `keep` and bends nothing. A filled pause is
    /// the same question with the count at zero (Fi reads a filler's
    /// `keep` as `""`): every copy is a surplus, so half a marker bends
    /// too, and no copy can ever be missing.
    ///
    /// A span raw does not carry at that occurrence stands nowhere — it is
    /// a `lint` error of its own (`'span' not found in raw`), and a bend
    /// off one would be a guess.
    private static func contradicts(_ span: String, keep: String, occurrence: Int,
                                    in rawTokens: [EvalToken], opsA: [AlignOp]) -> Bool {
        guard let kept = EvalLint.survivors(of: span, occurrence: occurrence,
                                            in: rawTokens, opsA: opsA) else { return false }
        var allowed: [String: Int] = [:]
        for token in Align.canonicalTokens(keep) { allowed[token.canonical, default: 0] += 1 }
        var survived: [String: Int] = [:]
        for i in kept { survived[rawTokens[i].canonical, default: 0] += 1 }
        return survived != allowed
    }

    /// A numeral in the candidate the speaker never said (§3.1) — a `lint`
    /// error no annotation edit can absorb, so it refuses the candidate
    /// whatever the annotations' status.
    public static func invention(_ fixture: EvalCase, candidate: String) -> String? {
        var said = Set(Align.canonicalTokens(fixture.raw).map(\.canonical))
        for alternate in fixture.alternates {
            for form in alternate.to { said.formUnion(Align.canonicalTokens(form).map(\.canonical)) }
        }
        for token in Align.canonicalTokens(candidate) where token.isNumeral && !said.contains(token.canonical) {
            return "it carries the numeral '\(token.canonical)', which is not in raw"
        }
        return nil
    }

    // MARK: - Pieces

    public static let editSource = "edit"
    public static let droppedFactTag = "dropped-fact"
    public static let droppedHedgeTag = "dropped-hedge"

    /// `ship:<run_key>:<formatter>` — §3.1's `gold_source` for a gold he
    /// accepted as it was produced.
    public static func shipSource(runKey: String, formatter: String) -> String {
        "ship:\(runKey):\(formatter)"
    }

    /// HTER: word-level (S + D + I) between the output he opened the
    /// editor on and the gold he saved, over the gold's word count (the
    /// post-edit reference — HTER's own denominator). 0 when he changed
    /// nothing, 1.0 when every word moved.
    public static func editDistance(id: String, formatter: String, outputSha: String,
                                    from output: String, to gold: String) -> EditDistance {
        let a = Align.canonicalTokens(output)
        let b = Align.canonicalTokens(gold)
        let result = Align.align(a, b)
        let words = max(b.count, 1)
        return EditDistance(id: id, formatter: formatter, outputSha: outputSha,
                            hter: EvalRun.round(Double(result.errors) / Double(words), places: 3),
                            edits: result.errors, goldWords: b.count, outputWords: a.count)
    }

    /// §7.3 rule 5. A maximal run of raw words the gold drops, with a
    /// correction cue inside it (or starting right after it), is a
    /// self-correction: the abandoned words are the reparandum, what
    /// follows to the end of that sentence is the repair. Only drafts that
    /// would pass `lint` are returned — the reparandum must be in raw and
    /// gone from gold, the repair must be in gold — so `gold --write`
    /// can never leave his file failing its own linter.
    public static func draftRepairs(raw: String, gold: String,
                                    language: DictationLanguage = .english) -> [EvalCase.Repair] {
        let rawTokens = Align.canonicalTokens(raw)
        let goldTokens = Align.canonicalTokens(gold)
        guard !rawTokens.isEmpty, !goldTokens.isEmpty else { return [] }
        let cues = CorrectionCues.promptPhrases(for: language)
            .map { Align.canonicalTokens($0).map(\.canonical) }
            .filter { !$0.isEmpty }

        var deleted = Set<Int>()
        for op in Align.align(rawTokens, goldTokens).ops {
            if case .del(let i) = op { deleted.insert(i) }
        }
        var drafts: [EvalCase.Repair] = []
        var i = 0
        while i < rawTokens.count {
            guard deleted.contains(i) else { i += 1; continue }
            var end = i
            while end + 1 < rawTokens.count, deleted.contains(end + 1) { end += 1 }
            defer { i = end + 1 }
            // The cue: inside the run, or opening the words right after it.
            guard let cue = cueRange(cues, in: rawTokens, searching: i...min(end + 3, rawTokens.count - 1)) else {
                continue
            }
            // The reparandum runs to the end of the abandoned words or
            // the end of the cue, whichever comes later ("Tuesday, I mean").
            let reparandumEnd = max(end, cue.upperBound - 1)
            guard reparandumEnd + 1 < rawTokens.count else { continue }
            let reparandum = surface(rawTokens[i...reparandumEnd])
            let repair = surface(rawTokens[(reparandumEnd + 1)...sentenceEnd(rawTokens, from: reparandumEnd + 1)])
            guard Align.locate(reparandum, in: rawTokens) != nil,
                  Align.locate(reparandum, in: goldTokens) == nil,
                  Align.locate(repair, in: goldTokens) != nil else { continue }
            drafts.append(EvalCase.Repair(reparandum: reparandum, repair: repair))
        }
        return drafts
    }

    /// The first cue occurrence whose tokens start inside `window`.
    private static func cueRange(_ cues: [[String]], in tokens: [EvalToken],
                                 searching window: ClosedRange<Int>) -> Range<Int>? {
        for start in window.lowerBound...window.upperBound {
            for cue in cues where start + cue.count <= tokens.count {
                if (0..<cue.count).allSatisfy({ tokens[start + $0].canonical == cue[$0] }) {
                    return start..<(start + cue.count)
                }
            }
        }
        return nil
    }

    /// The last index of the sentence `from` opens: the first token
    /// carrying a stop or question mark, else the end of the text.
    private static func sentenceEnd(_ tokens: [EvalToken], from: Int) -> Int {
        for i in from..<tokens.count where tokens[i].trailingMarks.contains(where: { ".!?;".contains($0) }) {
            return i
        }
        return tokens.count - 1
    }

    private static func surface(_ tokens: ArraySlice<EvalToken>) -> String {
        tokens.map { EvalReport.surface($0) }.joined(separator: " ")
    }

    /// Filled pauses as the diff names them: what the gold LEFT of each one
    /// — not always the whole span, now that half a marker bends the axis
    /// — the span the annotation named it by, and which of its occurrences
    /// in raw when there is more than one.
    private static func list(_ fillers: [EvalCase.Filler], in rawTokens: [EvalToken],
                             opsA: [AlignOp]) -> String {
        fillers.map { filler in
            let at = filler.occurrence > 1 ? " (occurrence \(filler.occurrence))" : ""
            let kept = EvalLint.survivors(of: filler.span, occurrence: filler.occurrence,
                                          in: rawTokens, opsA: opsA) ?? []
            guard kept.count < Align.canonicalTokens(filler.span).count else {
                return quote(filler.span) + at
            }
            return phrase(kept, of: rawTokens) + " of " + quote(filler.span) + at
        }.joined(separator: ", ")
    }

    /// A stutter entry as the diff names it: the run, and which of its
    /// occurrences in raw when there is more than one.
    private static func name(_ run: EvalCase.Stutter) -> String {
        quote(run.span) + (run.occurrence > 1 ? " (occurrence \(run.occurrence))" : "")
    }

    /// Words in a diff line, quoted — or "nothing", which both sides of a
    /// bend can be: a gold may leave no copy of a run standing, and a
    /// filler's `keep` is always empty.
    private static func phrase(_ text: String) -> String {
        text.isEmpty ? "nothing" : quote(text)
    }

    /// The words at `indices`, as raw spells them. A span in a note is a
    /// word list, not a quotation — `EvalCase`'s own spans carry no
    /// punctuation (`EvalToken.cased`), and neither do these.
    private static func phrase(_ indices: [Int], of rawTokens: [EvalToken]) -> String {
        phrase(indices.map { rawTokens[$0].cased }.joined(separator: " "))
    }

    private static func uniqued(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted }
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: " ⏎ ") + "\""
    }
}
