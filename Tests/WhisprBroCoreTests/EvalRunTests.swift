import XCTest
@testable import WhisprBroCore

/// Pins for the run record (plan §5, §6.2): the macro aggregates, the
/// status ladder with every gate condition from both sides, nearest-rank
/// latency percentiles with the re-prime exclusion, the rated / draft /
/// unrated split (D1), the canonical JSON contract (sorted keys,
/// byte-identical modulo `date`, snake_case names), `run_key` stability
/// and the leaderboard projection. Numbers are hand-counted in comments.
final class EvalRunTests: XCTestCase {
    private func obs(_ c: EvalCase, _ out: String, source: FormatterSource? = nil, ms: Int? = nil,
                     reprime: Bool = false, rejected: String? = nil) -> EvalRun.Observation {
        EvalRun.Observation(fixture: c, stripped: c.raw, out: out, source: source, ms: ms, reprime: reprime,
                            rejected: rejected, score: QualityScore.score(c, out: out),
                            modelScore: rejected.map { QualityScore.score(c, out: $0) })
    }

    private func column(_ observations: [EvalRun.Observation], formatter: String = "rules",
                        budgetMs: Int = 700) -> EvalRun.Column {
        EvalRun.Column.make(formatter: formatter, level: "standard", config: EvalRun.Config(budgetMs: budgetMs),
                            runKey: "0123456789ab", observations: observations)
    }

    private func run(_ columns: [EvalRun.Column], cases: [EvalCase] = EvalCase.seeds,
                     date: String = "2026-09-14T18:02:00Z") throws -> EvalRun {
        EvalRun(runId: "2026-09-14T180200-36ff03b-seeds", date: date, gitSha: "36ff03b", dirty: false,
                machine: EvalRun.Machine(model: "Mac14,12", os: "26.5.1"),
                fixtures: try EvalRun.Fixtures(path: "seeds", name: "seeds", cases: cases), columns: columns)
    }

    private var goldCopy: [EvalRun.Observation] { EvalCase.seeds.map { obs($0, $0.gold) } }

    /// 150 spoken words: fifteen copies of a ten-word sentence.
    private let long = EvalCase(
        id: "long-150",
        raw: Array(repeating: "we ship the fix today and then test it tomorrow", count: 15).joined(separator: " "),
        gold: Array(repeating: "We ship the fix today and then test it tomorrow.", count: 15).joined(separator: " "),
        tags: ["long"])
    private let short = EvalCase(id: "short-5", raw: "we ship the fix today", gold: "We ship the fix today.", tags: ["short"])

    // MARK: - Versions and fixture split

    func testSchemaAndScoringVersionArePinned() throws {
        XCTAssertEqual(EvalRun.schema, 3)
        XCTAssertEqual(EvalRun.scoringVersion, 4)
        let r = try run([column(goldCopy)])
        XCTAssertEqual(r.schema, 3)
        XCTAssertEqual(r.scoringVersion, 4)
    }

    func testFixturesCountRatedDraftAndUnrated() throws {
        let cases = [
            EvalCase(id: "a", raw: "um hi", gold: "Hi."),
            EvalCase(id: "b", raw: "um hi", gold: "Hi.", goldSource: "draft:claude", annotationsStatus: .draft),
            EvalCase(id: "c", raw: "um hi", gold: "", goldSource: "history-unrated"),
            // A draft with no gold is unrated, not a draft gold.
            EvalCase(id: "d", raw: "um hi", gold: "", goldSource: "history-unrated", annotationsStatus: .draft),
        ]
        let f = try EvalRun.Fixtures(path: "p.json", name: "personal", cases: cases)
        XCTAssertEqual([f.n, f.ratedN, f.draftN, f.unratedN], [4, 1, 1, 2])
        XCTAssertEqual(f.sha256, try EvalCase.fixtureSetHash(cases))
        // The all-filler seed's empty gold is a RATED gold (`gold_source`
        // "seed"), so every seed counts as rated.
        let seeds = try EvalRun.Fixtures(path: "seeds", name: "seeds", cases: EvalCase.seeds)
        XCTAssertEqual([seeds.n, seeds.ratedN, seeds.draftN, seeds.unratedN], [81, 81, 0, 0])
    }

    // MARK: - Aggregates (macro)

    func testGoldCopyColumnAggregates() {
        let col = column(goldCopy)
        XCTAssertEqual(col.scores, EvalRun.Scores(f: 100, fi: 100, m: 100, c: 100))
        XCTAssertEqual(col.micro, EvalRun.Micro(wer: 0, punctF1: 1, caseAccuracy: 1))
        XCTAssertEqual(col.verdicts["PASS"], 81)
        XCTAssertEqual(col.verdicts.count, 10)
        XCTAssertEqual(col.verdicts.values.reduce(0, +), 81)
        XCTAssertEqual(Set(col.verdicts.keys), Set(EvalVerdict.allCases.map(\.rawValue)))
        XCTAssertEqual(col.gate.status, .pass)
        // 49 controls (SeedFixtureTests hand-counts them), all unchanged.
        XCTAssertEqual(col.gate.controls, 49)
        XCTAssertEqual(col.gate.controlsUnchanged, 49)
        XCTAssertEqual(col.gate.controlsUnchangedPct, 100)
        XCTAssertNil(col.latencyMs)
        XCTAssertEqual(col.fallbacks, EvalRun.Fallbacks())
        // Every seed is tagged; controls carry no filler so their Fi is nil.
        XCTAssertEqual(col.byTag["agent-prompt"], EvalRun.TagScores(c: 100, f: 100, fi: 100, m: 100, n: 59))
        XCTAssertEqual(col.byTag["control"], EvalRun.TagScores(c: 100, f: 100, fi: nil, m: 100, n: 49))
        XCTAssertEqual(col.byTag["hedge"]?.n, 5)
        XCTAssertEqual(col.rows.count, 81)
        XCTAssertEqual(col.rows.map(\.id), EvalCase.seeds.map(\.id))
        XCTAssertEqual(col.rows[0].source, "rules")
        XCTAssertEqual(col.rows[0].c, 100)
        XCTAssertNil(col.rows[0].ms)
    }

    func testMacroMeanWeighsEveryFixtureOnce() {
        // 80 seeds at 100 and one deleteAll at 0 → 8000/81 = 98.8.
        var observations = goldCopy
        observations[0] = obs(EvalCase.seeds[0], "")
        let col = column(observations)
        XCTAssertEqual(col.scores.c, 98.8)
        XCTAssertEqual(col.verdicts["OVER_EDIT_FACT"], 1)
        XCTAssertEqual(col.verdicts["PASS"], 80)
    }

