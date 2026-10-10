import XCTest
@testable import WhisprBroCore

/// The seed set as a fixture file would be linted (plan §3.1 `lint`, §3.2
/// table, §9 replica pins): every gold passes its own scorer, every
/// annotation span is where it says it is, the class counts are the
/// plan's, and the set clears the lint floors with numbers hand-counted
/// here — so a seed edit that breaks its own scorer, or tips the set's
/// balance, fails CI rather than silently moving the leaderboard.
final class SeedFixtureTests: XCTestCase {
    private let seeds = EvalCase.seeds

    private func seed(_ id: String) -> EvalCase { seeds.first { $0.id == id }! }

    private func score(_ id: String, _ out: String) -> QualityScore {
        QualityScore.score(seed(id), out: out)
    }

    /// The step-5 seeds (after the 17 originals) with a given id prefix,
    /// in set order — "punct-" must not pick up the original punct-double.
    private func ids(prefix: String) -> [String] {
        seeds.dropFirst(17).map(\.id).filter { $0.hasPrefix(prefix + "-") }
    }

    // MARK: - Identity

    func testEightyOneUniqueIdsWithTheOriginalsFirst() {
        XCTAssertEqual(seeds.count, 81)
        XCTAssertEqual(Set(seeds.map(\.id)).count, 81)
        // The 17 originals keep their order (AlignTests pins their counts).
        XCTAssertEqual(seeds.prefix(17).map(\.id),
                       ["correct-time", "correct-day", "cue-is-content", "correct-long-span", "correct-number",
                        "premise-fillers", "bench-standup", "bench-quarterly", "bench-meeting", "bench-code",
                        "cap-mid", "abbrev-eg", "abbrev-us", "comma-leading", "comma-double", "comma-terminal",
                        "punct-double"])
        for c in seeds {
            XCTAssertEqual(c.source, "synthetic", c.id)
            XCTAssertEqual(c.goldSource, "seed", c.id)
            XCTAssertEqual(c.annotationsStatus, .confirmed, c.id)
            XCTAssertNil(c.observed, c.id)
            XCTAssertNil(c.observedMs, c.id)
            XCTAssertNil(c.control, c.id)   // derived, never asserted by hand
            XCTAssertFalse(c.isGoldFree, c.id)
            XCTAssertFalse(c.tags.isEmpty, c.id)
        }
    }

    // MARK: - Gold passes its own scorer

    func testEveryGoldScoresPerfectAgainstItself() {
        for c in seeds {
            let q = QualityScore.score(c, out: c.gold)
            XCTAssertEqual(q.verdict, .pass, c.id)
            XCTAssertEqual(q.formatting?.score, 100, c.id)
            XCTAssertEqual(q.meaning?.score, 100, c.id)
            XCTAssertEqual(q.composite, 100, c.id)
            XCTAssertEqual(q.gates, [], c.id)
            XCTAssertEqual(q.goldIndex, 0, c.id)
            if let fi = q.fillers { XCTAssertEqual(fi.score, 100, c.id) }
            XCTAssertEqual(q.continuity?.wer, 0, c.id)
            // Every alternate gold is a perfect output too (best-of picks it).
            for alt in c.golds {
                XCTAssertEqual(QualityScore.score(c, out: alt).composite, 100, "\(c.id) alternate")
            }
        }
        let col = EvalRun.Column.make(formatter: "gold", level: "standard", config: EvalRun.Config(), runKey: "0",
                                      observations: seeds.map {
                                          EvalRun.Observation(fixture: $0, stripped: $0.raw, out: $0.gold,
                                                              score: QualityScore.score($0, out: $0.gold))
                                      })
        XCTAssertEqual(col.gate.status, .pass)
        XCTAssertEqual(col.verdicts["PASS"], 81)
        XCTAssertEqual(col.scores, EvalRun.Scores(f: 100, fi: 100, m: 100, c: 100))
    }

    func testTheEmptyGoldSeedIsARatedGold() {
        // fragment-01: raw "Uh", gold "" under seed provenance — not
        // gold-free (dispatcher decision a). The empty output is its PASS;
        // the fast path's "Uh." is a MISSED removal with F 0.
        let uh = seed("fragment-01")
        XCTAssertEqual(uh.gold, "")
        XCTAssertFalse(uh.isGoldFree)
        XCTAssertEqual(uh.expectedFillers, [EvalCase.Filler(span: "Uh")])
        XCTAssertEqual(score("fragment-01", "").verdict, .pass)
        XCTAssertEqual(score("fragment-01", "").composite, 100)
        let kept = score("fragment-01", "Uh.")
        XCTAssertEqual(kept.verdict, .missed)
        XCTAssertEqual(kept.fillers?.score, 0)
        XCTAssertEqual(kept.formatting?.score, 0)
        XCTAssertEqual(kept.composite, 50)
        XCTAssertEqual(try EvalRun.Fixtures(path: "seeds", name: "seeds", cases: seeds).ratedN, 81)
    }

