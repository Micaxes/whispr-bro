import XCTest
@testable import WhisprBroCore

/// `whispr-bench lint` as data (plan §3.1, §9), in the three tiers the rules
/// have: **structural errors** — a span that is not where it says it is, an
/// annotation no acceptable gold could satisfy, a flag its own text
/// contradicts — **the invariant**, which is the scorer run with hypothesis
/// = gold and is the ONLY consistency check between an annotation and its
/// gold, and **warnings**, which never block. One fixture per rule, built so
/// exactly that rule fires; the seeds clear every one of them with the
/// set-level floors on.
final class EvalLintTests: XCTestCase {
    private func errors(_ c: EvalCase, repoGuard: Bool = false) -> [String] {
        EvalLint.lint([c], repoGuard: repoGuard).filter { $0.severity == .error }.map(\.message)
    }

    private func warnings(_ c: EvalCase) -> [String] {
        EvalLint.lint([c]).filter { $0.severity == .warning }.map(\.message)
    }

    // MARK: - The seeds are clean

    func testSeedsLintCleanWithFloors() {
        XCTAssertEqual(EvalLint.lint(EvalCase.seeds, floors: true, repoGuard: true), [])
        XCTAssertFalse(EvalLint.hasErrors([]))
    }

    func testFloorsArePinned() {
        XCTAssertEqual(EvalLint.minControlShare, 0.15)
        XCTAssertEqual(EvalLint.minSixtyWordShare, 0.20)
        XCTAssertEqual(EvalLint.minThirtyWordShare, 0.40)
        XCTAssertEqual(EvalLint.minAgentPromptShare, 0.60)
        XCTAssertEqual(EvalLint.maxOneWordShare, 0.10)
        XCTAssertEqual(EvalLint.historySourcePrefix, "history:")
    }

    // MARK: - Structural errors

    func testDuplicateIds() {
        let a = EvalCase(id: "a", raw: "um hi", gold: "Hi.")
        let issues = EvalLint.lint([a, a])
        XCTAssertEqual(issues, [EvalLint.Issue(.error, id: "a", "duplicate id")])
        XCTAssertTrue(EvalLint.hasErrors(issues))
        XCTAssertEqual(issues[0].description, "error: [a] duplicate id")
    }

    func testEmptyRaw() {
        XCTAssertEqual(errors(EvalCase(id: "e", raw: "  ", gold: "")), ["empty raw"])
    }

    func testFillerSpanMustBeInRaw() {
        // A span that is not in raw is both a structural error and, since
        // the scorer counts it expected and missed, an Fi miss on the gold.
        let c = EvalCase(id: "f", raw: "so we ship it", gold: "So we ship it.", fillers: [.init(span: "uh")])
        XCTAssertEqual(errors(c), [
            "filler 'uh' (occurrence 1) not found in raw",
            "gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 [MISSED] — Fi missed 'uh'",
        ])
        // The second "um" of one: the occurrence is checked, not only the word.
        let twice = EvalCase(id: "f2", raw: "um so we ship it", gold: "So we ship it.", fillers: [.init(span: "um", occurrence: 2)])
        XCTAssertEqual(errors(twice).first, "filler 'um' (occurrence 2) not found in raw")
    }

    func testStutterSpanAndKeep() {
        let missing = EvalCase(id: "s", raw: "we ship it", gold: "We ship it.", stutters: [.init(span: "the the", keep: "the")])
        XCTAssertEqual(errors(missing).first, "stutter 'the the' (occurrence 1) not found in raw")
        let badKeep = EvalCase(id: "s2", raw: "and a and sixty two", gold: "and 62",
                               stutters: [.init(span: "and a and", keep: "or")])
        XCTAssertEqual(errors(badKeep).first, "stutter keep 'or' is not a subsequence of 'and a and'")
        // An in-order subsequence keep is fine ("my l laptop" keeps "my laptop").
        let ok = EvalCase(id: "s3", raw: "on my l laptop today", gold: "On my laptop today.",
                          stutters: [.init(span: "my l laptop", keep: "my laptop")])
        XCTAssertEqual(errors(ok), [])
    }

