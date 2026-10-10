import XCTest
@testable import WhisprBroCore

/// §7.4's six checks and the one decision they exist to make: may the
/// composite call itself calibrated? The dataset below is synthetic and
/// deliberately perfect — a metric that agrees with him exactly — so that
/// the only thing moving in each test is the evidence: 99 rated rows vs
/// 100, 39 pairs vs 40, κ 0.59 vs 0.60. Everything else pins the mapping,
/// the joins, and the record `eval` reads for its banner.
final class CalibrationTests: XCTestCase {
    // MARK: Dataset

    private let cleanGold = "We ship the fix today."
    private let overEditOut = "Try some broad benchmarking."

    private func clean(_ i: Int) -> EvalCase {
        EvalCase(id: "c\(i)", raw: "um we ship the fix today", gold: cleanGold, tags: ["clean"])
    }

    /// A fixture whose output drops an annotated fact — OVER_EDIT_FACT,
    /// C = 0, M = 0.
    private func overEdit(_ i: Int) -> EvalCase {
        EvalCase(id: "b\(i)", raw: "um I don't know, try some broad benchmarking",
                 gold: "I don't know, try some broad benchmarking.", tags: ["hedge"],
                 mustKeep: [EvalCase.MustKeep(span: "I don't know", weight: 5)])
    }

    private func column(_ pairs: [(EvalCase, String)], formatter: String, runKey: String) -> EvalRun.Column {
        EvalRun.Column.make(formatter: formatter, level: "standard", config: EvalRun.Config(), runKey: runKey,
                            observations: pairs.map { c, out in
                                EvalRun.Observation(fixture: c, stripped: c.raw, out: out, source: .model,
                                                    ms: 400, score: QualityScore.score(c, out: out))
                            })
    }

    private func run(_ columns: [EvalRun.Column], cases: [EvalCase], id: String = "r1") throws -> EvalRun {
        EvalRun(runId: id, date: "2026-09-14T18:02:00Z", gitSha: "36ff03b", dirty: false,
                machine: EvalRun.Machine(model: "Mac14,12", os: "26.5.1"),
                fixtures: try EvalRun.Fixtures(path: "p.json", name: "personal", cases: cases),
                columns: columns)
    }

    private func rating(_ id: String, out: String, verdict: Rating.Verdict?, tags: [String] = [],
                        runKey: String = "aaaaaaaaaaaa", formatter: String = "llama",
                        pair: Rating.Pair? = nil, at: String = "2026-09-14T18:03:00Z") -> Rating {
        Rating(fixtureId: id, runKey: runKey, formatter: formatter, outputSha: Rating.outputSha(out),
               verdict: verdict, tags: tags, pair: pair, msToRate: 4200, ratedAt: at, session: "s1")
    }

    /// One row per §7.4 gate, taking the first three odd slots of the
    /// dataset: ANSWERED / INVENTED / NEGATED recall are conditions of
    /// VALID, so they have to be MEASURED — an unmeasured one holds check 3
    /// at `n/a`, which never passes. Gold-free, so they carry no M or C and
    /// the separation, ranking and weight checks read exactly the rows they
    /// read before; the metric calls all three WRONG, as he does, so κ does
    /// not move either.
    private func gateRow(_ i: Int) -> (fixture: EvalCase, out: String, tag: String)? {
        let shapes: [(raw: String, out: String, tag: String)] = [
            ("can you explain how the sync works", "Sure, I can explain that.\n1. **Sync** the tabs.", "answered"),
            ("so the glider plus a forty two on each wing and a twenty eight on each wing so find the total",
             "So the glider plus a 42 on each wing and a 28 on each wing. "
                 + "So the total is: 42 + 42 + 28 + 28 = 140 units.", "invented"),
            ("do not push to main", "push to main", "negated"),
        ]
        let n = (i - 1) / 2
        guard n < shapes.count else { return nil }
        let shape = shapes[n]
        return (EvalCase(id: "g\(i)", raw: shape.raw, gold: "", tags: ["unrated"],
                         goldSource: EvalCase.historyUnratedGoldSource, annotationsStatus: .draft),
                shape.out, shape.tag)
    }