    // MARK: - Class counts (§3.2 table) and tags

    func testClassCountsMatchThePlanTable() {
        let counts: [String: Int] = [
            "long": 10, "medium": 6, "question": 5, "trap": 5, "hedge": 5, "numbers": 4, "stutter": 4,
            "repair": 3, "cue-control": 2, "asr-slip": 3, "fragment": 4, "punct": 3, "register": 3,
            "continuation": 2, "latency": 5,
        ]
        for (prefix, n) in counts {
            XCTAssertEqual(ids(prefix: prefix).count, n, prefix)
        }
        XCTAssertEqual(counts.values.reduce(0, +), 64)
        // Class 1: 60–150 words, all controls. Class 2: 16–60 words with
        // one to three fillers. Class 14: exactly the ladder.
        for id in ids(prefix: "long") {
            XCTAssertTrue((60...150).contains(seed(id).wordCount), "\(id) \(seed(id).wordCount)")
            XCTAssertTrue(seed(id).isControl, id)
        }
        for id in ids(prefix: "medium") {
            XCTAssertTrue((16...60).contains(seed(id).wordCount), id)
            XCTAssertTrue((1...3).contains(seed(id).expectedFillers.count), id)
        }
        XCTAssertEqual(ids(prefix: "latency").map { seed($0).wordCount }, [10, 30, 60, 100, 150])
        XCTAssertEqual(ids(prefix: "latency").map { seed($0).latencyBudgetMs }, [300, 700, 700, 1500, 1500])
        // The ladder is one prompt: each raw is a prefix of the next.
        let ladder = ids(prefix: "latency").map { seed($0).raw }
        for (short, long) in zip(ladder, ladder.dropFirst()) { XCTAssertTrue(long.hasPrefix(short)) }
        // Registers set the field the bench directs by.
        XCTAssertEqual(seed("register-messaging").register, .messaging)
        XCTAssertEqual(seed("register-notes").register, .notes)
        XCTAssertEqual(seed("register-browser").register, .browser)
        XCTAssertTrue(seeds.filter { $0.register != .unknown }.allSatisfy { $0.id.hasPrefix("register-") })
        XCTAssertTrue(seeds.allSatisfy { $0.level == .standard && $0.language == .english })
    }

    func testTagHistogramIsHandCounted() {
        var histogram: [String: Int] = [:]
        for tag in seeds.flatMap(\.tags) { histogram[tag, default: 0] += 1 }
        XCTAssertEqual(histogram, [
            "agent-prompt": 59,   // bench-code + 58 of the 64 (not the fragments, messaging, notes)
            "control": 49,        // = isControl, asserted below
            "long": 13,           // class 1 + the 60 / 100 / 150 ladder rows
            "fillers": 20,        // = a derived filler, asserted below
            "stutter": 6,         // bench-standup, numbers-01, class 7
            "repair": 8,          // the five annotated originals + class 8
            "cue-control": 3,     // cue-is-content + class 8's two
            "punct": 10,          // the seven deterministic-fix originals + class 11
            "bench": 4, "medium": 6, "question": 6, "trap": 5, "hedge": 5, "numbers": 5,
            "asr-slip": 3, "fragment": 4, "all-filler": 1, "backchannel": 1,
            "register": 3, "messaging": 1, "notes": 1, "browser": 1,
            "continuation": 2, "latency": 5, "replica": 3,
        ])
        for c in seeds {
            XCTAssertEqual(c.tags.contains("control"), c.isControl, c.id)
            XCTAssertEqual(c.tags.contains("fillers"), !c.expectedFillers.isEmpty, c.id)
            XCTAssertEqual(c.tags.contains("stutter"), !c.expectedStutters.isEmpty, c.id)
            XCTAssertEqual(c.tags.contains("repair"), !c.repairs.isEmpty, c.id)
            XCTAssertEqual(c.tags.contains("hedge"),
                           c.mustKeep.contains { $0.weight < EvalCase.MustKeep.factWeight }, c.id)
            XCTAssertEqual(Set(c.tags).count, c.tags.count, c.id)
        }
        XCTAssertEqual(seeds.filter { $0.tags.contains("replica") }.map(\.id), ["question-01", "trap-01", "hedge-01"])
    }

