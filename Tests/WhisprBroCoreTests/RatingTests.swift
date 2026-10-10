import XCTest
@testable import WhisprBroCore

/// The rating loop's data and state machine (plan §7.1–7.2): the record's
/// shape on disk, the queue's order and its skip-already-rated rule, every
/// key of the triage machine driven the way scripted mode drives it (one
/// answer per line), the blind pairwise slot's determinism and balance,
/// and the summary's zero-edit rate. No terminal, no files — the bench
/// glue only reads keys and writes the lines this emits.
final class RatingTests: XCTestCase {
    // MARK: Fixtures

    /// A gold-free history-shaped row (what the first rating session sees).
    private let unrated = EvalCase(id: "h58", raw: "I don't know, try some broad benchmarking on the tabs",
                                   gold: "", tags: ["unrated", "unknown"], source: "history:58",
                                   goldSource: EvalCase.historyUnratedGoldSource,
                                   observed: "Try some broad benchmarking on the tabs.")
    /// A rated one, so the diff has a gold to run against.
    private let rated = EvalCase(id: "seed-01", raw: "um we ship the fix today",
                                 gold: "We ship the fix today.", tags: ["filler"])

    private func row(_ c: EvalCase, _ out: String, ms: Int? = 410) -> EvalRun.Row {
        column([c], outs: [out], formatter: "llama", runKey: "aaaaaaaaaaaa", ms: ms).rows[0]
    }

    private func column(_ cases: [EvalCase], outs: [String], formatter: String, runKey: String,
                        ms: Int? = 410) -> EvalRun.Column {
        let observations = zip(cases, outs).map { c, out in
            EvalRun.Observation(fixture: c, stripped: c.raw, out: out, source: .model, ms: ms,
                                score: QualityScore.score(c, out: out))
        }
        return EvalRun.Column.make(formatter: formatter, level: "standard", config: EvalRun.Config(),
                                   runKey: runKey, observations: observations)
    }

    private func run(_ columns: [EvalRun.Column], cases: [EvalCase]) throws -> EvalRun {
        EvalRun(runId: "2026-09-14T180200-36ff03b-personal", date: "2026-09-14T18:02:00Z", gitSha: "36ff03b",
                dirty: false, machine: EvalRun.Machine(model: "Mac14,12", os: "26.5.1"),
                fixtures: try EvalRun.Fixtures(path: "p.json", name: "personal", cases: cases), columns: columns)
    }

    private func rating(_ id: String, out: String, verdict: Rating.Verdict? = .ship,
                        formatter: String = "llama", runKey: String = "aaaaaaaaaaaa",
                        pair: Rating.Pair? = nil) -> Rating {
        Rating(fixtureId: id, runKey: runKey, formatter: formatter, outputSha: Rating.outputSha(out),
               verdict: verdict, pair: pair, msToRate: 4200, ratedAt: "2026-09-14T18:03:00Z", session: "s1")
    }

    /// A session with a fixed clock so `ms_to_rate` is pinned: every
    /// `now()` call advances 500 ms.
    private func session(_ items: [RatingQueue.Item], id: String = "s1") -> RatingSession {
        let ticks = Ticker()
        return RatingSession(items: items, session: id, now: { ticks.next() })
    }

