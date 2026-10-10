import XCTest
@testable import WhisprBroCore

/// Every §7.3 rule on hand-written fixtures: a SHIP becomes the gold, a
/// second one an alternate, his edit wins over both and carries its HTER,
/// `y` confirms, a tagged WRONG drafts `must_keep`, a cue-adjacent deletion
/// drafts a repair, fillers / stutters / control stay derived, a confirmed
/// gold is never overwritten, and two edits for one fixture are a conflict
/// that leaves the fixture exactly as it was. The property that matters
/// most is last: whatever it derives, the file still passes `lint`.
final class GoldDerivationTests: XCTestCase {
    // MARK: Fixtures and records

    /// The shape of the over-edit row: a hedge the formatter dropped. A
    /// history export is a DRAFT, as every row of his own file is.
    private let hedge = EvalCase(
        id: "h58", raw: "I don't know, try some broad benchmarking on the tabs",
        gold: "", tags: ["unrated", "unknown"], source: "history:58",
        goldSource: EvalCase.historyUnratedGoldSource, annotationsStatus: .draft,
        observed: "Try some broad benchmarking on the tabs.")

    private func rating(_ id: String, out: String, verdict: Rating.Verdict?, tags: [String] = [],
                        mustKeep: [EvalCase.MustKeep] = [], goldEdit: String? = nil, altGold: String? = nil,
                        confirm: Bool? = nil, formatter: String = "llama",
                        runKey: String = "b5e821d340da", at: String = "2026-09-14T18:03:00Z") -> Rating {
        Rating(fixtureId: id, runKey: runKey, formatter: formatter, outputSha: Rating.outputSha(out),
               verdict: verdict, tags: tags, mustKeep: mustKeep, goldEdit: goldEdit, altGold: altGold,
               confirm: confirm, msToRate: 4200, ratedAt: at, session: "s1")
    }

    private func outputs(_ pairs: [(String, String)]) -> GoldDerivation.Outputs {
        var outputs = GoldDerivation.Outputs()
        for (id, text) in pairs { outputs.add(fixtureId: id, text: text) }
        return outputs
    }

    private func derived(_ fixtures: [EvalCase], _ ratings: [Rating],
                         _ outputs: GoldDerivation.Outputs) -> GoldDerivation.Result {
        GoldDerivation.derive(fixtures: fixtures, ratings: ratings, outputs: outputs)
    }

    // MARK: - Rule 1: SHIP