    func testRepairSpans() {
        let raw = "meet on Tuesday, I mean on Wednesday"
        let noReparandum = EvalCase(id: "r", raw: raw, gold: "Meet on Wednesday.",
                                    repairs: [.init(reparandum: "on Monday, I mean", repair: "on Wednesday")])
        XCTAssertEqual(errors(noReparandum).first, "repair reparandum 'on Monday, I mean' not found in raw")
        let noRepair = EvalCase(id: "r2", raw: raw, gold: "Meet on Saturday.",
                                repairs: [.init(reparandum: "on Tuesday, I mean", repair: "on Sunday")])
        XCTAssertEqual(errors(noRepair).first, "repair 'on Sunday' not found in gold")
        let ok = EvalCase(id: "r4", raw: raw, gold: "Meet on Wednesday.",
                          repairs: [.init(reparandum: "on Tuesday, I mean", repair: "on Wednesday")])
        XCTAssertEqual(errors(ok), [])
    }

    func testMustKeepSpans() {
        let notInRaw = EvalCase(id: "m", raw: "try some benchmarking", gold: "Try some benchmarking.",
                                mustKeep: [.init(span: "I don't know,")])
        XCTAssertEqual(errors(notInRaw).prefix(2), ["must_keep 'I don't know,' not found in raw",
                                                   "must_keep 'I don't know,' not found in gold"])
        let notInGold = EvalCase(id: "m2", raw: "I don't know, try some benchmarking", gold: "Try some benchmarking.",
                                 mustKeep: [.init(span: "I don't know,")])
        XCTAssertEqual(errors(notInGold).first, "must_keep 'I don't know,' not found in gold")
        let zeroWeight = EvalCase(id: "m3", raw: "I don't know, try some benchmarking", gold: "I don't know, try some benchmarking.",
                                  mustKeep: [.init(span: "I don't know,", weight: 0)])
        XCTAssertEqual(errors(zeroWeight), ["must_keep 'I don't know,' weight 0 < 1"])
    }

    func testAMustKeepOrRepairNeedsONEAcceptableGold() {
        // The structural rule asks only that some acceptable gold could
        // carry the span — the scorer scores against the best of them.
        // Which gold does, and what the primary one costs, is the
        // invariant's business below.
        let none = EvalCase(id: "m4", raw: "I don't know, try some benchmarking", gold: "Try some benchmarking.",
                            golds: ["Do the research."], mustKeep: [.init(span: "I don't know,")])
        XCTAssertEqual(none.acceptableGolds.count, 2)
        XCTAssertEqual(errors(none).first, "must_keep 'I don't know,' not found in any acceptable gold")
        let alternate = EvalCase(id: "m5", raw: "I don't know, try some benchmarking", gold: "Try some benchmarking.",
                                 golds: ["I don't know, try some benchmarking."], mustKeep: [.init(span: "I don't know,")])
        XCTAssertFalse(errors(alternate).contains { $0.hasSuffix("not found in any acceptable gold") })
        // …and the invariant still holds the PRIMARY gold to the span.
        XCTAssertEqual(errors(alternate), ["gold does not score 100 against itself: F 100.0 Fi — M 92.0 C 95.0 "
                                           + "[OVER_EDIT_HEDGE] — must_keep missing 'I don't know,'"])
        let repair = EvalCase(id: "m6", raw: "meet on Tuesday, I mean on Wednesday", gold: "Meet on Tuesday.",
                              golds: ["Meet on Wednesday."],
                              repairs: [.init(reparandum: "on Tuesday, I mean", repair: "on Wednesday")])
        XCTAssertFalse(errors(repair).contains { $0.hasSuffix("not found in any acceptable gold") })
    }

    func testGoldNumeralMustBeSaidOrAlternate() {
        let invented = EvalCase(id: "n", raw: "a 42 on each wing so find the total", gold: "A 42 on each wing, so find the total. 140 units.")
        XCTAssertEqual(errors(invented), ["gold numeral '140' is not in raw or alternates"])
        // Cardinals canonicalize on their own; a decimal needs an alternate.
        let spelled = EvalCase(id: "n2", raw: "fifty four other things", gold: "54 other things.")
        XCTAssertEqual(errors(spelled), [])
        let alternate = EvalCase(id: "n3", raw: "twenty six K", gold: "26000.", alternates: [.init(from: "twenty six K", to: ["26000"])])
        XCTAssertEqual(errors(alternate), [])
        let badAlternate = EvalCase(id: "n4", raw: "we ship it", gold: "We ship it.", alternates: [.init(from: " ", to: [])])
        XCTAssertEqual(errors(badAlternate), ["alternate needs a non-empty 'from' and at least one 'to'"])
    }