    /// `rated` triage rows (half clean → SHIP, half over-edit → WRONG
    /// tagged `dropped-fact`, the first three odd ones a gate apiece) plus
    /// `pairs` blind picks, half favouring each run so neither side of τ_b
    /// is constant. `wrongShips` flips that many SHIPs to WRONG, which is
    /// how the κ boundary is walked.
    private func dataset(rated: Int, pairs: Int, wrongShips: Int = 0) throws
        -> (fixtures: [EvalCase], runs: [EvalRun], ratings: [Rating]) {
        var fixtures: [EvalCase] = []
        var rows: [(EvalCase, String)] = []
        var ratings: [Rating] = []
        for i in 0..<rated {
            if i % 2 == 0 {
                let c = clean(i)
                fixtures.append(c)
                rows.append((c, cleanGold))
                let flipped = i / 2 < wrongShips
                ratings.append(rating(c.id, out: cleanGold, verdict: flipped ? .wrong : .ship,
                                      tags: flipped ? ["reworded"] : []))
            } else if let gate = gateRow(i) {
                fixtures.append(gate.fixture)
                rows.append((gate.fixture, gate.out))
                ratings.append(rating(gate.fixture.id, out: gate.out, verdict: .wrong, tags: [gate.tag]))
            } else {
                let c = overEdit(i)
                fixtures.append(c)
                rows.append((c, overEditOut))
                ratings.append(rating(c.id, out: overEditOut, verdict: .wrong, tags: ["dropped-fact"]))
            }
        }
        // The pairwise half: the same fixture scored by two runs, the
        // better output alternating sides so his picks vary too.
        var aRows: [(EvalCase, String)] = [], bRows: [(EvalCase, String)] = []
        for i in 0..<pairs {
            let c = EvalCase(id: "p\(i)", raw: "um we ship the fix today", gold: cleanGold, tags: ["pair"])
            fixtures.append(c)
            let aWins = i % 2 == 0
            aRows.append((c, aWins ? cleanGold : overEditOut))
            bRows.append((c, aWins ? overEditOut : cleanGold))
            ratings.append(rating(c.id, out: aWins ? cleanGold : overEditOut, verdict: nil,
                                  pair: Rating.Pair(aRun: "aaaaaaaaaaaa", bRun: "bbbbbbbbbbbb",
                                                    slot: "a", pick: aWins ? "a" : "b")))
        }
        let runA = try run([column(rows + aRows, formatter: "llama", runKey: "aaaaaaaaaaaa")], cases: fixtures)
        let runB = bRows.isEmpty ? nil
            : try run([column(bRows, formatter: "foundation", runKey: "bbbbbbbbbbbb")], cases: fixtures, id: "r2")
        return (fixtures, [runA] + (runB.map { [$0] } ?? []), ratings)
    }

    private func report(rated: Int, pairs: Int, wrongShips: Int = 0) throws -> Calibration.Report {
        let d = try dataset(rated: rated, pairs: pairs, wrongShips: wrongShips)
        return Calibration.report(fixtures: d.fixtures, runs: d.runs, ratings: d.ratings,
                                  fixturesName: "personal", date: "2026-09-14T19:00:00Z")
    }

    private func check(_ report: Calibration.Report, _ number: Int) throws -> Calibration.Check {
        try XCTUnwrap(report.checks.first { $0.number == number })
    }

    // MARK: - The validity boundary

    func testValidWhenEveryCheckPassesOnEnoughEvidence() throws {
        let report = try report(rated: 100, pairs: 40)
        XCTAssertEqual(report.n, 100)
        XCTAssertEqual(report.pairs, 40)
        XCTAssertTrue(report.valid, report.checks.map { "\($0.number) \($0.status.rawValue)" }.joined(separator: " "))
        XCTAssertEqual(report.banner, "CALIBRATION: VALID (n=100 rated)")
        for number in 2...5 {
            XCTAssertEqual(try check(report, number).status, .pass, "check \(number)")
        }
        XCTAssertEqual(report.kappaWeighted!, 1.0, accuracy: 1e-9)
    }

