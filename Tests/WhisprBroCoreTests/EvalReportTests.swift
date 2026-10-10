import XCTest
@testable import WhisprBroCore

/// The report renderers (plan §6.3): the per-row line, the summary block
/// line by line, the word diff, and the markdown report's sections —
/// pinned on runs whose numbers EvalRunTests already hand-counts.
final class EvalReportTests: XCTestCase {
    private func obs(_ c: EvalCase, _ out: String, source: FormatterSource? = nil, ms: Int? = nil,
                     reprime: Bool = false, rejected: String? = nil) -> EvalRun.Observation {
        EvalRun.Observation(fixture: c, stripped: c.raw, out: out, source: source, ms: ms, reprime: reprime,
                            rejected: rejected, score: QualityScore.score(c, out: out),
                            modelScore: rejected.map { QualityScore.score(c, out: $0) })
    }

    private func column(_ observations: [EvalRun.Observation], formatter: String = "rules",
                        budgetMs: Int = 700) -> EvalRun.Column {
        EvalRun.Column.make(formatter: formatter, modelKey: formatter == "llama" ? "qwen2.5-1.5b" : nil,
                            level: "fixture", config: EvalRun.Config(budgetMs: budgetMs),
                            runKey: "0123456789ab", observations: observations)
    }

    private func run(_ columns: [EvalRun.Column], cases: [EvalCase] = EvalCase.seeds) throws -> EvalRun {
        EvalRun(runId: "2026-09-14T180200-36ff03b-seeds", date: "2026-09-14T18:02:00Z", gitSha: "36ff03b", dirty: false,
                machine: EvalRun.Machine(model: "Mac14,12", os: "26.5.1"),
                fixtures: try EvalRun.Fixtures(path: "seeds", name: "seeds", cases: cases), columns: columns)
    }

    private var goldCopy: [EvalRun.Observation] { EvalCase.seeds.map { obs($0, $0.gold) } }

    // MARK: - Row line