    func testFiMeanIncludesGoldFreeRowsAndSkipsUndefined() {
        // 24 seeds define Fi (hand-counted in ReferenceFormatterTests),
        // all 100 under goldCopy; a gold-free "Uh" → "" adds a 25th 100; a
        // gold-free row with no fillers adds nothing.
        let uh = EvalCase(id: "uh", raw: "Uh", gold: "", goldSource: "history-unrated")
        let plain = EvalCase(id: "plain", raw: "ship it", gold: "", goldSource: "history-unrated")
        let col = column(goldCopy + [obs(uh, ""), obs(plain, "Ship it.")])
        XCTAssertEqual(col.scores.fi, 100)
        XCTAssertEqual(col.rows.filter { $0.fi != nil }.count, 25)
        // The gold-free rows carry no F / M / C and read UNRATED.
        XCTAssertEqual(col.verdicts["UNRATED"], 2)
        XCTAssertNil(col.rows.last?.c)
        // A missed removal pulls the mean: 24 × 100 + 0 → 2400/25 = 96.
        let kept = column(goldCopy + [obs(uh, "Uh.")])
        XCTAssertEqual(kept.scores.fi, 96)
    }

    func testNoGoldScoredRowsLeavesScoresNil() {
        let personal = (1...3).map { EvalCase(id: "h\($0)", raw: "ship it now please", gold: "", goldSource: "history-unrated") }
        let col = column(personal.map { obs($0, "Ship it now, please.") }, formatter: "shipped")
        XCTAssertEqual(col.scores, EvalRun.Scores(f: nil, fi: nil, m: nil, c: nil))
        XCTAssertNil(col.micro)
        XCTAssertEqual(col.verdicts["UNRATED"], 3)
        XCTAssertEqual(col.gate.status, .pass)
        XCTAssertNil(col.gate.controlsUnchangedPct)
        XCTAssertEqual(col.rows[0].source, "shipped")
    }

    func testByTagMeans() {
        // "long" (1 fixture, C 100) and "short" (1 fixture, deleteAll → 0);
        // a fixture with both tags at 100 joins each.
        let both = EvalCase(id: "both", raw: "ship it now", gold: "Ship it now.", tags: ["long", "short"])
        let col = column([obs(long, long.gold), obs(short, ""), obs(both, both.gold)])
        XCTAssertEqual(col.byTag["long"], EvalRun.TagScores(c: 100, f: 100, fi: nil, m: 100, n: 2))
        XCTAssertEqual(col.byTag["short"], EvalRun.TagScores(c: 50, f: 50, fi: nil, m: 50, n: 2))
    }

    func testReorderingObservationsLeavesAggregatesUnchanged() {
        var observations = goldCopy
        observations[3] = obs(EvalCase.seeds[3], "")
        observations[8] = obs(EvalCase.seeds[8], EvalCase.seeds[8].raw)
        let a = column(observations)
        let b = column(observations.reversed())
        XCTAssertEqual(a.scores, b.scores)
        XCTAssertEqual(a.micro, b.micro)
        XCTAssertEqual(a.gate, b.gate)
        XCTAssertEqual(a.verdicts, b.verdicts)
        XCTAssertEqual(a.byTag, b.byTag)
        XCTAssertEqual(a.rows.map(\.id), b.rows.map(\.id).reversed())
    }

    func testMacroCompositeVersusMicroWer() {
        // Sixteen 5-word fixtures and one 150-word fixture. Emptying the
        // long one or one short one costs the SAME macro C (one fixture of
        // 17 → 1600/17 = 94.1) while the micro WER weighs by words: 150 of
        // 230 gold words (0.652) vs 5 of 230 (0.022).
        let shorts = (1...16).map { EvalCase(id: "s\($0)", raw: short.raw, gold: short.gold) }
        let longBad = column(shorts.map { obs($0, $0.gold) } + [obs(long, "")])
        let shortBad = column([obs(shorts[0], "")] + shorts.dropFirst().map { obs($0, $0.gold) } + [obs(long, long.gold)])
        XCTAssertEqual(longBad.scores.c, 94.1)
        XCTAssertEqual(shortBad.scores.c, 94.1)
        XCTAssertEqual(longBad.micro?.wer, 0.652)
        XCTAssertEqual(shortBad.micro?.wer, 0.022)
        XCTAssertEqual(long.wordCount, 150)
    }

    // MARK: - Status ladder (§5)