    func testNinetyNineRatedRowsIsPending() throws {
        let report = try report(rated: 99, pairs: 40)
        XCTAssertEqual(report.n, 99)
        XCTAssertFalse(report.valid)
        XCTAssertEqual(report.banner, "CALIBRATION: PENDING (n=99 rated)")
        // …and nothing failed: the evidence is short, not contradictory.
        for number in 2...5 {
            XCTAssertEqual(try check(report, number).status, .pass, "check \(number)")
        }
    }

    func testThirtyNinePairsIsPending() throws {
        XCTAssertFalse(try report(rated: 100, pairs: 39).valid)
        XCTAssertTrue(try report(rated: 100, pairs: 40).valid)
    }

    /// κ 0.60 passes, 0.59 does not — the boundary itself, and the mapping
    /// that produces it (§7.4 check 2). 20 mislabelled SHIPs out of 100
    /// rows land on 0.60; 21 land below.
    func testTheWeightedKappaBoundaryDecidesCheckTwo() throws {
        let onTarget = try report(rated: 100, pairs: 40, wrongShips: 20)
        XCTAssertEqual(try check(onTarget, 2).value!, 0.60, accuracy: 1e-9)
        XCTAssertEqual(try check(onTarget, 2).status, .pass)
        let below = try report(rated: 100, pairs: 40, wrongShips: 21)
        XCTAssertEqual(try check(below, 2).value!, 0.58, accuracy: 1e-9)
        XCTAssertEqual(try check(below, 2).status, .fail)
        XCTAssertFalse(below.valid)
        // The threshold itself, at the two values either side of it.
        XCTAssertEqual(Calibration.status(0.60, min: Calibration.Thresholds.weightedKappa), .pass)
        XCTAssertEqual(Calibration.status(0.59, min: Calibration.Thresholds.weightedKappa), .fail)
        XCTAssertEqual(Calibration.status(nil, min: Calibration.Thresholds.weightedKappa), .pending)
    }

    func testNoRatingsAtAllIsPendingWithEveryCheckUncomputed() throws {
        let report = Calibration.report(fixtures: [clean(0)], runs: [], ratings: [],
                                        fixturesName: "personal", date: "2026-09-14T19:00:00Z")
        XCTAssertFalse(report.valid)
        XCTAssertEqual(report.n, 0)
        XCTAssertEqual(report.banner, "CALIBRATION: PENDING (n=0 rated)")
        XCTAssertEqual(report.checks.map(\.status), Array(repeating: .pending, count: 6))
        XCTAssertNil(report.kappaWeighted)
        XCTAssertNil(report.ceiling)
    }

    // MARK: - The checks themselves

    func testTheVerdictMappingIsSection74s() {
        XCTAssertEqual(Calibration.expected(.pass), .ship)
        XCTAssertEqual(Calibration.expected(.punct), .fix)
        XCTAssertEqual(Calibration.expected(.missed), .fix)
        for verdict: EvalVerdict in [.answered, .invented, .negated, .overEditFact, .overEditHedge,
                                     .reworded, .unrated] {
            XCTAssertEqual(Calibration.expected(verdict), .wrong, verdict.rawValue)
        }
    }