    func testControlWithWordEdits() {
        let c = EvalCase(id: "c", raw: "I don't know, try some benchmarking", gold: "Try some benchmarking.", control: true)
        XCTAssertEqual(errors(c).first, "control: true but raw→gold has 3 word edit(s)")
        // A derived control cannot contradict itself; an explicit false is never checked.
        XCTAssertEqual(errors(EvalCase(id: "c2", raw: "we ship it", gold: "We ship it.", control: true)), [])
        XCTAssertEqual(errors(EvalCase(id: "c3", raw: "we ship it", gold: "We ship it.", control: false)), [])
    }

    func testEmptyAlternateGold() {
        XCTAssertEqual(errors(EvalCase(id: "g", raw: "we ship it", gold: "We ship it.", golds: [" "])), ["golds[0] is empty"])
    }

    // MARK: - The invariant (§9): the gold scores 100 against itself

    func testTheInvariantQuotesTheScorersOwnNumbers() {
        // The genuine contradiction: both runs annotated with keep "the",
        // a gold that leaves the first one standing and cuts the second
        // one whole. Neither collapse is credited, and the finding is the
        // scorer's Fi, not a count this file re-derived.
        let both = [EvalCase.Stutter(span: "the the", keep: "the"),
                    EvalCase.Stutter(span: "the the", keep: "the", occurrence: 2)]
        let c = EvalCase(id: "x", raw: "send the the report and the the file",
                         gold: "Send the the report and file.", stutters: both)
        XCTAssertEqual(errors(c), ["gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 "
                                   + "[MISSED] — Fi missed 'the the', 'the the'"])
        // The scorer agrees, which is the point: lint IS this call.
        let q = QualityScore.score(c, out: c.gold)
        XCTAssertEqual(q.fillers?.score, 0)
        XCTAssertEqual(q.composite, 80)
        // A surplus on one run and a deficit on the other do not cancel:
        // each is charged where it happened.
        XCTAssertEqual(q.fillers?.missed, ["the the", "the the"])
        // Collapsing both is the well-formed fixture.
        XCTAssertEqual(errors(EvalCase(id: "x2", raw: "send the the report and the the file",
                                       gold: "Send the report and the file.", stutters: both)), [])
    }

    func testUnnamedCopiesOfAnAnnotatedFillerAreNotRequiredToSurvive() {
        // Three "uh" in raw, two of them annotated, every acceptable gold
        // deleting all three: a clean fixture. The deleted rule demanded
        // that the copy the list does not name stand in the gold — a
        // clause the plan never had and the scorer never applied.
        let c = EvalCase(id: "u", raw: "Okay uh so the uh plan is to ship it uh tomorrow",
                         gold: "Okay, so the plan is to ship it tomorrow.",
                         golds: ["Okay, so the plan is to ship it, tomorrow."],
                         fillers: [.init(span: "uh"), .init(span: "uh", occurrence: 2)])
        XCTAssertEqual(EvalLint.lint([c]), [])
        XCTAssertEqual(QualityScore.score(c, out: c.gold).composite, 100)
        // Derived, the same fixture names all three and is equally clean.
        let derived = EvalCase(id: "u2", raw: c.raw, gold: c.gold)
        XCTAssertEqual(derived.expectedFillers.count, 3)
        XCTAssertEqual(EvalLint.lint([derived]), [])
    }