    func testRowSummary() {
        let pass = column(goldCopy).rows[0]
        XCTAssertEqual(EvalReport.rowSummary(pass), "PASS · F 100.0 Fi — M 100.0 C 100.0 · D 0 I 0 novel 0")
        // A timed re-prime row over the on-device timeout, with a rejected
        // model text scored beside it.
        let timed = column([obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .fallback(.implausible), ms: 3100,
                                reprime: true, rejected: "Sure, here's that:\n1. **" + EvalCase.seeds[0].raw)],
                           formatter: "llama").rows[0]
        XCTAssertEqual(EvalReport.rowSummary(timed),
                       "PASS · F 100.0 Fi — M 100.0 C 100.0 · D 0 I 0 novel 0 · 3100ms reprime >3s · model ANSWERED")
        // A gated row names its triggers; an emptied output shows the drop.
        let gated = column([obs(EvalCase.seeds[0], "")]).rows[0]
        XCTAssertTrue(EvalReport.rowSummary(gated).hasPrefix("OVER_EDIT_FACT (length-collapse"), EvalReport.rowSummary(gated))
        XCTAssertTrue(EvalReport.rowSummary(gated).contains("C 0.0"))
        XCTAssertTrue(EvalReport.rowSummary(gated).contains("dropped "))
        // Gold-free: verdict, Fi when defined, the diagnostics, no F / M / C.
        let uh = EvalCase(id: "uh", raw: "Uh", gold: "", goldSource: "history-unrated")
        XCTAssertEqual(EvalReport.rowSummary(column([obs(uh, "")]).rows[0]), "UNRATED · Fi 100.0 · D 0 I 0 novel 0")
        let plain = EvalCase(id: "p", raw: "ship it today", gold: "", goldSource: "history-unrated")
        XCTAssertEqual(EvalReport.rowSummary(column([obs(plain, "Ship it today.")]).rows[0]), "UNRATED · D 0 I 0 novel 0")
        let invented = column([obs(plain, "Ship it today, 140 units.")]).rows[0]
        // Gold-free: the H/S/D/I counts are gold↔out and stay 0; novelty is raw↔out.
        XCTAssertEqual(EvalReport.rowSummary(invented), "INVENTED (novel-numeral) · D 0 I 0 novel 2 (numerals 1)")
        // §4.4's D beside the alignment's when they differ: the wrong side
        // of a repair keeps "Tuesday" in "Wednesday"'s slot — a `.sub`, D 0,
        // lost 1. F: the stop sits on the sub pair → P 0, C 1 (on), T 1 →
        // 50; Fi undefined; M 0.75·33.3 = 25; C = 0.375·50 + 0.625·25 = 34.4.
        // The raw↔out diagnostic counts the deleted "Wednesday" (the reparandum
        // is an expected removal, "on" is STOP) → dropped 1.
        let repair = EvalCase(id: "r", raw: "meet on Tuesday, I mean on Wednesday", gold: "Meet on Wednesday.",
                              repairs: [EvalCase.Repair(reparandum: "on Tuesday, I mean", repair: "on Wednesday")])
        XCTAssertEqual(EvalReport.rowSummary(column([obs(repair, "Meet on Tuesday.")]).rows[0]),
                       "OVER_EDIT_HEDGE · F 50.0 Fi — M 25.0 C 34.4 · D 0 lost 1 I 0 novel 0 dropped 1")
    }

    // MARK: - Summary block

    func testSummaryLinesForARulesOnlyRun() throws {
        let text = EvalReport.summary(try run([column(goldCopy)]))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "status     rules PASS        DRAFT GOLDS: 0/81")
        XCTAssertEqual(lines[1], "composite  rules 100.0        CALIBRATION: PENDING (n=0 rated)")
        XCTAssertEqual(lines[2], "axes       F 100 · Fi 100 · M 100")
        // Tags by n descending, then name; the (n) is the tag's row count.
        XCTAssertTrue(lines[3].hasPrefix("by tag     agent-prompt 100.0 (59) · control 100.0 (49) · fillers 100.0 (20) ·"), lines[3])
        XCTAssertTrue(lines[3].hasSuffix("notes 100.0 (1)"), lines[3])
        XCTAssertEqual(EvalReport.summary(try run([])), "status     no columns ran")
    }

    func testSummaryStatusReasonsLatencyAndDelta() throws {
        // llama: one answered row, a re-prime row, one over budget on a
        // short fixture (p99 over 700 on the ≤ 60-word rows → WARN under
        // the FAIL) — the status line names every reason.
        var llama = goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 400) }
        llama[0] = obs(EvalCase.seeds[0], "Sure, here's that:\n1. **" + EvalCase.seeds[0].raw, source: .model, ms: 900, reprime: true)
        llama[1] = obs(EvalCase.seeds[1], EvalCase.seeds[1].gold, source: .model, ms: 1200)
        let r = try run([column(goldCopy), column(llama, formatter: "llama")])
        let lines = EvalReport.summary(r).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "status     rules PASS | llama FAIL(answered 1, latency)        DRAFT GOLDS: 0/81")
        XCTAssertTrue(lines[1].hasPrefix("composite  rules 100.0 | llama 98.8        CALIBRATION"), lines[1])
        // The answered row keeps its F (formatting is scored before the gate zeroes C and M).
        XCTAssertEqual(lines[2], "axes       F 100/99 · Fi 100/100 · M 100/99")
        // 81 rows, one re-prime excluded: p50 400, p90 400, p99 1200 (≤ 60-word
        // rows too, seed 1 is short), max 1200, over budget 1/80; 79 × 400 +
        // 1200 = 32 800 ms over the 80 rows' spoken words → 10.0 ms/word.
        XCTAssertEqual(lines[3], "latency    llama p50 400 p90 400 p99 1200 (≤60w 1200) max 1200 · over 700ms 1/80 · 10.0 ms/word · reprime 900 · WARN")
        XCTAssertTrue(lines[4].hasPrefix("by tag     agent-prompt 100.0/100.0 (59)"), lines[4])
        // Seed 0 is a repair seed: 7 × 100 + 0 → 87.5 over its 8 rows.
        XCTAssertTrue(lines[4].contains("· repair 100.0/87.5 (8) ·"), lines[4])
        // Δ from a previous comparable row rides on the composite line.
        let prev = r.leaderboardRow(r.columns[1])
        var improved = llama
        improved[0] = obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .model, ms: 400, reprime: true)
        improved[1] = obs(EvalCase.seeds[1], EvalCase.seeds[1].gold, source: .model, ms: 400)
        let r2 = try run([column(goldCopy), column(improved, formatter: "llama")])
        let delta = try Leaderboard.diff(prev, r2.leaderboardRow(r2.columns[1]))
        let withDelta = EvalReport.summary(r2, deltas: ["llama": delta]).split(separator: "\n").map(String.init)
        XCTAssertEqual(withDelta[1], "composite  rules 100.0 | llama 100.0 (Δ +1.2)        CALIBRATION: PENDING (n=0 rated)")
        XCTAssertEqual(withDelta[0], "status     rules PASS | llama PASS        DRAFT GOLDS: 0/81")
        // 80 × 400 = 32 000 ms over the same spoken words → 9.7 ms/word.
        XCTAssertEqual(withDelta[3], "latency    llama p50 400 p90 400 p99 400 (≤60w 400) max 400 · over 700ms 0/80 · 9.7 ms/word · reprime 400 · ok")
    }

    func testSummaryCountsDraftGoldsAndInvalidHarness() throws {
        let cases = [
            EvalCase(id: "a", raw: "um hi there friend", gold: "Hi there, friend."),
            EvalCase(id: "b", raw: "um hi there friend", gold: "Hi there, friend.", goldSource: "draft:claude", annotationsStatus: .draft),
        ]
        let col = EvalRun.Column.make(formatter: "foundation", level: "fixture", config: EvalRun.Config(), runKey: "k",
                                      observations: cases.map { obs($0, $0.gold, source: .fallback(.unavailable), ms: 5) })
        let lines = EvalReport.summary(try run([col], cases: cases)).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "status     foundation INVALID(harness fallbacks 2)        DRAFT GOLDS: 1/2")
        XCTAssertEqual(lines[1], "composite  foundation 100.0        CALIBRATION: PENDING (n=0 rated)")
        // Fallback rows carry no model latency → no latency line.
        XCTAssertFalse(lines.contains { $0.hasPrefix("latency") })
    }

    func testSummaryLatencyWithNoTimedRowIsNotAnOk() throws {
        // A one-fixture llama run: its only model row is its group's
        // first, so every number is undefined — the line says so instead
        // of printing zeros under an "ok".
        let lone = column([obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .model, ms: 900, reprime: true)],
                          formatter: "llama")
        let lines = EvalReport.summary(try run([lone])).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[3], "latency    llama p50 — p90 — p99 — max — · over 700ms 0/0 · reprime 900 · n/a (every timed row was a re-prime)")
        XCTAssertEqual(lines[0], "status     llama PASS        DRAFT GOLDS: 0/81")
        // The same row on the shipped column is a measurement, not a re-prime.
        let shipped = column([obs(EvalCase.seeds[0], EvalCase.seeds[0].gold, source: .model, ms: 900, reprime: true)],
                             formatter: "shipped")
        let shippedLines = EvalReport.summary(try run([shipped])).split(separator: "\n").map(String.init)
        XCTAssertTrue(shippedLines[3].hasPrefix("latency    shipped p50 900 p90 900 p99 900 (≤60w 900) max 900 · over 700ms 1/1 ·"), shippedLines[3])
        XCTAssertTrue(shippedLines[3].hasSuffix("· WARN"), shippedLines[3])
        XCTAssertEqual(shippedLines[0], "status     shipped WARN(latency)        DRAFT GOLDS: 0/81")
    }

    // MARK: - Fallback lines

    func testFallbackLinesNameTheThreeKindsAndInvalidateOnlyTheHarness() throws {
        // §5: fast-path / raw-mode are design, timed-out / rejected are
        // real behaviour scored as the fallback text, unavailable /
        // request-failed are the harness — only those print INVALID, the
        // same rule the status line and the exit code read.
        let s = EvalCase.seeds
        let behaviour = column([
            obs(s[0], s[0].gold, source: .model, ms: 400),
            obs(s[1], s[1].gold, source: .fallback(.fastPath), ms: 3),
            obs(s[2], s[2].gold, source: .fallback(.timedOut), ms: 3100),
            obs(s[3], s[3].gold, source: .fallback(.implausible), ms: 600, rejected: "Sure, here's that."),
        ], formatter: "llama")
        XCTAssertEqual(EvalReport.fallbackLines(behaviour), [
            "  llama      fallbacks: 3/4 · by design: fast-path ×1 · scored as the fallback text: timed-out ×1, rejected ×1",
        ])
        XCTAssertEqual(behaviour.gate.status, .warn)   // the 3100 ms row, not an INVALID
        let harness = column([
            obs(s[0], s[0].gold, source: .model, ms: 400),
            obs(s[1], s[1].gold, source: .fallback(.unavailable), ms: 3),
            obs(s[2], s[2].gold, source: .fallback(.requestFailed), ms: 3),
            obs(s[3], s[3].gold, source: .fallback(.rawMode), ms: 3),
        ], formatter: "foundation")
        XCTAssertEqual(EvalReport.fallbackLines(harness), [
            "  foundation fallbacks: 3/4 · by design: raw-mode ×1 · harness: unavailable ×1, request-failed ×1",
            "  foundation INVALID — 2/4 fell back to rules because the harness failed; NOT model evidence",
        ])
        XCTAssertEqual(harness.gate.status, .invalid)
        // A clean model column, the rules column, and the shipped column.
        XCTAssertEqual(EvalReport.fallbackLines(column(goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 400) },
                                                       formatter: "llama")),
                       ["  llama      fallbacks: 0/81"])
        XCTAssertEqual(EvalReport.fallbackLines(column(goldCopy)), [])
        XCTAssertEqual(EvalReport.fallbackLines(column(goldCopy, formatter: "shipped")), [
            "  shipped    fallbacks: n/a (history records no provenance; a row is a model row when production "
            + "would have run the model — ≥ 6 words, or a correction cue at standard, and not over the "
            + "150-word ceiling — else rules)",
        ])
    }

    // MARK: - Word diff

    func testWordDiff() {
        XCTAssertEqual(EvalReport.wordDiff(gold: "I don't know, try some benchmarking.", out: "Try some benchmarking."),
                       "[-I-] [-don't-] [-know,-] Try some benchmarking.")
        XCTAssertEqual(EvalReport.wordDiff(gold: "Meet on Wednesday.", out: "Meet on Tuesday."),
                       "Meet on [-Wednesday.-]{+Tuesday.+}")
        XCTAssertEqual(EvalReport.wordDiff(gold: "Ship it.", out: "Ship it, 140 units."),
                       "Ship it, {+140+} {+units.+}")
        // Hits print as the output wrote them: a punctuation miss stays a hit.
        XCTAssertEqual(EvalReport.wordDiff(gold: "Okay, we ship it.", out: "Okay we ship it"), "Okay we ship it")
        XCTAssertEqual(EvalReport.wordDiff(gold: "", out: ""), "")
        XCTAssertEqual(EvalReport.wordDiff(gold: "and 54", out: "and fifty-four"), "and fifty-four")
    }

    // MARK: - Markdown

    func testMarkdownSections() throws {
        var llama = goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 400) }
        llama[0] = obs(EvalCase.seeds[0], "Sure, here's that:\n1. **" + EvalCase.seeds[0].raw, source: .model, ms: 900, reprime: true)
        llama[2] = obs(EvalCase.seeds[2], EvalCase.seeds[2].gold, source: .fallback(.implausible), ms: 600,
                       rejected: "Sure, I can explain that.")
        let r = try run([column(goldCopy), column(llama, formatter: "llama")])
        let prev = r.leaderboardRow(r.columns[1])
        let md = EvalReport.markdown(r, cases: EvalCase.seeds, previous: ["llama": prev])
        for heading in ["# whispr-bench eval — 2026-09-14T180200-36ff03b-seeds", "## Leaderboard rows", "## Verdicts",
                        "## Gated fixtures", "## Worst 10 by C — rules", "## Worst 10 by C — llama",
                        "## Latency — llama", "## Provenance", "## By tag (C)"] {
            XCTAssertTrue(md.contains(heading + "\n"), heading)
        }
        XCTAssertFalse(md.contains("## Latency — rules"))
        XCTAssertTrue(md.contains("- **CALIBRATION: PENDING (n=0 rated)**"))
        XCTAssertTrue(md.contains("- fixtures: **seeds** n=81 (rated 81, draft 0, unrated 0)"))
        XCTAssertTrue(md.contains("| rules | — | fixture | 100.0 | 100.0 | 100.0 | 100.0 | PASS | — | — | — | — |"), md)
        // The answered row keeps a partial F (99.1 over the column); the
        // rejected row's 600 ms is model-path latency, so p99 over the 80
        // timed rows (the re-prime row excluded) lands on it.
        XCTAssertTrue(md.contains("| llama | qwen2.5-1.5b | fixture | 98.8 | 99.1 | 100.0 | 98.8 | FAIL | 400 | 600 | 0 | `0123456789ab` 36ff03b |"), md)
        XCTAssertTrue(md.contains("| ANSWERED | 0 | 1 |"))
        XCTAssertTrue(md.contains("### \(EvalCase.seeds[0].id) — llama **ANSWERED** (multi-line, markdown, opener"), md)
        XCTAssertTrue(md.contains("- raw: `\(EvalCase.seeds[0].raw)`"))
        XCTAssertTrue(md.contains("- gold: `\(EvalCase.seeds[0].gold)`"))
        XCTAssertTrue(md.contains("- diff vs gold: `"))
        XCTAssertTrue(md.contains("### \(EvalCase.seeds[2].id) — llama stage PASS, model **ANSWERED** (rejected)"), md)
        XCTAssertTrue(md.contains("- rejected: `Sure, I can explain that.`"))
        XCTAssertTrue(md.contains("- reprime_ms: 900"))
        XCTAssertTrue(md.contains("- n_llm 80 · p50 400 · p90 400 · p99 600 (≤60w 600) · max 600 · over 700ms: 0 ·"), md)
        XCTAssertTrue(md.contains("| id | C | verdict | F | Fi | M | D | lost | I | novel | ms |\n"))
        XCTAssertTrue(md.contains("| llama | 80 | 0 | 0 | 0 | 0 | 1 | 0 | 0 |"), md)
        XCTAssertTrue(md.contains("| rules | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |"))
        // The rules column has no gated row; its worst-10 starts at the seeds' floor.
        XCTAssertTrue(md.contains("| \(EvalCase.seeds[0].id) | 0.0 | ANSWERED |"), md)
        // Without a gated row the section says so.
        let clean = EvalReport.markdown(try run([column(goldCopy)]), cases: EvalCase.seeds)
        XCTAssertTrue(clean.contains("## Gated fixtures\n\n_none_\n"), clean)
        XCTAssertFalse(clean.contains("## Latency"))
    }

    /// The banner was a hard-coded constant (`PENDING (n=0 rated)`) with
    /// no way to reach any other value; it now states what the ratings
    /// file actually says (§7.4).
    func testTheCalibrationBannerIsLive() throws {
        let run = try run([column(goldCopy)])
        let pending = Calibration.Live(rated: 12, valid: false, zeroEditRates: ["rules": 41.7])
        XCTAssertEqual(EvalReport.summary(run, calibration: pending).split(separator: "\n")[1],
                       "composite  rules 100.0        CALIBRATION: PENDING (n=12 rated)")
        let valid = Calibration.Live(rated: 124, valid: true, zeroEditRates: ["rules": 88.0])
        XCTAssertEqual(EvalReport.summary(run, calibration: valid).split(separator: "\n")[1],
                       "composite  rules 100.0        CALIBRATION: VALID (n=124 rated)")
        // No --ratings: the zero state, exactly as before.
        XCTAssertEqual(EvalReport.summary(run).split(separator: "\n")[1],
                       "composite  rules 100.0        CALIBRATION: PENDING (n=0 rated)")
        XCTAssertEqual(EvalReport.calibrationBanner, "CALIBRATION: PENDING (n=0 rated)")
        // The markdown carries the same line plus the zero-edit rates.
        let md = EvalReport.markdown(run, cases: EvalCase.seeds, calibration: valid)
        XCTAssertTrue(md.contains("- **CALIBRATION: VALID (n=124 rated)** · zero-edit rules 88.0%"), md)
        XCTAssertTrue(EvalReport.markdown(run, cases: EvalCase.seeds)
            .contains("- **CALIBRATION: PENDING (n=0 rated)**"))
    }

    func testMarkdownQuotesPipesNewlinesAndEmptyText() throws {
        // Six-plus words so the empty output trips the collapse gate.
        let c = EvalCase(id: "q", raw: "ship it | now before the meeting starts", gold: "Ship it | now before the meeting starts.")
        let col = column([obs(c, "")])
        let md = EvalReport.markdown(try run([col], cases: [c]), cases: [c])
        XCTAssertTrue(md.contains("- raw: `ship it \\| now before the meeting starts`"), md)
        XCTAssertTrue(md.contains("- out: _(empty)_"), md)
        let answered = column([obs(c, "Sure:\n1. **ship** it | now before the meeting starts")])
        let md2 = EvalReport.markdown(try run([answered], cases: [c]), cases: [c])
        XCTAssertTrue(md2.contains("- out: `Sure: ⏎ 1. **ship** it \\| now before the meeting starts`"), md2)
        // A gold-free gated row diffs against raw.
        let free = EvalCase(id: "h", raw: "ship it now", gold: "", goldSource: "history-unrated", observed: "Sure:\n1. **ship** it now")
        let shipped = column([obs(free, free.observed!)], formatter: "shipped")
        let md3 = EvalReport.markdown(try run([shipped], cases: [free]), cases: [free])
        XCTAssertTrue(md3.contains("- gold: _(unrated)_\n- diff vs raw: `{+Sure:+} {+1.+} ship it now`"), md3)
    }
}