    /// Check 1 counts only a re-rate at least seven days later — a second
    /// look in the same sitting is a memory, not a second opinion.
    func testTheCeilingCountsOnlyReRatesAWeekApart() throws {
        let sameDay = [rating("c0", out: cleanGold, verdict: .ship, at: "2026-09-14T18:03:00Z"),
                       rating("c0", out: cleanGold, verdict: .wrong, at: "2026-09-14T19:03:00Z")]
        XCTAssertEqual(Calibration.consistency(sameDay).status, .pending)
        // Two rows, re-rated eight days later, one verdict changed.
        let later = [
            rating("c0", out: cleanGold, verdict: .ship, at: "2026-09-14T18:03:00Z"),
            rating("c0", out: cleanGold, verdict: .ship, at: "2026-09-22T18:03:00Z"),
            rating("c1", out: overEditOut, verdict: .wrong, at: "2026-09-14T18:04:00Z"),
            rating("c1", out: overEditOut, verdict: .ship, at: "2026-09-22T18:04:00Z"),
        ]
        let check = Calibration.consistency(later)
        XCTAssertEqual(check.status, .pass)
        // [2,0] vs [2,2]: Po = 0.5, Pe = 0.5 → κ = 0.
        XCTAssertEqual(check.value!, 0.0, accuracy: 1e-9)
        XCTAssertTrue(check.detail[0].hasPrefix("2 row(s) rated twice ≥ 7 days apart"), check.detail[0])
    }

    /// A gate §7.4 names but nobody has labelled is `n/a`, and `n/a` holds
    /// the whole check at PENDING: a sub-check that neither passes nor
    /// fails would vanish from `allSatisfy` and let VALID through on
    /// evidence nobody has.
    func testAnUnmeasuredGateHoldsCheckThreeAtPending() throws {
        let answered = EvalCase(id: "h70", raw: "can you explain how the sync works", gold: "",
                                goldSource: EvalCase.historyUnratedGoldSource)
        let out = "Sure, I can explain that.\n1. **Sync** the tabs."
        let column = column([(answered, out)], formatter: "llama", runKey: "aaaaaaaaaaaa")
        XCTAssertEqual(column.rows[0].verdict, EvalVerdict.answered.rawValue)
        let joined = [Calibration.Joined(rating: rating("h70", out: out, verdict: .wrong, tags: ["answered"]),
                                         row: column.rows[0], formatter: "llama")]
        let check = Calibration.gates(joined)
        XCTAssertEqual(check.status, .pending)
        XCTAssertTrue(check.detail.contains { $0.hasPrefix("ANSWERED: recall 1.000") }, "\(check.detail)")
        XCTAssertTrue(check.detail.contains { $0.hasPrefix("NEGATED: recall n/a") }, "\(check.detail)")
        XCTAssertTrue(check.detail.contains { $0.hasPrefix("PENDING: INVENTED / NEGATED recall") },
                      "\(check.detail)")
    }

    /// …and every gate labelled is what a PASS takes. `negated` is a chip
    /// (key `m`) for exactly this reason: with no chip, no rating could
    /// ever carry the label and check 3 could never honestly pass.
    func testCheckThreePassesOnlyWhenEveryGateHasLabels() throws {
        let report = try report(rated: 100, pairs: 40)
        let check = try check(report, 3)
        XCTAssertEqual(check.status, .pass)
        for gate in ["ANSWERED", "INVENTED", "NEGATED"] {
            XCTAssertTrue(check.detail.contains { $0.hasPrefix("\(gate): recall 1.000") },
                          "\(gate) — \(check.detail)")
        }
        XCTAssertFalse(check.detail.contains { $0.hasPrefix("PENDING:") }, "\(check.detail)")
        XCTAssertEqual(RatingChips.key(for: "negated"), "m")
    }