    func testAnOverlappingRunIsCountedOnce() {
        // "the the the" is ONE run with ONE annotation: the occurrence
        // walk that read "the the" twice inside it (copies 1 and 2 share a
        // token) is gone, and the gold that keeps one "the" is clean.
        let explicit = EvalCase(id: "o", raw: "I want the the the report", gold: "I want the report.",
                                stutters: [.init(span: "the the the", keep: "the")])
        XCTAssertEqual(EvalLint.lint([explicit]), [])
        XCTAssertEqual(QualityScore.score(explicit, out: explicit.gold).fillers?.expected, 1)
        let derived = EvalCase(id: "o2", raw: "I want the the the report", gold: "I want the report.")
        XCTAssertEqual(derived.expectedStutters, [EvalCase.Stutter(span: "the the the", keep: "the")])
        XCTAssertEqual(EvalLint.lint([derived]), [])
        // A gold that collapses the run only half way contradicts a keep
        // of one — and agrees with a keep of two.
        let half = EvalCase(id: "o3", raw: "I want the the the report", gold: "I want the the report.",
                            stutters: [.init(span: "the the the", keep: "the")])
        XCTAssertEqual(errors(half), ["gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 "
                                      + "[MISSED] — Fi missed 'the the the'"])
        XCTAssertEqual(errors(EvalCase(id: "o4", raw: "I want the the the report", gold: "I want the the report.",
                                       stutters: [.init(span: "the the the", keep: "the the")])), [])
    }

    func testAnAlternateGoldWarnsAndThePrimaryOneBlocks() {
        // An annotation the primary gold reads the same way and an
        // alternate does not: the alternate is a warning, never a block —
        // the scorer keeps the best gold, and a fixture is well formed
        // when its first reading is perfect.
        let alternate = EvalCase(id: "g1", raw: "send the the report", gold: "Send the report.",
                                 golds: ["Send report."], stutters: [.init(span: "the the", keep: "the")])
        XCTAssertEqual(errors(alternate), [])
        XCTAssertEqual(warnings(alternate), ["golds[0] does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 "
                                             + "C 80.0 [MISSED] — Fi missed 'the the'"])
        // The same disagreement on the PRIMARY gold errors: it is the
        // fixture's own statement of the ideal output.
        let primary = EvalCase(id: "g2", raw: "send the the report", gold: "Send report.",
                               golds: ["Send the report."], stutters: [.init(span: "the the", keep: "the")])
        XCTAssertEqual(errors(primary), ["gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 "
                                         + "[MISSED] — Fi missed 'the the'"])
    }

    func testTheInvariantCatchesWhatTheAnnotationRulesUsedTo() {
        // Every shape the deleted annotation-vs-gold rules existed for,
        // now on the axis it corrupts — and a gated gold, which no
        // hand-written rule ever caught.
        let survives = EvalCase(id: "i1", raw: "meet on Tuesday, I mean on Wednesday",
                                gold: "Meet on Tuesday, I mean on Wednesday.",
                                repairs: [.init(reparandum: "on Tuesday, I mean", repair: "on Wednesday")])
        XCTAssertEqual(errors(survives), ["gold does not score 100 against itself: F 100.0 Fi — M 75.0 C 84.4 "
                                          + "[MISSED] — repair unresolved 'on Tuesday, I mean'"])
        let doubled = EvalCase(id: "i2", raw: "I I think we should ship it", gold: "I I think we should ship it.",
                               stutters: [.init(span: "I I", keep: "I")])
        XCTAssertEqual(errors(doubled), ["gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 "
                                         + "[MISSED] — Fi missed 'I I'"])
        let forms = EvalCase(id: "i3", raw: "my l phone is dead", gold: "My l is dead.",
                             stutters: [.init(span: "my l phone", keep: "my phone")])
        XCTAssertEqual(errors(forms), ["gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 "
                                       + "[MISSED] — Fi missed 'my l phone'"])
        let negated = EvalCase(id: "i4", raw: "I don't think we should ship it", gold: "I think we should ship it.")
        XCTAssertEqual(errors(negated), ["gold does not score 100 against itself: F 100.0 Fi — M 0.0 C 0.0 "
                                         + "[NEGATED] — gated negation-dropped"])
        let fact = EvalCase(id: "i5", raw: "send me the 54 files", gold: "Send me the files.",
                            mustKeep: [.init(span: "54 files", weight: 5)])
        XCTAssertEqual(errors(fact).last, "gold does not score 100 against itself: F 100.0 Fi — M 0.0 C 0.0 "
                       + "[OVER_EDIT_FACT] — gated must-keep-fact; must_keep missing '54 files'")
        // Gold-free rows have no gold to hold to anything.
        let unrated = EvalCase(id: "i6", raw: "send the the report", gold: "",
                               stutters: [.init(span: "the the", keep: "the")],
                               goldSource: EvalCase.historyUnratedGoldSource, observed: "Send the report.")
        XCTAssertEqual(EvalLint.lint([unrated]), [])
    }

