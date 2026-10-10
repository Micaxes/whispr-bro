import XCTest
@testable import WhisprBroCore

/// The run plan (plan §6.1): what `--tag` / `--only` / `--confirmed-only`
/// keep, the (register, level) sort with its re-prime marks, and the
/// per-item pipeline decisions the bench mirrors from PipelineController.
final class EvalPlanTests: XCTestCase {
    private let unknownStd = EvalCase(id: "u1", raw: "um so we ship it today", gold: "So we ship it today.", tags: ["a"])
    private let unknownStd2 = EvalCase(id: "u2", raw: "we ship it tomorrow", gold: "We ship it tomorrow.", tags: ["b"])
    private let unknownFillers = EvalCase(id: "u3", raw: "we ship it", gold: "We ship it.", tags: ["a", "b"], level: .fillers)
    private let messaging = EvalCase(id: "m1", raw: "yeah ship it", gold: "yeah ship it", register: .messaging)
    private let notes = EvalCase(id: "n1", raw: "um profile dump", gold: "Um profile dump.", register: .notes, fillers: [])

    // MARK: - Ordering

    func testSortsByRegisterThenLevelAndMarksTheFirstOfEachGroup() {
        let plan = EvalPlan(cases: [unknownStd, notes, unknownStd2, messaging, unknownFillers])
        XCTAssertEqual(plan.items.map(\.fixture.id), ["m1", "n1", "u3", "u1", "u2"])
        XCTAssertEqual(plan.items.map(\.level), [.standard, .verbatim, .fillers, .standard, .standard])
        XCTAssertEqual(plan.items.map(\.reprime), [true, true, true, true, false])
        XCTAssertEqual(plan.groups, 4)
        XCTAssertEqual(plan.levelName, "fixture")
        XCTAssertNil(plan.levelOverride)
    }

    func testStableWithinAGroup() {
        let plan = EvalPlan(cases: [unknownStd2, unknownStd])
        XCTAssertEqual(plan.items.map(\.fixture.id), ["u2", "u1"])
        XCTAssertEqual(plan.items.map(\.reprime), [true, false])
        XCTAssertEqual(EvalPlan(cases: []).items, [])
    }

    func testLevelOverrideCollapsesGroupsButNeverTouchesAVerbatimRegister() {
        let plan = EvalPlan(cases: [unknownStd, unknownFillers, notes], levelOverride: .standard)
        XCTAssertEqual(plan.levelName, "standard")
        XCTAssertEqual(plan.items.map(\.fixture.id), ["n1", "u1", "u3"])
        XCTAssertEqual(plan.items.map(\.level), [.verbatim, .standard, .standard])
        XCTAssertEqual(plan.items.map(\.reprime), [true, true, false])
        let fillers = EvalPlan(cases: [unknownStd], levelOverride: .fillers)
        XCTAssertEqual(fillers.items[0].level, .fillers)
        XCTAssertEqual(fillers.levelName, "fillers")
    }

    func testItemFlagsMirrorThePipeline() {
        let plan = EvalPlan(cases: [unknownStd, unknownFillers, notes])
        let std = plan.items.first { $0.fixture.id == "u1" }!
        XCTAssertTrue(std.stripFillers)
        XCTAssertTrue(std.resolveCorrections)
        XCTAssertFalse(std.verbatim)
        let fil = plan.items.first { $0.fixture.id == "u3" }!
        XCTAssertTrue(fil.stripFillers)
        XCTAssertFalse(fil.resolveCorrections)
        let verbatim = plan.items.first { $0.fixture.id == "n1" }!
        XCTAssertFalse(verbatim.stripFillers)
        XCTAssertFalse(verbatim.resolveCorrections)
        XCTAssertTrue(verbatim.verbatim)
        // The verbatim categories are config; an empty list makes notes a normal register.
        XCTAssertEqual(EvalPlan.level(for: notes, override: nil, verbatimCategories: []), .standard)
        XCTAssertEqual(EvalPlan.level(for: notes, override: .fillers, verbatimCategories: []), .fillers)
        XCTAssertEqual(EvalPlan.level(for: notes, override: .fillers, verbatimCategories: ["Notes"]), .verbatim)
    }