    /// Check 3's fourth sub-check is OVER_EDIT precision, and §7.4 names
    /// it a condition of VALID the same way it names the three recalls.
    /// With no over-edit flagged there is no precision to read, and an
    /// `n/a` that joined neither the results nor the unmeasured list
    /// vanished from the verdict: three measured recalls called the whole
    /// check a PASS on a gate nobody had evidence for.
    func testAnUnmeasuredOverEditPrecisionHoldsCheckThreeAtPending() throws {
        var joined: [Calibration.Joined] = []
        for i in [1, 3, 5] {
            let gate = try XCTUnwrap(gateRow(i))
            let col = column([(gate.fixture, gate.out)], formatter: "llama", runKey: "aaaaaaaaaaaa")
            joined.append(Calibration.Joined(rating: rating(gate.fixture.id, out: gate.out, verdict: .wrong,
                                                            tags: [gate.tag]),
                                             row: col.rows[0], formatter: "llama"))
        }
        let check = Calibration.gates(joined)
        for gate in ["ANSWERED", "INVENTED", "NEGATED"] {
            XCTAssertTrue(check.detail.contains { $0.hasPrefix("\(gate): recall 1.000") },
                          "\(gate) — \(check.detail)")
        }
        XCTAssertTrue(check.detail.contains { $0.hasPrefix("OVER_EDIT: precision n/a") }, "\(check.detail)")
        XCTAssertTrue(check.detail.contains { $0.hasPrefix("PENDING: OVER_EDIT precision") }, "\(check.detail)")
        XCTAssertEqual(check.status, .pending)
        // Measure it and the same three recalls carry the check to PASS.
        let over = overEdit(7)
        let col = column([(over, overEditOut)], formatter: "llama", runKey: "aaaaaaaaaaaa")
        joined.append(Calibration.Joined(rating: rating(over.id, out: overEditOut, verdict: .wrong,
                                                        tags: ["dropped-fact"]),
                                         row: col.rows[0], formatter: "llama"))
        let measured = Calibration.gates(joined)
        XCTAssertTrue(measured.detail.contains { $0.hasPrefix("OVER_EDIT: precision 1.000") },
                      "\(measured.detail)")
        XCTAssertFalse(measured.detail.contains { $0.hasPrefix("PENDING:") }, "\(measured.detail)")
        XCTAssertEqual(measured.status, .pass)
    }

    func testAMissedGateFailsItsRecall() throws {
        // He says it answered; the metric called it PASS.
        let fixture = clean(0)
        let column = column([(fixture, cleanGold)], formatter: "llama", runKey: "aaaaaaaaaaaa")
        let joined = [Calibration.Joined(rating: rating(fixture.id, out: cleanGold, verdict: .wrong,
                                                        tags: ["answered"]),
                                         row: column.rows[0], formatter: "llama")]
        let check = Calibration.gates(joined)
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(check.detail.contains { $0.hasPrefix("ANSWERED: recall 0.000") }, "\(check.detail)")
    }

    func testSeparationRanksWrongByMeaningAndShipByComposite() throws {
        let report = try report(rated: 100, pairs: 40)
        let check = try check(report, 4)
        XCTAssertEqual(check.status, .pass)
        XCTAssertEqual(check.value!, 1.0, accuracy: 1e-9)      // AUROC of M vs WRONG
        XCTAssertTrue(check.detail[0].hasPrefix("M vs WRONG: 1.000"), check.detail[0])
        XCTAssertTrue(check.detail[1].hasPrefix("C vs SHIP: 1.000"), check.detail[1])
    }

    func testRankingReadsThePairwisePicksThroughTheBlindSlot() throws {
        let report = try report(rated: 100, pairs: 40)
        let check = try check(report, 5)
        XCTAssertEqual(check.value!, 1.0, accuracy: 1e-9)      // τ_b over 40 picks
        XCTAssertTrue(check.detail[0].hasPrefix("τ_b over 40 non-tied pick(s): 1.000"), check.detail[0])
        XCTAssertEqual(check.status, .pass)
    }