    // MARK: - Warnings

    func testAKeptFillerWarnsForExplicitAndDerivedAlike() {
        // A gold that retains a core filler nothing annotates: a reading,
        // not a verdict. The fixture is often right — and where it is not,
        // the invariant has already charged it on Fi.
        let derived = EvalCase(id: "k", raw: "um so we ship it", gold: "Um, so we ship it.")
        XCTAssertEqual(errors(derived), [])
        XCTAssertEqual(warnings(derived), ["filler 'um' (occurrence 1) is kept in gold and not annotated"])
        // `fillers: []` is the opt-out for a fixture that keeps its "um"
        // on purpose; the rule is asked of it too (it used to be skipped
        // for every explicit list, which made it inert on his own set).
        XCTAssertEqual(warnings(EvalCase(id: "k2", raw: "um so we ship it", gold: "Um, so we ship it.", fillers: [])),
                       ["filler 'um' (occurrence 1) is kept in gold and not annotated"])
        // Annotating it as a removal is not a second way out: the gold
        // keeps what the annotation strips, so Fi says 0.
        XCTAssertEqual(errors(EvalCase(id: "k3", raw: "um so we ship it", gold: "Um, so we ship it.",
                                       fillers: [.init(span: "um")])),
                       ["gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 [MISSED] — Fi missed 'um'"])
        // Only the kept occurrence is named, and naming the deleted one
        // explicitly is how a mixed fixture is written.
        XCTAssertEqual(warnings(EvalCase(id: "k4", raw: "um so we um ship it", gold: "Um, so we ship it.")),
                       ["filler 'um' (occurrence 1) is kept in gold and not annotated"])
        let named = EvalCase(id: "k5", raw: "um so we uh ship it", gold: "Um, so we ship it.",
                             fillers: [.init(span: "uh")])
        XCTAssertEqual(errors(named), [])
        XCTAssertEqual(warnings(named), ["filler 'um' (occurrence 1) is kept in gold and not annotated"])
        // An alternate that keeps it is named as the gold it is.
        let alternate = EvalCase(id: "k6", raw: "um so we ship it", gold: "So we ship it.",
                                 golds: ["Um, so we ship it."], fillers: [])
        XCTAssertEqual(errors(alternate), [])
        XCTAssertEqual(warnings(alternate), ["filler 'um' (occurrence 1) is kept in golds[0] and not annotated"])
        // A filler inside an annotated stutter run is mentioned.
        let inside = EvalCase(id: "k7", raw: "so we um um ship it", gold: "So we um ship it.",
                              stutters: [.init(span: "um um", keep: "um")])
        XCTAssertEqual(EvalLint.lint([inside]), [])
    }