    private final class Ticker: @unchecked Sendable {
        private var t = 0.0
        private let lock = NSLock()
        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            t += 0.5
            return Date(timeIntervalSince1970: 1_789_408_920 + t)   // 2026-09-14T18:02:00Z
        }
    }

    // MARK: - The record

    func testRecordEncodesSection72Keys() throws {
        let r = Rating(fixtureId: "h58", runKey: "b5e821d340da", formatter: "llama",
                       outputSha: Rating.outputSha("Try some broad benchmarking."), verdict: .wrong,
                       tags: ["dropped-hedge"], mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 2)],
                       goldEdit: "I don't know, try some broad benchmarking.",
                       msToRate: 5200, ratedAt: "2026-09-14T18:03:00Z", session: "2026-09-14-1")
        let line = String(decoding: try RatingLog.encode(r), as: UTF8.self)
        XCTAssertTrue(line.contains(#""fixture_id":"h58""#), line)
        XCTAssertTrue(line.contains(#""run_key":"b5e821d340da""#), line)
        XCTAssertTrue(line.contains(#""output_sha":"#), line)
        XCTAssertTrue(line.contains(#""verdict":"wrong""#), line)
        XCTAssertTrue(line.contains(#""tags":["dropped-hedge"]"#), line)
        XCTAssertTrue(line.contains(#""must_keep":[{"span":"I don't know,","weight":2}]"#), line)
        XCTAssertTrue(line.contains(#""should_go":[]"#), line)
        XCTAssertTrue(line.contains(#""gold_edit":"#), line)
        XCTAssertTrue(line.contains(#""ms_to_rate":5200"#), line)
        XCTAssertTrue(line.contains(#""rated_at":"2026-09-14T18:03:00Z""#), line)
        XCTAssertTrue(line.contains(#""session":"2026-09-14-1""#), line)
        // Absent unless they apply: no fake verdict-adjacent noise on disk.
        XCTAssertFalse(line.contains("alt_gold"), line)
        XCTAssertFalse(line.contains("\"pair\""), line)
        XCTAssertFalse(line.contains("confirm"), line)
        XCTAssertEqual(try RatingLog.load(try RatingLog.encode(r)), [r])
    }

    func testRecordRoundTripsThroughTheLog() throws {
        let a = rating("h58", out: "Try some broad benchmarking.", verdict: .wrong)
        let b = Rating(fixtureId: "h58", runKey: "aaaaaaaaaaaa", formatter: "llama",
                       outputSha: Rating.outputSha("x"), verdict: nil,
                       pair: Rating.Pair(aRun: "aaaaaaaaaaaa", bRun: "bbbbbbbbbbbb", slot: "b", pick: "a"),
                       msToRate: 2900, ratedAt: "2026-09-14T18:04:00Z", session: "s1")
        var data = Data()
        data += try RatingLog.encode(a) + Data("\n".utf8)
        data += Data("\n".utf8)                      // a blank line is skipped
        data += try RatingLog.encode(b) + Data("\n".utf8)
        let loaded = try RatingLog.load(data)
        XCTAssertEqual(loaded, [a, b])
        XCTAssertTrue(loaded[0].isTriage)
        XCTAssertTrue(loaded[1].isPairwise)
        XCTAssertNil(loaded[1].verdict)
        // Slot b held run A, he picked slot a → run B won.
        XCTAssertEqual(loaded[1].pair?.pickedRun, "bbbbbbbbbbbb")
        XCTAssertEqual(loaded[1].pair?.preference, -1)
        XCTAssertThrowsError(try RatingLog.load(Data("{\"fixture_id\":\"h1\"}\n".utf8))) { error in
            XCTAssertEqual(error as? RatingLog.Error, .malformedLine(1))
        }
    }

    /// §7.2's list spells `must_keep` as strings; the object form carries
    /// the weight `K` sets. Both decode, as `EvalCase.MustKeep` does.
    func testMustKeepDecodesFromStringsAndObjects() throws {
        let line = #"{"fixture_id":"h1","run_key":"k","formatter":"llama","output_sha":"ab","verdict":"wrong","#
            + #""tags":[],"must_keep":["I don't know,",{"span":"62 other things","weight":5}],"#
            + #""should_go":[],"ms_to_rate":1,"rated_at":"2026-09-14T18:03:00Z","session":"s"}"#
        let r = try RatingLog.load(Data(line.utf8))[0]
        XCTAssertEqual(r.mustKeep, [EvalCase.MustKeep(span: "I don't know,", weight: 2),
                                    EvalCase.MustKeep(span: "62 other things", weight: 5)])
    }

    func testOutputShaIsStableAndTextKeyed() {
        XCTAssertEqual(Rating.outputSha("Try some broad benchmarking."), Rating.outputSha("Try some broad benchmarking."))
        XCTAssertNotEqual(Rating.outputSha("Try some broad benchmarking."), Rating.outputSha("Try some broad benchmarking"))
        XCTAssertEqual(Rating.outputSha("x").count, 12)
    }

    // MARK: - The queue

    func testQueueOrdersFlaggedThenUnratedThenTheRest() throws {
        // clean: a rated fixture its output matches; unrated: gold-free,
        // nothing dropped; flagged: gold-free with 4 dropped content words.
        let clean = rated
        let plain = EvalCase(id: "h2", raw: "we ship the fix today", gold: "",
                             goldSource: EvalCase.historyUnratedGoldSource)
        let col = column([clean, plain, unrated],
                         outs: ["We ship the fix today.", "We ship the fix today.",
                                "Try some broad benchmarking on the tabs."],
                         formatter: "llama", runKey: "aaaaaaaaaaaa")
        let r = try run([col], cases: [clean, plain, unrated])
        let queue = RatingQueue.build(run: r, fixtures: [clean, plain, unrated], session: "s1")
        XCTAssertEqual(queue.map(\.fixture.id), ["h58", "h2", "seed-01"])
        XCTAssertTrue(queue[0].flagged)
        XCTAssertTrue(queue[1].unrated)
        XCTAssertFalse(queue[2].flagged)
        // The flagged row is flagged because 4 raw content words are gone.
        XCTAssertGreaterThanOrEqual(queue[0].row.droppedContent, EvalThresholds.flaggedDroppedContent)
    }

    func testOnlyFlaggedAndOnlyUnratedNarrowTheQueue() throws {
        let plain = EvalCase(id: "h2", raw: "we ship the fix today", gold: "",
                             goldSource: EvalCase.historyUnratedGoldSource)
        let col = column([rated, plain, unrated],
                         outs: ["We ship the fix today.", "We ship the fix today.",
                                "Try some broad benchmarking on the tabs."],
                         formatter: "llama", runKey: "aaaaaaaaaaaa")
        let r = try run([col], cases: [rated, plain, unrated])
        let fixtures = [rated, plain, unrated]
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: fixtures, only: .flagged, session: "s1")
            .map(\.fixture.id), ["h58"])
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: fixtures, only: .unrated, session: "s1")
            .map(\.fixture.id), ["h58", "h2"])
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: fixtures, only: .gated, session: "s1")
            .map(\.fixture.id), [])
    }

    func testEveryColumnIsQueuedUnlessOneIsNamed() throws {
        let a = column([rated], outs: ["We ship the fix today."], formatter: "llama", runKey: "aaaaaaaaaaaa")
        let b = column([rated], outs: ["we ship the fix today"], formatter: "shipped", runKey: "bbbbbbbbbbbb")
        let r = try run([a, b], cases: [rated])
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [rated], session: "s1").map(\.formatter),
                       ["llama", "shipped"])
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [rated], column: "shipped", session: "s1")
            .map(\.formatter), ["shipped"])
    }

    func testAnOutputAlreadyRatedIsSkippedUnlessRerate() throws {
        let out = "We ship the fix today."
        let col = column([rated], outs: [out], formatter: "llama", runKey: "aaaaaaaaaaaa")
        let r = try run([col], cases: [rated])
        let already = [rating("seed-01", out: out)]
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [rated], ratings: already, session: "s1").count, 0)
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [rated], ratings: already, rerate: true,
                                         session: "s1").count, 1)
        // The key is the TEXT: another run's identical output is rated too,
        // a different output is not.
        let other = column([rated], outs: [out], formatter: "foundation", runKey: "cccccccccccc")
        XCTAssertEqual(RatingQueue.build(run: try run([other], cases: [rated]), fixtures: [rated],
                                         ratings: already, session: "s1").count, 0)
        let changed = column([rated], outs: ["We ship the fix today"], formatter: "llama", runKey: "aaaaaaaaaaaa")
        XCTAssertEqual(RatingQueue.build(run: try run([changed], cases: [rated]), fixtures: [rated],
                                         ratings: already, session: "s1").count, 1)
    }

    /// `y` confirms the fixture's ANNOTATIONS; it says nothing about the
    /// output. The row must come back next session — a confirm that locked
    /// it out could never be turned into a SHIP / FIX / WRONG without
    /// `--rerate` re-opening every row of the pass, and it would count
    /// toward a calibration banner no check can see.
    func testAConfirmDoesNotCountAsRatedAndTheRowComesBack() throws {
        let out = "Try some broad benchmarking on the tabs."
        let col = column([unrated], outs: [out], formatter: "llama", runKey: "aaaaaaaaaaaa")
        let r = try run([col], cases: [unrated])
        var s = session([item(unrated, out: out)])
        guard case .write(let confirm)? = s.handle("y").first else { return XCTFail("no record") }
        XCTAssertTrue(confirm.isConfirm)
        XCTAssertNil(confirm.verdict)
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [unrated], ratings: [confirm], session: "s2")
            .map(\.fixture.id), ["h58"])
        XCTAssertEqual(RatingLog.ratedKeys([confirm]), [])
        XCTAssertEqual(RatingLog.ratedCount([confirm], in: [unrated]), 0)
        XCTAssertEqual(RatingLog.ratedRows([confirm]), 0)
        // The verdict he presses afterwards is what closes the row.
        let judged = rating("h58", out: out, verdict: .fix)
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [unrated], ratings: [confirm, judged],
                                         session: "s2").count, 0)
        XCTAssertEqual(RatingLog.ratedRows([confirm, judged]), 1)
    }

    /// `y` after an edit is not the no-op a bare confirm is: the record
    /// carries no verdict but it carries his GOLD. Skipping every
    /// verdict-less record put that row back in the next session's queue —
    /// he would type the same gold twice — so a record that changes the
    /// fixture counts as rated, while §7.4's `n` still counts verdicts
    /// only.
    func testAConfirmCarryingHisGoldCountsAsRatedAndRoundTrips() throws {
        let out = "Try some broad benchmarking on the tabs."
        let gold = "I don't know, try some broad benchmarking on the tabs."
        var s = session([item(unrated, out: out)])
        XCTAssertEqual(s.handle("e"), [.openEditor(text: out, fixtureId: "h58")])
        XCTAssertEqual(s.applyEdit(gold), [.note("gold edit staged — press 1/2/3 to record it")])
        guard case .write(let record)? = s.handle("y").first else { return XCTFail("no record") }
        XCTAssertTrue(record.isConfirm)
        XCTAssertNil(record.verdict)
        XCTAssertEqual(record.goldEdit, gold)
        XCTAssertTrue(record.carriesAGold)

        // Through the log and back, then through the queue.
        let log = try RatingLog.load(try RatingLog.encode(record) + Data("\n".utf8))
        XCTAssertEqual(log, [record])
        XCTAssertEqual(RatingLog.ratedKeys(log), [record.key])
        let r = try run([column([unrated], outs: [out], formatter: "llama", runKey: "aaaaaaaaaaaa")],
                        cases: [unrated])
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [unrated], ratings: log, session: "s2").count, 0)
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [unrated], ratings: log, rerate: true,
                                         session: "s2").count, 1)
        // §7.4's n is verdicts, and only verdicts.
        XCTAssertEqual(RatingLog.ratedRows(log), 0)
        XCTAssertEqual(RatingLog.ratedCount(log, in: [unrated]), 0)

        // And the derivation reads the gold AND the confirm out of the one
        // record — the round trip his session actually walks.
        var texts = GoldDerivation.Outputs()
        texts.add(fixtureId: "h58", text: out)
        let derived = GoldDerivation.derive(fixtures: [unrated], ratings: log, outputs: texts)
        XCTAssertEqual(derived.cases[0].gold, gold)
        XCTAssertEqual(derived.cases[0].goldSource, GoldDerivation.editSource)
        XCTAssertEqual(derived.cases[0].annotationsStatus, .confirmed)
        XCTAssertFalse(derived.cases[0].tags.contains(HistoryExport.unratedTag))
    }

    /// The same rule for the other staged gold, and the two lines it does
    /// not cross: a pairwise pick is not a triage record at all, and a
    /// blank edit is not text he typed.
    func testOnlyAStagedGoldMakesAVerdictLessRecordCount() throws {
        let out = "Try some broad benchmarking on the tabs."
        let bare = rating("h58", out: out, verdict: nil)
        XCTAssertFalse(bare.carriesAGold)
        var alternate = bare
        alternate.altGold = out
        XCTAssertTrue(alternate.carriesAGold)
        var blank = bare
        blank.goldEdit = "   "
        XCTAssertFalse(blank.carriesAGold)
        var pick = bare
        pick.pair = Rating.Pair(aRun: "aaaaaaaaaaaa", bRun: "bbbbbbbbbbbb", slot: "a", pick: "a")
        pick.altGold = out
        XCTAssertFalse(pick.carriesAGold)
        XCTAssertEqual(RatingLog.ratedKeys([bare, blank, pick]), [])
        XCTAssertEqual(RatingLog.ratedKeys([alternate]), [alternate.key])
    }

    /// A mark is not a gold. `k` / `K` stages a span and rides along on
    /// the next record, but marking is work the loop can ask for again,
    /// and a row he only MARKED still owes a verdict — reading the mark as
    /// "rated" locked that row out of every future queue without one. The
    /// span is not lost either way: `gold` drafts the `must_keep` from the
    /// record it is already in.
    func testAMarkedRowStillComesBackForItsVerdict() throws {
        let out = "Try some broad benchmarking on the tabs."
        var marked = rating("h58", out: out, verdict: nil)
        marked.mustKeep = [EvalCase.MustKeep(span: "I don't know", weight: 2)]
        marked.confirm = true
        XCTAssertFalse(marked.carriesAGold)
        XCTAssertEqual(RatingLog.ratedKeys([marked]), [])
        let r = try run([column([unrated], outs: [out], formatter: "llama", runKey: "aaaaaaaaaaaa")],
                        cases: [unrated])
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [unrated], ratings: [marked],
                                         session: "s2").count, 1)
        var texts = GoldDerivation.Outputs()
        texts.add(fixtureId: "h58", text: out)
        let derived = GoldDerivation.derive(fixtures: [unrated], ratings: [marked], outputs: texts)
        XCTAssertEqual(derived.cases[0].mustKeep.map(\.span), ["I don't know"])
        // The verdict he presses next is what closes the row.
        let judged = rating("h58", out: out, verdict: .wrong)
        XCTAssertEqual(RatingQueue.build(run: r, fixtures: [unrated], ratings: [marked, judged],
                                         session: "s2").count, 0)
    }

    // MARK: - Pairwise

    func testTheBlindSlotIsStablePerSessionAndFlipsWithIt() {
        let first = RatingQueue.slot(fixtureId: "h58", session: "s1")
        XCTAssertEqual(first, RatingQueue.slot(fixtureId: "h58", session: "s1"))
        XCTAssertTrue(["a", "b"].contains(first))
        // A different session re-lays the same fixture (blind twice over).
        let sessions = (0..<20).map { RatingQueue.slot(fixtureId: "h58", session: "s\($0)") }
        XCTAssertTrue(sessions.contains("a") && sessions.contains("b"))
    }

    /// A re-rate pass must be an independent blind, not the same layout or
    /// its mirror: two sessions disagree on about HALF a large id set. (A
    /// session folded one bit at a time into the id's digest leaves only
    /// two layouts in existence — identity and mirror — so this lands on 0
    /// or 200 of 200 rather than near 100.)
    func testTwoSessionsLayTheSameFixturesOutIndependently() {
        let ids = (0..<200).map { "h\($0)" }
        let flips = ids.filter {
            RatingQueue.slot(fixtureId: $0, session: "2026-09-14-1")
                != RatingQueue.slot(fixtureId: $0, session: "2026-09-21-1")
        }.count
        XCTAssertGreaterThan(flips, 70, "\(flips)/200 fixtures moved between sessions")
        XCTAssertLessThan(flips, 130, "\(flips)/200 fixtures moved between sessions")
    }

    func testTheBlindSlotIsBalancedAcrossFixtures() {
        let slots = (0..<400).map { RatingQueue.slot(fixtureId: "h\($0)", session: "2026-09-14-1") }
        let a = slots.filter { $0 == "a" }.count
        // A coin with 400 flips: anything outside 40–60% is not a coin.
        XCTAssertGreaterThan(a, 160, "slot a \(a)/400")
        XCTAssertLessThan(a, 240, "slot a \(a)/400")
    }

    func testPairwiseQueuesOnlyFixturesBothRunsMeasuredAndDiffer() throws {
        let same = EvalCase(id: "h9", raw: "we ship the fix today", gold: "",
                            goldSource: EvalCase.historyUnratedGoldSource)
        let a = column([rated, same], outs: ["We ship the fix today.", "We ship it."],
                       formatter: "llama", runKey: "aaaaaaaaaaaa")
        let b = column([rated, same], outs: ["We ship the fix today!", "We ship it."],
                       formatter: "llama", runKey: "bbbbbbbbbbbb")
        let runA = try run([a], cases: [rated, same])
        let runB = try run([b], cases: [rated, same])
        let queue = RatingQueue.build(run: runA, fixtures: [rated, same], pairwise: runB, session: "s1")
        // h9's two outputs are identical — nothing to choose between.
        XCTAssertEqual(queue.map(\.fixture.id), ["seed-01"])
        XCTAssertEqual(queue[0].pair?.otherRunKey, "bbbbbbbbbbbb")
        XCTAssertEqual(queue[0].pair?.otherOut, "We ship the fix today!")
        let slots = queue[0].pair!.slots(queue[0].row.out)
        XCTAssertEqual(Set([slots.a, slots.b]), ["We ship the fix today.", "We ship the fix today!"])
    }

    func testAPairAlreadyJudgedIsSkippedUnlessRerate() throws {
        let a = column([rated], outs: ["We ship the fix today."], formatter: "llama", runKey: "aaaaaaaaaaaa")
        let b = column([rated], outs: ["We ship the fix today!"], formatter: "llama", runKey: "bbbbbbbbbbbb")
        let runA = try run([a], cases: [rated]), runB = try run([b], cases: [rated])
        let judged = [rating("seed-01", out: "We ship the fix today.", verdict: nil,
                             pair: Rating.Pair(aRun: "bbbbbbbbbbbb", bRun: "aaaaaaaaaaaa", slot: "a", pick: "b"))]
        XCTAssertEqual(RatingQueue.build(run: runA, fixtures: [rated], pairwise: runB, ratings: judged,
                                         session: "s1").count, 0)
        XCTAssertEqual(RatingQueue.build(run: runA, fixtures: [rated], pairwise: runB, ratings: judged,
                                         rerate: true, session: "s1").count, 1)
    }

    // MARK: - The screen

    func testTheScreenShowsRawOutputDiffAndTheDraftAnnotations() throws {
        let fixture = EvalCase(id: "h26", raw: "I don't know, try some broad benchmarking", gold: "",
                               tags: ["unrated"], goldSource: EvalCase.historyUnratedGoldSource)
        let item = RatingQueue.Item(fixture: fixture, formatter: "llama", runKey: "aaaaaaaaaaaa",
                                    row: row(fixture, "Try some broad benchmarking."), flagged: true,
                                    unrated: true, pair: nil)
        var s = session([item])
        let screen = try XCTUnwrap(s.screen)
        XCTAssertEqual(screen.mode, .triage)
        XCTAssertEqual(screen.index, 1)
        XCTAssertEqual(screen.total, 1)
        XCTAssertTrue(screen.flagged)
        XCTAssertEqual(screen.droppedSpans, ["I don't know"])
        XCTAssertTrue(screen.diff.contains("[-I-]"), screen.diff)
        XCTAssertTrue(screen.annotations.contains { $0.hasPrefix("gold  (none yet") }, "\(screen.annotations)")
        let text = screen.render()
        XCTAssertTrue(text.hasPrefix("[1/1]  h26 · llama · unknown · FLAGGED"), text)
        XCTAssertTrue(text.contains("1 ship · 2 fix · 3 wrong"), text)
    }

    func testDroppedSpansAreContiguousRunsOfTheReference() {
        XCTAssertEqual(RatingScreen.droppedSpans(reference: "I don't know, try some broad benchmarking on the tabs",
                                                 out: "Try some broad benchmarking."),
                       ["I don't know", "on the tabs"])
        XCTAssertEqual(RatingScreen.droppedSpans(reference: "we ship it", out: "We ship it."), [])
    }

    // MARK: - The key state machine

    /// The five-second path: one key, one record, next row.
    func testShipRecordsImmediatelyAndAdvances() throws {
        var s = session([item(rated, out: "We ship the fix today."), item(unrated, out: "Try some benchmarking.")])
        let effects = s.handle("1")
        guard case .write(let rating)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(rating.verdict, .ship)
        XCTAssertEqual(rating.fixtureId, "seed-01")
        XCTAssertEqual(rating.formatter, "llama")
        XCTAssertEqual(rating.runKey, "aaaaaaaaaaaa")
        XCTAssertEqual(rating.outputSha, Rating.outputSha("We ship the fix today."))
        XCTAssertEqual(rating.tags, [])
        XCTAssertEqual(rating.session, "s1")
        XCTAssertEqual(rating.msToRate, 500)         // one 500 ms tick on the clock
        XCTAssertEqual(rating.ratedAt, "2026-09-14T18:02:01Z")
        XCTAssertEqual(s.screen?.fixtureId, "h58")
        XCTAssertFalse(s.isFinished)
    }

    func testWrongOpensTheTagPickerAndEnterRecords() throws {
        var s = session([item(unrated, out: "Try some benchmarking.")])
        XCTAssertEqual(s.handle("3"), [.note("tags — a..m toggle, enter records")])
        XCTAssertEqual(s.handle("d"), [.note("+ dropped-hedge")])      // d = dropped-hedge
        XCTAssertEqual(s.handle("e"), [.note("+ reworded")])           // e = reworded (a chip here, not the editor)
        XCTAssertEqual(s.handle("e"), [.note("− reworded")])           // toggles off
        XCTAssertEqual(s.handle("z"), [.note("unknown chip key 'z' — a..m, enter to record")])
        let effects = s.handle("")
        guard case .write(let rating)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(rating.verdict, .wrong)
        XCTAssertEqual(rating.tags, ["dropped-hedge"])
        guard case .finished(let summary)? = effects.last else { return XCTFail("\(effects)") }
        XCTAssertEqual(summary.rated, 1)
        XCTAssertTrue(s.isFinished)
    }

    func testKAndCapitalKMarkDroppedSpansAtTwoWeights() throws {
        var s = session([item(unrated, out: "Try some broad benchmarking on the tabs.")])
        XCTAssertEqual(s.handle("k"), [.note("mark a span must_keep at weight 2")])
        XCTAssertEqual(s.handle("1"), [.note("+ must_keep \"I don't know\" (w2)")])
        XCTAssertEqual(s.handle("9"), [.note("no span 9 — 1 dropped")])
        XCTAssertEqual(s.handle(""), [])                                  // back to the verdict keys
        XCTAssertEqual(s.handle("K"), [.note("mark a span must_keep at weight 5")])
        XCTAssertEqual(s.handle("1"), [.note("− must_keep \"I don't know\"")])   // same span toggles off
        XCTAssertEqual(s.handle("1"), [.note("+ must_keep \"I don't know\" (w5)")])
        XCTAssertEqual(s.handle(""), [])
        let effects = s.handle("3") + s.handle("c") + s.handle("")
        guard let write = effects.compactMap({ effect -> Rating? in
            if case .write(let r) = effect { return r } else { return nil }
        }).first else { return XCTFail("\(effects)") }
        XCTAssertEqual(write.mustKeep, [EvalCase.MustKeep(span: "I don't know", weight: 5)])
        XCTAssertEqual(write.tags, ["dropped-fact"])
    }

    func testKOnARowWithNothingDroppedSaysSo() {
        var s = session([item(rated, out: "We ship the fix today.")])
        XCTAssertEqual(s.handle("k"), [.note("nothing dropped on this row to mark")])
    }

    func testEditOpensTheEditorAndStagesAGoldEdit() throws {
        var s = session([item(unrated, out: "Try some broad benchmarking on the tabs.")])
        XCTAssertEqual(s.handle("e"), [.openEditor(text: "Try some broad benchmarking on the tabs.", fixtureId: "h58")])
        // A key while the editor is open is not a verdict.
        XCTAssertEqual(s.handle("1"), [.note("waiting for the editor")])
        XCTAssertEqual(s.applyEdit("I don't know, try some broad benchmarking on the tabs."),
                       [.note("gold edit staged — press 1/2/3 to record it")])
        let effects = s.handle("2") + s.handle("j") + s.handle("")
        guard let write = effects.compactMap({ effect -> Rating? in
            if case .write(let r) = effect { return r } else { return nil }
        }).first else { return XCTFail("\(effects)") }
        XCTAssertEqual(write.goldEdit, "I don't know, try some broad benchmarking on the tabs.")
        XCTAssertEqual(write.verdict, .fix)
        XCTAssertEqual(write.tags, ["wrong-punct"])
    }

    func testAnAbandonedOrUnchangedEditLeavesTheRowAlone() {
        var s = session([item(unrated, out: "Try some benchmarking.")])
        _ = s.handle("e")
        XCTAssertEqual(s.applyEdit(nil), [.note("gold unchanged")])
        _ = s.handle("e")
        XCTAssertEqual(s.applyEdit("Try some benchmarking."), [.note("gold unchanged")])
        let effects = s.handle("1")
        guard case .write(let rating)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertNil(rating.goldEdit)
    }

    func testAlsoFineRecordsTheOutputAsAnAlternateGold() throws {
        var s = session([item(rated, out: "We ship the fix today!")])
        XCTAssertEqual(s.handle("="), [.note("marked also-fine — press 1/2/3 to record it")])
        let effects = s.handle("1")
        guard case .write(let rating)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(rating.altGold, "We ship the fix today!")
        XCTAssertEqual(rating.verdict, .ship)
    }

    func testConfirmWritesAVerdictlessRecordAndSkipWritesNothing() throws {
        var s = session([item(rated, out: "We ship the fix today."), item(unrated, out: "Try some benchmarking.")])
        let confirm = s.handle("y")
        guard case .write(let rating)? = confirm.first else { return XCTFail("\(confirm)") }
        XCTAssertNil(rating.verdict)
        XCTAssertTrue(rating.isConfirm)
        let skip = s.handle("s")
        XCTAssertFalse(skip.contains { if case .write = $0 { return true } else { return false } })
        guard case .finished(let summary)? = skip.last else { return XCTFail("\(skip)") }
        XCTAssertEqual([summary.rated, summary.skipped, summary.queued], [1, 1, 2])
        XCTAssertFalse(summary.quit)
    }

    func testQuitKeepsWhatWasWrittenAndStops() throws {
        var s = session([item(rated, out: "We ship the fix today."), item(unrated, out: "Try some benchmarking.")])
        _ = s.handle("1")
        let effects = s.handle("q")
        guard case .finished(let summary)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertTrue(summary.quit)
        XCTAssertEqual(summary.rated, 1)
        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.handle("1"), [])           // nothing after the end
    }

    /// Scripted mode's contract: input runs out, the session closes with
    /// what it has instead of blocking.
    func testEndOfInputFinishesCleanly() throws {
        var s = session([item(rated, out: "We ship the fix today."), item(unrated, out: "Try some benchmarking.")])
        _ = s.handle("1")
        let effects = s.endOfInput()
        guard case .finished(let summary)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(summary.rated, 1)
        XCTAssertTrue(summary.quit)
        XCTAssertEqual(s.endOfInput(), [])
    }

    func testAnUnknownKeyIsRefusedNotRecorded() {
        var s = session([item(rated, out: "We ship the fix today.")])
        XCTAssertEqual(s.handle("x"), [.note("unknown key 'x' — 1 ship · 2 fix · 3 wrong · ? for help")])
        XCTAssertEqual(s.handle("?").count, 1)
        XCTAssertEqual(s.handle(""), [])
        XCTAssertFalse(s.isFinished)
    }

    func testPairwiseKeysRecordTheSlotAndThePick() throws {
        let candidate = RatingQueue.PairCandidate(otherRunKey: "bbbbbbbbbbbb", otherFormatter: "llama",
                                                  otherOut: "We ship the fix today!", slot: "b")
        let item = RatingQueue.Item(fixture: rated, formatter: "llama", runKey: "aaaaaaaaaaaa",
                                    row: row(rated, "We ship the fix today."), flagged: false,
                                    unrated: false, pair: candidate)
        var s = session([item])
        XCTAssertEqual(s.screen?.mode, .pairwise)
        XCTAssertEqual(s.screen?.slotA, "We ship the fix today!")
        XCTAssertEqual(s.screen?.slotB, "We ship the fix today.")
        XCTAssertEqual(s.handle("1"), [.note("unknown key '1' — a · b · = · s · q")])
        let effects = s.handle("a")
        guard case .write(let rating)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertNil(rating.verdict)
        // `a_run` is the run that was SHOWN in slot A — here the other run,
        // since this item's output went to slot B. Recording it the other
        // way (a_run = always the primary run) makes `preference` +1 every
        // time he prefers that run, and τ_b's y column constant exactly
        // where the agreement is strongest.
        XCTAssertEqual(rating.pair, Rating.Pair(aRun: "bbbbbbbbbbbb", bRun: "aaaaaaaaaaaa", slot: "a", pick: "a"))
        // He picked slot a, which held run B.
        XCTAssertEqual(rating.pair?.pickedRun, "bbbbbbbbbbbb")
        XCTAssertEqual(rating.pair?.preference, 1)
        guard case .finished(let summary)? = effects.last else { return XCTFail("\(effects)") }
        XCTAssertEqual(summary.pairs, 1)
    }

    // MARK: - Aggregates

    func testSummaryCountsPerColumnAndItsZeroEditRate() throws {
        var s = session([item(rated, out: "We ship the fix today.", formatter: "llama"),
                         item(unrated, out: "Try some benchmarking.", formatter: "llama"),
                         item(rated, out: "we ship the fix today", formatter: "shipped")])
        _ = s.handle("1")                       // llama ship
        _ = s.handle("3"); _ = s.handle("")     // llama wrong
        let effects = s.handle("2") + s.handle("")   // shipped fix
        guard case .finished(let summary)? = effects.last else { return XCTFail("\(effects)") }
        XCTAssertEqual(summary.counts["llama"], RatingLog.Counts(ship: 1, fix: 0, wrong: 1))
        XCTAssertEqual(summary.counts["llama"]?.zeroEditRate, 50)
        XCTAssertEqual(summary.counts["shipped"]?.zeroEditRate, 0)
        let text = summary.render()
        XCTAssertTrue(text.hasPrefix("rated 3 of 3"), text)
        XCTAssertTrue(text.contains("llama      ship 1 fix 0 wrong 1 · zero-edit 50.0%"), text)
    }

    func testLogAggregatesCountRatedFixturesAndZeroEditRates() {
        let ratings = [
            rating("h1", out: "a", verdict: .ship, formatter: "llama"),
            rating("h1", out: "b", verdict: .wrong, formatter: "shipped"),
            rating("h2", out: "c", verdict: .ship, formatter: "llama"),
            rating("h9", out: "d", verdict: .ship, formatter: "llama"),   // not in the set
            rating("h2", out: "e", verdict: nil, formatter: "llama",
                   pair: Rating.Pair(aRun: "a", bRun: "b", slot: "a", pick: "b")),
        ]
        let cases = [EvalCase(id: "h1", raw: "x", gold: ""), EvalCase(id: "h2", raw: "y", gold: ""),
                     EvalCase(id: "h3", raw: "z", gold: "")]
        XCTAssertEqual(RatingLog.ratedCount(ratings, in: cases), 2)
        let ids = Set(cases.map(\.id))
        XCTAssertEqual(RatingLog.zeroEditRates(ratings, ids: ids), ["llama": 100, "shipped": 0])
        XCTAssertEqual(RatingLog.zeroEditRates(ratings), ["llama": 100, "shipped": 0])
        XCTAssertNil(RatingLog.Counts().zeroEditRate)
    }

    func testChipKeysAreTheFixedListInOrder() {
        XCTAssertEqual(RatingChips.all.count, 13)
        XCTAssertEqual(RatingChips.key(for: "answered"), "a")
        XCTAssertEqual(RatingChips.key(for: "asr-slip"), "l")
        // §7.4 check 3 gates VALID on NEGATED recall: without a chip no
        // rating could carry the label and the gate was unmeasurable.
        // Appended, so no key already in his fingers moved.
        XCTAssertEqual(RatingChips.key(for: "negated"), "m")
        XCTAssertEqual(RatingChips.chip(forKey: "c"), "dropped-fact")
        XCTAssertEqual(RatingChips.chip(forKey: "m"), "negated")
        XCTAssertNil(RatingChips.chip(forKey: "n"))
        XCTAssertNil(RatingChips.chip(forKey: "A"))
        XCTAssertEqual(RatingChips.menu(selected: ["invented"]).first,
                       "[ ] a answered  [×] b invented  [ ] c dropped-fact  [ ] d dropped-hedge  "
                       + "[ ] e reworded  [ ] f missed-filler")
    }

    // MARK: Helpers

    private func item(_ c: EvalCase, out: String, formatter: String = "llama") -> RatingQueue.Item {
        RatingQueue.Item(fixture: c, formatter: formatter, runKey: "aaaaaaaaaaaa", row: row(c, out),
                         flagged: RatingQueue.isFlagged(row(c, out)), unrated: c.isGoldFree, pair: nil)
    }
}