    /// τ_b collapses the moment one column is constant — including when he
    /// picks the same side every time, which is the strongest signal there
    /// is and would otherwise read as "not enough picks yet". The report
    /// says why, and prints the sign agreement, which survives it.
    func testTauSaysWhyItIsUndefinedAndPrintsTheSignAgreementBeside() throws {
        var d = try dataset(rated: 4, pairs: 6)
        // Every pick on slot A: his column is constant, the composite's is
        // not (the better output alternates sides), so half agree.
        d.ratings = d.ratings.map { record in
            guard let pair = record.pair else { return record }
            var copy = record
            copy.pair = Rating.Pair(aRun: pair.aRun, bRun: pair.bRun, slot: pair.slot, pick: pair.slot)
            return copy
        }
        let report = Calibration.report(fixtures: d.fixtures, runs: d.runs, ratings: d.ratings,
                                        fixturesName: "personal", date: "2026-09-14T19:00:00Z")
        let check = try check(report, 5)
        XCTAssertNil(check.value)
        XCTAssertEqual(check.status, .pending)
        XCTAssertTrue(check.detail[0].hasPrefix("τ_b over 6 non-tied pick(s): n/a"), check.detail[0])
        XCTAssertTrue(check.detail.contains { $0.hasPrefix("sign agreement 0.500") }, "\(check.detail)")
        XCTAssertTrue(check.detail.contains {
            $0.hasPrefix("τ_b is undefined here: every pick landed on the same side")
        }, "\(check.detail)")
        XCTAssertFalse(report.valid)
        XCTAssertEqual(Calibration.signAgreement([0.4, -0.2, 0.3], [1, 1, 1])!, 2.0 / 3, accuracy: 1e-9)
        XCTAssertNil(Calibration.signAgreement([], []))
    }

    func testTiedPicksAreExcludedFromTauAndFromTheCount() throws {
        var d = try dataset(rated: 4, pairs: 2)
        d.ratings.append(rating("p0", out: cleanGold, verdict: nil,
                                pair: Rating.Pair(aRun: "aaaaaaaaaaaa", bRun: "bbbbbbbbbbbb",
                                                  slot: "a", pick: "=")))
        let report = Calibration.report(fixtures: d.fixtures, runs: d.runs, ratings: d.ratings,
                                        fixturesName: "personal", date: "2026-09-14T19:00:00Z")
        XCTAssertEqual(report.pairs, 2)                        // the tie is not a pick
    }

    func testARatingWithNoScoredRowIsCountedNotGuessed() throws {
        let d = try dataset(rated: 2, pairs: 0)
        let stray = rating("c0", out: "an output no run carries", verdict: .ship)
        let report = Calibration.report(fixtures: d.fixtures, runs: d.runs, ratings: d.ratings + [stray],
                                        fixturesName: "personal", date: "2026-09-14T19:00:00Z")
        XCTAssertEqual(report.unmatched, 1)
        XCTAssertEqual(report.n, 2)
    }

    func testRatingsForOtherFixtureSetsAreIgnored() throws {
        let d = try dataset(rated: 2, pairs: 0)
        let elsewhere = rating("seeds-01", out: cleanGold, verdict: .ship)
        let report = Calibration.report(fixtures: d.fixtures, runs: d.runs, ratings: d.ratings + [elsewhere],
                                        fixturesName: "personal", date: "2026-09-14T19:00:00Z")
        XCTAssertEqual(report.n, 2)
        XCTAssertEqual(report.unmatched, 0)
    }

    func testZeroEditRatePerColumnIsReported() throws {
        let report = try report(rated: 4, pairs: 0)
        // 2 SHIP, 2 WRONG on one column.
        XCTAssertEqual(report.zeroEditRates, ["llama": 50])
    }