    func testShippedSourceMirrorsTheProductionFastPath() {
        // `TextFormatter.formatDetailed`: the model runs unless the text
        // is under the fast-path word limit (6) AND carries no plausible
        // correction cue at a level that resolves corrections. "monday no
        // wait tuesday" is four words with a cue → the model ran; the same
        // words at `fillers` (no clause) or under a verbatim register →
        // fast path; "meet at 2 actually 3" has no bypass cue → fast path
        // at any level; six words → the model, cue or not; empty → fast
        // path.
        let cued = EvalCase(id: "c", raw: "monday no wait tuesday", gold: "", goldSource: "history-unrated")
        let plain = EvalCase(id: "p", raw: "meet at 2 actually 3", gold: "", goldSource: "history-unrated")
        let six = EvalCase(id: "s", raw: "we ship the fix on tuesday", gold: "", goldSource: "history-unrated")
        func item(_ c: EvalCase, level: AppConfig.Cleanup.Level) -> EvalPlan.Item {
            EvalPlan.Item(fixture: c, level: level, reprime: false)
        }
        XCTAssertEqual(EvalPlan.shippedSource(stripped: cued.raw, item: item(cued, level: .standard)), .model)
        XCTAssertEqual(EvalPlan.shippedSource(stripped: cued.raw, item: item(cued, level: .fillers)), .fallback(.fastPath))
        XCTAssertEqual(EvalPlan.shippedSource(stripped: cued.raw, item: item(cued, level: .verbatim)), .fallback(.fastPath))
        XCTAssertEqual(EvalPlan.shippedSource(stripped: plain.raw, item: item(plain, level: .standard)), .fallback(.fastPath))
        XCTAssertEqual(EvalPlan.shippedSource(stripped: six.raw, item: item(six, level: .fillers)), .model)
        XCTAssertEqual(EvalPlan.shippedSource(stripped: "  ", item: item(six, level: .standard)), .fallback(.fastPath))

        // …and the ceiling at the other end: production skips the model above
        // `llmWordLimit`, so a long row is rules output in history, never a
        // model row. The boundary itself still measures the model.
        let limit = TextFormatter.Config().llmWordLimit
        let atLimit = (1...limit).map { "word\($0)" }.joined(separator: " ")
        let overLimit = atLimit + " overflow"
        XCTAssertEqual(EvalPlan.shippedSource(stripped: atLimit, item: item(six, level: .standard)), .model)
        XCTAssertEqual(EvalPlan.shippedSource(stripped: overLimit, item: item(six, level: .standard)),
                       .fallback(.tooLong))
        // The limit is production's, and the boundary is `<`.
        XCTAssertEqual(TextFormatter.Config().fastPathWordLimit, 6)
        XCTAssertEqual(EvalPlan.shippedSource(stripped: "one two three four five", item: item(six, level: .standard)),
                       .fallback(.fastPath))
        XCTAssertEqual(EvalPlan.shippedSource(stripped: "one two three four five", item: item(six, level: .standard),
                                              fastPathWordLimit: 5), .model)
    }

    func testShippedSourceStandsOnlyWhereEveryPrePassAgrees() {
        // History carries no binary version: a row may have reached the
        // formatter as the strip alone left it (before the self-repair rules)
        // or as the rules left it. "monday, no wait, tuesday" kept its cue
        // under the strip alone — the model ran — but the rules take it out,
        // and a one-word row takes the fast path: no provenance.
        let cued = EvalCase(id: "c", raw: "monday, no wait, tuesday", gold: "", goldSource: "history-unrated")
        let item = EvalPlan.Item(fixture: cued, level: .standard, reprime: false)
        let stripOnly = FillerStripper().strip(cued.raw)
        let repaired = DictationPipeline.prePass(cued.raw, dictionary: DictionaryEngine(rules: []),
                                                 stripper: FillerStripper(), level: .standard,
                                                 verbatimRegister: false, language: .english)
        XCTAssertEqual(repaired, "tuesday")
        XCTAssertEqual(EvalPlan.shippedSource(stripped: stripOnly, item: item), .model)
        XCTAssertEqual(EvalPlan.shippedSource(stripped: repaired, item: item), .fallback(.fastPath))
        XCTAssertNil(EvalPlan.shippedSource(candidates: [stripOnly, repaired], item: item))
        // Where the pre-passes agree, the source stands.
        let six = EvalCase(id: "s", raw: "we ship the fix on tuesday", gold: "", goldSource: "history-unrated")
        let sixItem = EvalPlan.Item(fixture: six, level: .standard, reprime: false)
        XCTAssertEqual(EvalPlan.shippedSource(candidates: [six.raw, six.raw], item: sixItem), .model)
        XCTAssertEqual(EvalPlan.shippedSource(candidates: ["meet at 3"], item: sixItem), .fallback(.fastPath))
        XCTAssertNil(EvalPlan.shippedSource(candidates: [], item: sixItem))
    }

