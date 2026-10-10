import XCTest
@testable import WhisprBroCore

/// Hand-counted pins for the quality scorer: every row of the plan's §4.2
/// (F), §4.3 (Fi) and §4.4 (M) tables to 0.1, the §4.6 verdict ladder
/// class by class, the §5 composite with its renormalization, best-of
/// golds, gold-free and verbatim paths, and the scoring weights literal by
/// literal. Nothing above the scorer catches a wrong formula — a threshold
/// that drifts here re-grades every stored run — so each number is derived
/// in a comment, never copied from the scorer's own output.
final class QualityScoreTests: XCTestCase {
    private func score(_ raw: String, _ gold: String, _ out: String,
                       golds: [String] = [], register: AppCategory = .unknown,
                       level: AppConfig.Cleanup.Level = .standard,
                       fillers: [EvalCase.Filler]? = nil, stutters: [EvalCase.Stutter]? = nil,
                       repairs: [EvalCase.Repair] = [], mustKeep: [EvalCase.MustKeep] = [],
                       alternates: [EvalCase.Alternate] = [],
                       runLevel: AppConfig.Cleanup.Level? = nil) -> QualityScore {
        QualityScore.score(EvalCase(id: "t", raw: raw, gold: gold, golds: golds, register: register, level: level,
                                    fillers: fillers, stutters: stutters, repairs: repairs, mustKeep: mustKeep,
                                    alternates: alternates),
                           out: out, level: runLevel)
    }

    // MARK: - Weights (§4.2, §4.4, §5 literals)

    func testScoringWeightsMatchThePlan() {
        XCTAssertEqual(EvalThresholds.formatPunctuationWeight, 0.5)
        XCTAssertEqual(EvalThresholds.formatCasingWeight, 0.3)
        XCTAssertEqual(EvalThresholds.formatTerminalWeight, 0.2)
        XCTAssertEqual(EvalThresholds.meaningDeletionCost, 2)
        XCTAssertEqual(EvalThresholds.meaningNoveltyCost, 3)
        XCTAssertEqual(EvalThresholds.meaningMustKeepPenalty, 4)
        XCTAssertEqual(EvalThresholds.meaningTextShare, 0.75)
        XCTAssertEqual(EvalThresholds.meaningRepairPoints, 25)
        XCTAssertEqual(EvalThresholds.compositeFormatWeight, 0.30)
        XCTAssertEqual(EvalThresholds.compositeFillerWeight, 0.20)
        XCTAssertEqual(EvalThresholds.compositeMeaningWeight, 0.50)
        XCTAssertEqual(EvalThresholds.failOverEditFactShare, 0.05)
        XCTAssertEqual(EvalThresholds.failControlsUnchangedPct, 95)
        XCTAssertEqual(EvalThresholds.warnLatencyMaxWords, 60)
        XCTAssertEqual(EvalThresholds.defaultBudgetMs, 700)
        XCTAssertEqual(EvalThresholds.defaultTimeoutMs, 3000)
        XCTAssertEqual(EvalThresholds.flaggedDroppedContent, 3)
    }

    func testVerdictLadderOrderAndGateMap() {
        XCTAssertEqual(EvalVerdict.allCases.map(\.rawValue),
                       ["ANSWERED", "INVENTED", "NEGATED", "OVER_EDIT_FACT", "OVER_EDIT_HEDGE",
                        "REWORDED", "MISSED", "PUNCT", "PASS", "UNRATED"])
        for gate in ContentGuard.Gate.allCases {
            XCTAssertEqual(EvalVerdict(gate: gate).gate, gate)
            XCTAssertTrue(EvalVerdict(gate: gate).isGated)
        }
        for verdict in [EvalVerdict.overEditHedge, .reworded, .missed, .punct, .pass, .unrated] {
            XCTAssertNil(verdict.gate, verdict.rawValue)
            XCTAssertFalse(verdict.isGated, verdict.rawValue)
        }
        XCTAssertTrue(EvalVerdict.answered.isWorse(than: .invented))
        XCTAssertTrue(EvalVerdict.overEditFact.isWorse(than: .overEditHedge))
        XCTAssertTrue(EvalVerdict.missed.isWorse(than: .punct))
        XCTAssertFalse(EvalVerdict.pass.isWorse(than: .punct))
        XCTAssertEqual(EvalVerdict.answered.rank, 0)
        XCTAssertEqual(EvalVerdict.unrated.rank, 9)
    }

    // MARK: - §4.2 F table