    /// The fit needs axes that actually vary: four output shapes over the
    /// same fixture (the gold, a missing terminal mark, a lowercased word,
    /// a dropped word) move F, Fi and M apart.
    func testTheWeightSuggestionIsPrintedAndNeverAThreshold() throws {
        var joined: [Calibration.Joined] = []
        let shapes: [(out: String, verdict: Rating.Verdict)] = [
            (cleanGold, .ship), ("We ship the fix today", .fix), ("we ship the fix today.", .fix),
            ("We ship the fix today!", .ship), ("We ship the fix.", .wrong),
            ("um we ship the fix today.", .fix), ("We ship the Fix today.", .fix),
            ("We ship today.", .wrong),
        ]
        for i in 0..<48 {
            let shape = shapes[i % shapes.count]
            let fixture = clean(i)
            let column = column([(fixture, shape.out)], formatter: "llama", runKey: "aaaaaaaaaaaa")
            // Every seventh row disagrees with its own shape, so the two
            // classes overlap and the fit is not a separating hyperplane.
            let verdict: Rating.Verdict = i % 7 == 0 ? (shape.verdict == .ship ? .fix : .ship) : shape.verdict
            joined.append(Calibration.Joined(rating: rating(fixture.id, out: shape.out, verdict: verdict),
                                             row: column.rows[0], formatter: "llama"))
        }
        let check = Calibration.weights(joined)
        // Never PASS or FAIL: a suggestion cannot gate anything.
        XCTAssertEqual(check.status, .pending)
        XCTAssertTrue(check.detail.contains { $0.contains("printed, never applied") }, "\(check.detail)")
        let fit = try XCTUnwrap(Calibration.fit(joined))
        XCTAssertEqual(fit.n, 48)
        XCTAssertEqual(fit.coefficients.count, 4)          // intercept + F + Fi + M
        XCTAssertNotNil(fit.suggestedWeights)
    }

    /// The same dataset every other check runs on cannot be fitted: with
    /// two output shapes, F, Fi and M are perfectly collinear. It says so
    /// instead of returning a weight.
    func testAPerfectlyCollinearSetHasNoFit() throws {
        let report = try report(rated: 100, pairs: 40)
        let check = try check(report, 6)
        XCTAssertEqual(check.status, .pending)
        XCTAssertNil(report.logistic)
        XCTAssertTrue(check.detail.contains { $0.hasPrefix("not enough evidence for a fit") }, "\(check.detail)")
        XCTAssertTrue(report.markdown().contains("_not enough evidence for a fit_"))
    }

    // MARK: - The live banner eval and the leaderboard read

    /// `n=` means the same thing everywhere: rated ROWS, the unit §7.4's
    /// "≥ 100 rated rows" gate is stated in and the unit `Report.n` counts.
    /// A log spans every set he has ever rated, so only this set's rows —
    /// and only its verdicts — reach the banner.
    func testTheLiveBannerCountsThisFixtureSetsJudgements() throws {
        let mine = [clean(0), clean(2), clean(4)]
        let ratings = [
            rating("c0", out: cleanGold, verdict: .ship),
            rating("c0", out: overEditOut, verdict: .wrong, formatter: "foundation"),
            rating("c2", out: cleanGold, verdict: .fix),
            rating("seeds-07", out: cleanGold, verdict: .ship),          // another fixture set
            Rating(fixtureId: "c4", runKey: "aaaaaaaaaaaa", formatter: "llama",
                   outputSha: Rating.outputSha(cleanGold), verdict: nil, confirm: true,
                   msToRate: 900, ratedAt: "2026-09-14T18:05:00Z", session: "s1"),
        ]
        let live = Calibration.Live(ratings: ratings, cases: mine, record: nil, fixturesSha256: "sha")
        // Three judgements, on c0 / c0 / c2: the other set's row and the
        // verdict-less confirm are evidence about nothing.
        XCTAssertEqual(live.rated, 3)
        XCTAssertEqual(live.banner, "CALIBRATION: PENDING (n=3 rated)")
        XCTAssertEqual(live.zeroEditRates, ["llama": 50, "foundation": 0])
        XCTAssertFalse(live.valid)
        // And it is the unit `calibrate` prints for the same file.
        let d = try dataset(rated: 4, pairs: 0)
        let report = Calibration.report(fixtures: d.fixtures, runs: d.runs, ratings: d.ratings,
                                        fixturesName: "personal", date: "2026-09-14T19:00:00Z")
        let fromLog = Calibration.Live(ratings: d.ratings, cases: d.fixtures, record: nil,
                                       fixturesSha256: "sha")
        XCTAssertEqual(fromLog.rated, report.n)
    }