    func testDirectiveIsTheRegisterLinePlusTheClauseAtStandard() {
        let plan = EvalPlan(cases: [unknownStd, unknownFillers, messaging, notes])
        let rules = StyleRules()
        let std = plan.items.first { $0.fixture.id == "u1" }!
        XCTAssertEqual(EvalPlan.directive(for: std),
                       rules.directive(for: .unknown) + "\n\n" + PromptBuilder.correctionClause(for: .english))
        let fil = plan.items.first { $0.fixture.id == "u3" }!
        XCTAssertEqual(EvalPlan.directive(for: fil), rules.directive(for: .unknown))
        let msg = plan.items.first { $0.fixture.id == "m1" }!
        XCTAssertTrue(EvalPlan.directive(for: msg).hasPrefix(rules.directive(for: .messaging)))
        XCTAssertTrue(EvalPlan.directive(for: msg).contains("When the speaker corrects themselves"))
        // Verbatim register: the register's own directive, no clause.
        let verbatim = plan.items.first { $0.fixture.id == "n1" }!
        XCTAssertEqual(EvalPlan.directive(for: verbatim), rules.directive(for: .notes))
    }

    // MARK: - Selection

    func testTagFilterIsAnyOf() {
        let cases = [unknownStd, unknownStd2, unknownFillers, messaging]
        XCTAssertEqual(EvalPlan.select(cases, tags: ["a"]).map(\.id), ["u1", "u3"])
        XCTAssertEqual(EvalPlan.select(cases, tags: ["a", "b"]).map(\.id), ["u1", "u2", "u3"])
        XCTAssertEqual(EvalPlan.select(cases, tags: ["zzz"]).map(\.id), [])
        XCTAssertEqual(EvalPlan.select(cases).map(\.id), ["u1", "u2", "u3", "m1"])
    }

    func testConfirmedOnlyDropsDraftGoldsButKeepsGoldFreeRows() {
        let draft = EvalCase(id: "d", raw: "um hi", gold: "Hi.", goldSource: "draft:claude", annotationsStatus: .draft)
        let unrated = EvalCase(id: "h", raw: "um hi", gold: "", goldSource: "history-unrated", annotationsStatus: .draft)
        let cases = [unknownStd, draft, unrated]
        XCTAssertEqual(EvalPlan.select(cases, confirmedOnly: true).map(\.id), ["u1", "h"])
        XCTAssertEqual(EvalPlan.select(cases).map(\.id), ["u1", "d", "h"])
        XCTAssertEqual(EvalPlan.select(cases, only: .unrated).map(\.id), ["h"])
    }

    func testOnlyGatedAndFlaggedReadTheObservedOutput() {
        let raw = "Can you explain how the sync works between the tabs and the phone"
        let answered = EvalCase(id: "h70", raw: raw, gold: "", goldSource: "history-unrated",
                                observed: "Sure, I can explain that.\n1. **Sync** runs every minute between the tabs and the phone.")
        let hedgeRaw = "I want the main focus to be the login page and the settings page"
        // Not gated (7/14 words is not a collapse), five content words gone.
        let flagged = EvalCase(id: "h58", raw: hedgeRaw, gold: "", goldSource: "history-unrated",
                               observed: "The login page and the settings page.")
        let clean = EvalCase(id: "h1", raw: "um I also signed into the tunnel", gold: "", goldSource: "history-unrated",
                             observed: "I also signed into the tunnel.")
        let noObserved = EvalCase(id: "h2", raw: "um I also signed into the tunnel", gold: "", goldSource: "history-unrated")
        let cases = [answered, flagged, clean, noObserved, unknownStd]
        XCTAssertEqual(EvalPlan.select(cases, only: .gated).map(\.id), ["h70"])
        XCTAssertEqual(EvalPlan.select(cases, only: .flagged).map(\.id), ["h70", "h58"])
        XCTAssertEqual(EvalPlan.select(cases, only: .unrated).map(\.id), ["h70", "h58", "h1", "h2"])
        XCTAssertEqual(EvalPlan.select(cases, only: .all).count, 5)
        // Hand-count: "I want the main focus to be the login page and the
        // settings page" → out keeps "the login page and the settings page";
        // dropped content = I, want, primary, thing, be (the / to are STOP) = 5 ≥ 3.
        let score = QualityScore.score(flagged, out: flagged.observed!)
        XCTAssertFalse(score.isGated)
        XCTAssertEqual(score.contentGuard.droppedContent.count, 5)
        // Filters compose: a tag no observed row carries empties the gated set.
        XCTAssertEqual(EvalPlan.select(cases, tags: ["a"], only: .gated), [])
        XCTAssertEqual(EvalPlan.Only.allCases.map(\.rawValue), ["all", "gated", "flagged", "unrated"])
    }
}