    // MARK: - Set-level lint floors (§3.1)

    func testSetLevelLintFloors() {
        let n = Double(seeds.count)
        let controls = seeds.filter(\.isControl).count
        let sixty = seeds.filter { $0.wordCount >= 60 }.count
        let thirty = seeds.filter { $0.wordCount >= 30 }.count
        let agent = seeds.filter { $0.tags.contains("agent-prompt") }.count
        let oneWord = seeds.filter { $0.wordCount == 1 }.count
        // Hand-counted: 10 original controls + 39 new; ≥ 60 words = the 10
        // long controls, three ladder rows, notes, browser, question-01,
        // question-02 and hedge-05 (61 with its "uh"); ≥ 30 adds the 30-word
        // ladder row, question-03…05, the five traps, hedge-02…04, the four
        // number seeds, the six mediums, stutter-03 and the three slips;
        // one-word = Uh, Mm-hmm, But.
        XCTAssertEqual(controls, 49)
        XCTAssertEqual(sixty, 18)
        XCTAssertEqual(thirty, 44)
        XCTAssertEqual(agent, 59)
        XCTAssertEqual(oneWord, 3)
        XCTAssertGreaterThanOrEqual(Double(controls) / n, 0.15)
        XCTAssertGreaterThanOrEqual(Double(sixty) / n, 0.20)
        XCTAssertGreaterThanOrEqual(Double(thirty) / n, 0.40)
        XCTAssertGreaterThanOrEqual(Double(agent) / n, 0.60)
        XCTAssertLessThanOrEqual(Double(oneWord) / n, 0.10)
    }

    // MARK: - Row-level lint (§3.1): every annotation is where it says it is

    func testEveryAnnotationSpanIsFoundInRawAndGold() {
        for c in seeds {
            let raw = Align.canonicalTokens(c.raw)
            let gold = Align.canonicalTokens(c.gold)
            for f in c.expectedFillers {
                XCTAssertNotNil(Align.locate(f.span, in: raw, occurrence: f.occurrence), "\(c.id) filler \(f)")
            }
            for s in c.expectedStutters {
                XCTAssertNotNil(Align.locate(s.span, in: raw, occurrence: s.occurrence), "\(c.id) stutter \(s)")
                // `keep` is an in-order subsequence of the run ("my l
                // laptop" keeps "my laptop"), not a contiguous raw span.
                var remaining = Align.canonicalTokens(s.span).map(\.canonical)[...]
                for kept in Align.canonicalTokens(s.keep).map(\.canonical) {
                    guard let at = remaining.firstIndex(of: kept) else { XCTFail("\(c.id) keep \(s.keep)"); break }
                    remaining = remaining[(at + 1)...]
                }
            }
            for r in c.repairs {
                XCTAssertNotNil(Align.locate(r.reparandum, in: raw), "\(c.id) reparandum")
                XCTAssertNil(Align.locate(r.reparandum, in: gold), "\(c.id) reparandum survives in gold")
                XCTAssertNotNil(Align.locate(r.repair, in: gold), "\(c.id) repair")
                XCTAssertEqual(r.resolveAt, .standard, c.id)
            }
            for m in c.mustKeep {
                XCTAssertNotNil(Align.locate(m.span, in: raw), "\(c.id) must_keep in raw")
                XCTAssertNotNil(Align.locate(m.span, in: gold), "\(c.id) must_keep in gold")
            }
            // No seed keeps a filler: every core filler in raw is expected gone.
            let lexicon = Set(FillerStripper.coreFillers(for: c.language))
            XCTAssertEqual(c.expectedFillers.count, raw.filter { lexicon.contains($0.normalized) }.count, c.id)
            // No numeral in a gold the speaker did not say (alternates cover
            // the ITN spellings; cardinals canonicalize on their own).
            let said = Set(raw.map(\.canonical))
            for token in gold where token.isNumeral {
                XCTAssertTrue(said.contains(token.canonical), "\(c.id) invented numeral \(token.canonical)")
            }
            // The inventor's appended atoms must be novel on every seed.
            XCTAssertFalse(said.contains("140"), c.id)
            XCTAssertFalse(said.contains("units"), c.id)
            // A control has zero word edits between raw and gold.
            if c.isControl {
                XCTAssertEqual(Align.align(raw, gold).errors, 0, c.id)
            }
        }
    }