    func testShipBecomesTheGoldWithItsProvenance() throws {
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([hedge], [rating("h58", out: out, verdict: .ship)], outputs([("h58", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.gold, out)
        XCTAssertEqual(after.goldSource, "ship:b5e821d340da:llama")
        // A SHIP judges the OUTPUT: the fixture keeps the status it had
        // (§7.3.4 flips it on `y` or an edit, and on nothing else).
        XCTAssertEqual(after.annotationsStatus, .draft)
        XCTAssertFalse(after.tags.contains("unrated"))
        XCTAssertFalse(after.isGoldFree)
        XCTAssertEqual(result.changes.count, 1)
        XCTAssertTrue(result.changes[0].notes.contains { $0.hasPrefix("gold ← ship:b5e821d340da:llama") },
                      "\(result.changes[0].notes)")
        // Nothing else about the fixture moved.
        XCTAssertEqual(after.raw, hedge.raw)
        XCTAssertEqual(after.observed, hedge.observed)
        XCTAssertEqual(after.source, "history:58")
    }

    func testASecondDifferingShipIsAnAlternateGold() throws {
        let first = "Try some broad benchmarking on the tabs."
        let second = "Try some broad benchmarking on the tabs!"
        let result = derived([hedge],
                             [rating("h58", out: first, verdict: .ship, formatter: "shipped", runKey: "7ae02c57ba33"),
                              rating("h58", out: second, verdict: .ship)],
                             outputs([("h58", first), ("h58", second)]))
        let after = result.cases[0]
        XCTAssertEqual(after.gold, first)
        XCTAssertEqual(after.goldSource, "ship:7ae02c57ba33:shipped")
        XCTAssertEqual(after.golds, [second])
        XCTAssertEqual(after.acceptableGolds, [first, second])
        // An identical second SHIP adds nothing.
        let same = derived([hedge],
                           [rating("h58", out: first, verdict: .ship),
                            rating("h58", out: first, verdict: .ship, formatter: "shipped")],
                           outputs([("h58", first)]))
        XCTAssertEqual(same.cases[0].golds, [])
    }

    func testAlsoFineAppendsAnAlternateWithoutBecomingTheGold() throws {
        let out = "Try some broad benchmarking on the tabs."
        let alt = "Try some broad benchmarking on the tabs!"
        let result = derived([hedge], [rating("h58", out: out, verdict: .ship, altGold: alt)],
                             outputs([("h58", out)]))
        XCTAssertEqual(result.cases[0].gold, out)
        XCTAssertEqual(result.cases[0].golds, [alt])
    }

    // MARK: - Rule 2: the edit

    func testAGoldEditWinsOverAShipAndCarriesItsHter() throws {
        let out = "Try some broad benchmarking on the tabs."
        let edit = "I don't know, try some broad benchmarking on the tabs."
        let result = derived([hedge],
                             [rating("h58", out: out, verdict: .ship, formatter: "shipped", runKey: "7ae02c57ba33"),
                              rating("h58", out: out, verdict: .wrong, tags: ["dropped-hedge"], goldEdit: edit)],
                             outputs([("h58", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.gold, edit)
        XCTAssertEqual(after.goldSource, "edit")
        // The SHIP's text survives as an alternate, not as the gold.
        XCTAssertEqual(after.golds, [out])
        // out = 7 words (try some broad benchmarking on the tabs); gold = 10
        // (I don't know try some broad benchmarking on the tabs): 3 insertions.
        let distance = try XCTUnwrap(result.editDistances.first)
        XCTAssertEqual(distance.edits, 3)
        XCTAssertEqual(distance.goldWords, 10)
        XCTAssertEqual(distance.outputWords, 7)
        XCTAssertEqual(distance.hter, 0.3, accuracy: 0.0005)
        XCTAssertEqual(distance.formatter, "llama")
    }

    /// §7.3.4: a draft is precisely the thing a human overrides. An agent
    /// drafted `must_keep "probably"` on this row; the text he types drops
    /// that word, and his gold wins anyway — the draft goes with it, named
    /// in the diff so he can put it back, and the file still lints clean.
    func testADraftAnnotationDoesNotRefuseHisOwnGold() throws {
        let drafted = EvalCase(id: "h14", raw: "the blue kettle probably needs descaling on tuesday",
                               gold: "The blue kettle probably needs descaling on Tuesday.",
                               tags: ["unrated"],
                               mustKeep: [EvalCase.MustKeep(span: "probably", weight: 5)],
                               goldSource: "draft:agent-2026-09-12", annotationsStatus: .draft,
                               observed: "The blue kettle needs descaling on Tuesday.")
        let out = "The blue kettle needs descaling on Tuesday."
        let result = derived([drafted],
                             [rating("h14", out: out, verdict: .wrong, tags: ["reworded"], goldEdit: out)],
                             outputs([("h14", out)]))
        let after = result.cases[0]
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(after.gold, out)
        XCTAssertEqual(after.goldSource, "edit")
        XCTAssertEqual(after.annotationsStatus, .confirmed)
        XCTAssertEqual(after.mustKeep, [])
        XCTAssertTrue(result.changes[0].notes.contains { $0.hasPrefix("− must_keep \"probably\"") },
                      "\(result.changes[0].notes)")
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    /// The other side of the same rule: a CONFIRMED annotation is his own
    /// work, so it refuses a gold that would break it and the fixture does
    /// not move — either the annotation or the rating is wrong, and both
    /// are his to settle.
    func testAConfirmedAnnotationStillRefusesAContradictingGold() throws {
        let confirmed = EvalCase(id: "seed-03", raw: "the blue kettle probably needs descaling on tuesday",
                                 gold: "The blue kettle probably needs descaling on Tuesday.",
                                 mustKeep: [EvalCase.MustKeep(span: "probably", weight: 5)],
                                 goldSource: "seed", annotationsStatus: .confirmed)
        let out = "The blue kettle needs descaling on Tuesday."
        let result = derived([confirmed],
                             [rating("seed-03", out: out, verdict: .wrong, tags: ["reworded"], goldEdit: out)],
                             outputs([("seed-03", out)]))
        XCTAssertEqual(result.cases, [confirmed])
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertTrue(result.conflicts[0].reason.hasPrefix("edit contradicts the fixture's annotations"),
                      result.conflicts[0].reason)
    }

    /// The same rule on the population this loop actually works on. A
    /// history export writes `history-unrated` on every row, so almost
    /// every fixture he rates is GOLD-FREE — and a weight-5 span he marked
    /// and then confirmed on one of those rows is his work, not a draft.
    /// Reading the GOLD's protection for the ANNOTATIONS deleted it
    /// silently and called it a draft in the diff.
    func testAConfirmedAnnotationOnAGoldFreeRowRefusesTheRatingToo() throws {
        let confirmed = EvalCase(id: "h58", raw: "I don't know, try some broad benchmarking on the tabs",
                                 gold: "", tags: ["unknown"],
                                 mustKeep: [EvalCase.MustKeep(span: "I don't know", weight: 5)],
                                 source: "history:58", goldSource: EvalCase.historyUnratedGoldSource,
                                 annotationsStatus: .confirmed,
                                 observed: "Try some broad benchmarking on the tabs.")
        XCTAssertTrue(confirmed.isGoldFree)
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([confirmed], [rating("h58", out: out, verdict: .ship)], outputs([("h58", out)]))
        XCTAssertEqual(result.cases, [confirmed])
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertTrue(result.conflicts[0].reason.contains("contradicts the fixture's annotations"),
                      result.conflicts[0].reason)
        XCTAssertEqual(result.cases[0].mustKeep, [EvalCase.MustKeep(span: "I don't know", weight: 5)])
        // Nothing in the diff calls a confirmed annotation a draft.
        XCTAssertFalse(result.render().contains("[draft"), result.render())
        // The other half of the same rule, on the same gold-free row: a
        // DRAFT span an agent guessed still loses to his rating.
        let draft = EvalCase(id: "h58", raw: confirmed.raw, gold: "", tags: ["unknown"],
                             mustKeep: confirmed.mustKeep, source: "history:58",
                             goldSource: EvalCase.historyUnratedGoldSource, annotationsStatus: .draft,
                             observed: confirmed.observed)
        let dropped = derived([draft], [rating("h58", out: out, verdict: .ship)], outputs([("h58", out)]))
        XCTAssertEqual(dropped.conflicts, [])
        XCTAssertEqual(dropped.cases[0].gold, out)
        XCTAssertEqual(dropped.cases[0].mustKeep, [])
        XCTAssertTrue(dropped.changes[0].notes.contains { $0.hasPrefix("− must_keep \"I don't know\"") },
                      "\(dropped.changes[0].notes)")
    }

    /// The one refusal no status can absorb: a gold carrying a numeral the
    /// speaker never said is a `lint` error on the spot.
    func testAGoldCarryingANumeralHeNeverSaidIsRefusedOnADraftToo() throws {
        let draft = EvalCase(id: "h15", raw: "let's ship it in the morning", gold: "",
                             tags: ["unrated"], goldSource: EvalCase.historyUnratedGoldSource,
                             annotationsStatus: .draft, observed: "Let's ship it in the morning.")
        let out = "Let's ship it in the morning."
        let result = derived([draft],
                             [rating("h15", out: out, verdict: .fix, goldEdit: "Let's ship it at 5.")],
                             outputs([("h15", out)]))
        XCTAssertEqual(result.cases, [draft])
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertTrue(result.conflicts[0].reason.contains("numeral '5'"), result.conflicts[0].reason)
    }

    func testTwoDifferentEditsAreAConflictAndTheFixtureDoesNotMove() throws {
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([hedge],
                             [rating("h58", out: out, verdict: .wrong, goldEdit: "I don't know, try some benchmarking."),
                              rating("h58", out: out, verdict: .wrong, goldEdit: "I don't know, try some broad benchmarking.")],
                             outputs([("h58", out)]))
        XCTAssertEqual(result.cases, [hedge])
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.conflicts[0].id, "h58")
        XCTAssertTrue(result.conflicts[0].reason.hasPrefix("2 different gold edits"), result.conflicts[0].reason)
        // The same edit twice is not a conflict.
        let agreed = derived([hedge],
                             [rating("h58", out: out, verdict: .wrong, goldEdit: "I don't know, try some benchmarking."),
                              rating("h58", out: out, verdict: .wrong, goldEdit: "I don't know, try some benchmarking.")],
                             outputs([("h58", out)]))
        XCTAssertEqual(agreed.conflicts, [])
        XCTAssertEqual(agreed.cases[0].gold, "I don't know, try some benchmarking.")
    }

    // MARK: - Rule 3: confirm

    func testConfirmFlipsTheStatusAndDropsTheUnratedTag() throws {
        let draft = EvalCase(id: "h9", raw: "we ship the fix today", gold: "We ship the fix today.",
                             tags: ["unrated", "unknown"], goldSource: "draft:claude-2026-09-12",
                             annotationsStatus: .draft, observed: "We ship the fix today.")
        let result = derived([draft], [rating("h9", out: "We ship the fix today.", verdict: nil, confirm: true)],
                             outputs([("h9", "We ship the fix today.")]))
        let after = result.cases[0]
        XCTAssertEqual(after.annotationsStatus, .confirmed)
        XCTAssertEqual(after.tags, ["unknown"])
        XCTAssertEqual(after.gold, draft.gold)            // the gold itself is untouched
        XCTAssertEqual(after.goldSource, "draft:claude-2026-09-12")
    }

    // MARK: - Rule 4: must_keep drafts

    func testAWrongTaggedDroppedHedgeDraftsMustKeepAtWeightTwo() throws {
        let out = "Try some broad benchmarking on the tabs."
        let edit = "I don't know, try some broad benchmarking on the tabs."
        let result = derived([hedge],
                             [rating("h58", out: out, verdict: .wrong, tags: ["dropped-hedge"], goldEdit: edit)],
                             outputs([("h58", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.mustKeep, [EvalCase.MustKeep(span: "I don't know", weight: 2)])
        XCTAssertEqual(after.annotationsStatus, .draft)   // drafted, so not confirmed
        XCTAssertEqual(after.gold, edit)
    }

    func testDroppedFactDraftsAtWeightFive() throws {
        let out = "Try some broad benchmarking on the tabs."
        let edit = "I don't know, try some broad benchmarking on the tabs."
        let result = derived([hedge],
                             [rating("h58", out: out, verdict: .wrong, tags: ["dropped-fact"], goldEdit: edit)],
                             outputs([("h58", out)]))
        XCTAssertEqual(result.cases[0].mustKeep, [EvalCase.MustKeep(span: "I don't know", weight: 5)])
    }

    func testHisOwnMarksOverrideTheDerivedSpans() throws {
        let out = "Try some broad benchmarking on the tabs."
        let edit = "I don't know, try some broad benchmarking on the tabs."
        let result = derived([hedge],
                             [rating("h58", out: out, verdict: .wrong, tags: ["dropped-fact"],
                                     mustKeep: [EvalCase.MustKeep(span: "don't know", weight: 5)], goldEdit: edit)],
                             outputs([("h58", out)]))
        XCTAssertEqual(result.cases[0].mustKeep, [EvalCase.MustKeep(span: "don't know", weight: 5)])
    }

    func testADraftedSpanTheGoldDoesNotCarryIsNotWritten() throws {
        // He says a fact was dropped, but the gold he shipped does not
        // contain it either — writing it would fail `lint` on the spot.
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([hedge],
                             [rating("h58", out: out, verdict: .ship, formatter: "shipped", runKey: "7ae02c57ba33"),
                              rating("h58", out: out, verdict: .wrong, tags: ["dropped-fact"])],
                             outputs([("h58", out)]))
        XCTAssertEqual(result.cases[0].mustKeep, [])
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)))
    }

    func testAWrongWithNoDropTagDraftsNothing() throws {
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([hedge], [rating("h58", out: out, verdict: .wrong, tags: ["reworded"])],
                             outputs([("h58", out)]))
        XCTAssertEqual(result.cases[0].mustKeep, [])
        XCTAssertEqual(result.changes, [])
    }

    // MARK: - Rule 5: repairs

    func testADeletionBesideACueDraftsARepair() {
        let repairs = GoldDerivation.draftRepairs(raw: "let's meet on Tuesday, I mean on Wednesday",
                                                  gold: "Let's meet on Wednesday.")
        XCTAssertEqual(repairs.count, 1)
        // Exactly the shape of the plan's own §3.1 example annotation.
        XCTAssertEqual(repairs.first?.reparandum, "on Tuesday, I mean")
        XCTAssertEqual(repairs.first?.repair, "on Wednesday")
        XCTAssertEqual(repairs.first?.resolveAt, .standard)
    }

    func testADeletionWithNoCueNearbyDraftsNothing() {
        XCTAssertEqual(GoldDerivation.draftRepairs(raw: "I don't know, try some broad benchmarking",
                                                   gold: "Try some broad benchmarking."), [])
        // A cue that is CONTENT ("it doesn't actually allow") keeps its
        // words, so there is no deletion to hang a repair on.
        XCTAssertEqual(GoldDerivation.draftRepairs(raw: "it doesn't actually allow that",
                                                   gold: "It doesn't actually allow that."), [])
    }

    func testTheRepairDraftLandsOnTheFixtureAndPassesLint() throws {
        let fixture = EvalCase(id: "h43", raw: "let's meet on Tuesday, I mean on Wednesday", gold: "",
                               tags: ["unrated"], goldSource: EvalCase.historyUnratedGoldSource,
                               observed: "Let's meet on Wednesday.")
        let out = "Let's meet on Wednesday."
        let result = derived([fixture], [rating("h43", out: out, verdict: .ship)], outputs([("h43", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.repairs.map(\.reparandum), ["on Tuesday, I mean"])
        XCTAssertEqual(after.annotationsStatus, .draft)
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    // MARK: - Rule 6: derived fields stay derived

    func testFillersStuttersAndControlAreNeverWritten() throws {
        let fixture = EvalCase(id: "h12", raw: "um we we ship the fix today", gold: "",
                               tags: ["unrated"], goldSource: EvalCase.historyUnratedGoldSource,
                               observed: "We ship the fix today.")
        let out = "We ship the fix today."
        let after = derived([fixture], [rating("h12", out: out, verdict: .ship)], outputs([("h12", out)])).cases[0]
        XCTAssertNil(after.fillers)
        XCTAssertNil(after.stutters)
        XCTAssertNil(after.control)
        // …and they now derive off the new gold.
        XCTAssertEqual(after.expectedFillers.map(\.span), ["um"])
        XCTAssertEqual(after.expectedStutters.map(\.span), ["we we"])
        XCTAssertFalse(after.isControl)
    }

    func testControlRederivesWhenTheGoldIsThePassThrough() throws {
        let fixture = EvalCase(id: "h70", raw: "We ship the fix today.", gold: "",
                               goldSource: EvalCase.historyUnratedGoldSource,
                               observed: "We ship the fix today.")
        let out = "We ship the fix today."
        let result = derived([fixture], [rating("h70", out: out, verdict: .ship)], outputs([("h70", out)]))
        XCTAssertTrue(result.cases[0].isControl)
        XCTAssertNil(result.cases[0].control)
        XCTAssertTrue(result.changes[0].notes.contains("control (derived) false → true"),
                      "\(result.changes[0].notes)")
    }

    // MARK: - Protection and resolution

    func testAConfirmedGoldIsNeverOverwritten() throws {
        let confirmed = EvalCase(id: "seed-01", raw: "um we ship the fix today", gold: "We ship the fix today.",
                                 goldSource: "seed", annotationsStatus: .confirmed)
        let out = "We ship the fix today!"
        let result = derived([confirmed], [rating("seed-01", out: out, verdict: .ship)], outputs([("seed-01", out)]))
        XCTAssertEqual(result.cases[0].gold, "We ship the fix today.")
        XCTAssertEqual(result.cases[0].goldSource, "seed")
        XCTAssertEqual(result.cases[0].golds, [out])        // appended, not replaced
        XCTAssertEqual(result.protected.count, 1)
        XCTAssertTrue(result.protected[0].reason.contains("is confirmed"), result.protected[0].reason)
    }

    /// One keystroke on an output must not outrank his considered
    /// judgement a week later: a SHIP-derived gold stays a DRAFT, so the
    /// gold he types next pass replaces it instead of being demoted into
    /// `golds[]` by a fixture the SHIP confirmed behind him.
    func testAShipDerivedGoldStaysADraftHisLaterEditReplaces() throws {
        let out = "Try some broad benchmarking on the tabs."
        let shipped = derived([hedge],
                              [rating("h58", out: out, verdict: .ship, formatter: "shipped",
                                      runKey: "7ae02c57ba33")],
                              outputs([("h58", out)])).cases[0]
        XCTAssertEqual(shipped.gold, out)
        XCTAssertEqual(shipped.annotationsStatus, .draft)
        let edit = "I don't know, try some broad benchmarking on the tabs."
        let later = derived([shipped],
                            [rating("h58", out: out, verdict: .wrong, tags: ["reworded"], goldEdit: edit,
                                    at: "2026-09-21T18:03:00Z")],
                            outputs([("h58", out)]))
        XCTAssertEqual(later.cases[0].gold, edit)
        XCTAssertEqual(later.cases[0].goldSource, "edit")
        XCTAssertEqual(later.cases[0].annotationsStatus, .confirmed)
        XCTAssertEqual(later.protected, [])
    }

    func testAConfirmedAnnotationIsNeverOverwritten() throws {
        let confirmed = EvalCase(id: "seed-02", raw: "I don't know, try some broad benchmarking",
                                 gold: "I don't know, try some broad benchmarking.",
                                 mustKeep: [EvalCase.MustKeep(span: "I don't know", weight: 2)],
                                 goldSource: "seed", annotationsStatus: .confirmed)
        let out = "Try some broad benchmarking."
        let result = derived([confirmed],
                             [rating("seed-02", out: out, verdict: .wrong, tags: ["dropped-fact"])],
                             outputs([("seed-02", out)]))
        XCTAssertEqual(result.cases[0].mustKeep, [EvalCase.MustKeep(span: "I don't know", weight: 2)])
        XCTAssertEqual(result.cases[0].annotationsStatus, .confirmed)
    }

    func testAnOutputTheRunsDoNotCarryIsListedNotGuessed() throws {
        let result = derived([hedge], [rating("h58", out: "a text nobody passed", verdict: .ship)],
                             GoldDerivation.Outputs())
        XCTAssertEqual(result.cases, [hedge])
        XCTAssertEqual(result.unresolved.count, 1)
        XCTAssertEqual(result.unresolved[0].id, "h58")
        XCTAssertEqual(result.unresolved[0].formatter, "llama")
    }

    func testOutputsResolveFromARunAndFromTheObservedColumn() throws {
        // `observed` is the shipped output by construction, so the shipped
        // column needs no run file.
        let outputs = GoldDerivation.Outputs(fixtures: [hedge])
        XCTAssertEqual(outputs.text(fixtureId: "h58", outputSha: Rating.outputSha(hedge.observed!)),
                       hedge.observed)
        XCTAssertNil(outputs.text(fixtureId: "h9", outputSha: Rating.outputSha(hedge.observed!)))
    }

    func testAPairwiseRecordDerivesNothing() throws {
        let out = "Try some broad benchmarking on the tabs."
        let pick = Rating(fixtureId: "h58", runKey: "aaaaaaaaaaaa", formatter: "llama",
                          outputSha: Rating.outputSha(out), verdict: nil,
                          pair: Rating.Pair(aRun: "aaaaaaaaaaaa", bRun: "bbbbbbbbbbbb", slot: "a", pick: "b"),
                          msToRate: 2900, ratedAt: "2026-09-14T18:04:00Z", session: "s1")
        XCTAssertEqual(derived([hedge], [pick], outputs([("h58", out)])).changes, [])
    }

    // MARK: - Properties

    func testDerivingTwiceChangesNothingTheSecondTime() throws {
        let out = "Try some broad benchmarking on the tabs."
        let edit = "I don't know, try some broad benchmarking on the tabs."
        let ratings = [rating("h58", out: out, verdict: .wrong, tags: ["dropped-hedge"], goldEdit: edit)]
        let once = derived([hedge], ratings, outputs([("h58", out)]))
        let twice = derived(once.cases, ratings, outputs([("h58", out)]))
        XCTAssertEqual(twice.cases, once.cases)
        XCTAssertEqual(twice.changes, [])
    }

    func testFixturesWithNoRatingsAreUntouched() throws {
        let other = EvalCase(id: "h2", raw: "we ship the fix today", gold: "We ship it.",
                             goldSource: "draft:claude", annotationsStatus: .draft)
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([hedge, other], [rating("h58", out: out, verdict: .ship)], outputs([("h58", out)]))
        XCTAssertEqual(result.cases[1], other)
        XCTAssertEqual(result.cases.count, 2)
    }

    // MARK: - Rule 7: a gold that keeps a disfluency

    /// The measured failure: a full session derived 23 changed fixtures and
    /// then refused the whole file over one row whose accepted output kept
    /// an "uh" — 22 good golds lost to one filled pause. His gold is the
    /// ground truth, so the ANNOTATION bends: the row takes `lint`'s own
    /// opt-out, `fillers: []`, and the diff says so in words.
    func testAGoldThatKeepsAFillerTurnsTheFillerAxisOff() throws {
        let kept = EvalCase(id: "h2", raw: "uh the blue kettle is uh on the counter and uh it needs descaling",
                            gold: "", tags: ["unrated"], source: "history:2",
                            goldSource: EvalCase.historyUnratedGoldSource, annotationsStatus: .draft,
                            observed: "The blue kettle is on the counter and uh it needs descaling.")
        let out = "The blue kettle is on the counter and uh it needs descaling."
        let result = derived([kept], [rating("h2", out: out, verdict: .ship)], outputs([("h2", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.gold, out)
        XCTAssertEqual(after.fillers, [])
        XCTAssertEqual(after.expectedFillers, [])
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "fillers: [] — this gold keeps \"uh\" (occurrence 3); `lint`'s opt-out is the whole list, "
                + "so the 2 filler(s) it does remove stop being scored too"
        }, "\(result.changes[0].notes)")
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "Fi is off for this row — nothing is expected removed any more"
        }, "\(result.changes[0].notes)")
        // The axis is off, not silently zero: his own gold scores nothing
        // on Fi rather than 0 on it.
        XCTAssertNil(QualityScore.score(after, out: out).fillers)
        // The whole point: the derived set lints clean, so `--write` writes.
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
        XCTAssertEqual(GoldDerivation.writable(result).held, [])
        // A gold that removes every filler leaves the axis alone.
        let stripped = "The blue kettle is on the counter and it needs descaling."
        let clean = derived([kept], [rating("h2", out: stripped, verdict: .ship)],
                            outputs([("h2", stripped)]))
        XCTAssertNil(clean.cases[0].fillers)
        XCTAssertFalse(clean.changes[0].notes.contains { $0.hasPrefix("fillers:") },
                       "\(clean.changes[0].notes)")
    }

    /// `lint` only reads `fillers` when it is nil or non-empty, so the
    /// opt-out is the linter's own rule, not a hole punched beside it. And
    /// the list rule 7 bends off is one list: `retainedFillers` answers
    /// the same for an ANNOTATED survivor as for an unannotated one — both
    /// are a gold contradicting an expectation, and both bend.
    func testTheKeptFillerListIsTheLinterSOwnRule() throws {
        let raw = "uh the blue kettle is uh on the counter and uh it needs descaling"
        let gold = "The blue kettle is on the counter and uh it needs descaling."
        XCTAssertEqual(EvalLint.retainedFillers(raw: raw, gold: gold, language: .english, fillers: nil),
                       [EvalCase.Filler(span: "uh", occurrence: 3)])
        XCTAssertEqual(EvalLint.retainedFillers(raw: raw, gold: gold, language: .english, fillers: []), [])
        XCTAssertEqual(EvalLint.retainedFillers(raw: raw, gold: gold, language: .english,
                                                fillers: [EvalCase.Filler(span: "uh", occurrence: 3)]),
                       [EvalCase.Filler(span: "uh", occurrence: 3)])
    }

    /// Fi's expected set is `fillers` ∪ `stutters`, so bending the filler
    /// half alone leaves the axis ON: an annotated stutter run the same
    /// gold keeps scores his own accepted gold 0 on the row he just
    /// settled, under a diff line claiming the axis was off. The whole
    /// disfluency annotation bends, and the diff says what went.
    func testAGoldThatKeepsBothBendsTheWholeDisfluencyAnnotation() throws {
        let raw = "uh and a and the blue kettle needs descaling"
        let out = "Uh, and a and the blue kettle needs descaling."
        let kept = EvalCase(id: "h3", raw: raw, gold: "", tags: ["unrated"],
                            stutters: [EvalCase.Stutter(span: "and a and", keep: "and")],
                            source: "history:3", goldSource: EvalCase.historyUnratedGoldSource,
                            annotationsStatus: .draft, observed: out)
        // Half a bend is what the row used to get, and this is what it cost.
        let halfBent = EvalCase(id: "h3", raw: raw, gold: out, fillers: [], stutters: kept.stutters)
        XCTAssertEqual(QualityScore.score(halfBent, out: out).fillers?.score, 0)

        let result = derived([kept], [rating("h3", out: out, verdict: .ship)], outputs([("h3", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.gold, out)
        XCTAssertEqual(after.fillers, [])
        XCTAssertEqual(after.stutters, [])
        XCTAssertEqual(after.expectedFillers, [])
        XCTAssertEqual(after.expectedStutters, [])
        XCTAssertNil(QualityScore.score(after, out: out).fillers)
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "− stutters \"and a and\"  [this gold keeps \"and a and\" where the annotation "
                + "keeps \"and\"]; stutters: [] — the list is empty now"
        }, "\(result.changes[0].notes)")
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "Fi is off for this row — nothing is expected removed any more"
        }, "\(result.changes[0].notes)")
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    /// Only the entries the gold contradicts: a run it DOES collapse is
    /// still expected of the formatter, and the diff says how much of the
    /// axis is left.
    func testOnlyTheStutterRunTheGoldKeepsIsDropped() throws {
        let raw = "and a and the the blue kettle needs descaling"
        let out = "And a and the blue kettle needs descaling."
        let kept = EvalCase(id: "h4", raw: raw, gold: "", tags: ["unrated"],
                            stutters: [EvalCase.Stutter(span: "and a and", keep: "and"),
                                       EvalCase.Stutter(span: "the the", keep: "the")],
                            source: "history:4", goldSource: EvalCase.historyUnratedGoldSource,
                            annotationsStatus: .draft, observed: out)
        let result = derived([kept], [rating("h4", out: out, verdict: .ship)], outputs([("h4", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.stutters, [EvalCase.Stutter(span: "the the", keep: "the")])
        XCTAssertNil(after.fillers)
        XCTAssertEqual(QualityScore.score(after, out: out).fillers?.expected, 1)
        XCTAssertEqual(QualityScore.score(after, out: out).fillers?.score, 100)
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "− stutters \"and a and\"  [this gold keeps \"and a and\" where the annotation "
                + "keeps \"and\"]"
        }, "\(result.changes[0].notes)")
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "Fi still expects 1 removal(s) this gold does make"
        }, "\(result.changes[0].notes)")
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    /// "Keeps" is survival, not "was not deleted". A filler the gold
    /// REPLACES aligns as a `.sub` — it is gone from the gold and expects
    /// nothing — so the row keeps its filler axis instead of losing it to
    /// a bend nobody asked for.
    func testAFillerTheGoldReplacesIsNotAFillerItKeeps() throws {
        let raw = "we er ship the fix today"
        let gold = "We also ship the fix today."
        let ops = Align.align(Align.canonicalTokens(raw), Align.canonicalTokens(gold)).opsA
        guard case .sub = ops[1] else { return XCTFail("'er' should align as a sub: \(ops)") }
        XCTAssertEqual(EvalLint.retainedFillers(raw: raw, gold: gold, language: .english, fillers: nil), [])

        let replaced = EvalCase(id: "h5", raw: raw, gold: "", tags: ["unrated"], source: "history:5",
                                goldSource: EvalCase.historyUnratedGoldSource, annotationsStatus: .draft,
                                observed: gold)
        let result = derived([replaced], [rating("h5", out: gold, verdict: .ship)], outputs([("h5", gold)]))
        XCTAssertNil(result.cases[0].fillers)
        XCTAssertFalse(result.changes[0].notes.contains { $0.hasPrefix("fillers:") },
                       "\(result.changes[0].notes)")
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    /// The bend is a deletion, so it reads the ANNOTATIONS' status like
    /// the other two: a set he CONFIRMED refuses the gold as a conflict
    /// and leaves the row exactly as it was — his annotation and his
    /// rating disagree, and that is his to settle.
    func testAConfirmedDisfluencyAnnotationRefusesTheGoldInsteadOfBeingDeleted() throws {
        let raw = "uh the blue kettle is uh on the counter"
        let out = "The blue kettle is uh on the counter."
        let confirmed = EvalCase(id: "h6", raw: raw, gold: "", tags: ["unrated"],
                                 fillers: [EvalCase.Filler(span: "uh", occurrence: 1),
                                           EvalCase.Filler(span: "uh", occurrence: 2)],
                                 source: "history:6", goldSource: EvalCase.historyUnratedGoldSource,
                                 annotationsStatus: .confirmed, observed: out)
        let result = derived([confirmed], [rating("h6", out: out, verdict: .ship)], outputs([("h6", out)]))
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(result.cases[0], confirmed)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertTrue(result.conflicts[0].reason.contains("it keeps the filler \"uh\""),
                      result.conflicts[0].reason)
        // The same annotations as a DRAFT are the agent's guess, not his:
        // there the gold wins and the axis bends.
        let draft = EvalCase(id: "h6", raw: raw, gold: "", tags: ["unrated"], fillers: confirmed.fillers,
                             source: "history:6", goldSource: EvalCase.historyUnratedGoldSource,
                             annotationsStatus: .draft, observed: out)
        let bent = derived([draft], [rating("h6", out: out, verdict: .ship)], outputs([("h6", out)]))
        XCTAssertEqual(bent.conflicts, [])
        XCTAssertEqual(bent.cases[0].gold, out)
        XCTAssertEqual(bent.cases[0].fillers, [])

        // The stutter half, in the direction "did more survive than `keep`
        // allows" cannot see: a CONFIRMED run his gold collapses PAST its
        // keep is his annotation against his own rating, and the refusal
        // says which way they disagree.
        let past = "It is a harbour ferry we booked."
        let overCollapsed = EvalCase(id: "h6b", raw: "it is a like a a harbour ferry we booked",
                                     gold: "", tags: ["unrated"],
                                     stutters: [EvalCase.Stutter(span: "a like a a", keep: "like a")],
                                     source: "history:6", goldSource: EvalCase.historyUnratedGoldSource,
                                     annotationsStatus: .confirmed, observed: past)
        let refused = derived([overCollapsed], [rating("h6b", out: past, verdict: .ship)],
                              outputs([("h6b", past)]))
        XCTAssertEqual(refused.changes, [])
        XCTAssertEqual(refused.conflicts.count, 1)
        XCTAssertTrue(refused.conflicts[0].reason.hasSuffix(
            "of the stutter run \"a like a a\" it keeps \"a\" where the annotations "
                + "keep \"like a\""), refused.conflicts[0].reason)
    }

    /// And the line that refusal must not cross. A history export writes
    /// `confirmed` and no annotations at all, so a DERIVED expectation is
    /// nobody's annotation: reading the status there would refuse every
    /// row whose accepted output keeps an "uh" — the same 22 golds, lost
    /// to the guard instead of to the linter.
    func testADerivedAxisBendsOnAConfirmedExportRowToo() throws {
        let raw = "uh the blue kettle is uh on the counter"
        let out = "The blue kettle is uh on the counter."
        let exported = EvalCase(id: "h7", raw: raw, gold: "", tags: ["unrated"], source: "history:7",
                                goldSource: EvalCase.historyUnratedGoldSource, observed: out)
        XCTAssertEqual(exported.annotationsStatus, .confirmed)   // the export writes no status
        let result = derived([exported], [rating("h7", out: out, verdict: .ship)], outputs([("h7", out)]))
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.cases[0].gold, out)
        XCTAssertEqual(result.cases[0].fillers, [])
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    /// What the opt-out costs is counted on `lint`'s identity, not on the
    /// synthesized one. The kept list carries RAW's casing — the
    /// sentence-initial "Uh" — and his annotation carries his own "uh", so
    /// span-plus-occurrence equality read the kept filler as a fourth,
    /// different one and the line claimed three removals lost over a gold
    /// that removes two.
    func testTheBendCountsWhatItLosesOnLintsOwnIdentity() throws {
        let raw = "Uh the harbour ferry is uh late again and uh nobody posted why"
        let out = "Uh, the harbour ferry is late again and nobody posted why."
        let annotated = EvalCase(id: "h8", raw: raw, gold: "", tags: ["unrated"],
                                 fillers: [EvalCase.Filler(span: "uh", occurrence: 1),
                                           EvalCase.Filler(span: "uh", occurrence: 2),
                                           EvalCase.Filler(span: "uh", occurrence: 3)],
                                 source: "history:8", goldSource: EvalCase.historyUnratedGoldSource,
                                 annotationsStatus: .draft, observed: out)
        // The gold keeps the one raw spells "Uh" and removes the two it
        // spells "uh".
        XCTAssertEqual(EvalLint.retainedFillers(raw: raw, gold: out, language: .english,
                                                fillers: annotated.fillers),
                       [EvalCase.Filler(span: "Uh", occurrence: 1)])
        let result = derived([annotated], [rating("h8", out: out, verdict: .ship)], outputs([("h8", out)]))
        XCTAssertEqual(result.cases[0].fillers, [])
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "fillers: [] — this gold keeps \"Uh\"; `lint`'s opt-out is the whole list, "
                + "so the 2 filler(s) it does remove stop being scored too"
        }, "\(result.changes[0].notes)")
    }

    /// A marker that repeats, and a gold that removes the occurrence the
    /// annotation points at. "Is this span anywhere in the gold" answers
    /// yes — the other occurrence is right there — and the axis went off
    /// over a gold doing exactly what the row expects. Read at its own
    /// occurrence in raw, nothing bends and Fi scores the removal it made.
    func testAGoldThatRemovesTheAnnotatedOccurrenceBendsNothing() throws {
        let raw = "you know the harbour ferry is you know late again"
        let out = "You know, the harbour ferry is late again."
        let marked = EvalCase(id: "h9", raw: raw, gold: "", tags: ["unrated"],
                              fillers: [EvalCase.Filler(span: "you know", occurrence: 2)],
                              source: "history:9", goldSource: EvalCase.historyUnratedGoldSource,
                              annotationsStatus: .draft, observed: out)
        // The span IS in the gold — the first marker is untouched — and
        // the list the bend reads says nothing was kept anyway.
        XCTAssertNotNil(Align.locate("you know", in: Align.canonicalTokens(out)))
        XCTAssertEqual(EvalLint.retainedFillers(raw: raw, gold: out, language: .english,
                                                fillers: marked.fillers), [])

        let result = derived([marked], [rating("h9", out: out, verdict: .ship)], outputs([("h9", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.gold, out)
        XCTAssertEqual(after.fillers, marked.fillers)
        XCTAssertFalse(result.changes[0].notes.contains { $0.hasPrefix("fillers:") },
                       "\(result.changes[0].notes)")
        XCTAssertEqual(QualityScore.score(after, out: out).fillers?.score, 100)
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    /// The same read with its sign flipped, and the reason the occurrence
    /// is followed through the alignment instead of counted in the gold:
    /// his gold drops the FIRST marker and keeps the second, so the gold
    /// carries one where the annotation names two. Looked up there, the
    /// axis stays on over a marker the gold keeps — and scores the gold he
    /// just accepted 0 on Fi.
    func testTheOccurrenceIsARawIndexNotAGoldOne() throws {
        let raw = "you know the harbour ferry is you know late again"
        let out = "The harbour ferry is, you know, late again."
        let marked = EvalCase(id: "h10", raw: raw, gold: "", tags: ["unrated"],
                              fillers: [EvalCase.Filler(span: "you know", occurrence: 2)],
                              source: "history:10", goldSource: EvalCase.historyUnratedGoldSource,
                              annotationsStatus: .draft, observed: out)
        // What leaving the axis on costs: his own gold, 0 on Fi.
        let unbent = EvalCase(id: "h10", raw: raw, gold: out, fillers: marked.fillers)
        XCTAssertEqual(QualityScore.score(unbent, out: out).fillers?.score, 0)
        XCTAssertEqual(Align.locate("you know", in: Align.canonicalTokens(out), occurrence: 2), nil)
        XCTAssertEqual(EvalLint.retainedFillers(raw: raw, gold: out, language: .english,
                                                fillers: marked.fillers), marked.fillers)

        let result = derived([marked], [rating("h10", out: out, verdict: .ship)], outputs([("h10", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.fillers, [])
        XCTAssertNil(QualityScore.score(after, out: out).fillers)
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "fillers: [] — this gold keeps \"you know\" (occurrence 2); `lint`'s opt-out is the "
                + "whole list, so nothing else was expected here"
        }, "\(result.changes[0].notes)")
    }

    /// Half a marker is the same contradiction: a filled pause may keep NO
    /// copies, so a gold that drops the "know" and leaves the "you" holds
    /// one more than the row allows, Fi charges the surplus, and the axis
    /// has to bend. A predicate that wants the whole span to have survived
    /// reads that gold as removing the marker, bends nothing, and his own
    /// accepted gold fails `lint`'s invariant.
    ///
    /// The raw carries the marker ONCE, which is what makes the claim
    /// testable: with a second, untouched copy elsewhere, "is this span
    /// anywhere in the gold" answers yes off THAT one and the row bends
    /// whatever the annotated copy did — the reading that was really being
    /// pinned, and a gap on every row where the marker appears alone.
    func testAMarkerTheGoldOnlyHalfRemovesBendsTheAxisToo() throws {
        let raw = "you know the harbour ferry is late again"
        let out = "You the harbour ferry is late again."
        let marked = EvalCase(id: "h16", raw: raw, gold: "", tags: ["unrated"],
                              fillers: [EvalCase.Filler(span: "you know", occurrence: 1)],
                              source: "history:16", goldSource: EvalCase.historyUnratedGoldSource,
                              annotationsStatus: .draft, observed: out)
        // Hand-counted: the marker is raw[0...1]; the gold keeps "you" (0)
        // and drops "know" (1). The span itself is nowhere in the gold.
        let rawTokens = Align.canonicalTokens(raw)
        let opsA = Align.align(rawTokens, Align.canonicalTokens(out)).opsA
        XCTAssertEqual((0...1).filter { opsA[$0].survives }.map { rawTokens[$0].normalized }, ["you"])
        XCTAssertNil(Align.locate("you know", in: Align.canonicalTokens(out)))
        // What leaving the axis on costs: his own gold, 0 on Fi, and a
        // fixture that fails its own linter.
        let unbent = EvalCase(id: "h16", raw: raw, gold: out, fillers: marked.fillers)
        XCTAssertEqual(QualityScore.score(unbent, out: out).fillers?.score, 0)
        XCTAssertTrue(EvalLint.hasErrors(EvalLint.row(unbent)), "\(EvalLint.row(unbent).map(\.description))")
        // The one list, counting survivals at the entry's own occurrence:
        // "is the span in the gold" answers no here and left the axis on.
        XCTAssertEqual(EvalLint.retainedFillers(raw: raw, gold: out, language: .english,
                                                fillers: marked.fillers), marked.fillers)

        let result = derived([marked], [rating("h16", out: out, verdict: .ship)], outputs([("h16", out)]))
        XCTAssertEqual(result.cases[0].fillers, [])
        XCTAssertNil(QualityScore.score(result.cases[0], out: out).fillers)
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
        // The note names what the gold kept, not the span the annotation
        // named: the marker itself is not in this gold.
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "fillers: [] — this gold keeps \"you\" of \"you know\"; `lint`'s opt-out is the "
                + "whole list, so nothing else was expected here"
        }, "\(result.changes[0].notes)")
        // End to end through `gold --write`: the bend is what makes the row
        // writable, and a row held back takes the session's other golds
        // with it under the plain path.
        let write = GoldDerivation.writable(result)
        XCTAssertEqual(write.written, ["h16"])
        XCTAssertEqual(write.held, [])
        XCTAssertTrue(GoldDerivation.writeDecision(write, issues: EvalLint.lint(write.cases),
                                                   changes: result.changes.count, skipFailing: false,
                                                   lintPath: "personal.json").writes)
    }

    /// The multi-occurrence row on the stutter half: two runs of the same
    /// words, a gold that collapses the first and keeps the second. The
    /// span alone cannot tell them apart, so both entries went and the
    /// removal his gold DOES make stopped being scored. At its own
    /// occurrence only the standing run goes.
    func testOnlyTheStutterOccurrenceTheGoldKeepsIsDropped() throws {
        let raw = "and and we ship the kettle today and and we test it tomorrow"
        let out = "And we ship the kettle today and and we test it tomorrow."
        let runs = [EvalCase.Stutter(span: "and and", keep: "and", occurrence: 1),
                    EvalCase.Stutter(span: "and and", keep: "and", occurrence: 2)]
        let kept = EvalCase(id: "h11", raw: raw, gold: "", tags: ["unrated"], stutters: runs,
                            source: "history:11", goldSource: EvalCase.historyUnratedGoldSource,
                            annotationsStatus: .draft, observed: out)
        // The span is in the gold either way, so it cannot tell the two
        // apart; at its own occurrence only the standing run contradicts.
        XCTAssertNotNil(Align.locate("and and", in: Align.canonicalTokens(out)))
        XCTAssertEqual(GoldDerivation.contradictedStutters(raw: raw, gold: out, stutters: runs), [runs[1]])

        let result = derived([kept], [rating("h11", out: out, verdict: .ship)], outputs([("h11", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.stutters, [runs[0]])
        XCTAssertEqual(QualityScore.score(after, out: out).fillers?.expected, 1)
        XCTAssertEqual(QualityScore.score(after, out: out).fillers?.score, 100)
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "− stutters \"and and\" (occurrence 2)  [this gold keeps \"and and\" where the "
                + "annotation keeps \"and\"]"
        }, "\(result.changes[0].notes)")
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "Fi still expects 1 removal(s) this gold does make"
        }, "\(result.changes[0].notes)")
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    /// The run a gold HALF-collapses — the shape his own h44 has, and the
    /// one that held a whole 70-row `--write` back. Raw carries "a like
    /// a a", the annotation keeps "like a", and the shipped output
    /// he accepted keeps "a like a": one copy more than the `keep`
    /// allows, which is the surplus Fi charges and scores his own gold 0
    /// on. "Was the run left intact" answers NO there — one "a" did go —
    /// so nothing bent, the fixture failed `lint`'s invariant, and the
    /// refusal cost him every other gold in the session.
    func testAStutterRunTheGoldHalfCollapsesBendsToo() throws {
        let raw = "it is a like a a harbour ferry we booked"
        let out = "It is a like a harbour ferry we booked."
        let runs = [EvalCase.Stutter(span: "a like a a", keep: "like a")]
        // Hand-counted: the run is raw[2...5]. The gold keeps "a" (2),
        // "like" (3) and "a" (4) and drops "a" (5) — "a" survives
        // twice where `keep` allows it once.
        let rawTokens = Align.canonicalTokens(raw)
        let opsA = Align.align(rawTokens, Align.canonicalTokens(out)).opsA
        XCTAssertEqual((2...5).filter { opsA[$0].survives }.map { rawTokens[$0].normalized },
                       ["a", "like", "a"])
        // What leaving it on costs: his own accepted gold, 0 on Fi, and a
        // fixture that fails its own linter.
        let unbent = EvalCase(id: "h13", raw: raw, gold: out, stutters: runs)
        XCTAssertEqual(QualityScore.score(unbent, out: out).fillers?.score, 0)
        XCTAssertTrue(EvalLint.hasErrors(EvalLint.row(unbent)), "\(EvalLint.row(unbent).map(\.description))")

        let kept = EvalCase(id: "h13", raw: raw, gold: "", tags: ["unrated"], stutters: runs,
                            source: "history:13", goldSource: EvalCase.historyUnratedGoldSource,
                            annotationsStatus: .draft, observed: out)
        XCTAssertEqual(GoldDerivation.contradictedStutters(raw: raw, gold: out, stutters: runs), runs)

        let result = derived([kept], [rating("h13", out: out, verdict: .ship)], outputs([("h13", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.gold, out)
        XCTAssertEqual(after.stutters, [])
        XCTAssertNil(QualityScore.score(after, out: out).fillers)
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "− stutters \"a like a a\"  [this gold keeps \"a like a\" where the "
                + "annotation keeps \"like a\"]; stutters: [] — the list is empty now"
        }, "\(result.changes[0].notes)")
        // The regression itself: the row lints clean, so the session's
        // golds go in.
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
        XCTAssertEqual(GoldDerivation.writable(result).held, [])
    }

    /// The other direction, and the one "did more survive than `keep`
    /// allows" cannot see: a gold that collapses the run PAST the
    /// annotation. Raw carries "a like a a", the annotation keeps
    /// "like a", and the gold he accepted keeps only "a". Fi holds an
    /// EXPLICIT span to its own `keep`, so a word the annotation states
    /// survives and the gold cut is no collapse at all — it credits the
    /// span nothing, scores his own accepted gold 0 on Fi and fails
    /// `lint`'s invariant exactly as a surplus copy does, and the write is
    /// held back exactly the same way. Rule 7 is his gold outranking an
    /// annotation that disagrees with it, whichever way it disagrees.
    func testAStutterRunTheGoldCollapsesPastItsKeepBendsToo() throws {
        let raw = "it is a like a a harbour ferry we booked"
        let out = "It is a harbour ferry we booked."
        let runs = [EvalCase.Stutter(span: "a like a a", keep: "like a")]
        // Hand-counted: of raw[2...5] the gold keeps one "a" and drops
        // the "like" the annotation says survives.
        let rawTokens = Align.canonicalTokens(raw)
        let opsA = Align.align(rawTokens, Align.canonicalTokens(out)).opsA
        XCTAssertEqual((2...5).filter { opsA[$0].survives }.map { rawTokens[$0].normalized }, ["a"])
        // What leaving it on costs: his own accepted gold, 0 on Fi, and a
        // fixture that fails its own linter.
        let unbent = EvalCase(id: "h17", raw: raw, gold: out, stutters: runs)
        XCTAssertEqual(QualityScore.score(unbent, out: out).fillers?.score, 0)
        XCTAssertTrue(EvalLint.hasErrors(EvalLint.row(unbent)), "\(EvalLint.row(unbent).map(\.description))")
        XCTAssertEqual(GoldDerivation.contradictedStutters(raw: raw, gold: out, stutters: runs), runs)

        let kept = EvalCase(id: "h17", raw: raw, gold: "", tags: ["unrated"], stutters: runs,
                            source: "history:17", goldSource: EvalCase.historyUnratedGoldSource,
                            annotationsStatus: .draft, observed: out)
        let result = derived([kept], [rating("h17", out: out, verdict: .ship)], outputs([("h17", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.gold, out)
        XCTAssertEqual(after.stutters, [])
        XCTAssertNil(QualityScore.score(after, out: out).fillers)
        // The line says what the gold LEFT, which is the only sentence
        // true of a deficit as well as of a surplus.
        XCTAssertTrue(result.changes[0].notes.contains {
            $0 == "− stutters \"a like a a\"  [this gold keeps \"a\" where the annotation "
                + "keeps \"like a\"]; stutters: [] — the list is empty now"
        }, "\(result.changes[0].notes)")
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
        XCTAssertEqual(GoldDerivation.writable(result).held, [])
    }

    /// And the floor under the count. A gold that collapses the run
    /// EXACTLY as the annotation asks keeps what its `keep` states,
    /// contradicts nothing in either direction and goes on being scored —
    /// a bend here would switch Fi off on the rows the formatter got
    /// RIGHT.
    func testAStutterRunTheGoldCollapsesAsAnnotatedBendsNothing() throws {
        let raw = "it is a like a a harbour ferry we booked"
        let out = "It is like a harbour ferry we booked."
        let runs = [EvalCase.Stutter(span: "a like a a", keep: "like a")]
        // Hand-counted: of raw[2...5] the gold keeps one "like" and one
        // "a" — the `keep`, exactly.
        let rawTokens = Align.canonicalTokens(raw)
        let opsA = Align.align(rawTokens, Align.canonicalTokens(out)).opsA
        XCTAssertEqual((2...5).filter { opsA[$0].survives }.map { rawTokens[$0].normalized }.sorted(),
                       ["a", "like"])
        XCTAssertEqual(GoldDerivation.contradictedStutters(raw: raw, gold: out, stutters: runs), [])

        let kept = EvalCase(id: "h14", raw: raw, gold: "", tags: ["unrated"], stutters: runs,
                            source: "history:14", goldSource: EvalCase.historyUnratedGoldSource,
                            annotationsStatus: .draft, observed: out)
        let result = derived([kept], [rating("h14", out: out, verdict: .ship)], outputs([("h14", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.stutters, runs)
        XCTAssertEqual(QualityScore.score(after, out: out).fillers?.expected, 1)
        XCTAssertEqual(QualityScore.score(after, out: out).fillers?.score, 100)
        XCTAssertFalse(result.changes[0].notes.contains { $0.hasPrefix("− stutters") },
                       "\(result.changes[0].notes)")
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(result.cases)),
                       "\(EvalLint.lint(result.cases).map(\.description))")
    }

    /// The same reading on `lint`'s own side. The kept-filler warning
    /// asked whether the token was ALIGNED, which a `.sub` is, so a gold
    /// that REPLACES the "er" was reported as keeping a word it does not
    /// carry — and the row was told to annotate a filler its reader cannot
    /// find. Survival is the test there too.
    func testAFillerTheGoldReplacesIsNotWarnedAsKept() throws {
        let raw = "we er ship the fix today"
        let gold = "We also ship the fix today."
        // Hand-counted: "er" is raw[1] and pairs with "also" — aligned,
        // and gone.
        let opsA = Align.align(Align.canonicalTokens(raw), Align.canonicalTokens(gold)).opsA
        guard case .sub = opsA[1] else { return XCTFail("'er' should align as a sub: \(opsA)") }
        XCTAssertTrue(opsA[1].isAligned)
        XCTAssertFalse(opsA[1].survives)

        let replaced = EvalCase(id: "h15", raw: raw, gold: gold)
        // Nothing expects its removal either — `deriveFillers` reads the
        // deletions, and a replaced word is not one — so a warning here
        // would be the only thing on the row, and wrong.
        XCTAssertEqual(replaced.expectedFillers, [])
        let issues = EvalLint.row(replaced)
        XCTAssertFalse(issues.contains { $0.message.contains("is kept in gold") },
                       "\(issues.map(\.description))")
        XCTAssertFalse(EvalLint.hasErrors(issues), "\(issues.map(\.description))")
        // A gold that really does keep it is still warned about: this is a
        // narrower reading of "kept", not a quieter linter.
        let keeps = EvalCase(id: "h15", raw: raw, gold: "We er ship the fix today.")
        XCTAssertTrue(EvalLint.row(keeps).contains {
            $0.severity == .warning
                && $0.message == "filler 'er' (occurrence 1) is kept in gold and not annotated"
        }, "\(EvalLint.row(keeps).map(\.description))")
    }

    /// The bend is a MACHINE's decision about his annotations, so it
    /// drafts them. An export row reads `confirmed` (the export writes no
    /// status), and an Fi axis switched off underneath that reads as a
    /// call somebody checked — and counts as rated in the composite.
    func testTheBendDraftsTheAnnotationItRewrote() throws {
        let raw = "uh the harbour ferry is uh late again"
        let out = "The harbour ferry is uh late again."
        let exported = EvalCase(id: "h12", raw: raw, gold: "", tags: ["unrated"], source: "history:12",
                                goldSource: EvalCase.historyUnratedGoldSource, observed: out)
        XCTAssertEqual(exported.annotationsStatus, .confirmed)   // the export writes no status
        let result = derived([exported], [rating("h12", out: out, verdict: .ship)], outputs([("h12", out)]))
        let after = result.cases[0]
        XCTAssertEqual(after.fillers, [])
        XCTAssertEqual(after.annotationsStatus, .draft)
        XCTAssertTrue(result.changes[0].notes.contains { $0 == "annotations_status confirmed → draft" },
                      "\(result.changes[0].notes)")
        let issues = EvalLint.lint(result.cases)
        XCTAssertFalse(EvalLint.hasErrors(issues), "\(issues.map(\.description))")
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.message.hasPrefix("draft gold") },
                      "\(issues.map(\.description))")
        // And `y` in the same pass does not bless what the bend wrote
        // behind it (§7.3.4).
        let confirmed = derived([exported],
                                [rating("h12", out: out, verdict: .ship),
                                 rating("h12", out: out, verdict: nil, confirm: true)],
                                outputs([("h12", out)]))
        XCTAssertEqual(confirmed.cases[0].annotationsStatus, .draft)
        XCTAssertTrue(confirmed.changes[0].notes.contains {
            $0 == "confirm held — annotations drafted in this same pass"
        }, "\(confirmed.changes[0].notes)")
    }

    // MARK: - What --write writes

    /// One bad fixture never costs the others. A `control: true` row he
    /// SHIPs a reworded output on derives a gold that breaks the
    /// pass-through rule — a real `lint` error — and the plain `--write`
    /// refuses the whole file for it. `--skip-failing` writes the rest and
    /// hands the row back with the error that holds it.
    func testOneFixtureThatFailsLintNeverCostsTheOthers() throws {
        let control = EvalCase(id: "h71", raw: "we ship the fix today", gold: "", tags: ["unrated"],
                               control: true, source: "history:71",
                               goldSource: EvalCase.historyUnratedGoldSource, annotationsStatus: .draft,
                               observed: "We ship the fix tomorrow.")
        let reworded = "We ship the fix tomorrow."
        let good = "Try some broad benchmarking on the tabs."
        let result = derived([hedge, control],
                             [rating("h58", out: good, verdict: .ship),
                              rating("h71", out: reworded, verdict: .ship)],
                             outputs([("h58", good), ("h71", reworded)]))
        XCTAssertEqual(result.changes.count, 2)
        XCTAssertTrue(EvalLint.hasErrors(EvalLint.lint(result.cases)))   // the whole file refuses

        let write = GoldDerivation.writable(result)
        XCTAssertEqual(write.written, ["h58"])
        XCTAssertEqual(write.held.map(\.id), ["h71"])
        XCTAssertTrue(write.held[0].reason.contains("control: true"), write.held[0].reason)
        XCTAssertEqual(write.cases[0], result.cases[0])                  // his gold, written
        XCTAssertEqual(write.cases[1], control)                          // the bad row, untouched
        XCTAssertFalse(EvalLint.hasErrors(EvalLint.lint(write.cases)),
                       "\(EvalLint.lint(write.cases).map(\.description))")
        XCTAssertTrue(write.render().contains("h71: control: true"), write.render())
        XCTAssertEqual(write.render().contains("h58"), false, write.render())
    }

    /// An error the file already carried is not this pass's doing: holding
    /// the change back would not fix it, so the change is written and the
    /// error stays visible to `lint`.
    func testAnErrorTheFileAlreadyCarriedIsNotHeldAgainstTheChange() throws {
        let broken = EvalCase(id: "h72", raw: "we ship the fix today", gold: "", tags: ["unrated"],
                              mustKeep: [EvalCase.MustKeep(span: "the fix", weight: 0)],
                              source: "history:72", goldSource: EvalCase.historyUnratedGoldSource,
                              annotationsStatus: .draft, observed: "We ship the fix today.")
        XCTAssertTrue(EvalLint.hasErrors(EvalLint.row(broken)))          // weight 0 < 1
        let out = "We ship the fix today."
        let result = derived([broken], [rating("h72", out: out, verdict: .ship)], outputs([("h72", out)]))
        let write = GoldDerivation.writable(result)
        XCTAssertEqual(write.written, ["h72"])
        XCTAssertEqual(write.held, [])
        XCTAssertEqual(write.cases[0].gold, out)
        XCTAssertEqual(write.render(), "")
    }

    /// The other side of the same sort: an annotation a gold-free row was
    /// never held to. `fillers: ['um']` on a raw with no "um" is a broken
    /// span before and after, but the gold this pass derives also has to
    /// score 100 against that annotation (§9) — a rule that cannot fire
    /// while the row has no gold. So the pass IS what made the row fail,
    /// the row is held back untouched, and the one error named is the one
    /// the pass introduced.
    func testAnAnnotationOnlyAGoldMakesDecidableHoldsTheRowBack() throws {
        let broken = EvalCase(id: "h73", raw: "we ship the fix today", gold: "",
                              tags: ["unrated"], fillers: [EvalCase.Filler(span: "um", occurrence: 1)],
                              source: "history:73", goldSource: EvalCase.historyUnratedGoldSource,
                              annotationsStatus: .draft, observed: "We ship the fix today.")
        let out = "We ship the fix today."
        let result = derived([hedge, broken],
                             [rating("h58", out: "Try some broad benchmarking on the tabs.", verdict: .ship),
                              rating("h73", out: out, verdict: .ship)],
                             outputs([("h58", "Try some broad benchmarking on the tabs."), ("h73", out)]))
        let write = GoldDerivation.writable(result)
        XCTAssertEqual(write.written, ["h58"])                           // his other gold is untouched by it
        XCTAssertEqual(write.held.map(\.id), ["h73"])
        XCTAssertEqual(write.held[0].reason,
                       "gold does not score 100 against itself: F 100.0 Fi 0.0 M 100.0 C 80.0 "
                       + "[MISSED] — Fi missed 'um'")
        XCTAssertEqual(write.cases[1], broken)                           // the file as it was
    }

    /// And the refusal reads off the same sort. A row that was already
    /// failing before he rated anything holds nothing back, so `--write`
    /// writes the changes `writable` proved clean and prints those errors
    /// as the warnings they are — refusing there cost him every gold in
    /// the session over a row the pass never touched.
    func testAPreExistingErrorIsWrittenAsAWarningNotARefusal() throws {
        let broken = EvalCase(id: "h72", raw: "we ship the kettle today", gold: "",
                              tags: ["unrated"], fillers: [EvalCase.Filler(span: "um", occurrence: 1)],
                              source: "history:72", goldSource: EvalCase.historyUnratedGoldSource,
                              annotationsStatus: .draft, observed: "We ship the kettle today.")
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([hedge, broken], [rating("h58", out: out, verdict: .ship)],
                             outputs([("h58", out)]))
        let set = GoldDerivation.writable(result)
        XCTAssertEqual(set.held, [])
        let issues = EvalLint.lint(set.cases)
        XCTAssertTrue(EvalLint.hasErrors(issues))                        // 'um' is not in h72's raw
        let decision = GoldDerivation.writeDecision(set, issues: issues, changes: result.changes.count,
                                                    skipFailing: false, lintPath: "/tmp/personal.json")
        XCTAssertTrue(decision.writes)
        XCTAssertEqual(decision.render(),
                       "1 lint error(s) this pass did not introduce — the 1 change(s) here are clean, "
                       + "so they are written:\n"
                       + "  error: [h72] filler 'um' (occurrence 1) not found in raw\n"
                       + "fix those rows by hand (`whispr-bench lint /tmp/personal.json`)")
        // Nothing to say when the derived set lints clean.
        let clean = GoldDerivation.writable(derived([hedge], [rating("h58", out: out, verdict: .ship)],
                                                    outputs([("h58", out)])))
        XCTAssertEqual(GoldDerivation.writeDecision(clean, issues: EvalLint.lint(clean.cases), changes: 1,
                                                    skipFailing: false, lintPath: "/tmp/personal.json"),
                       GoldDerivation.WriteDecision(writes: true, lines: []))
    }

    /// A change THIS pass derived that fails is the other half: a scoring
    /// bug on its way into his file, so the write refuses and names the
    /// row, the rule and what `--skip-failing` would still write.
    func testAChangeThatFailsLintRefusesTheWriteAndNamesIt() throws {
        let control = EvalCase(id: "h71", raw: "we ship the kettle today", gold: "", tags: ["unrated"],
                               control: true, source: "history:71",
                               goldSource: EvalCase.historyUnratedGoldSource, annotationsStatus: .draft,
                               observed: "We ship the kettle tomorrow.")
        let good = "Try some broad benchmarking on the tabs."
        let result = derived([hedge, control],
                             [rating("h58", out: good, verdict: .ship),
                              rating("h71", out: control.observed!, verdict: .ship)],
                             outputs([("h58", good), ("h71", control.observed!)]))
        let set = GoldDerivation.writable(result)
        let issues = EvalLint.lint(set.cases)
        let decision = GoldDerivation.writeDecision(set, issues: issues, changes: result.changes.count,
                                                    skipFailing: false, lintPath: "/tmp/personal.json")
        XCTAssertFalse(decision.writes)
        XCTAssertEqual(decision.render(),
                       "refusing to write: 1 of 2 changed fixture(s) derive a lint error\n"
                       + "  h71: control: true but raw→gold has 1 word edit(s)\n"
                       + "re-run with --skip-failing to write the other 1 and hold these back, "
                       + "or fix the rows by hand")
        // With the flag the other gold goes in, and the held row — back to
        // exactly what it was — takes its error with it, so the file it
        // writes lints clean.
        let skipping = GoldDerivation.writeDecision(set, issues: issues, changes: result.changes.count,
                                                    skipFailing: true, lintPath: "/tmp/personal.json")
        XCTAssertTrue(skipping.writes)
        XCTAssertEqual(skipping.lines, [])
        XCTAssertFalse(EvalLint.hasErrors(issues), "\(issues.map(\.description))")
    }

    /// Nothing failing: `writable` is the identity.
    func testWritableIsTheIdentityWhenEverythingLintsClean() throws {
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([hedge], [rating("h58", out: out, verdict: .ship)], outputs([("h58", out)]))
        let write = GoldDerivation.writable(result)
        XCTAssertEqual(write.cases, result.cases)
        XCTAssertEqual(write.written, ["h58"])
        XCTAssertEqual(write.held, [])
    }

    /// The load-bearing property: whatever it derives, the file it writes
    /// still passes its own linter.
    func testWhateverIsDerivedStillPassesLint() throws {
        let fixtures = [
            hedge,
            EvalCase(id: "h43", raw: "let's meet on Tuesday, I mean on Wednesday", gold: "",
                     tags: ["unrated"], goldSource: EvalCase.historyUnratedGoldSource,
                     observed: "Let's meet on Wednesday."),
            EvalCase(id: "h12", raw: "um we we ship the fix today", gold: "",
                     tags: ["unrated"], goldSource: EvalCase.historyUnratedGoldSource,
                     observed: "We ship the fix today."),
        ]
        let texts = [("h58", "Try some broad benchmarking on the tabs."), ("h43", "Let's meet on Wednesday."),
                     ("h12", "We ship the fix today.")]
        let ratings = [
            rating("h58", out: texts[0].1, verdict: .wrong, tags: ["dropped-hedge"],
                   goldEdit: "I don't know, try some broad benchmarking on the tabs."),
            rating("h43", out: texts[1].1, verdict: .ship),
            rating("h12", out: texts[2].1, verdict: .ship),
        ]
        let result = derived(fixtures, ratings, outputs(texts))
        let issues = EvalLint.lint(result.cases)
        XCTAssertFalse(EvalLint.hasErrors(issues), "\(issues.map(\.description))")
        XCTAssertEqual(result.changes.count, 3)
        // And the whole thing encodes and decodes as the fixture file it is.
        let data = try HistoryExport.encode(result.cases)
        XCTAssertEqual(try JSONDecoder().decode([EvalCase].self, from: data), result.cases)
    }

    func testTheDryRunRendersEveryFinding() throws {
        let out = "Try some broad benchmarking on the tabs."
        let result = derived([hedge],
                             [rating("h58", out: out, verdict: .wrong, tags: ["dropped-hedge"],
                                     goldEdit: "I don't know, try some broad benchmarking on the tabs."),
                              rating("h58", out: "unknown text", verdict: .ship)],
                             outputs([("h58", out)]))
        let text = result.render()
        XCTAssertTrue(text.contains("h58"), text)
        XCTAssertTrue(text.contains("gold ← edit"), text)
        XCTAssertTrue(text.contains("+ must_keep"), text)
        XCTAssertTrue(text.contains("unresolved outputs"), text)
        XCTAssertTrue(text.contains("edit distance (HTER"), text)
        XCTAssertTrue(result.summary.hasPrefix("1 fixture(s) changed · 0 conflict(s)"), result.summary)
        XCTAssertEqual(GoldDerivation.derive(fixtures: [hedge], ratings: [], outputs: outputs([])).render(),
                       "no change")
    }
}