    func testInvalidWhenAnyRowFellBackToRulesByFailure() {
        for reason in [FormatterFallbackReason.unavailable, .requestFailed] {
            var observations = goldCopy
            observations[0] = obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .fallback(reason), ms: 5)
            let col = column(observations, formatter: "llama")
            XCTAssertEqual(col.gate.status, .invalid, reason.rawValue)
            XCTAssertEqual(col.fallbacks.harnessFailures, 1)
        }
        // Designed and real-behaviour fallbacks do not invalidate.
        for reason in [FormatterFallbackReason.fastPath, .rawMode, .timedOut, .implausible] {
            var observations = goldCopy
            observations[0] = obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .fallback(reason), ms: 5)
            XCTAssertEqual(column(observations, formatter: "llama").gate.status, .pass, reason.rawValue)
        }
        let f = EvalRun.Fallbacks(sources: [.model, .fallback(.fastPath), .fallback(.fastPath), .fallback(.rawMode),
                                            .fallback(.timedOut), .fallback(.implausible), .fallback(.unavailable),
                                            .fallback(.requestFailed), nil])
        XCTAssertEqual([f.fastPath, f.rawMode, f.timedOut, f.rejected, f.unavailable, f.requestFailed], [2, 1, 1, 1, 1, 1])
    }

    func testInvalidOutranksFailOutranksWarn() {
        var observations = goldCopy
        observations[0] = obs(EvalCase.seeds[0], "Sure, here's that:\n1. **" + EvalCase.seeds[0].raw,
                              source: .fallback(.unavailable), ms: 5000)
        XCTAssertEqual(column(observations, formatter: "llama").gate.status, .invalid)
        observations[0] = obs(EvalCase.seeds[0], "Sure, here's that:\n1. **" + EvalCase.seeds[0].raw,
                              source: .model, ms: 5000)
        let fail = column(observations, formatter: "llama")
        XCTAssertEqual(fail.gate.status, .fail)
        XCTAssertTrue(fail.gate.latencyOverBudget)
        XCTAssertEqual(fail.gate.answered, 1)
    }

    func testFailOnEachGatedVerdictClass() {
        let c = EvalCase(id: "x", raw: "do not push the fix to main today", gold: "Do not push the fix to main today.")
        XCTAssertEqual(column(goldCopy + [obs(c, "Push the fix to main today.")]).gate.negated, 1)
        XCTAssertEqual(column(goldCopy + [obs(c, "Push the fix to main today.")]).gate.status, .fail)
        XCTAssertEqual(column(goldCopy + [obs(c, "Do not push the fix to main today. 140 units.")]).gate.invented, 1)
        XCTAssertEqual(column(goldCopy + [obs(c, "Do not push the fix to main today. 140 units.")]).gate.status, .fail)
    }

    func testOverEditFactShareGateIsStrictlyAboveFivePercent() {
        // 4 of 81 gold-scored = 4.9% → not > 5% → PASS; 5 of 81 = 6.2% →
        // FAIL. The emptied seeds all have ≥ 6 raw words, so each empty
        // output is a length collapse.
        func emptied(_ ids: [String]) -> [EvalRun.Observation] {
            goldCopy.map { ids.contains($0.fixture.id) ? obs($0.fixture, "") : $0 }
        }
        let four = column(emptied(["correct-time", "bench-quarterly", "bench-code", "bench-meeting"]))
        XCTAssertEqual(four.gate.overEditFact, 4)
        XCTAssertEqual(four.gate.status, .pass)
        let five = column(emptied(["correct-time", "bench-quarterly", "bench-code", "bench-meeting", "bench-standup"]))
        XCTAssertEqual(five.gate.overEditFact, 5)
        XCTAssertEqual(five.gate.status, .fail)
        // A gold-free collapse is counted in the histogram but not in the
        // share (it has no gold to over-edit against).
        let unrated = EvalCase(id: "h", raw: "ship the fix to prod now please", gold: "", goldSource: "history-unrated")
        let withUnrated = column(goldCopy + [obs(unrated, "")])
        XCTAssertEqual(withUnrated.verdicts["OVER_EDIT_FACT"], 1)
        XCTAssertEqual(withUnrated.gate.overEditFact, 0)
        XCTAssertEqual(withUnrated.gate.status, .pass)
    }

    func testControlsUnchangedGate() {
        // 49 seed controls; two reworded → 47/49 = 95.9% → PASS, three →
        // 46/49 = 93.9% < 95% → FAIL. Reordering a control's words is
        // REWORDED, never gated, so this is the only reason the run fails.
        let reworded: [String: String] = [
            "cue-is-content": "I enjoyed actually the movie.",
            "punct-02": "Can you check if the build Fleetwing passed on the release branch before I start the deploy?",
            "latency-010": "Please add a retry to the client Lumabase for timeouts.",
        ]
        func rewording(_ ids: [String]) -> EvalRun.Column {
            column(goldCopy.map { ids.contains($0.fixture.id) ? obs($0.fixture, reworded[$0.fixture.id]!) : $0 })
        }
        let three = rewording(Array(reworded.keys))
        XCTAssertEqual(three.gate.controls, 49)
        XCTAssertEqual(three.gate.controlsUnchanged, 46)
        XCTAssertEqual(three.gate.controlsUnchangedPct, 93.9)
        XCTAssertEqual(three.gate.answered + three.gate.invented + three.gate.negated + three.gate.overEditFact, 0)
        XCTAssertEqual(three.verdicts["REWORDED"], 3)
        XCTAssertEqual(three.gate.status, .fail)
        let two = rewording(["cue-is-content", "punct-02"])
        XCTAssertEqual(two.gate.controlsUnchangedPct, 95.9)
        XCTAssertEqual(two.gate.status, .pass)
        // Punctuation and casing on a control are not word edits.
        var punct = goldCopy
        let cue = EvalCase.seeds.first { $0.id == "cue-is-content" }!
        punct[EvalCase.seeds.firstIndex(of: cue)!] = obs(cue, "i actually enjoyed the movie")
        XCTAssertEqual(column(punct).gate.controlsUnchanged, 49)
        XCTAssertEqual(column(punct).gate.status, .pass)
    }

    func testLatencyWarnReadsOnlyShortRows() {
        // Every ≤ 60-word row under budget but the 150-word row over it:
        // the headline p99 is over budget, the gate's p99 (≤ 60 words) is
        // not → PASS. A short row over budget → WARN.
        let base = goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 400) }
        let longSlow = column(base + [obs(long, long.gold, source: .model, ms: 1400)], formatter: "llama")
        XCTAssertEqual(longSlow.latencyMs?.p99, 1400)
        XCTAssertEqual(longSlow.latencyMs?.p99Short, 400)
        XCTAssertEqual(longSlow.latencyMs?.overBudget, 1)
        XCTAssertFalse(longSlow.gate.latencyOverBudget)
        XCTAssertEqual(longSlow.gate.status, .pass)
        var shortSlow = base
        shortSlow[2] = obs(EvalCase.seeds[2], EvalCase.seeds[2].gold, source: .model, ms: 900)
        let warn = column(shortSlow, formatter: "llama")
        XCTAssertTrue(warn.gate.latencyOverBudget)
        XCTAssertEqual(warn.gate.status, .warn)
        // Budget is the config's: at 1000 ms the same column passes.
        XCTAssertEqual(column(shortSlow, formatter: "llama", budgetMs: 1000).gate.status, .pass)
    }

    func testExitCodes() {
        XCTAssertEqual(EvalRun.Status.pass.exitCode(strictLatency: false), 0)
        XCTAssertEqual(EvalRun.Status.warn.exitCode(strictLatency: false), 0)
        XCTAssertEqual(EvalRun.Status.warn.exitCode(strictLatency: true), 3)
        XCTAssertEqual(EvalRun.Status.invalid.exitCode(strictLatency: false), 1)
        XCTAssertEqual(EvalRun.Status.fail.exitCode(strictLatency: true), 2)
        XCTAssertEqual(EvalRun.Status.allCases, [.invalid, .fail, .warn, .pass])
        XCTAssertTrue(EvalRun.Status.invalid.isWorse(than: .fail))
        XCTAssertTrue(EvalRun.Status.fail.isWorse(than: .warn))
        XCTAssertTrue(EvalRun.Status.warn.isWorse(than: .pass))
    }

    func testRunStatusIsTheWorstColumn() throws {
        // One answered row fails a column outright (one collapse among 81
        // is 1.2%, under the OVER_EDIT_FACT share).
        var bad = goldCopy
        bad[0] = obs(EvalCase.seeds[0], "Sure, here's that:\n1. **" + EvalCase.seeds[0].raw)
        let r = try run([column(goldCopy), column(bad, formatter: "llama")])
        XCTAssertEqual(r.columns.map(\.status), [.pass, .fail])
        XCTAssertEqual(r.status, .fail)
        XCTAssertEqual(try run([]).status, .pass)
    }

    // MARK: - Latency percentiles

    func testNearestRankPercentilesAndBuckets() {
        // ms 100…1000 on ten ≤ 15-word rows: p50 = rank ceil(5) → 500, p90 →
        // 900, p99 → 1000, max 1000, over 700 → 3, ms/word = 5500/100 = 55.
        // An eleventh row is a re-prime: listed, excluded from every number
        // — n_llm included, so `over_budget / n_llm` and the terminal's
        // "3/10" are the same fraction.
        let samples = (1...10).map { (ms: $0 * 100, words: 10, reprime: false) } + [(ms: 3000, words: 10, reprime: true)]
        let l = EvalRun.Latency(samples: samples, budget: 700)
        XCTAssertEqual([l.nLlm, l.p50, l.p90, l.p99, l.max, l.overBudget], [10, 500, 900, 1000, 1000, 3])
        XCTAssertEqual(l.p99Short, 1000)
        XCTAssertEqual(l.msPerWord, 55)
        XCTAssertEqual(l.reprimeMs, [3000])
        XCTAssertEqual(l.byLength, ["<=15": EvalRun.Latency.Bucket(n: 10, p50: 500, p99: 1000)])
        // Every timed row a re-prime: no percentile, not a zero.
        let empty = EvalRun.Latency(samples: [(ms: 900, words: 10, reprime: true)], budget: 700)
        XCTAssertEqual(empty.nLlm, 0)
        XCTAssertNil(empty.p50); XCTAssertNil(empty.p90); XCTAssertNil(empty.p99); XCTAssertNil(empty.max)
        XCTAssertNil(empty.p99Short)
        XCTAssertNil(empty.msPerWord)
        XCTAssertEqual(empty.overBudget, 0)
        XCTAssertEqual(empty.reprimeMs, [900])
        XCTAssertEqual(empty.byLength, [:])
        XCTAssertEqual(EvalRun.Latency.percentile([], 0.5), 0)
        XCTAssertEqual(EvalRun.Latency.percentile([7], 0.99), 7)
        XCTAssertEqual(EvalRun.Latency.percentile([3, 1, 2], 0.5), 2)
        for (words, key) in [(15, "<=15"), (16, "16-60"), (60, "16-60"), (61, "61-150"), (150, "61-150"), (151, ">150")] {
            XCTAssertEqual(EvalRun.Latency.bucket(words: words), key)
        }
        // Long rows are excluded from p99_le60; with none short it is nil.
        let onlyLong = EvalRun.Latency(samples: [(ms: 1400, words: 100, reprime: false)], budget: 700)
        XCTAssertNil(onlyLong.p99Short)
        XCTAssertEqual(onlyLong.byLength.keys.sorted(), ["61-150"])
        XCTAssertEqual(onlyLong.msPerWord, 14)
    }

    func testLatencyRowsAreModelPathOnly() {
        // fast-path and raw-mode rows carry no model latency; timed-out
        // and rejected rows do (the model ran). Untimed rows never count.
        let s = EvalCase.seeds
        let col = column([
            obs(s[0], s[0].gold, source: .model, ms: 400),
            obs(s[1], s[1].gold, source: .fallback(.fastPath), ms: 3),
            obs(s[2], s[2].gold, source: .fallback(.rawMode), ms: 3),
            obs(s[3], s[3].gold, source: .fallback(.timedOut), ms: 3100),
            obs(s[4], s[4].gold, source: .fallback(.implausible), ms: 600, rejected: "Sure, here's that."),
            obs(s[5], s[5].gold, source: .model),
        ], formatter: "foundation")
        XCTAssertEqual(col.latencyMs?.nLlm, 3)
        XCTAssertEqual(col.latencyMs?.max, 3100)
        XCTAssertEqual(col.rows.map(\.source), ["model", "fast-path", "raw-mode", "timed-out", "implausible", "model"])
        XCTAssertEqual(col.rows.map(\.wouldTimeout3s), [false, false, false, true, false, false])
        XCTAssertEqual(col.rows[4].modelVerdict, "ANSWERED")
        XCTAssertEqual(col.rows[4].rejected, "Sure, here's that.")
        XCTAssertEqual(col.rows[4].verdict, "PASS")
        XCTAssertEqual(col.fallbacks.rejected, 1)
        // The timed-out row is real behaviour: 3100 ms on a short fixture
        // is the column's p99 and trips the latency WARN.
        XCTAssertEqual(col.latencyMs?.p99Short, 3100)
        XCTAssertTrue(col.gate.latencyOverBudget)
        XCTAssertEqual(col.gate.status, .warn)
    }

    func testTimedRowsWithoutProvenanceCarryNoModelLatency() {
        // A rules column whose loop records elapsed ms (source nil): no
        // latency block, no WARN — a stage with no model has no model
        // latency. The shipped column passes `.model` for the rows its
        // production stage ran the model on, and those DO count.
        let rules = column(goldCopy.map { obs($0.fixture, $0.out, ms: 5000) })
        XCTAssertNil(rules.latencyMs)
        XCTAssertFalse(rules.gate.latencyOverBudget)
        XCTAssertEqual(rules.gate.status, .pass)
        XCTAssertEqual(rules.rows[0].ms, 5000)   // still on the row
        XCTAssertEqual(rules.rows[0].source, "rules")
        let shipped = column(goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 5000) }, formatter: "shipped")
        XCTAssertEqual(shipped.latencyMs?.nLlm, 81)
        XCTAssertEqual(shipped.gate.status, .warn)
        // The plan's re-prime mark is a live-model matter: the shipped
        // column's `observed_ms` was measured by the production binary
        // (no engine to re-prime), so its first row of a group stays in
        // the percentiles and the row itself drops the mark; a llama
        // column honours it.
        XCTAssertEqual(EvalRun.liveModelFormatters, ["llama", "foundation"])
        XCTAssertTrue(EvalRun.reprimeApplies(formatter: "llama"))
        XCTAssertTrue(EvalRun.reprimeApplies(formatter: "foundation"))
        XCTAssertFalse(EvalRun.reprimeApplies(formatter: "shipped"))
        XCTAssertFalse(EvalRun.reprimeApplies(formatter: "rules"))
        var marked = goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 400) }
        marked[0] = obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .model, ms: 2454, reprime: true)
        let shippedMarked = column(marked, formatter: "shipped")
        XCTAssertEqual(shippedMarked.latencyMs?.nLlm, 81)
        XCTAssertEqual(shippedMarked.latencyMs?.max, 2454)
        XCTAssertEqual(shippedMarked.latencyMs?.reprimeMs, [])
        XCTAssertFalse(shippedMarked.rows[0].reprime)
        let llamaMarked = column(marked, formatter: "llama")
        XCTAssertEqual(llamaMarked.latencyMs?.nLlm, 80)
        XCTAssertEqual(llamaMarked.latencyMs?.max, 400)
        XCTAssertEqual(llamaMarked.latencyMs?.reprimeMs, [2454])
        XCTAssertTrue(llamaMarked.rows[0].reprime)
        // A one-row model column whose row is its group's first: no
        // percentile at all, and the latency gate cannot fire off nothing.
        let lone = column([obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .model, ms: 900, reprime: true)],
                          formatter: "llama")
        XCTAssertEqual(lone.latencyMs?.nLlm, 0)
        XCTAssertNil(lone.latencyMs?.p99)
        XCTAssertFalse(lone.gate.latencyOverBudget)
        XCTAssertEqual(lone.gate.status, .pass)
    }

    func testRowsCarryLostBesideTheAlignmentsD() {
        // §4.4's D counts a `.sub` whose gold word is gone and whose
        // replacement is not novel: gold "Meet on Wednesday." out "Meet on
        // Tuesday." is D 0 on the alignment and lost 1 for M — the row
        // carries both, so an OVER_EDIT_HEDGE beside `D 0` explains itself.
        let repair = EvalCase(id: "r", raw: "meet on Tuesday, I mean on Wednesday", gold: "Meet on Wednesday.",
                              repairs: [EvalCase.Repair(reparandum: "on Tuesday, I mean", repair: "on Wednesday")])
        let row = column([obs(repair, "Meet on Tuesday.")]).rows[0]
        XCTAssertEqual(row.verdict, "OVER_EDIT_HEDGE")
        XCTAssertEqual([row.dels, row.lost], [0, 1])
        XCTAssertEqual(column([obs(repair, repair.gold)]).rows[0].lost, 0)
        // A plain deletion is both.
        let dropped = column([obs(EvalCase.seeds[0], "")]).rows[0]
        XCTAssertEqual(dropped.lost, dropped.dels)
        XCTAssertGreaterThan(dropped.dels, 0)
        // Gold-free rows have no gold to lose.
        let free = EvalCase(id: "h", raw: "ship it today", gold: "", goldSource: "history-unrated")
        XCTAssertNil(column([obs(free, "Ship it.")]).rows[0].lost)
        // The seeds' three ASR-slip fixtures under a slip-keeping echo are
        // the shape that prompted the field: lost 1, D 0 on every one.
        for id in ["asr-slip-01", "asr-slip-02", "asr-slip-03"] {
            let c = EvalCase.seeds.first { $0.id == id }!
            let echoed = column([obs(c, TextFormatter.ruleBasedCleanup(c.raw))]).rows[0]
            XCTAssertEqual(echoed.verdict, "OVER_EDIT_HEDGE", id)
            XCTAssertEqual([echoed.dels, echoed.lost], [0, 1], id)
        }
        // Mixed: only the two model rows are sampled.
        let s = EvalCase.seeds
        let mixed = column([obs(s[0], s[0].gold, ms: 9000), obs(s[1], s[1].gold, source: .model, ms: 400),
                            obs(s[2], s[2].gold, source: .fallback(.fastPath), ms: 3),
                            obs(s[3], s[3].gold, source: .model, ms: 500)], formatter: "shipped")
        XCTAssertEqual(mixed.latencyMs?.nLlm, 2)
        XCTAssertEqual(mixed.latencyMs?.max, 500)
        XCTAssertEqual(mixed.gate.status, .pass)
    }

    // MARK: - JSON contract

    func testCanonicalJSONRoundTripsAndIsByteIdenticalModuloDate() throws {
        var observations = goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 410) }
        observations[1] = obs(EvalCase.seeds[1], "", source: .fallback(.timedOut), ms: 3100, reprime: true)
        let r1 = try run([column(goldCopy), column(observations, formatter: "llama")])
        let bytes1 = try r1.canonicalJSON()
        // Decodes to an equal record, and re-encodes to the same bytes.
        let decoded = try EvalRun.load(bytes1)
        XCTAssertEqual(decoded, r1)
        XCTAssertEqual(try decoded.canonicalJSON(), bytes1)
        XCTAssertEqual(try r1.canonicalJSON(), bytes1)
        // Pretty output decodes to the same record.
        XCTAssertEqual(try EvalRun.load(try r1.canonicalJSON(pretty: true)), r1)
        // The same scoring on another day differs in `date` and nothing else.
        let r2 = try run([column(goldCopy), column(observations, formatter: "llama")], date: "2026-09-15T00:00:00Z")
        let text1 = String(decoding: bytes1, as: UTF8.self)
        let text2 = String(decoding: try r2.canonicalJSON(), as: UTF8.self)
        XCTAssertNotEqual(text1, text2)
        XCTAssertEqual(text2.replacingOccurrences(of: #""date":"2026-09-15T00:00:00Z""#,
                                                  with: #""date":"2026-09-14T18:02:00Z""#), text1)
    }

    func testJSONKeysArePinned() throws {
        var observations = goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 410) }
        observations[4] = obs(EvalCase.seeds[4], EvalCase.seeds[4].gold, source: .fallback(.implausible), ms: 600,
                              rejected: "Sure.")
        let col = EvalRun.Column.make(formatter: "llama", modelKey: "qwen2.5-1.5b", modelSha256: "m", promptSha256: "p",
                                      level: "standard", config: EvalRun.Config(), runKey: "0123456789ab",
                                      observations: observations)
        let text = String(decoding: try run([col]).canonicalJSON(), as: UTF8.self)
        for key in ["schema", "run_id", "date", "git_sha", "dirty", "machine", "scoring_version", "fixtures",
                    "rated_n", "draft_n", "unrated_n", "sha256", "columns", "formatter", "model_key", "level",
                    "config", "timeout_ms", "budget_ms", "run_key", "scores", "micro", "wer", "punct_f1", "case",
                    "gate", "status", "answered", "invented", "negated", "over_edit_fact", "controls_unchanged_pct",
                    "latency_over_budget", "verdicts", "fallbacks", "fastPath", "tooLong", "rawMode", "timedOut", "rejected",
                    "unavailable", "requestFailed", "latency_ms", "n_llm", "p50", "p90", "p99", "p99_le60", "max",
                    "budget", "over_budget", "ms_per_word", "reprime_ms", "by_length", "by_tag", "rows", "id",
                    "stripped", "out", "source", "ms", "would_timeout_3s", "reprime", "verdict", "triggers",
                    "lost", "novel", "novel_numerals", "dropped_content", "ratio", "missed_must_keep",
                    "unresolved_repairs", "c_initial", "gold_index", "model_verdict"] {
            XCTAssertTrue(text.contains("\"\(key)\":"), key)
        }
        for axis in ["F", "Fi", "M", "C", "H", "S", "D", "I"] {
            XCTAssertTrue(text.contains("\"\(axis)\":"), axis)
        }
        // Sorted keys put `by_tag` first, its tags alphabetical.
        XCTAssertTrue(text.hasPrefix(#"{"columns":[{"by_tag":{"agent-prompt":{"C":100,"F":100,"Fi":100,"M":100,"n":59},"all-filler":{"C":100,"F":100,"Fi":100,"M":100,"n":1},"#))
        XCTAssertTrue(text.contains(#""config":{"budget_ms":700,"timeout_ms":3000},"fallbacks":{"fastPath":0,"rawMode":0,"rejected":1,"requestFailed":0,"timedOut":0,"tooLong":0,"unavailable":0},"formatter":"llama","gate":{"answered":0,"controls":49,"controls_unchanged":49,"controls_unchanged_pct":100,"invented":0,"latency_over_budget":false,"negated":0,"over_edit_fact":0,"status":"PASS"},"latency_ms":{"#))
        XCTAssertTrue(text.contains(#""scores":{"C":100,"F":100,"Fi":100,"M":100}"#))
        XCTAssertTrue(text.contains(#""scoring_version":4"#))
        XCTAssertTrue(text.contains(#""schema":3"#))
        XCTAssertTrue(text.contains(#""verdicts":{"ANSWERED":0,"INVENTED":0,"MISSED":0,"NEGATED":0,"OVER_EDIT_FACT":0,"OVER_EDIT_HEDGE":0,"PASS":81,"PUNCT":0,"REWORDED":0,"UNRATED":0}"#))
        XCTAssertFalse(text.contains("\n"))
        // nil fields are omitted, not written as null (the word itself is
        // in bench-code's text).
        XCTAssertFalse(text.contains(":null"))
    }

    // MARK: - Fallback counters

    /// The tolerant decode is load-bearing, not defensive dressing: Swift's
    /// synthesized `Decodable` ignores stored-property defaults, so without it
    /// every leaderboard row written before `tooLong` existed throws
    /// `keyNotFound` and `whispr-bench leaderboard` exits 1 on the committed
    /// baseline. Adding a counter must never invalidate history.
    func testFallbacksDecodeRowsWrittenBeforeACounterExisted() throws {
        let legacy = Data(#"{"fastPath": 3, "rawMode": 1, "rejected": 2, "requestFailed": 0, "timedOut": 4, "unavailable": 0}"#.utf8)
        let decoded = try JSONDecoder().decode(EvalRun.Fallbacks.self, from: legacy)
        XCTAssertEqual(decoded.fastPath, 3)
        XCTAssertEqual(decoded.timedOut, 4)
        XCTAssertEqual(decoded.tooLong, 0, "a missing counter reads as zero, not a throw")
        XCTAssertEqual(decoded.harnessFailures, 0)

        // An empty object is still valid — every counter defaults.
        XCTAssertEqual(try JSONDecoder().decode(EvalRun.Fallbacks.self, from: Data("{}".utf8)),
                       EvalRun.Fallbacks())
    }

    /// `.tooLong` is a design skip, like the fast path — it must never make a
    /// run INVALID (only a harness failure does that).
    func testTooLongIsNotAHarnessFailure() {
        let f = EvalRun.Fallbacks(sources: [.fallback(.tooLong), .fallback(.tooLong), .fallback(.fastPath)])
        XCTAssertEqual(f.tooLong, 2)
        XCTAssertEqual(f.harnessFailures, 0)
        XCTAssertEqual(EvalRun.Fallbacks(sources: [.fallback(.unavailable)]).harnessFailures, 1)
    }

    // MARK: - Identity

    func testRunKeyIsStableAndSensitive() throws {
        let sha = try EvalCase.fixtureSetHash(EvalCase.seeds)
        let key = EvalRun.runKey(gitSha: "36ff03b", formatter: "llama", modelSha256: "m", promptSha256: "p",
                                 fixturesSha256: sha, level: "standard")
        XCTAssertEqual(key.count, 12)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(key, EvalRun.runKey(gitSha: "36ff03b", formatter: "llama", modelSha256: "m", promptSha256: "p",
                                           fixturesSha256: sha, level: "standard"))
        XCTAssertNotEqual(key, EvalRun.runKey(gitSha: "36ff03c", formatter: "llama", modelSha256: "m", promptSha256: "p",
                                              fixturesSha256: sha, level: "standard"))
        XCTAssertNotEqual(key, EvalRun.runKey(gitSha: "36ff03b", formatter: "rules", modelSha256: "m", promptSha256: "p",
                                              fixturesSha256: sha, level: "standard"))
        XCTAssertNotEqual(key, EvalRun.runKey(gitSha: "36ff03b", formatter: "llama", modelSha256: nil, promptSha256: "p",
                                              fixturesSha256: sha, level: "standard"))
        XCTAssertNotEqual(key, EvalRun.runKey(gitSha: "36ff03b", formatter: "llama", modelSha256: "m", promptSha256: "p",
                                              fixturesSha256: sha, level: "fillers"))
        // SHA-256 of the empty string — the helper is the standard digest.
        XCTAssertEqual(EvalRun.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testLeaderboardRowIsTheColumnMinusRows() throws {
        var observations = goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 410) }
        observations[0] = obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .model, ms: 900, reprime: true)
        let col = EvalRun.Column.make(formatter: "llama", modelKey: "qwen2.5-1.5b", modelSha256: "m", promptSha256: "p",
                                      level: "standard", config: EvalRun.Config(label: "baseline"), runKey: "abc",
                                      observations: observations)
        let r = try run([col])
        let row = r.leaderboardRow(col)
        XCTAssertEqual(row.runKey, "abc")
        XCTAssertEqual(row.label, "baseline")
        XCTAssertEqual(row.modelKey, "qwen2.5-1.5b")
        XCTAssertEqual(row.scores, col.scores)
        XCTAssertEqual(row.gate, col.gate)
        XCTAssertEqual(row.latencyMs?.reprimeMs, [900])
        XCTAssertEqual(row.fixtures.n, 81)
        XCTAssertEqual(row.fixtures.ratedN, 81)
        XCTAssertFalse(row.calibrated)
        XCTAssertNil(row.zeroEditRate)
        let text = String(decoding: try row.canonicalJSON(), as: UTF8.self)
        XCTAssertFalse(text.contains("\"rows\""))
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.contains(#""calibrated":false"#))
        XCTAssertTrue(text.contains(#""fixtures":{"draft_n":0,"n":81,"name":"seeds","rated_n":81,"sha256":""#))
        // Δ-comparability ignores the git sha.
        let other = try run([col]).leaderboardRow(col)
        XCTAssertEqual(row.comparabilityKey, other.comparabilityKey)
        XCTAssertFalse(row.comparabilityKey.contains("36ff03b"))
        XCTAssertTrue(row.comparabilityKey.contains(r.fixtures.sha256))
        XCTAssertEqual(try JSONDecoder().decode(EvalRun.LeaderboardRow.self, from: try row.canonicalJSON()), row)

        // With ratings in play both fields come alive (§7.4): the column's
        // own zero-edit rate, and `calibrated` only when a record covers
        // this exact fixture set.
        let live = Calibration.Live(rated: 81, valid: true, zeroEditRates: ["llama": 72.8, "rules": 10.0])
        let calibrated = r.leaderboardRow(col, calibration: live)
        XCTAssertTrue(calibrated.calibrated)
        XCTAssertEqual(calibrated.zeroEditRate, 72.8)
        let json = String(decoding: try calibrated.canonicalJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains(#""calibrated":true"#), json)
        XCTAssertTrue(json.contains(#""zero_edit_rate":72.8"#), json)
        // A record that does not cover the set never calibrates the row.
        let pending = Calibration.Live(rated: 81, valid: false, zeroEditRates: [:])
        XCTAssertFalse(r.leaderboardRow(col, calibration: pending).calibrated)
        XCTAssertNil(r.leaderboardRow(col, calibration: pending).zeroEditRate)
    }
}

// MARK: - Re-scoring, prompt identity, row provenance (step 6)

extension EvalRunTests {
    private func obs6(_ c: EvalCase, _ out: String, source: FormatterSource? = nil, ms: Int? = nil,
                      reprime: Bool = false, rejected: String? = nil) -> EvalRun.Observation {
        EvalRun.Observation(fixture: c, stripped: c.raw, out: out, source: source, ms: ms, reprime: reprime,
                            rejected: rejected, score: QualityScore.score(c, out: out),
                            modelScore: rejected.map { QualityScore.score(c, out: $0) })
    }

    /// A two-column run whose run keys are the real ones, so a rescore
    /// reproduces it exactly.
    private func keyedRun() throws -> EvalRun {
        let sha = try EvalCase.fixtureSetHash(EvalCase.seeds)
        var llama = EvalCase.seeds.map { obs6($0, $0.gold, source: .model, ms: 410) }
        llama[0] = obs6(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .model, ms: 900, reprime: true)
        llama[1] = obs6(EvalCase.seeds[1], "", source: .fallback(.timedOut), ms: 3100)
        llama[2] = obs6(EvalCase.seeds[2], EvalCase.seeds[2].gold, source: .fallback(.implausible), ms: 600, rejected: "Sure.")
        llama[3] = obs6(EvalCase.seeds[3], EvalCase.seeds[3].gold, source: .fallback(.fastPath))
        let rules = EvalRun.Column.make(
            formatter: "rules", modelSha256: "rules", level: "fixture", config: EvalRun.Config(),
            runKey: EvalRun.runKey(gitSha: "36ff03b", formatter: "rules", modelSha256: "rules", promptSha256: nil,
                                   fixturesSha256: sha, level: "fixture"),
            observations: EvalCase.seeds.map { obs6($0, $0.gold) })
        let column = EvalRun.Column.make(
            formatter: "llama", modelKey: "qwen2.5-1.5b", modelSha256: "m", promptSha256: "p", level: "fixture",
            config: EvalRun.Config(timeoutMs: 6000, budgetMs: 700, label: "baseline"),
            runKey: EvalRun.runKey(gitSha: "36ff03b", formatter: "llama", modelSha256: "m", promptSha256: "p",
                                   fixturesSha256: sha, level: "fixture"),
            observations: llama)
        return EvalRun(runId: "2026-09-14T180200-36ff03b-seeds", date: "2026-09-14T18:02:00Z", gitSha: "36ff03b",
                       dirty: false, machine: EvalRun.Machine(model: "Mac14,12", os: "26.5.1"),
                       fixtures: try EvalRun.Fixtures(path: "seeds", name: "seeds", cases: EvalCase.seeds),
                       columns: [rules, column])
    }

    func testRescoreReproducesTheRunAndIsIdempotent() throws {
        let r = try keyedRun()
        let once = try r.rescored(with: EvalCase.seeds)
        XCTAssertEqual(once, r)
        XCTAssertEqual(try once.canonicalJSON(), try r.canonicalJSON())
        // Through the file: load → rescore → the same bytes (date included).
        let loaded = try EvalRun.load(try r.canonicalJSON(pretty: true))
        let twice = try loaded.rescored(with: EvalCase.seeds).rescored(with: EvalCase.seeds)
        XCTAssertEqual(try twice.canonicalJSON(), try r.canonicalJSON())
        // Provenance, latencies, the re-prime mark and the rejected text survive.
        let llama = once.columns[1]
        XCTAssertEqual(llama.rows[1].source, "timed-out")
        XCTAssertEqual(llama.rows[2].rejected, "Sure.")
        XCTAssertEqual(llama.rows[2].modelVerdict, "ANSWERED")
        XCTAssertEqual(llama.rows[3].source, "fast-path")
        XCTAssertEqual(llama.rows[0].reprime, true)
        XCTAssertEqual(llama.latencyMs?.reprimeMs, [900])
        XCTAssertEqual(llama.fallbacks.timedOut, 1)
        XCTAssertEqual(llama.fallbacks.rejected, 1)
        XCTAssertEqual(llama.config.label, "baseline")
        // The fixture ORDER given to `score` does not matter.
        XCTAssertEqual(try r.rescored(with: EvalCase.seeds.reversed()), r)
    }

    func testRescoreRegradesStoredOutputsUnderTheCurrentVersion() throws {
        // Simulate an older run: a stale scoring version and a wrong C on a
        // row, as a v0 scorer might have written them.
        let r = try keyedRun()
        var text = String(decoding: try r.canonicalJSON(), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"scoring_version\":\(EvalRun.scoringVersion)", with: #""scoring_version":0"#)
        let stale = try EvalRun.load(Data(text.utf8))
        XCTAssertEqual(stale.scoringVersion, 0)
        var edited = stale
        edited.columns[0].rows[0].c = 12.3
        edited.columns[0].scores.c = 12.3
        edited.columns[0].runKey = "stale"
        let fresh = try edited.rescored(with: EvalCase.seeds)
        XCTAssertEqual(fresh.scoringVersion, EvalRun.scoringVersion)
        XCTAssertEqual(fresh.columns[0].rows[0].c, 100)
        XCTAssertEqual(fresh.columns[0].scores.c, 100)
        XCTAssertEqual(fresh.columns[0].runKey, r.columns[0].runKey)
        XCTAssertEqual(fresh, r)
    }

    func testRescoreRefusesAnotherFixtureSetOrAnUnknownRow() throws {
        let r = try keyedRun()
        XCTAssertThrowsError(try r.rescored(with: Array(EvalCase.seeds.dropLast()))) { error in
            guard case .fixturesMismatch(let stored, let given)? = error as? EvalRun.RescoreError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(stored, r.fixtures.sha256)
            XCTAssertNotEqual(given, stored)
            XCTAssertTrue("\(error as! EvalRun.RescoreError)".hasPrefix("fixture set differs from the run's"))
        }
        // A level the scorer cannot run is refused, not silently defaulted.
        var odd = r
        odd.columns[0].level = "verbatim"
        XCTAssertThrowsError(try odd.rescored(with: EvalCase.seeds)) { error in
            XCTAssertEqual(error as? EvalRun.RescoreError, .unknownLevel("verbatim"))
        }
        // A row whose id is not in the set (a hand-edited run file).
        var orphan = r
        orphan.columns[0].rows[0].id = "ghost"
        XCTAssertThrowsError(try orphan.rescored(with: EvalCase.seeds)) { error in
            XCTAssertEqual(error as? EvalRun.RescoreError, .unknownFixture("ghost"))
        }
    }

    func testRescoreHonoursTheColumnLevel() throws {
        // A fillers-level column scores no repair; at standard the echo is
        // an unresolved repair (M 75). Same outputs, different level, both
        // reproduced from the stored `level` string.
        let c = EvalCase.seeds.first { $0.id == "correct-time" }!
        let sha = try EvalCase.fixtureSetHash([c])
        func column(_ level: String) -> EvalRun.Column {
            let parsed = AppConfig.Cleanup.Level(rawValue: level)
            let score = QualityScore.score(c, out: "Let's meet at 2 actually 3.", level: parsed)
            return EvalRun.Column.make(formatter: "rules", modelSha256: "rules", level: level, config: EvalRun.Config(),
                                       runKey: EvalRun.runKey(gitSha: "s", formatter: "rules", modelSha256: "rules",
                                                              promptSha256: nil, fixturesSha256: sha, level: level),
                                       observations: [EvalRun.Observation(fixture: c, stripped: c.raw,
                                                                          out: "Let's meet at 2 actually 3.", score: score)])
        }
        let run = EvalRun(runId: "x", date: "d", gitSha: "s", dirty: false, machine: EvalRun.Machine(model: "m", os: "o"),
                          fixtures: try EvalRun.Fixtures(path: "p", name: "n", cases: [c]),
                          columns: [column("fillers"), column("standard")])
        XCTAssertEqual(run.columns[0].rows[0].m, 100)
        XCTAssertEqual(run.columns[1].rows[0].m, 75)
        let again = try run.rescored(with: [c])
        XCTAssertEqual(again, run)
    }

    func testPromptHashIsOverTheDistinctSortedPrompts() {
        XCTAssertEqual(EvalRun.promptHash(["b", "a", "a"]), EvalRun.promptHash(["a", "b"]))
        XCTAssertNotEqual(EvalRun.promptHash(["a"]), EvalRun.promptHash(["a", "b"]))
        XCTAssertEqual(EvalRun.promptHash(["only"]), EvalRun.sha256Hex("only"))
        XCTAssertEqual(EvalRun.promptHash([]), EvalRun.sha256Hex(""))
        // The separator keeps "ab"+"c" apart from "a"+"bc".
        XCTAssertNotEqual(EvalRun.promptHash(["ab", "c"]), EvalRun.promptHash(["a", "bc"]))
    }

    func testRowSourceRoundTrips() {
        XCTAssertEqual(FormatterSource(evalRowSource: "model"), .model)
        XCTAssertEqual(FormatterSource(evalRowSource: "fast-path"), .fallback(.fastPath))
        XCTAssertEqual(FormatterSource(evalRowSource: "raw-mode"), .fallback(.rawMode))
        XCTAssertEqual(FormatterSource(evalRowSource: "timed-out"), .fallback(.timedOut))
        XCTAssertEqual(FormatterSource(evalRowSource: "implausible"), .fallback(.implausible))
        XCTAssertEqual(FormatterSource(evalRowSource: "unavailable"), .fallback(.unavailable))
        XCTAssertEqual(FormatterSource(evalRowSource: "request-failed"), .fallback(.requestFailed))
        XCTAssertNil(FormatterSource(evalRowSource: "rules"))
        XCTAssertNil(FormatterSource(evalRowSource: "shipped"))
        // Every reason survives a trip through the row string.
        for reason in [FormatterFallbackReason.fastPath, .rawMode, .timedOut, .implausible, .unavailable, .requestFailed] {
            XCTAssertEqual(FormatterSource(evalRowSource: reason.rawValue), .fallback(reason))
        }
    }
}