    func testHedgesStayUnderFifteenPercentOfTheirGold() {
        // Dispatcher decision e: an unannotated drop of the same words must
        // still read as the hedge rung (D/N_g < 0.15), so the annotation
        // only adds the flat penalty — never the difference between HEDGE
        // and a FACT gate.
        for c in seeds where c.mustKeep.contains(where: { $0.weight < EvalCase.MustKeep.factWeight }) {
            let goldWords = Double(Align.canonicalTokens(c.gold).count)
            let hedgeWords = c.mustKeep.filter { $0.weight < EvalCase.MustKeep.factWeight }
                .reduce(0) { $0 + Align.canonicalTokens($1.span).count }
            XCTAssertLessThan(Double(hedgeWords) / goldWords, 0.15, c.id)
            let dropped = ReferenceFormatters.hedgeDropper(c)
            let bare = QualityScore.score(EvalCase(id: c.id, raw: c.raw, gold: c.gold), out: dropped)
            XCTAssertEqual(bare.verdict, .overEditHedge, "\(c.id) unannotated")
            XCTAssertEqual(QualityScore.score(c, out: dropped).verdict, .overEditHedge, "\(c.id) annotated")
        }
    }

    func testAsrSlipGoldsAreLongEnoughForAnEchoToKeepNinety() {
        // One lost word costs 2/N_g of M_text; at ≥ 22 gold words the echo
        // of the slip stays at or above 90 (§9's fillerOnly floor).
        for id in ids(prefix: "asr-slip") {
            let c = seed(id)
            XCTAssertGreaterThanOrEqual(Align.canonicalTokens(c.gold).count, 22, id)
            let echo = QualityScore.score(c, out: c.raw)
            XCTAssertEqual(echo.meaning?.lost, 1, id)
            XCTAssertEqual(echo.meaning?.novel, 0, id)
            XCTAssertGreaterThanOrEqual(echo.meaning!.text, 90, id)
            XCTAssertEqual(echo.gates, [], id)
        }
    }

    // MARK: - The three replicas (§9)

    func testReplicaOfRow70IsAnswered() {
        // question-01: a how-does-it-work question. Under the reference
        // answerer → ANSWERED; under the failure's own shape — the real
        // row was 214 → 488 chars of markdown — an opener, a numbered
        // bold list over six lines, 116 atoms against 65 spoken (ratio
        // 1.78): all four ANSWERED triggers. The list numerals 1 and 3 are
        // invented ("2" and "4" are covered by the spoken "two" and "four
        // songs"), so INVENTED joins it, and the reply drops most of the
        // question's own words, so the gold-scored deleted share fires too
        // — the real row did all three. ANSWERED still heads the ladder
        // and C = 0. The reply carries no negation on purpose: an inserted
        // "not" between two aligned neighbours would add NEGATED to the
        // list without changing the verdict.
        let c = seed("question-01")
        XCTAssertEqual(QualityScore.score(c, out: ReferenceFormatters.answerer(c)).verdict, .answered)
        let reply = """
            Sure, I can explain that.

            1. **Add songs** on the phone. The playlist is stored locally first and only queued for the watch.
            2. **Foreground sync** runs when the app is open. It pushes the queued songs over the bridge in order, a few at a time, so a long list takes several passes.
            3. **Background sync** runs on a timer once the watch is on the charger. This is the second sync you noticed, and it picks up whatever the foreground pass left behind.
            4. **Check the watch** after the run. Songs that arrived mid-run were delivered by the background pass rather than the phone.

            Let me know if you want the timer interval changed.
            """
        let q = QualityScore.score(c, out: reply)
        XCTAssertEqual(q.verdict, .answered)
        XCTAssertEqual(q.composite, 0)
        XCTAssertEqual(q.meaning?.score, 0)
        XCTAssertEqual(q.contentGuard.triggers.prefix(4), [.multiLine, .markdown, .opener, .lengthRatio])
        XCTAssertEqual(q.contentGuard.rawWords, 65)
        XCTAssertEqual(q.contentGuard.outWords, 116)
        XCTAssertGreaterThanOrEqual(q.meaning!.novel, EvalThresholds.inventedNovelTokens)
        XCTAssertEqual(q.meaning?.novelNumerals, 2)
        XCTAssertEqual(q.goldTriggers, [.deletedShare])
        XCTAssertEqual(q.gates, [.answered, .invented, .overEditFact])
        // The question punctuated is a PASS.
        XCTAssertEqual(QualityScore.score(c, out: c.gold).verdict, .pass)
    }