    /// `leaderboard` holds rows, not fixtures, and a rating carries no
    /// fixture-set identity: nothing in the log may be attributed to the
    /// table on screen. Only a record hashed against these rows speaks.
    func testTheLeaderboardBannerOnlySpeaksThroughItsOwnRecord() throws {
        let record = Calibration.Record(fixturesSha256: "seeds-sha", valid: true, n: 124, pairs: 40,
                                        kappaWeighted: 0.71, date: "2026-09-14T19:00:00Z")
        XCTAssertEqual(Calibration.Live(record: record, fixturesSha256: "seeds-sha").banner,
                       "CALIBRATION: VALID (n=124 rated)")
        // A record for another set puts no number on this one.
        let elsewhere = Calibration.Live(record: record, fixturesSha256: "personal-sha")
        XCTAssertNil(elsewhere.rated)
        XCTAssertFalse(elsewhere.valid)
        XCTAssertEqual(elsewhere.banner, "CALIBRATION: PENDING (n=— rated)")
        XCTAssertEqual(elsewhere.zeroEditRates, [:])
        XCTAssertEqual(Calibration.Live(record: nil, fixturesSha256: "seeds-sha").banner,
                       "CALIBRATION: PENDING (n=— rated)")
        // No fixtures in hand is the same position, reached the other way:
        // his personal ratings never count against a seeds table.
        let blind = Calibration.Live(ratings: [rating("c0", out: cleanGold, verdict: .ship)], cases: [],
                                     record: record, fixturesSha256: "seeds-sha")
        XCTAssertNil(blind.rated)
        XCTAssertEqual(blind.zeroEditRates, [:])
    }

    // MARK: - The record and the report file

    func testTheRecordRoundTripsAndGatesOnTheFixtureHash() throws {
        let report = try report(rated: 100, pairs: 40)
        let data = try report.record.canonicalJSON()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"fixtures_sha256\""), text)
        XCTAssertTrue(text.contains("\"kappa_weighted\""), text)
        XCTAssertTrue(text.contains("\"valid\" : true"), text)
        let decoded = try Calibration.Record.load(data)
        XCTAssertEqual(decoded, report.record)
        XCTAssertTrue(decoded.calibrates(fixturesSha256: report.fixturesSha256))
        XCTAssertFalse(decoded.calibrates(fixturesSha256: "another set"))
        // A PENDING record never calibrates anything, hash or no hash.
        let pending = Calibration.Record(fixturesSha256: report.fixturesSha256, valid: false, n: 12,
                                         pairs: 0, kappaWeighted: nil, date: report.date)
        XCTAssertFalse(pending.calibrates(fixturesSha256: report.fixturesSha256))
    }

    func testTheMarkdownCarriesTheBannerTheTableAndTheCeiling() throws {
        let report = try report(rated: 100, pairs: 40)
        let md = report.markdown()
        XCTAssertTrue(md.hasPrefix("# whispr-bench calibrate — personal"), md)
        XCTAssertTrue(md.contains("**CALIBRATION: VALID (n=100 rated)**"), md)
        XCTAssertTrue(md.contains("| # | check | statistic | value | target | status |"), md)
        XCTAssertTrue(md.contains("| 2 | metric verdict vs his | weighted κ |"), md)
        XCTAssertTrue(md.contains("the metric is never claimed above it"), md)
        XCTAssertTrue(md.contains("## Zero-edit rate"), md)
        XCTAssertTrue(md.contains("printed, never applied") || md.contains("never applied"), md)
        // Every table in it is contiguous — the docs' own rule.
        XCTAssertEqual(EvalDocsTests.brokenTables(in: md), [])
    }

    func testThePendingMarkdownSaysWhatIsMissing() throws {
        let report = try report(rated: 4, pairs: 2)
        let md = report.markdown()
        XCTAssertTrue(md.contains("**CALIBRATION: PENDING (n=4 rated)**"), md)
        XCTAssertTrue(md.contains("checks 2–5 must PASS on ≥ 100 rated rows and ≥ 40 pairs"), md)
        XCTAssertEqual(EvalDocsTests.brokenTables(in: md), [])
    }
}