    func testFCommaMissedOnAThreeClassGold() {
        // gold `Okay, we ship it. Do you agree?` out `Okay we ship it. Do you agree?`
        // P: comma gold 1 / out 0 → F1 0; stop 1/1 → 1; question 1/1 → 1;
        // macro over the three present classes = 0.667. C: sentence-initial
        // gold positions are 0 ("Okay") and 4 ("Do", after "it."); the other
        // five hit words match case → 1. T: "?" == "?" → 1.
        // F = 100·(0.5·0.667 + 0.3·1 + 0.2·1) = 83.3.
        let q = score("okay we ship it do you agree", "Okay, we ship it. Do you agree?", "Okay we ship it. Do you agree?")
        let f = try! XCTUnwrap(q.formatting)
        XCTAssertEqual(f.perClass["comma"]!, 0, accuracy: 1e-9)
        XCTAssertEqual(f.perClass["stop"]!, 1, accuracy: 1e-9)
        XCTAssertEqual(f.perClass["question"]!, 1, accuracy: 1e-9)
        XCTAssertEqual(f.punctuation!, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(f.casing, 1)
        XCTAssertEqual(f.cInitial, 1)
        XCTAssertEqual(f.terminal, 1)
        XCTAssertEqual(f.score, 83.3, accuracy: 0.05)
        XCTAssertEqual(q.verdict, .punct)
        // Fi undefined (no fillers) → C_i = (0.3·83.33 + 0.5·100) / 0.8 = 93.75.
        XCTAssertNil(q.fillers)
        XCTAssertEqual(q.composite!, 93.75, accuracy: 0.05)
    }

    func testFCasingExcludesTheSentenceInitialWord() {
        // gold `Push the fix to Zephyrnet.` out `push the fix to zephyrnet.`
        // P: stop 1/1 → 1 (comma/question absent from both → skipped).
        // C: non-initial hits the/fix/to/zephyrnet → 3/4 = 0.75; the
        // lowercased "push" is c_initial 0/1, reported, never scored. T 1.
        // F = 100·(0.5 + 0.225 + 0.2) = 92.5.
        let q = score("push the fix to zephyrnet", "Push the fix to Zephyrnet.", "push the fix to zephyrnet.")
        let f = try! XCTUnwrap(q.formatting)
        XCTAssertEqual(f.perClass.keys.sorted(), ["stop"])
        XCTAssertEqual(f.punctuation, 1)
        XCTAssertEqual(f.casing, 0.75)
        XCTAssertEqual(f.cInitial, 0)
        XCTAssertEqual(f.terminal, 1)
        XCTAssertEqual(f.score, 92.5, accuracy: 0.05)
        XCTAssertEqual(q.verdict, .punct)
    }

    func testFFragmentGetsNoTerminalCredit() {
        // gold `Okay, and the` (fragment, no terminal) out `Okay, and the.`
        // P: comma 1/1 → 1; stop gold 0 / out 1 → 0; macro 0.5. C: "and",
        // "the" match → 1. T: none ≠ "." → 0.
        // F = 100·(0.25 + 0.3 + 0) = 55.0.
        let q = score("okay and the um", "Okay, and the", "Okay, and the.")
        let f = try! XCTUnwrap(q.formatting)
        XCTAssertEqual(f.punctuation!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.casing, 1)
        XCTAssertEqual(f.terminal, 0)
        XCTAssertEqual(f.score, 55.0, accuracy: 0.05)
        // The fixture's own gold gets the fragment right: none == none.
        XCTAssertEqual(score("okay and the um", "Okay, and the", "Okay, and the").formatting?.score, 100)
    }

    func testFIdenticalIs100() {
        let q = score("meet on wednesday", "Meet on Wednesday.", "Meet on Wednesday.")
        XCTAssertEqual(q.formatting?.score, 100)
        XCTAssertEqual(q.formatting?.punctuation, 1)
        XCTAssertEqual(q.formatting?.casing, 1)
        XCTAssertEqual(q.formatting?.terminal, 1)
        XCTAssertEqual(q.verdict, .pass)
        XCTAssertEqual(q.composite, 100)
    }

    func testFComponentsRenormalizeWhenAbsent() {
        // No marks on either side and no non-initial word: only T is
        // defined → F = 100·T. "Uh" ↔ "Uh": T 1 → 100; "Uh" ↔ "Uh.": T 0 → 0.
        XCTAssertEqual(score("uh yeah", "Uh", "Uh").formatting?.score, 100)
        XCTAssertEqual(score("uh yeah", "Uh", "Uh.").formatting?.score, 0)
        // Marks but no non-initial hit word: P and T only, weights 0.5/0.2.
        // gold "Yeah." out "yeah": P stop 1/0 → 0; T 0 → F = 0. out "yeah.":
        // P 1, T 1 → 100 (casing is initial, unscored).
        XCTAssertEqual(score("yeah", "Yeah.", "yeah").formatting?.score, 0)
        XCTAssertEqual(score("yeah", "Yeah.", "yeah.").formatting?.score, 100)
        XCTAssertNil(score("yeah", "Yeah.", "yeah.").formatting?.casing)
        XCTAssertEqual(score("yeah", "Yeah.", "yeah.").formatting?.cInitial, 0)
    }

    func testPunctuationOnDeletedAndInsertedWordsIsCharged() {
        // A mark on a deleted gold word is a FN, on an inserted out word a
        // FP. gold `Yes, we can.` out `We can.`: comma gold 1 / out 0 → 0;
        // stop 1/1 → 1; P = 0.5. gold `We can.` out `Yes, we can.`: comma
        // gold 0 / out 1 → 0; P = 0.5 the other way.
        XCTAssertEqual(score("yes we can", "Yes, we can.", "We can.").formatting!.punctuation!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(score("we can", "We can.", "Yes, we can.").formatting!.punctuation!, 0.5, accuracy: 1e-9)
        // Orphan marks (a chunk with no word core) count for their class:
        // gold `Eggs, milk and bread.` out `Eggs, , milk and bread.` → comma
        // gold 1 / out 2 (the orphan attaches to "Eggs,") → 2·1/3 = 0.667.
        let f = score("eggs milk and bread", "Eggs, milk and bread.", "Eggs, , milk and bread.").formatting!
        XCTAssertEqual(f.perClass["comma"]!, 2.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - §4.3 Fi table

    func testFiFillerRemovedCleanly() {
        // raw `um I also signed into Zephyrnet` gold `I also signed into
        // Zephyrnet.` out = gold: "um" `.del`, its next neighbour "i" hit,
        // no previous neighbour → credited → 100.
        let q = score("um I also signed into Zephyrnet", "I also signed into Zephyrnet.", "I also signed into Zephyrnet.")
        XCTAssertEqual(q.fillers?.expected, 1)
        XCTAssertEqual(q.fillers?.credited, 1)
        XCTAssertEqual(q.fillers?.score, 100)
        XCTAssertEqual(q.verdict, .pass)
    }

    func testFiFillerDeletedWithItsClauseEarnsNothing() {
        // same, out `Zephyrnet.`: "um" is `.del` but the next neighbour "i"
        // is deleted too → 0; M charges D = 4 of 5. The raw↔out length
        // collapse (1 of 5 expected words, raw ≥ 6) gates OVER_EDIT_FACT.
        let q = score("um I also signed into Zephyrnet", "I also signed into Zephyrnet.", "Zephyrnet.")
        XCTAssertEqual(q.fillers?.score, 0)
        XCTAssertEqual(q.fillers?.missed, ["um"])
        XCTAssertEqual(q.meaning?.lost, 4)
        XCTAssertEqual(q.meaning?.lostTokens, ["I", "also", "signed", "into"])
        XCTAssertEqual(q.dels, 4)
        XCTAssertEqual(q.verdict, .overEditFact)
        XCTAssertEqual(q.composite, 0)
    }

    func testFiStutterCollapsedToOneHit() {
        // raw `the the whisper bro` gold `The Whisper Bro.`: derived run
        // [the, the] keep "the". out = gold → del(0) + hit(1) → collapsed → 100.
        let q = score("the the whisper bro", "The Whisper Bro.", "The Whisper Bro.")
        XCTAssertEqual(q.fillers?.expected, 1)
        XCTAssertEqual(q.fillers?.score, 100)
        XCTAssertEqual(q.verdict, .pass)
        // out `the the Whisper Bro.` keeps both copies: two hits → 0; M is
        // untouched (the extra "the" is an `.ins` that IS in raw), so the
        // verdict is MISSED, not REWORDED.
        let kept = score("the the whisper bro", "The Whisper Bro.", "the the Whisper Bro.")
        XCTAssertEqual(kept.fillers?.score, 0)
        XCTAssertEqual(kept.fillers?.missed, ["the the"])
        XCTAssertEqual(kept.meaning?.score, 100)
        XCTAssertEqual(kept.ins, 1)
        XCTAssertEqual(kept.verdict, .missed)
        // C_i = 0.3·100 + 0.2·0 + 0.5·100 = 80.
        XCTAssertEqual(kept.composite!, 80, accuracy: 1e-9)
    }

    func testFiSurvivesTheDiagonalTieBreak() {
        // The backtrace prefers the diagonal on equal cost (AlignTests pins
        // why), so a filler in the second-to-last raw slot with a word
        // appended to the output comes back as two substitutions —
        // sub(um→tomorrow), sub(tomorrow→thanks) — not del + hit + ins.
        // Credit is read off the out window between the neighbours'
        // paired positions, so the removal is still seen. raw `please call
        // me um tomorrow` gold `Please call me tomorrow.` out `Please call
        // me tomorrow, thanks.`: Fi 100; F: comma FP and the stop moved to
        // "thanks" → P 0, C 1, T 1 → 50; M: "thanks" novel → 100·(1 − 3/4)
        // = 25 → REWORDED; C = 15 + 20 + 12.5 = 47.5.
        let one = score("please call me um tomorrow", "Please call me tomorrow.", "Please call me tomorrow, thanks.")
        XCTAssertEqual(one.contentGuard.alignment.ops, [.hit(0, 0), .hit(1, 1), .hit(2, 2), .sub(3, 3), .sub(4, 4)])
        XCTAssertEqual(one.fillers?.score, 100)
        XCTAssertEqual(one.formatting!.score, 50, accuracy: 1e-9)
        XCTAssertEqual(one.meaning!.score, 25, accuracy: 1e-9)
        XCTAssertEqual(one.verdict, .reworded)
        XCTAssertEqual(one.composite!, 47.5, accuracy: 1e-9)
        // Three appended words shift the pairing by more than one slot
        // ("a" is STOP, so M charges two novel words → 0).
        let three = score("please call me um tomorrow", "Please call me tomorrow.", "Please call me tomorrow, thanks a lot.")
        XCTAssertEqual(three.contentGuard.alignment.ops,
                       [.hit(0, 0), .hit(1, 1), .hit(2, 2), .ins(3), .ins(4), .sub(3, 5), .sub(4, 6)])
        XCTAssertEqual(three.fillers?.score, 100)
        XCTAssertEqual(three.meaning?.score, 0)
        XCTAssertEqual(three.composite!, 35, accuracy: 1e-9)
        // The two-word raw the original pin called a known cost: sub(um→
        // send), sub(send→now), and Fi reads 100 all the same.
        let two = score("um send", "Send.", "Send now.")
        XCTAssertEqual(two.contentGuard.alignment.ops, [.sub(0, 0), .sub(1, 1)])
        XCTAssertEqual(two.fillers?.score, 100)
        // The mirror: a second-slot filler with a word prepended shifts the
        // other way — sub(call→well), sub(um→call).
        let mirror = score("call um me tomorrow", "Call me tomorrow.", "Well call me tomorrow.")
        XCTAssertEqual(mirror.contentGuard.alignment.ops, [.sub(0, 0), .sub(1, 1), .hit(2, 2), .hit(3, 3)])
        XCTAssertEqual(mirror.fillers?.score, 100)
        // Still no credit when a neighbour is gone: the next word deleted
        // with the filler, the appended word paired to it as a sub, is the
        // plan's own limit (a sub neighbour counts as present — M charges
        // the deletion and the novelty), so only a `.del` neighbour
        // withholds credit.
        let clause = score("please call me um tomorrow", "Please call me tomorrow.", "Please call me.")
        XCTAssertEqual(clause.contentGuard.alignment.ops, [.hit(0, 0), .hit(1, 1), .hit(2, 2), .del(3), .del(4)])
        XCTAssertEqual(clause.fillers?.score, 0)
        // A reworded neighbour is a `.sub` and still there (§4.3).
        XCTAssertEqual(score("it's um grey outside", "It's gray outside.", "It's gray outside.").fillers?.score, 100)
        // A novel word in the filler's place: the filler IS gone (Fi 100);
        // what replaced it is M's charge (novel 1 → REWORDED).
        let replaced = score("call me um tomorrow", "Call me tomorrow.", "Call me zorblat tomorrow.")
        XCTAssertEqual(replaced.contentGuard.alignment.ops, [.hit(0, 0), .hit(1, 1), .sub(2, 2), .hit(3, 3)])
        XCTAssertEqual(replaced.fillers?.score, 100)
        XCTAssertEqual(replaced.meaning?.novel, 1)
        XCTAssertEqual(replaced.verdict, .reworded)
        // An echoed filler sits in its own window → no credit.
        XCTAssertEqual(score("call me um tomorrow", "Call me tomorrow.", "Call me um tomorrow.").fillers?.score, 0)
        // Stutter runs read the same window: "the the" before an appended
        // word aligns as hit(the), sub(the→report), sub(report→thanks) and
        // the window holds one "the" — collapsed.
        let run = score("send the the report", "Send the report.", "Send the report, thanks.")
        XCTAssertEqual(run.contentGuard.alignment.ops, [.hit(0, 0), .hit(1, 1), .sub(2, 2), .sub(3, 3)])
        XCTAssertEqual(run.fillers?.score, 100)
        XCTAssertEqual(score("send the the report", "Send the report.", "Send the the report, thanks.").fillers?.score, 0)
    }

    func testFiCreditsPerSpanInsideASharedWindow() {
        // Two derived fillers between the same neighbours read one out
        // window: raw `um um call me tomorrow please` gold `Call me
        // tomorrow please.` — neither "um" has a previous neighbour and
        // both have "call" as the next, so the window is out[0..<call].
        // out `Um, call me tomorrow please.` leaves one "um" in it: one
        // surplus copy → one of the two spans missed → Fi 50 (version 2
        // read the whole window against each span and scored 0). F: comma
        // FP on the inserted "um", stop hit → P 0.5, C 1, T 1 → 75; M 100
        // (the "um" is in raw, not novel). MISSED; C = 22.5 + 10 + 50 =
        // 82.5.
        let raw = "um um call me tomorrow please", gold = "Call me tomorrow please."
        let half = score(raw, gold, "Um, call me tomorrow please.")
        XCTAssertEqual(half.fillers?.expected, 2)
        XCTAssertEqual(half.fillers?.credited, 1)
        XCTAssertEqual(half.fillers?.score, 50)
        XCTAssertEqual(half.fillers?.missed, ["um"])
        XCTAssertEqual(half.formatting!.score, 75, accuracy: 1e-9)
        XCTAssertEqual(half.meaning?.score, 100)
        XCTAssertEqual(half.verdict, .missed)
        XCTAssertEqual(half.composite!, 82.5, accuracy: 1e-9)
        // Both gone → 100; both kept → 0, and the report names both.
        XCTAssertEqual(score(raw, gold, gold).fillers?.score, 100)
        let none = score(raw, gold, "Um um call me tomorrow please.")
        XCTAssertEqual(none.fillers?.score, 0)
        XCTAssertEqual(none.fillers?.missed, ["um", "um"])
        // Different forms in one window are their own groups: "uh" gone,
        // "um" kept → 1 of 2, and the miss is the one that survived.
        let mixed = score("um uh call me tomorrow please", gold, "Um, call me tomorrow please.")
        XCTAssertEqual(mixed.fillers?.score, 50)
        XCTAssertEqual(mixed.fillers?.missed, ["um"])
    }

    func testFiRestartAroundAFillerScoresTheGoldCopy100() {
        // Two derived runs of one word around a filled pause: raw `I I um
        // I I think we should ship it` gold `I think we should ship it.`
        // derives "um" plus two "I I" runs (E = 3), each with keep "I" —
        // but the gold retains ONE "I" of the four. All three spans are
        // flanked by "think" alone, so they read the window out[0..<think]
        // and the runs are one group. The group is held to what the gold
        // keeps inside its spans (one raw↔gold hit on "i"), not to the
        // summed keeps (two): out = gold holds one → 3 of 3 → 100, PASS.
        // (Summing read the gold copy as a deficit: 1 of 3, C 86.7.)
        let restart = EvalCase(id: "r", raw: "I I um I I think we should ship it", gold: "I think we should ship it.")
        XCTAssertEqual(restart.expectedFillers.map(\.span), ["um"])
        XCTAssertEqual(restart.expectedStutters.map(\.keep), ["I", "I"])
        let q = QualityScore.score(restart, out: restart.gold)
        XCTAssertEqual(q.fillers?.expected, 3)
        XCTAssertEqual(q.fillers?.credited, 3)
        XCTAssertEqual(q.fillers?.score, 100)
        XCTAssertEqual(q.meaning?.lost, 0)
        XCTAssertEqual(q.verdict, .pass)
        XCTAssertEqual(q.composite, 100)
        // The same shape on an article.
        let article = score("the the um the the whisper bro is ready", "The Whisper Bro is ready.", "The Whisper Bro is ready.")
        XCTAssertEqual(article.fillers?.expected, 3)
        XCTAssertEqual(article.fillers?.score, 100)
        XCTAssertEqual(article.verdict, .pass)
        XCTAssertEqual(article.composite, 100)
    }

    func testFiRestartAroundAFillerLeftDoubledCreditsOneRunOfTwo() {
        // Same fixture, out `I I think we should ship it.`: "um" is gone
        // (credited) and the window holds two "i" against the gold's one
        // → one surplus copy → one run of two collapsed → 2 of 3 → 66.7,
        // the report naming the second run. (Summing the keeps read two
        // as exact: 3 of 3, PASS.) F 100 — the extra "I" is an `.ins`
        // without a mark and casing is read over the non-initial hits —
        // and M 100 (the word is in raw) → MISSED, C = 30 + 13.3 + 50 =
        // 93.3.
        let raw = "I I um I I think we should ship it", gold = "I think we should ship it."
        let q = score(raw, gold, "I I think we should ship it.")
        XCTAssertEqual(q.fillers?.expected, 3)
        XCTAssertEqual(q.fillers?.credited, 2)
        XCTAssertEqual(q.fillers?.missed, ["I I"])
        XCTAssertEqual(q.fillers!.score, 200.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(q.formatting?.score, 100)
        XCTAssertEqual(q.meaning?.score, 100)
        XCTAssertEqual(q.ins, 1)
        XCTAssertEqual(q.verdict, .missed)
        XCTAssertEqual(q.composite!, 93.3, accuracy: 0.05)
        // Both runs left in place: two surplus copies → neither credited.
        let both = score(raw, gold, "I I I think we should ship it.")
        XCTAssertEqual(both.fillers?.credited, 1)
        XCTAssertEqual(both.fillers?.missed, ["I I", "I I"])
        // The article: `The the Whisper Bro is ready.` — the gold's "The"
        // pairs with the second "the" at a sentence-initial position, so
        // casing is not charged either → F 100, C 93.3.
        let article = score("the the um the the whisper bro is ready", "The Whisper Bro is ready.", "The the Whisper Bro is ready.")
        XCTAssertEqual(article.fillers?.credited, 2)
        XCTAssertEqual(article.fillers?.missed, ["the the"])
        XCTAssertEqual(article.formatting?.score, 100)
        XCTAssertEqual(article.verdict, .missed)
        XCTAssertEqual(article.composite!, 93.3, accuracy: 0.05)
    }

    func testFiUndefinedForAContentWordDouble() {
        // "very" ∉ stutterCollapsible → E = ∅ → Fi undefined, composite
        // renormalizes over F and M.
        let q = score("very, very flat", "Very, very flat.", "Very, very flat.")
        XCTAssertNil(q.fillers)
        XCTAssertFalse(q.fillersSkipped)
        XCTAssertEqual(q.composite, 100)
        XCTAssertEqual(q.verdict, .pass)
    }

    func testFiExplicitNonIdenticalStutterSpan() {
        // raw `and a and sixty two` + stutters [{and a and → and}] gold
        // `and 62` out `and sixty-two`: ops del(0) del(1) hit(2) hit(3) —
        // one hit on "and", "a" and "and" deleted → 100. The spelled and
        // hyphenated number are one canonical atom, so M sees no novelty
        // and no deletion: 100, and the fixture's own PASS.
        let q = score("and a and sixty two", "and 62", "and sixty-two",
                      stutters: [EvalCase.Stutter(span: "and a and", keep: "and")])
        XCTAssertEqual(q.fillers?.score, 100)
        XCTAssertEqual(q.meaning?.score, 100)
        XCTAssertEqual(q.meaning?.novel, 0)
        XCTAssertEqual(q.hits, 2)
        XCTAssertEqual(q.verdict, .pass)
        XCTAssertEqual(q.composite, 100)
    }

    func testFiGoldFreeRestartHoldsEachRunToItsOwnKeep() {
        // The same restart with NO gold to read: raw `I I um I I think we
        // should ship it` under `history-unrated` derives "um" and two
        // `I I` runs keeping "I" each off the empty gold (E = 3) — the
        // stripper's own contract, which is all a history row carries
        // before the rating loop writes a gold. All three read the window
        // before "think", so each run expects ITS OWN copy there and is
        // credited on its own: the collapsed `I think we should ship it.`
        // holds one of the two entitled copies → one run collapsed, the
        // other charged the cut → 2 of 3, 66.7. (Summing the keeps into
        // one block read the whole group as a deficit — 1 of 3, 33.3 —
        // which is the inverted contract on exactly the population the
        // rating loop starts from.) Nothing else is scored: no F, no M, no
        // composite, and no gate fires → UNRATED.
        let unrated = EvalCase(id: "h9", raw: "I I um I I think we should ship it", gold: "",
                               goldSource: EvalCase.historyUnratedGoldSource)
        XCTAssertEqual(unrated.expectedFillers.map(\.span), ["um"])
        XCTAssertEqual(unrated.expectedStutters.map(\.keep), ["I", "I"])
        let collapsed = QualityScore.score(unrated, out: "I think we should ship it.")
        XCTAssertTrue(collapsed.isGoldFree)
        XCTAssertEqual(collapsed.fillers?.expected, 3)
        XCTAssertEqual(collapsed.fillers?.credited, 2)
        XCTAssertEqual(collapsed.fillers?.missed, ["I I"])
        XCTAssertEqual(collapsed.fillers!.score, 200.0 / 3, accuracy: 1e-9)
        XCTAssertNil(collapsed.formatting)
        XCTAssertNil(collapsed.meaning)
        XCTAssertNil(collapsed.composite)
        XCTAssertEqual(collapsed.verdict, .unrated)
        // Uncollapsed: the window holds four copies against the two the
        // runs are entitled to, plus the "um" — two surplus copies and a
        // filler left standing → nothing credited, Fi 0, all three named.
        let untouched = QualityScore.score(unrated, out: "I I um I I think we should ship it.")
        XCTAssertEqual(untouched.fillers?.credited, 0)
        XCTAssertEqual(untouched.fillers?.score, 0)
        XCTAssertEqual(untouched.fillers?.missed, ["um", "I I", "I I"])
        XCTAssertEqual(untouched.verdict, .unrated)
        // What the contract predicts — one copy per run, "um" gone — is
        // the 100 here; it takes a gold to prefer one "I" over two.
        XCTAssertEqual(QualityScore.score(unrated, out: "I I think we should ship it.").fillers?.score, 100)
        // One run left standing is one surplus copy, charged to one span.
        let half = QualityScore.score(unrated, out: "I I I think we should ship it.")
        XCTAssertEqual(half.fillers?.credited, 2)
        XCTAssertEqual(half.fillers?.missed, ["I I"])
        // A single-span group is what it always was: one span short of its
        // one copy is no credit, one copy over is no credit.
        let single = EvalCase(id: "h10", raw: "send the the report", gold: "",
                              goldSource: EvalCase.historyUnratedGoldSource)
        XCTAssertEqual(QualityScore.score(single, out: "Send the report.").fillers?.score, 100)
        XCTAssertEqual(QualityScore.score(single, out: "Send report.").fillers?.score, 0)
        XCTAssertEqual(QualityScore.score(single, out: "Send the the report.").fillers?.score, 0)
    }

    func testFiReadsAnExplicitSpanOffTheAnnotationNotTheGold() {
        // An explicit annotation is a statement about what the RAW
        // contains; the gold is a statement about the ideal output. Where
        // they disagree the fixture is malformed (`lint` names both
        // numbers) and the scorer holds the output to the annotation, so
        // the disagreement can never invert a span silently.
        //
        // Stutter: raw `send the the report` annotated `{the the → the}`
        // against a gold that drops BOTH articles. `Send report.` leaves
        // none of the copy the annotation keeps → a cut, not a collapse →
        // Fi 0. (Read off the gold, which retains zero, the same output
        // was credited 100.)
        let cut = score("send the the report", "Send report.", "Send report.",
                        stutters: [EvalCase.Stutter(span: "the the", keep: "the")])
        XCTAssertEqual(cut.fillers?.expected, 1)
        XCTAssertEqual(cut.fillers?.credited, 0)
        XCTAssertEqual(cut.fillers?.missed, ["the the"])
        // The annotation's own collapse is its 100, whatever the gold says.
        XCTAssertEqual(score("send the the report", "Send report.", "Send the report.",
                             stutters: [EvalCase.Stutter(span: "the the", keep: "the")]).fillers?.score, 100)
        // Filler: `fillers: [um]` says that "um" is an expected removal; a
        // gold that keeps it contradicts the annotation. The echoed "um"
        // is one surplus copy → Fi 0, MISSED, C = 30 + 0 + 50 = 80 (read
        // off the gold it was a clean removal, Fi 100 and PASS).
        let echoed = score("call me um tomorrow", "Call me um tomorrow.", "Call me um tomorrow.",
                           fillers: [EvalCase.Filler(span: "um")])
        XCTAssertEqual(echoed.fillers?.credited, 0)
        XCTAssertEqual(echoed.fillers?.missed, ["um"])
        XCTAssertEqual(echoed.formatting?.score, 100)
        XCTAssertEqual(echoed.meaning?.score, 100)
        XCTAssertEqual(echoed.verdict, .missed)
        XCTAssertEqual(echoed.composite!, 80, accuracy: 1e-9)
        // Stripping it is what the annotation asks for: Fi 100 — and the
        // gold still charges the deletion on its own axis (D 1 of 4).
        let stripped = score("call me um tomorrow", "Call me um tomorrow.", "Call me tomorrow.",
                             fillers: [EvalCase.Filler(span: "um")])
        XCTAssertEqual(stripped.fillers?.score, 100)
        XCTAssertEqual(stripped.meaning?.lost, 1)
        // A DERIVED span still reads the gold: with no annotation the same
        // raw derives nothing (its gold keeps the "um") → E = 0.
        XCTAssertNil(score("call me um tomorrow", "Call me um tomorrow.", "Call me um tomorrow.").fillers)
    }

    func testFiAllFillerGoldFreeRaw() {
        // raw `Uh` gold `` under `history-unrated` (gold-free): E = every
        // token; credited iff out is empty. No F, M or composite; verdict
        // UNRATED (no gate fired).
        let unrated = EvalCase(id: "h1", raw: "Uh", gold: "", goldSource: EvalCase.historyUnratedGoldSource)
        let gone = QualityScore.score(unrated, out: "")
        XCTAssertTrue(gone.isGoldFree)
        XCTAssertEqual(gone.fillers?.score, 100)
        XCTAssertNil(gone.formatting)
        XCTAssertNil(gone.meaning)
        XCTAssertNil(gone.composite)
        XCTAssertEqual(gone.verdict, .unrated)
        let kept = QualityScore.score(unrated, out: "Uh.")
        XCTAssertEqual(kept.fillers?.score, 0)
        XCTAssertEqual(kept.verdict, .unrated)
    }

    func testRatedEmptyGoldIsScoredNotGoldFree() {
        // The same raw and empty gold under seed provenance is a RATED
        // gold that says "paste nothing": the empty output is its PASS —
        // F 100 (no marks, terminal none == none), M 100 (nothing lost or
        // invented), Fi 100 — and "Uh." is the missed removal it is: F 0
        // (a stop mark the gold lacks, terminal "." ≠ none), M 100 ("uh"
        // is a raw word, not novel), Fi 0 → MISSED, C = 0.5·100 = 50.
        let gone = score("Uh", "", "")
        XCTAssertFalse(gone.isGoldFree)
        XCTAssertEqual(gone.verdict, .pass)
        XCTAssertEqual(gone.formatting?.score, 100)
        XCTAssertEqual(gone.meaning?.score, 100)
        XCTAssertEqual(gone.fillers?.score, 100)
        XCTAssertEqual(gone.composite, 100)
        XCTAssertEqual(gone.continuity?.wer, 0)
        let kept = score("Uh", "", "Uh.")
        XCTAssertEqual(kept.verdict, .missed)
        XCTAssertEqual(kept.formatting?.score, 0)
        XCTAssertEqual(kept.meaning?.score, 100)
        XCTAssertEqual(kept.fillers?.score, 0)
        XCTAssertEqual(kept.composite, 50)
        // An empty ALTERNATE gold is skipped, not scored.
        XCTAssertEqual(score("Uh", "Uh.", "Uh.", golds: [""]).goldIndex, 0)
        XCTAssertEqual(score("Uh", "Uh.", "", golds: [""]).verdict, .overEditHedge)
    }

    func testFiNeighbourSkipsGoldDeletedTokens() {
        // A filler inside a reparandum the gold drops: raw `meet at 2, uh,
        // actually 3` gold `Meet at 3.` out = gold. "uh" is flanked by "2"
        // and "actually", both deleted by the gold itself; the nearest
        // neighbours the rule reads are "at" and "3", both hit → 100.
        let q = score("meet at 2, uh, actually 3", "Meet at 3.", "Meet at 3.")
        XCTAssertEqual(q.fillers?.expected, 1)
        XCTAssertEqual(q.fillers?.score, 100)
    }

    func testFiIsSkippedUnderAVerbatimRegister() {
        // `.notes` is in the default verbatimCategories: no strip runs, so
        // the axis is not measured — even when the fixture has fillers.
        let q = score("um I also signed in", "I also signed in.", "I also signed in.", register: .notes)
        XCTAssertNil(q.fillers)
        XCTAssertTrue(q.fillersSkipped)
        XCTAssertEqual(q.composite, 100)
        // …and a non-verbatim register measures it.
        XCTAssertFalse(score("um I also signed in", "I also signed in.", "I also signed in.", register: .mail).fillersSkipped)
        // The scorer and the run plan share one predicate (`EvalPlan.level`),
        // so a config spelling the category "Notes" is verbatim for both.
        let notes = EvalCase(id: "n", raw: "um I also signed in", gold: "I also signed in.", register: .notes)
        XCTAssertTrue(QualityScore.score(notes, out: notes.gold, verbatimCategories: ["Notes"]).fillersSkipped)
        XCTAssertFalse(QualityScore.score(notes, out: notes.gold, verbatimCategories: []).fillersSkipped)
        XCTAssertEqual(EvalPlan.level(for: notes, override: nil, verbatimCategories: ["Notes"]), .verbatim)
    }

    // MARK: - §4.4 M table

    /// A 40-word gold whose first three tokens are the hedge "I don't know,".
    private let gold40 = "I don't know, try some broad benchmarking on the gravlin tabs and see what comes up, then write me a short summary of the three options with their tradeoffs and send it to me before the standup tomorrow morning, please."
    private let raw40 = "i don't know try some broad benchmarking on the gravlin tabs and see what comes up then write me a short summary of the three options with their tradeoffs and send it to me before the standup tomorrow morning please"
    private let out40 = "Try some broad benchmarking on the gravlin tabs and see what comes up, then write me a short summary of the three options with their tradeoffs and send it to me before the standup tomorrow morning, please."

    func testMThreeUnannotatedDeletionsOnFortyWords() {
        // D = 3, novel 0 → 100·(1 − 6/40) = 85. Deleted tokens are not all
        // STOP → OVER_EDIT_HEDGE; 3/40 = 0.075 < 0.15 → not gated. The
        // raw↔out guard sees "don't" deleted WITH its "know" → no flip.
        let q = score(raw40, gold40, out40)
        XCTAssertEqual(q.meaning?.goldWords, 40)
        XCTAssertEqual(q.meaning?.lost, 3)
        XCTAssertEqual(q.meaning?.lostTokens, ["I", "don't", "know"])
        XCTAssertEqual(q.meaning?.novel, 0)
        XCTAssertEqual(q.meaning!.score, 85, accuracy: 0.05)
        XCTAssertEqual(q.verdict, .overEditHedge)
        XCTAssertEqual(q.gates, [])
        XCTAssertEqual([q.hits, q.subs, q.dels, q.ins], [37, 0, 3, 0])
    }

    func testMMissedHedgeSpanCostsAFlatPenalty() {
        // same with must_keep "I don't know," w=2: 85 − 4·2 = 77, still
        // OVER_EDIT_HEDGE.
        let q = score(raw40, gold40, out40, mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 2)])
        XCTAssertEqual(q.meaning!.score, 77, accuracy: 0.05)
        XCTAssertEqual(q.meaning?.missedMustKeep.map(\.span), ["I don't know,"])
        XCTAssertEqual(q.verdict, .overEditHedge)
        XCTAssertEqual(q.goldTriggers, [])
    }

    func testMMissedFactSpanGates() {
        // w=5 → OVER_EDIT_FACT: M 0, C_i 0; M_text (65) is kept for the
        // report.
        let q = score(raw40, gold40, out40, mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 5)])
        XCTAssertEqual(q.meaning?.score, 0)
        XCTAssertEqual(q.meaning!.text, 65, accuracy: 0.05)
        XCTAssertEqual(q.goldTriggers, [.mustKeepFact])
        XCTAssertEqual(q.gates, [.overEditFact])
        XCTAssertEqual(q.verdict, .overEditFact)
        XCTAssertEqual(q.composite, 0)
        XCTAssertEqual(q.triggerNames, ["must-keep-fact"])
    }

    func testMInventedMathIsGatedToZero() {
        // The id-54 shape: novel {140, units}, one numeral → INVENTED.
        let q = score("so the glider plus a forty two on each wing and a twenty eight on each wing so find the total",
                      "So the glider plus a 42 on each wing and a 28 on each wing, so find the total.",
                      "So the glider plus a 42 on each wing and a 28 on each wing. So the total is: 42 + 42 + 28 + 28 = 140 units.")
        XCTAssertEqual(q.meaning?.novel, 2)
        XCTAssertEqual(q.meaning?.novelNumerals, 1)
        XCTAssertEqual(q.meaning?.score, 0)
        XCTAssertEqual(q.verdict, .invented)
        XCTAssertEqual(q.composite, 0)
        XCTAssertEqual(q.triggerNames, ["novel-numeral"])
    }

    private let repairRaw = "meet on Tuesday, I mean on Wednesday"
    private let repairGold = "Meet on Wednesday."
    private let repair = [EvalCase.Repair(reparandum: "on Tuesday, I mean", repair: "on Wednesday")]

    func testMUnresolvedRepairKeepsThreeQuartersOfText() {
        // out echoes the raw: D 0, novel 0 → M_text 100; the reparandum is
        // still present → unresolved → 0.75·100 + 0 = 75. MISSED.
        let q = score(repairRaw, repairGold, "Meet on Tuesday, I mean on Wednesday.", repairs: repair)
        XCTAssertEqual(q.meaning?.scoredRepairs, 1)
        XCTAssertEqual(q.meaning?.resolvedRepairs, 0)
        XCTAssertEqual(q.meaning?.unresolvedRepairs, ["on Tuesday, I mean"])
        XCTAssertEqual(q.meaning?.text, 100)
        XCTAssertEqual(q.meaning!.score, 75, accuracy: 0.05)
        XCTAssertEqual(q.verdict, .missed)
    }

    func testMResolvedRepairIs100() {
        // Reparandum absent, repair present → 0.75·100 + 25 = 100. The
        // raw↔out ratio is 3/7 — under the raw-length collapse line — but
        // the guard reads the EXPECTED length (raw minus the scored
        // reparandum = 3), so a correct resolution is never gated.
        let q = score(repairRaw, repairGold, "Meet on Wednesday.", repairs: repair)
        XCTAssertEqual(q.meaning?.score, 100)
        XCTAssertEqual(q.contentGuard.expectedWords, 3)
        XCTAssertEqual(q.gates, [])
        XCTAssertEqual(q.verdict, .pass)
        XCTAssertEqual(q.composite, 100)
    }

    func testMWrongSideOfARepairScoresBelowEcho() {
        // out `Meet on Tuesday.`: gold "Wednesday" is substituted by the raw
        // word "Tuesday" — gone from the output and not novel → D = 1 of
        // 3 → M_text 33.3 → 0.75·33.3 = 25 (unresolved). Below the 75 an
        // echo earns.
        let q = score(repairRaw, repairGold, "Meet on Tuesday.", repairs: repair)
        XCTAssertEqual(q.meaning?.lost, 1)
        XCTAssertEqual(q.meaning?.lostTokens, ["Wednesday"])
        XCTAssertEqual(q.meaning?.novel, 0)
        XCTAssertEqual(q.meaning!.text, 33.3, accuracy: 0.05)
        XCTAssertEqual(q.meaning!.score, 25, accuracy: 0.05)
        XCTAssertEqual(q.subsFromRaw, 1)
        XCTAssertEqual(q.verdict, .overEditHedge)
    }

    func testRepairsScoreOnlyAtTheirLevel() {
        // Run level `fillers` ≠ resolve_at `standard`: the echo is not
        // charged for the unresolved repair (M 100) and no reparandum is
        // subtracted from the expected length (7).
        let q = score(repairRaw, repairGold, "Meet on Tuesday, I mean on Wednesday.", repairs: repair, runLevel: .fillers)
        XCTAssertEqual(q.meaning?.scoredRepairs, 0)
        XCTAssertEqual(q.meaning?.score, 100)
        XCTAssertEqual(q.contentGuard.expectedWords, 7)
        XCTAssertEqual(q.verdict, .punct)
        // A verbatim register never runs the correction clause: same.
        let verbatim = score(repairRaw, repairGold, "Meet on Tuesday, I mean on Wednesday.", register: .terminal, repairs: repair)
        XCTAssertEqual(verbatim.meaning?.scoredRepairs, 0)
        // A fixture pinned to `fillers` scores its repair at that level.
        let fillersLevel = score("send it monday no wait tuesday", "Send it Tuesday.", "Send it Tuesday.", level: .fillers,
                                 repairs: [EvalCase.Repair(reparandum: "monday no wait", repair: "tuesday", resolveAt: .fillers)])
        XCTAssertEqual(fillersLevel.meaning?.scoredRepairs, 1)
        XCTAssertEqual(fillersLevel.meaning?.resolvedRepairs, 1)
    }

    func testMNovelReplacementIsChargedOnceAsNovelty() {
        // gold "Push the fix." out "Push the patch.": "patch" ∉ raw ∪ gold
        // → novel 1, and the substituted "fix" is NOT also counted lost —
        // 100·(1 − 3/3) = 0, not 1 − 2/3 − 3/3. REWORDED (one novel token,
        // under every INVENTED line).
        let q = score("push the fix", "Push the fix.", "Push the patch.")
        XCTAssertEqual(q.meaning?.novel, 1)
        XCTAssertEqual(q.meaning?.lost, 0)
        XCTAssertEqual(q.meaning?.score, 0)
        XCTAssertEqual(q.verdict, .reworded)
        // On a longer gold the arithmetic shows: 10 words, one novel sub →
        // 100·(1 − 3/10) = 70.
        let longer = score("please push the fix to the main branch before lunch",
                           "Please push the fix to the main branch before lunch.",
                           "Please push the patch to the main branch before lunch.")
        XCTAssertEqual(longer.meaning!.score, 70, accuracy: 0.05)
        XCTAssertEqual(longer.verdict, .reworded)
    }

    func testMDeletedShareGatesAtFifteenPercentOnSixWords() {
        // 1 of 6 = 0.167 ≥ 0.15 → deleted-share → OVER_EDIT_FACT; 1 of 7
        // = 0.143 → OVER_EDIT_HEDGE with M = 100·(1 − 2/7) = 71.4.
        let six = score("send the fix to prod now", "Send the fix to prod now.", "Send the fix to prod.")
        XCTAssertEqual(six.meaning?.goldWords, 6)
        XCTAssertEqual(six.meaning?.lost, 1)
        XCTAssertEqual(six.goldTriggers, [.deletedShare])
        XCTAssertEqual(six.verdict, .overEditFact)
        let seven = score("send the fix to the team now", "Send the fix to the team now.", "Send the fix to the team.")
        XCTAssertEqual(seven.meaning?.goldWords, 7)
        XCTAssertEqual(seven.goldTriggers, [])
        XCTAssertEqual(seven.verdict, .overEditHedge)
        XCTAssertEqual(seven.meaning!.score, 71.4, accuracy: 0.05)
        // Below the six-word floor the share never gates: 1 of 5 = 0.2.
        let five = score("send the fix to prod", "Send the fix to prod.", "Send the fix to.")
        XCTAssertEqual(five.goldTriggers, [])
        XCTAssertEqual(five.verdict, .overEditHedge)
    }

    func testStopDeletionsNeverFeedTheDeletedShareGate() {
        // "the" dropped from a 6-word gold: D = 1 but factLoss = 0, so the
        // 15% line is not crossed — a grammar nit is not a dropped fact
        // (§4.6's hedge rung and the guard's dropped_content already read
        // it that way). M still pays: 100·(1 − 2/6) = 66.7; verdict PASS
        // (every lost token is STOP).
        let q = score("send the fix to prod now", "Send the fix to prod now.", "Send fix to prod now.")
        XCTAssertEqual(q.meaning?.lostTokens, ["the"])
        XCTAssertEqual(q.meaning?.factLoss, 0)
        XCTAssertEqual(q.goldTriggers, [])
        XCTAssertEqual(q.verdict, .pass)
        XCTAssertEqual(q.meaning!.score, 66.7, accuracy: 0.05)
        // Two articles from a 13-word gold (2/13 = 0.154 as raw D): same.
        let two = score("send the fix and the test to the whole team before lunch today",
                        "Send the fix and the test to the whole team before lunch today.",
                        "Send fix and test to the whole team before lunch today.")
        XCTAssertEqual(two.meaning?.goldWords, 13)
        XCTAssertEqual(two.meaning?.lost, 2)
        XCTAssertEqual(two.meaning?.factLoss, 0)
        XCTAssertEqual(two.goldTriggers, [])
        XCTAssertEqual(two.verdict, .pass)
        // A content word beside a STOP word counts alone: 1 of 6 → gated.
        let mixed = score("send the fix to prod now", "Send the fix to prod now.", "Send fix to prod.")
        XCTAssertEqual(mixed.meaning?.lostTokens, ["the", "now"])
        XCTAssertEqual(mixed.meaning?.factLoss, 1)
        XCTAssertEqual(mixed.goldTriggers, [.deletedShare])
        XCTAssertEqual(mixed.verdict, .overEditFact)
    }

    func testOverEditReplicaOfRow58IsHedgeOnceAnnotatedAndFactBefore() {
        // §9's third replica, gold-scored. raw = the gold's words (16
        // atoms); the output drops the hedge "I don't know," — 3 words,
        // 18.75% of the gold. Annotated as must_keep w = 2 the loss is the
        // hedge rung's whatever its share (§9: "OVER_EDIT_HEDGE exactly on
        // fixtures with w = 2 spans"): M = 100·(1 − 6/16) − 8 = 54.5, no
        // gold trigger. F: comma 0/1 → 0, stop 1/1 → 1 → P 0.5; casing over
        // the 13 non-initial hits with "try" recased → 12/13; T 1 → 72.7.
        // Fi undefined → C = (0.3·72.7 + 0.5·54.5) / 0.8 = 61.3.
        let raw = "I don't know, try some broad benchmarking on the gravlin tabs and see what comes up"
        let gold = "I don't know, try some broad benchmarking on the gravlin tabs and see what comes up."
        let out = "Try some broad benchmarking on the gravlin tabs and see what comes up."
        let annotated = score(raw, gold, out, mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 2)])
        XCTAssertEqual(annotated.meaning?.goldWords, 16)
        XCTAssertEqual(annotated.meaning?.lostTokens, ["I", "don't", "know"])
        XCTAssertEqual(annotated.meaning?.factLoss, 0)
        XCTAssertEqual(annotated.goldTriggers, [])
        XCTAssertEqual(annotated.gates, [])
        XCTAssertEqual(annotated.verdict, .overEditHedge)
        XCTAssertEqual(annotated.meaning!.score, 54.5, accuracy: 0.05)
        XCTAssertEqual(annotated.formatting!.score, 72.7, accuracy: 0.05)
        XCTAssertEqual(annotated.composite!, 61.3, accuracy: 0.05)
        XCTAssertLessThan(annotated.meaning!.score, 80)   // §9's acceptance line for h58
        // Unannotated, the same drop is three content words of sixteen:
        // 0.1875 ≥ 0.15 → deleted-share → OVER_EDIT_FACT, C 0. The
        // annotation is what tells the scorer a hedge from a fact.
        let bare = score(raw, gold, out)
        XCTAssertEqual(bare.meaning?.factLoss, 3)
        XCTAssertEqual(bare.goldTriggers, [.deletedShare])
        XCTAssertEqual(bare.verdict, .overEditFact)
        XCTAssertEqual(bare.composite, 0)
        // Weight 5 is a fact whatever else: gated by both triggers.
        let fact = score(raw, gold, out, mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 5)])
        XCTAssertEqual(fact.meaning?.factLoss, 3)
        XCTAssertEqual(fact.goldTriggers, [.mustKeepFact, .deletedShare])
        XCTAssertEqual(fact.verdict, .overEditFact)
        // The hedge exemption covers only the annotated span: the hedge
        // plus three more content words (6 of 16, 3 counted → 0.1875) gates.
        let more = score(raw, gold, "Try some benchmarking on the gravlin tabs and see what comes up.",
                         mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 2)])
        XCTAssertEqual(more.meaning?.lost, 4)
        XCTAssertEqual(more.meaning?.factLoss, 1)
        XCTAssertEqual(more.verdict, .overEditHedge)
        let much = score(raw, gold, "Do benchmarking on the gravlin tabs and see what comes up.",
                         mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 2)])
        XCTAssertEqual(much.meaning?.factLoss, 2)
        XCTAssertEqual(much.verdict, .overEditHedge)
        let gated = score(raw, gold, "Do benchmarking on the tabs and see what comes up.",
                          mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 2)])
        XCTAssertEqual(gated.meaning?.factLoss, 3)
        XCTAssertEqual(gated.verdict, .overEditFact)
    }

    func testStopOnlyDeletionIsNotAnOverEditVerdictButStillCostsM() {
        // §4.6: OVER_EDIT_HEDGE needs a deleted token outside STOP. Dropping
        // one "the" from an 11-word gold (1/11 < 0.15) leaves the verdict
        // at PASS; §4.4's D still charges it: 100·(1 − 2/11) = 81.8.
        let q = score("please send the fix to the whole team before lunch today",
                      "Please send the fix to the whole team before lunch today.",
                      "Please send fix to the whole team before lunch today.")
        XCTAssertEqual(q.meaning?.lostTokens, ["the"])
        XCTAssertEqual(q.meaning!.score, 81.8, accuracy: 0.05)
        XCTAssertEqual(q.verdict, .pass)
    }

    func testCorrectResolutionWithAnAddedPrepositionIsAPass() {
        // Seed `correct-day` with "on" added: gold "Send it Tuesday." vs
        // out "Send it on Tuesday." — every gold word hits with its mark and
        // case (F 100), "on" is an unmarked STOP insertion (D 0, novel 0),
        // and the raw↔out NEGATED rule stays silent although the alignment
        // pairs the dropped "wait" with "on". §4.5 as literally written
        // fired here, zeroed the row and failed the column.
        let c = EvalCase.seeds.first { $0.id == "correct-day" }!
        let q = QualityScore.score(c, out: "Send it on Tuesday.")
        XCTAssertEqual(q.gates, [])
        XCTAssertEqual(q.verdict, .pass)
        XCTAssertEqual(q.composite, 100)
        XCTAssertEqual([q.hits, q.subs, q.dels, q.ins], [3, 0, 0, 1])
        // A novel trailing word is a reword, never a gate.
        let please = QualityScore.score(c, out: "Send it Tuesday please.")
        XCTAssertEqual(please.gates, [])
        XCTAssertEqual(please.verdict, .reworded)
    }

    func testCasingAfterADottedAbbreviationIsScored() {
        // Seed `abbrev-eg` exists to pin "npm must stay lowercase": the
        // period of "e.g." is part of the word, so "npm" is a scored casing
        // position. "Npm" → C 4/5 (use, eg, npm, for, packages), P 1, T 1
        // → F = 100·(0.5 + 0.24 + 0.2) = 94, PUNCT.
        let eg = EvalCase.seeds.first { $0.id == "abbrev-eg" }!
        let q = QualityScore.score(eg, out: "We use e.g. Npm for packages.")
        XCTAssertEqual(q.formatting?.casing, 0.8)
        XCTAssertEqual(q.formatting!.score, 94, accuracy: 0.05)
        XCTAssertEqual(q.verdict, .punct)
        // `abbrev-us`: "office" after "U.S." is scored (5/6 when recased);
        // "Bring" after "closed." stays sentence-initial — c_initial only.
        let us = EvalCase.seeds.first { $0.id == "abbrev-us" }!
        let office = QualityScore.score(us, out: "The U.S. Office is closed. Bring your badge.")
        XCTAssertEqual(office.formatting!.casing!, 5.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(office.verdict, .punct)
        let bring = QualityScore.score(us, out: "The U.S. office is closed. bring your badge.")
        XCTAssertEqual(bring.formatting?.casing, 1)
        XCTAssertEqual(bring.formatting?.cInitial, 0.5)
        XCTAssertEqual(bring.verdict, .pass)
        // A question mark after an initialism still ends the sentence.
        let asked = score("is it the us yes", "Is it the U.S.? Yes.", "Is it the U.S.? yes.")
        XCTAssertEqual(asked.formatting?.casing, 1)
        XCTAssertEqual(asked.formatting?.cInitial, 0.5)
    }

    func testFiStutterWithAMultiTokenKeep() {
        // §3.2 class 7 letter fragment: raw "my l phone", keep "my phone".
        // out = gold: my hit, l del, phone hit → hits [my, phone] == keep →
        // collapsed → 100, PASS. Keeping the "l": three hits ≠ two → 0,
        // MISSED (M untouched: "l" is an `.ins` that IS in raw). Cutting
        // "l phone" leaves hits [my] ≠ keep → 0 as well.
        let stutter = [EvalCase.Stutter(span: "my l phone", keep: "my phone")]
        let raw = "call me on my l phone tonight please", gold = "Call me on my phone tonight, please."
        let clean = score(raw, gold, gold, stutters: stutter)
        XCTAssertEqual(clean.fillers?.expected, 1)
        XCTAssertEqual(clean.fillers?.score, 100)
        XCTAssertEqual(clean.verdict, .pass)
        let kept = score(raw, gold, "Call me on my l phone tonight, please.", stutters: stutter)
        XCTAssertEqual(kept.fillers?.score, 0)
        XCTAssertEqual(kept.fillers?.missed, ["my l phone"])
        XCTAssertEqual(kept.meaning?.score, 100)
        XCTAssertEqual(kept.verdict, .missed)
        let overcut = score(raw, gold, "Call me on my tonight, please.", stutters: stutter)
        XCTAssertEqual(overcut.fillers?.score, 0)
    }

    func testDecimalCorruptionIsAVisibleRewordNotAHit() {
        // gold "Put a 15 on each wing." out "Put a 1.5 on each wing.": the
        // decimal keeps its point, so it is a novel token — REWORDED with
        // M = 100·(1 − 3/6) = 50 — never a silent hit on "15". Not an
        // invented numeral either (a correct "2.5" for "two and a half"
        // must not gate), which is the cardinals-only trade-off.
        let q = score("put a 15 on each wing", "Put a 15 on each wing.", "Put a 1.5 on each wing.")
        XCTAssertEqual(q.meaning?.novel, 1)
        XCTAssertEqual(q.meaning?.novelNumerals, 0)
        XCTAssertEqual(q.meaning?.score, 50)
        XCTAssertEqual(q.verdict, .reworded)
        XCTAssertEqual(q.continuity?.wordErrors, 1)
    }

    // MARK: - Verdict ladder (§4.6), one rung each

    func testRewordedFromASynonymOutsideRaw() {
        // An ASR-slip fix against a gold that kept the slip: one novel
        // token → REWORDED; M 100·(1 − 3/6) = 50; F stays 100 (all other
        // words hit with their marks and case).
        let q = score("I also signed into Norbose today", "I also signed into Norbose today.",
                      "I also signed into Norbase today.")
        XCTAssertEqual(q.verdict, .reworded)
        XCTAssertEqual(q.meaning?.novel, 1)
        XCTAssertEqual(q.meaning?.score, 50)
        XCTAssertEqual(q.formatting?.score, 100)
        XCTAssertEqual(q.composite!, (0.3 * 100 + 0.5 * 50) / 0.8, accuracy: 1e-9)
        // With the fix in the gold it is a PASS and nothing is novel.
        XCTAssertEqual(score("I also signed into Norbose today", "I also signed into Norbase today.",
                             "I also signed into Norbase today.").verdict, .pass)
    }

    func testRewordedFromAReorder() {
        // Two adjacent content words swapped: two `.sub` whose out tokens
        // are raw words → subsFromRaw 2; neither gold word is lost (both
        // still in the output) → M 100; verdict REWORDED. The continuity
        // WER still moves (2 of 4).
        let q = score("the quick brown fox", "The quick brown fox.", "The brown quick fox.")
        XCTAssertEqual([q.hits, q.subs, q.dels, q.ins], [2, 2, 0, 0])
        XCTAssertEqual(q.subsFromRaw, 2)
        XCTAssertEqual(q.meaning?.lost, 0)
        XCTAssertEqual(q.meaning?.score, 100)
        XCTAssertEqual(q.verdict, .reworded)
        XCTAssertEqual(q.gates, [])
        XCTAssertEqual(q.continuity?.wer, 0.5)
    }

    func testMissedBeatsPunctAndPassBeatsNothing() {
        // Fi < 100 with F < 100 → MISSED (the higher rung).
        let missed = score("um I also signed in", "I also signed in.", "um I also signed in")
        XCTAssertEqual(missed.fillers?.score, 0)
        XCTAssertLessThan(missed.formatting!.score, 100)
        XCTAssertEqual(missed.verdict, .missed)
        // F < 100 alone → PUNCT.
        XCTAssertEqual(score("I also signed in", "I also signed in.", "I also signed in").verdict, .punct)
        // Everything perfect → PASS.
        XCTAssertEqual(score("I also signed in", "I also signed in.", "I also signed in.").verdict, .pass)
    }

    func testGatedVerdictsZeroTheCompositeAndHeadTheLadder() {
        let answered = score("can you explain how the sync works", "Can you explain how the sync works?",
                             "Sure, I can explain that.\n1. **Sync** runs first.")
        XCTAssertEqual(answered.verdict, .answered)
        XCTAssertEqual(answered.composite, 0)
        XCTAssertEqual(answered.meaning?.score, 0)
        XCTAssertTrue(answered.isGated)
        let negated = score("do not push to main", "Do not push to main.", "Push to main.")
        XCTAssertEqual(negated.verdict, .negated)
        XCTAssertEqual(negated.composite, 0)
        // NEGATED outranks OVER_EDIT_FACT when both fire.
        let both = score("do not push the fix to main today", "Do not push the fix to main today.", "Push to main.")
        XCTAssertEqual(both.gates, [.negated, .overEditFact])
        XCTAssertEqual(both.verdict, .negated)
    }

    // MARK: - Composite (§5)

    func testCompositeWeightsAndRenormalization() {
        // F 75 (P 0.5, C 1, T 1), Fi 100, M 100 → 0.3·75 + 20 + 50 = 92.5.
        let withFi = score("um so I was thinking we should meet at 3", "So I was thinking we should meet at 3.",
                           "So I was thinking we should meet at 3, .")
        XCTAssertEqual(withFi.fillers?.score, 100)
        XCTAssertEqual(withFi.formatting!.score, 75, accuracy: 0.05)
        XCTAssertEqual(withFi.meaning?.score, 100)
        XCTAssertEqual(withFi.composite!, 92.5, accuracy: 0.05)
        // Same output, no filler in raw → Fi undefined → (0.3·75 + 0.5·100)
        // / 0.8 = 90.625.
        let noFi = score("so I was thinking we should meet at 3", "So I was thinking we should meet at 3.",
                         "So I was thinking we should meet at 3, .")
        XCTAssertNil(noFi.fillers)
        XCTAssertEqual(noFi.composite!, 90.625, accuracy: 0.05)
        XCTAssertEqual(0.3 / 0.8, 0.375, accuracy: 1e-12)
        XCTAssertEqual(0.5 / 0.8, 0.625, accuracy: 1e-12)
    }

    // MARK: - Best-of golds

    func testBestOfGoldsPicksTheHigherComposite() {
        // gold "and fifty-four." vs golds ["and 54."]: the digit gold
        // matches the output word-for-word on the continuity axis while
        // the quality axes see both as hits; C is a tie, so `gold` (index
        // 0) wins. A punctuation difference breaks the tie.
        let tie = score("and fifty four", "and fifty-four.", "and 54.", golds: ["and 54."])
        XCTAssertEqual(tie.goldIndex, 0)
        XCTAssertEqual(tie.composite, 100)
        let alt = score("okay we ship it", "Okay, we ship it.", "Okay we ship it!", golds: ["Okay we ship it!"])
        XCTAssertEqual(alt.goldIndex, 1)
        XCTAssertEqual(alt.composite, 100)
        XCTAssertEqual(alt.verdict, .pass)
        XCTAssertEqual(alt.continuity?.punctF1, 1)
        // Against `gold` alone the same output is PUNCT.
        XCTAssertEqual(score("okay we ship it", "Okay, we ship it.", "Okay we ship it!").verdict, .punct)
    }

    // MARK: - Gold-free

    func testGoldFreeFixtureScoresGatesAndFiOnly() {
        let c = EvalCase(id: "h1", raw: "can you explain how the sync works between the phone and the watch",
                         gold: "", goldSource: "history-unrated")
        let clean = QualityScore.score(c, out: "Can you explain how the sync works between the phone and the watch?")
        XCTAssertTrue(clean.isGoldFree)
        XCTAssertEqual(clean.verdict, .unrated)
        XCTAssertNil(clean.composite)
        XCTAssertNil(clean.continuity)
        XCTAssertEqual([clean.hits, clean.subs, clean.dels, clean.ins], [0, 0, 0, 0])
        let answered = QualityScore.score(c, out: "Sure, here is how it works:\n1. **Sync** the phone.")
        XCTAssertEqual(answered.verdict, .answered)
        XCTAssertNil(answered.composite)
        // A question reduced to three of its own words: the collapse rule
        // sees the shrink and — since task-023's fix round — the answer-shape
        // rule sees the QUESTION (the raw opens with "can", the output keeps
        // neither that opener nor a question mark and invents nothing). Both
        // fire, and ANSWERED outranks OVER_EDIT_FACT, so this row moves one
        // rung up the ladder. Gated either way, on both profiles.
        let collapsed = QualityScore.score(c, out: "Explain the sync.")
        XCTAssertEqual(collapsed.verdict, .answered)
        XCTAssertEqual(collapsed.triggerNames, ["answer-shape", "length-collapse"])
    }

    // MARK: - Draft golds (dispatcher decision D1) and v1 JSON

    func testDraftGoldIsScoredLikeAConfirmedOne() throws {
        let draft = try JSONDecoder().decode([EvalCase].self, from: Data(#"""
        [{"id": "h58", "raw": "i don't know try some benchmarking", "gold": "I don't know, try some benchmarking.",
          "gold_source": "draft:claude", "annotations_status": "draft"}]
        """#.utf8))[0]
        XCTAssertTrue(draft.isDraft)
        let q = QualityScore.score(draft, out: draft.gold)
        XCTAssertEqual(q.composite, 100)
        XCTAssertEqual(q.verdict, .pass)
    }

    func testV1FixtureDecodesAndScores() throws {
        let v1 = try JSONDecoder().decode([EvalCase].self,
                                          from: Data(#"[{"id": "mine-1", "raw": "hey um can you", "gold": "Hey, can you?"}]"#.utf8))[0]
        let q = QualityScore.score(v1, out: "Hey, can you?")
        XCTAssertEqual(q.verdict, .pass)
        XCTAssertEqual(q.fillers?.score, 100)
        XCTAssertEqual(q.composite, 100)
    }

    // MARK: - Every seed's gold passes its own scorer

    func testEverySeedGoldScores100AgainstItself() {
        for c in EvalCase.seeds {
            let q = QualityScore.score(c, out: c.gold)
            XCTAssertEqual(q.verdict, .pass, c.id)
            XCTAssertEqual(q.formatting?.score, 100, c.id)
            XCTAssertEqual(q.meaning?.score, 100, c.id)
            XCTAssertEqual(q.composite, 100, c.id)
            if let fi = q.fillers { XCTAssertEqual(fi.score, 100, c.id) }
            XCTAssertEqual(q.continuity?.wer, 0, c.id)
        }
    }
}