    func testReplicaOfRow54IsInvented() {
        // trap-01: two paired amounts and a request to total them. Under
        // the reference inventor → INVENTED; under the failure's own shape —
        // the sum written out — "104" is the one atom the speaker never
        // said (40 / 12 / 20 are raw words; "+", "=" are orphan symbols,
        // so the sum line is 10 atoms: so the total is 40 12 12 20 20 104 →
        // 31 + 5 = 36 atoms in all), and one novel numeral gates: C = 0.
        // The ratio 36/31 = 1.16 stays under the ANSWERED line, so the
        // verdict names the right failure.
        let c = seed("trap-01")
        XCTAssertEqual(QualityScore.score(c, out: ReferenceFormatters.inventor(c)).verdict, .invented)
        let math = "Okay, so the glider is 40, then I've got a 12 on each wing and a 20 on each wing. So the total is: 40 + 12 + 12 + 20 + 20 = 104. Put the total in the log."
        let q = QualityScore.score(c, out: math)
        XCTAssertEqual(q.verdict, .invented)
        XCTAssertEqual(q.composite, 0)
        XCTAssertEqual(q.contentGuard.novel, ["104"])
        XCTAssertEqual(q.meaning?.novelNumerals, 1)
        XCTAssertEqual(q.contentGuard.triggers, [.novelNumeral])
        XCTAssertEqual(q.contentGuard.outWords, 36)
        XCTAssertEqual(q.gates, [.invented])
        // The same words punctuated: a PASS; the raw echoed: PUNCT.
        XCTAssertEqual(QualityScore.score(c, out: c.gold).verdict, .pass)
        XCTAssertEqual(QualityScore.score(c, out: c.raw).verdict, .punct)
    }

    func testReplicaOfRow58IsOverEditHedge() {
        // hedge-01: "I don't know," dropped from a 25-word prompt. Under
        // the reference hedge dropper: lost 3, factLoss 0 (annotated
        // stance), no gate → OVER_EDIT_HEDGE with M = 100·(1 − 6/25) − 8 =
        // 68. F: comma 0/1 → 0, stop 1/1 → 1 → P 0.5; casing over the 21
        // non-initial hits all equal → 1; T 1 → 75. Fi undefined → C =
        // (0.3·75 + 0.5·68) / 0.8 = 70.6. The raw↔out guard sees "don't"
        // deleted WITH its "know" → no NEGATED; dropped_content lists the
        // hedge for the rating queue.
        let c = seed("hedge-01")
        let out = ReferenceFormatters.hedgeDropper(c)
        XCTAssertEqual(out, "maybe dig into the Orbitr tab groups thing first and see what actually comes back before we change the sync at all.")
        let q = QualityScore.score(c, out: out)
        XCTAssertEqual(q.verdict, .overEditHedge)
        XCTAssertEqual(q.gates, [])
        XCTAssertEqual(q.goldTriggers, [])
        XCTAssertEqual(q.meaning?.lostTokens, ["I", "don't", "know"])
        XCTAssertEqual(q.meaning?.factLoss, 0)
        XCTAssertEqual(q.meaning?.missedMustKeep.map(\.span), ["I don't know,"])
        XCTAssertEqual(q.meaning!.score, 68, accuracy: 0.05)
        XCTAssertEqual(q.formatting!.score, 75, accuracy: 0.05)
        XCTAssertEqual(q.composite!, 70.6, accuracy: 0.05)
        XCTAssertLessThan(q.meaning!.score, 80)   // §9's acceptance line for the h58 shape
        XCTAssertEqual(q.contentGuard.droppedContent, ["I", "don't", "know"])
        XCTAssertFalse(q.contentGuard.triggers.contains(.negationDropped))
        // Unannotated the same drop is 3 of 25 = 12% < 15%: still the hedge
        // rung, M = 100·(1 − 6/25) = 76 — the annotation adds the penalty.
        let bare = QualityScore.score(EvalCase(id: c.id, raw: c.raw, gold: c.gold), out: out)
        XCTAssertEqual(bare.verdict, .overEditHedge)
        XCTAssertEqual(bare.meaning!.score, 76, accuracy: 0.05)
        // The §9 forty-word row: hedge-02 under the dropper is M = 77.
        let forty = QualityScore.score(seed("hedge-02"), out: ReferenceFormatters.hedgeDropper(seed("hedge-02")))
        XCTAssertEqual(forty.verdict, .overEditHedge)
        XCTAssertEqual(forty.meaning?.goldWords, 40)
        XCTAssertEqual(forty.meaning!.score, 77, accuracy: 0.05)
    }
}