    func testDraftIsAWarningNotAnError() {
        let draft = EvalCase(id: "d", raw: "um hi", gold: "Hi.", goldSource: "draft:claude", annotationsStatus: .draft)
        XCTAssertEqual(errors(draft), [])
        XCTAssertEqual(warnings(draft), ["draft gold (draft:claude) — scored, not counted as rated"])
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint([draft])))
    }

    func testGoldFreeRowsSkipGoldRulesAndWarnWithoutObserved() {
        // No gold: must_keep / repair-in-gold / numeral / invariant rules
        // are off; the raw-side span checks stay.
        let bare = EvalCase(id: "h1", raw: "um I also signed into Zephyrnet", gold: "", mustKeep: [.init(span: "I also")],
                            source: "history:1", goldSource: "history-unrated")
        XCTAssertEqual(errors(bare), [])
        XCTAssertEqual(warnings(bare), ["gold-free fixture without an observed output scores nothing but Fi"])
        let observed = EvalCase(id: "h2", raw: "um I also signed into Zephyrnet", gold: "", source: "history:2",
                                goldSource: "history-unrated", observed: "I also signed into Zephyrnet.", observedMs: 400)
        XCTAssertEqual(EvalLint.lint([observed]), [])
        let badSpan = EvalCase(id: "h3", raw: "um hi", gold: "", mustKeep: [.init(span: "bye")], goldSource: "history-unrated")
        XCTAssertEqual(errors(badSpan), ["must_keep 'bye' not found in raw"])
    }

    // MARK: - Repo guard

    func testRepoGuardRefusesHistorySourcesAndObservedFields() {
        let history = EvalCase(id: "h", raw: "um hi", gold: "", source: "history:70", goldSource: "history-unrated",
                               observed: "Hi.", observedMs: 12)
        XCTAssertEqual(EvalLint.lint([history]), [])   // fine outside the tree
        XCTAssertEqual(EvalLint.guardRow(history).map(\.message), [
            "repo guard: source 'history:70' is a history row",
            "repo guard: 'observed' / 'observed_ms' is shipped-binary output",
        ])
        XCTAssertEqual(errors(history, repoGuard: true).count, 2)
        // The rule itself, on the fields — what a format-bench file is
        // guarded by (`FormatLint`), so the two files share one guard.
        XCTAssertEqual(EvalLint.guardExportFields(id: "h", source: "history:70", observed: "Hi.", observedMs: 12),
                       EvalLint.guardRow(history))
        XCTAssertEqual(EvalLint.guardExportFields(id: "f", source: nil, observed: nil, observedMs: nil), [])
        // observed_ms alone is enough; a synthetic row with neither passes.
        XCTAssertEqual(EvalLint.guardRow(EvalCase(id: "o", raw: "um hi", gold: "Hi.", observedMs: 3)).count, 1)
        XCTAssertEqual(EvalLint.guardRow(EvalCase(id: "s", raw: "um hi", gold: "Hi.")), [])
        XCTAssertEqual(EvalLint.lint(EvalCase.seeds, repoGuard: true), [])
        // The same test as one predicate, for the run-file refusal.
        XCTAssertTrue(EvalLint.carriesExportFields(history))
        XCTAssertTrue(EvalLint.carriesExportFields(EvalCase(id: "o", raw: "um hi", gold: "Hi.", observedMs: 3)))
        XCTAssertTrue(EvalLint.carriesExportFields(EvalCase(id: "o", raw: "um hi", gold: "Hi.", observed: "Hi.")))
        XCTAssertTrue(EvalLint.carriesExportFields(EvalCase(id: "h", raw: "um hi", gold: "Hi.", source: "history:3")))
        XCTAssertFalse(EvalLint.carriesExportFields(EvalCase(id: "s", raw: "um hi", gold: "Hi.")))
        XCTAssertFalse(EvalCase.seeds.contains(where: EvalLint.carriesExportFields))
    }

    // MARK: - Set level

    func testSetLevelFloors() {
        // Two five-word fixtures, no control, no agent-prompt, one one-word:
        // every floor fails, each with its own count.
        let tiny = [
            EvalCase(id: "a", raw: "um so we ship it", gold: "So we ship it."),
            EvalCase(id: "b", raw: "Uh", gold: ""),
        ]
        let issues = EvalLint.setLevel(tiny)
        XCTAssertEqual(issues.map(\.message), [
            "controls 0/2 (0%) below 15%",
            "fixtures ≥ 60 words 0/2 (0%) below 20%",
            "fixtures ≥ 30 words 0/2 (0%) below 40%",
            "agent-prompt 0/2 (0%) below 60%",
            "one-word fixtures 1/2 (50%) above 10%",
        ])
        XCTAssertTrue(issues.allSatisfy { $0.id == nil && $0.severity == .error })
        XCTAssertEqual(issues[0].description, "error: controls 0/2 (0%) below 15%")
        XCTAssertEqual(EvalLint.setLevel([]), [EvalLint.Issue(.error, "empty fixture set")])
        // Floors are off unless asked for.
        XCTAssertEqual(EvalLint.lint(tiny), [])
        XCTAssertEqual(EvalLint.lint(tiny, floors: true).count, 5)
        XCTAssertEqual(EvalLint.setLevel(EvalCase.seeds), [])
    }
}
