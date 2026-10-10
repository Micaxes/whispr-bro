import XCTest
@testable import WhisprBroCore

/// The plan's §9 sanity formatters: ten model-free text transforms with a
/// KNOWN quality, run over every seed so the scorer is validated against
/// outputs whose grade is not in doubt — the gold itself must score 100, an
/// answer must gate, an invented numeral must gate, emptying the output
/// must fail the run. Most assertions are written against the fixture's
/// own shape; the ones that pin a COUNT or a NAMED seed over the whole set
/// are marked "recount by hand when the seed set changes" — step 5 grows
/// the seeds to 81 and must re-derive those from the fixtures, never paste
/// the scorer's output back in.
enum ReferenceFormatters {
    static func goldCopy(_ c: EvalCase) -> String { c.gold }

    /// The raw, untouched — the one formatter whose Fi is 0 wherever a
    /// removal is expected. Out == raw makes every raw↔out gate trivially
    /// silent, so the "never gated" claim lives on `echoStripped`.
    static func echo(_ c: EvalCase) -> String { c.raw }

    /// The plan's §9 "echo": the stripped raw, i.e. the bench's own input
    /// to every formatter (`FillerStripper` with the fixture's language).
    /// Real `.del` ops for the derived fillers and identical stutter runs,
    /// nothing else — so the NEGATED and length-collapse rules are
    /// exercised on an honest pass-through.
    static func echoStripped(_ c: EvalCase) -> String {
        FillerStripper(core: FillerStripper.coreFillers(for: c.language)).strip(c.raw)
    }

    /// Raw minus every core filler token (with its marks), nothing else.
    static func fillerOnly(_ c: EvalCase) -> String {
        let lexicon = Set(FillerStripper.coreFillers(for: c.language))
        return chunks(c.raw).filter { !lexicon.contains(core($0)) }.joined(separator: " ")
    }

    static func deleteAll(_ c: EvalCase) -> String { "" }

    static func answerer(_ c: EvalCase) -> String { "Sure, here's that:\n1. **" + c.raw }

    static func inventor(_ c: EvalCase) -> String { c.gold + " 140 units" }

    /// Gold minus every `must_keep` span (each removed with its marks).
    static func hedgeDropper(_ c: EvalCase) -> String {
        var out = chunks(c.gold)
        for span in c.mustKeep {
            let needle = chunks(span.span).map(core).filter { !$0.isEmpty }
            guard let range = locate(needle, in: out) else { continue }
            out.removeSubrange(range)
        }
        return out.joined(separator: " ")
    }

    /// Gold with its first NEG token removed.
    static func negator(_ c: EvalCase) -> String {
        var out = chunks(c.gold)
        guard let i = out.firstIndex(where: { Align.isNegation(core($0)) }) else { return c.gold }
        out.remove(at: i)
        return out.joined(separator: " ")
    }

    /// Gold with the first swappable pair of adjacent content words
    /// exchanged: both mark-free, neither sentence-initial, STOP, NEG, a
    /// filler or a numeral, and distinct — so the only change is word
    /// order (S = 2, no mark or casing moves).
    static func reorderer(_ c: EvalCase) -> String {
        var out = chunks(c.gold)
        let lexicon = Set(FillerStripper.coreFillers(for: c.language))
        func swappable(_ chunk: String) -> Bool {
            let word = core(chunk)
            return !word.isEmpty && chunk.allSatisfy(Align.isWordChar)
                && !Align.stopWords.contains(word) && !Align.isNegation(word) && !lexicon.contains(word)
                && !Align.canonicalTokens(chunk).contains(where: \.isNumeral)
        }
        for i in 1..<max(out.count - 1, 1) {
            guard swappable(out[i]), swappable(out[i + 1]), core(out[i]) != core(out[i - 1]),
                  core(out[i]) != core(out[i + 1]),
                  !out[i - 1].contains(where: { QualityScore.MarkClass($0)?.endsSentence == true })
            else { continue }
            out.swapAt(i, i + 1)
            return out.joined(separator: " ")
        }
        return c.gold
    }

    static let all: [(name: String, format: (EvalCase) -> String)] = [
        ("goldCopy", goldCopy), ("echo", echo), ("echoStripped", echoStripped), ("fillerOnly", fillerOnly),
        ("deleteAll", deleteAll), ("answerer", answerer), ("inventor", inventor), ("hedgeDropper", hedgeDropper),
        ("negator", negator), ("reorderer", reorderer),
    ]

    // MARK: - Whitespace-chunk helpers (test-side; no number merging)

    static func chunks(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Lowercased word core of one chunk, marks peeled — `Align.tokenize`'s
    /// normalized form for a single chunk ("" for an orphan mark).
    static func core(_ chunk: String) -> String {
        Align.tokenize(chunk).tokens.first?.normalized ?? ""
    }

    private static func locate(_ needle: [String], in chunks: [String]) -> Range<Int>? {
        let cores = chunks.map(core)
        guard !needle.isEmpty, needle.count <= cores.count else { return nil }
        for start in 0...(cores.count - needle.count)
        where needle.indices.allSatisfy({ cores[start + $0] == needle[$0] }) {
            return start..<(start + needle.count)
        }
        return nil
    }
}

final class ReferenceFormatterTests: XCTestCase {
    private func score(_ c: EvalCase, _ format: (EvalCase) -> String) -> QualityScore {
        QualityScore.score(c, out: format(c))
    }

    private func column(_ format: (EvalCase) -> String, over cases: [EvalCase] = EvalCase.seeds) -> EvalRun.Column {
        EvalRun.Column.make(formatter: "ref", level: "standard", config: EvalRun.Config(), runKey: "0",
                            observations: cases.map {
                                EvalRun.Observation(fixture: $0, stripped: $0.raw, out: format($0),
                                                    score: QualityScore.score($0, out: format($0)))
                            })
    }

    /// The plan's §3.1 example and the §4.4 forty-word hedge row, both
    /// with `must_keep`, a weight-5 fact row, plus a stutter-only raw —
    /// kept beside the seeds so the annotated pins below stay readable.
    private let annotated: [EvalCase] = [
        EvalCase(id: "agent-hedge-03",
                 raw: "I don't know, um, try some broad benchmarking on the the gravlin tabs and a and sixty two other things.",
                 gold: "I don't know, try some broad benchmarking on the gravlin tabs and 62 other things.",
                 tags: ["agent-prompt", "hedge"],
                 stutters: [EvalCase.Stutter(span: "and a and", keep: "and"), EvalCase.Stutter(span: "the the", keep: "the")],
                 mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 2)]),
        EvalCase(id: "hedge-40",
                 raw: "i don't know try some broad benchmarking on the gravlin tabs and see what comes up then write me a short summary of the three options with their tradeoffs and send it to me before the standup tomorrow morning please",
                 gold: "I don't know, try some broad benchmarking on the gravlin tabs and see what comes up, then write me a short summary of the three options with their tradeoffs and send it to me before the standup tomorrow morning, please.",
                 tags: ["hedge"],
                 mustKeep: [EvalCase.MustKeep(span: "I don't know,", weight: 2)]),
        EvalCase(id: "fact-5",
                 raw: "the glider plus a forty two on each wing and a twenty eight on each wing so find the total",
                 gold: "The glider plus a 42 on each wing and a 28 on each wing, so find the total.",
                 tags: ["numbers", "trap"],
                 mustKeep: [EvalCase.MustKeep(span: "42 on each wing", weight: 5)]),
        EvalCase(id: "stutter-only", raw: "the the whisper bro", gold: "The Whisper Bro.", tags: ["stutter"]),
    ]

    private func seed(_ id: String) -> EvalCase { EvalCase.seeds.first { $0.id == id }! }

    // MARK: - Hand-counted seed groups (recount by hand when the seed set changes)

    /// Seeds carrying a scored repair: the five annotated originals plus
    /// class 8. Any echo of the raw leaves the reparandum in place →
    /// unresolved → M = 0.75·M_text and MISSED at best.
    private let repairSeeds: Set<String> = [
        "correct-time", "correct-day", "correct-long-span", "correct-number", "premise-fillers",
        "repair-01", "repair-02", "repair-03",
    ]

    /// Seeds whose gold rewrites one raw word (class 9): an echo of the
    /// slip loses that gold word (D = 1, not novel — the slip IS a raw
    /// word), so every pass-through formatter reads OVER_EDIT_HEDGE there
    /// with M_text = 100·(1 − 2/N_g), never a gate.
    private let asrSlipSeeds: Set<String> = ["asr-slip-01", "asr-slip-02", "asr-slip-03"]

    /// Seeds whose raw minus fillers already IS the gold (modulo the
    /// unscored sentence-initial case): the three fragments that need no
    /// mark and the continuation whose Parakeet marks were already right.
    private let alreadyGoldOnceStripped: Set<String> = ["fragment-01", "fragment-03", "fragment-04", "continuation-01"]

    /// Seeds whose raw IS the gold byte-for-byte modulo initial case: the
    /// two above that carry no filler.
    private let alreadyGoldRaw: Set<String> = ["fragment-04", "continuation-01"]

    /// Seeds with a defined Fi (a derived filler or an annotated run): 20
    /// with fillers (`fillers` tag) + numbers-01 and the four class-7 seeds
    /// that carry only stutters = 24 (stutter-03 has both).
    private let fiDefinedSeeds: Set<String> = [
        "premise-fillers", "bench-standup", "bench-meeting",
        "medium-01", "medium-02", "medium-03", "medium-04", "medium-05", "medium-06",
        "question-02", "question-03", "trap-03", "hedge-03", "hedge-05", "stutter-03", "repair-03",
        "asr-slip-03", "fragment-01", "fragment-03", "continuation-02",
        "numbers-01", "stutter-01", "stutter-02", "stutter-04",
    ]

    // MARK: - §9 table, formatter by formatter

    func testGoldCopyScores100Everywhere() {
        let col = column(ReferenceFormatters.goldCopy, over: EvalCase.seeds + annotated)
        XCTAssertEqual(col.scores, EvalRun.Scores(f: 100, fi: 100, m: 100, c: 100))
        XCTAssertEqual(col.verdicts["PASS"], EvalCase.seeds.count + annotated.count)
        XCTAssertEqual(col.gate.status, .pass)
        for row in col.rows { XCTAssertEqual(row.verdict, "PASS", row.id) }
    }

    func testEchoMissesEveryRemovalAndKeepsEveryWord() {
        for c in EvalCase.seeds + annotated {
            let q = score(c, ReferenceFormatters.echo)
            if let fi = q.fillers { XCTAssertEqual(fi.score, 0, c.id) }
            // A control echoed is PUNCT at worst (words untouched → M 100).
            if c.isControl {
                XCTAssertTrue([.pass, .punct].contains(q.verdict), "\(c.id) \(q.verdict)")
                XCTAssertEqual(q.meaning?.score, 100, c.id)
            }
            if asrSlipSeeds.contains(c.id) {
                // The slip echoed: one gold word lost, nothing novel.
                XCTAssertEqual(q.verdict, .overEditHedge, c.id)
                XCTAssertEqual(q.meaning?.lost, 1, c.id)
                XCTAssertEqual(q.meaning?.novel, 0, c.id)
                XCTAssertEqual(q.gates, [], c.id)
            } else if !c.expectedFillers.isEmpty || !c.expectedStutters.isEmpty || repairSeeds.contains(c.id) {
                // A fixture expecting a removal or a resolution is MISSED.
                XCTAssertEqual(q.verdict, .missed, c.id)
            }
            if repairSeeds.contains(c.id) {
                XCTAssertEqual(q.meaning?.unresolvedRepairs.count, 1, c.id)
                XCTAssertEqual(q.meaning!.score, 75, accuracy: 1e-9, c.id)   // 0.75 · 100
            }
        }
        // Hand-counted — recount by hand when the seed set changes: the 24
        // Fi-defined seeds minus asr-slip-03 (23) plus the six repair seeds
        // with no filler → 29 MISSED; the three slips → OVER_EDIT_HEDGE;
        // fragment-04 and continuation-01 are already their gold → PASS;
        // the other 47 carry missing or wrong marks → PUNCT. M: 8 repair
        // echoes at 75 and the slips at 93.5 / 93.5 / 94.3 →
        // (8100 − 200 − 18.6) / 81 = 97.3.
        let col = column(ReferenceFormatters.echo)
        XCTAssertEqual(col.verdicts["MISSED"], 29)
        XCTAssertEqual(col.verdicts["OVER_EDIT_HEDGE"], 3)
        XCTAssertEqual(col.verdicts["PASS"], 2)
        XCTAssertEqual(col.verdicts["PUNCT"], 47)
        XCTAssertEqual(col.scores.fi, 0)
        XCTAssertEqual(col.scores.m, 97.3)
        XCTAssertEqual(col.gate.status, .pass)
        for id in alreadyGoldRaw { XCTAssertEqual(score(seed(id), ReferenceFormatters.echo).verdict, .pass, id) }
    }

    func testEchoStrippedIsTheBenchInputAndNeverGates() {
        // §9's echo row proper: the stripper's own output, with real `.del`
        // ops on every derived filler and identical run, is never ANSWERED
        // / INVENTED / NEGATED and never collapses — the gates must not
        // false-fire on an honest pass-through.
        for c in EvalCase.seeds + annotated {
            let q = score(c, ReferenceFormatters.echoStripped)
            XCTAssertFalse(q.isGated, "\(c.id) \(q.triggerNames)")
            XCTAssertEqual(q.contentGuard.triggers, [], c.id)
            XCTAssertEqual(q.meaning?.novel, 0, c.id)
            if asrSlipSeeds.contains(c.id) {
                XCTAssertEqual(q.verdict, .overEditHedge, c.id)
                XCTAssertEqual(q.meaning!.score, 100 * (1 - 2 / Double(q.meaning!.goldWords)), accuracy: 1e-9, c.id)
            } else {
                XCTAssertTrue([.pass, .punct, .missed].contains(q.verdict), "\(c.id) \(q.verdict)")
                XCTAssertEqual(q.meaning?.score, repairSeeds.contains(c.id) ? 75 : 100, c.id)
            }
        }
        // The derived removals ARE the stripper's contract, so Fi is 100
        // wherever only fillers and identical runs are expected; the five
        // annotated runs it cannot see (and a and ×2, the like the, then
        // then then, my l laptop) leave numbers-01 / stutter-02 at 0 and
        // stutter-01 / -03 / -04 at 50 → (19·100 + 150) / 24 = 85.4. Those
        // five plus the 8 repair echoes → 13 MISSED; the 3 slips → HEDGE;
        // the 4 seeds that are their gold once stripped → PASS; 61 PUNCT.
        // Recount by hand when the seed set changes.
        let col = column(ReferenceFormatters.echoStripped)
        XCTAssertEqual(col.verdicts["PUNCT"], 61)
        XCTAssertEqual(col.verdicts["MISSED"], 13)
        XCTAssertEqual(col.verdicts["OVER_EDIT_HEDGE"], 3)
        XCTAssertEqual(col.verdicts["PASS"], 4)
        XCTAssertEqual(col.scores.fi, 85.4)
        XCTAssertEqual(col.scores.m, 97.3)
        XCTAssertEqual(col.gate.status, .pass)
        for id in alreadyGoldOnceStripped { XCTAssertEqual(score(seed(id), ReferenceFormatters.echoStripped).verdict, .pass, id) }
        XCTAssertEqual(ReferenceFormatters.echoStripped(seed("bench-standup")),
                       "hey can you send me the updated design doc before standup tomorrow morning thanks")
        XCTAssertEqual(score(seed("stutter-01"), ReferenceFormatters.echoStripped).fillers?.missed, ["the like the"])
        XCTAssertEqual(score(seed("stutter-04"), ReferenceFormatters.echoStripped).fillers?.missed, ["my l laptop"])
        // The annotated non-identical run ("and a and") is beyond the
        // stripper: um IS stripped and "the the" collapsed, so 2 of 3:
        // "and a and" missed → 66.7, MISSED.
        let hedge = score(annotated[0], ReferenceFormatters.echoStripped)
        XCTAssertEqual(hedge.fillers?.credited, 2)
        XCTAssertEqual(hedge.fillers?.expected, 3)
        XCTAssertEqual(hedge.fillers?.missed, ["and a and"])
        XCTAssertEqual(hedge.verdict, .missed)
        XCTAssertEqual(score(annotated[3], ReferenceFormatters.echoStripped).fillers?.score, 100)
    }

    func testFillerOnlyCreditsFillersNotStutters() {
        for c in EvalCase.seeds + annotated {
            let q = score(c, ReferenceFormatters.fillerOnly)
            XCTAssertFalse(q.isGated, c.id)
            // M_text ≥ 90 everywhere (a slip's echo loses one word of ≥ 22);
            // the repair blend takes its quarter where a repair is scored.
            XCTAssertGreaterThanOrEqual(q.meaning!.text, 90, c.id)
            if repairSeeds.contains(c.id) {
                XCTAssertEqual(q.meaning!.score, 0.75 * q.meaning!.text, accuracy: 1e-9, c.id)
            } else {
                XCTAssertGreaterThanOrEqual(q.meaning!.score, 90, c.id)
            }
            let fillers = c.expectedFillers.count, stutters = c.expectedStutters.count
            if fillers > 0, stutters == 0 { XCTAssertEqual(q.fillers?.score, 100, c.id) }
            if fillers == 0, stutters > 0 { XCTAssertEqual(q.fillers?.score, 0, c.id) }
            if fillers + stutters > 0 {
                // Credit is exactly the filler share of E.
                XCTAssertEqual(q.fillers?.credited, fillers, c.id)
                XCTAssertEqual(q.fillers?.expected, fillers + stutters, c.id)
            }
            if asrSlipSeeds.contains(c.id) {
                XCTAssertEqual(q.verdict, .overEditHedge, c.id)
            } else if alreadyGoldOnceStripped.contains(c.id) {
                XCTAssertEqual(q.verdict, .pass, c.id)
            } else {
                XCTAssertTrue([.punct, .missed].contains(q.verdict), "\(c.id) \(q.verdict)")
            }
        }
        // premise-fillers: 5 fillers, no stutter → Fi 100; F: comma on the
        // inserted "2," is a FP (0), stops 2/2 (1) → P 0.5; C: the period
        // of "p.m." is an abbreviation's, so gold's "Yeah" is a scored
        // position and the never-capitalizing dropper misses it → 10/11;
        // T 1 → F = 25 + 27.3 + 20 = 72.3. The reparandum "2" is still
        // there → unresolved → M = 0.75·100 = 75 → C_i = 21.7 + 20 + 37.5
        // = 79.2, MISSED. bench-standup: um credited, "the the" kept → 1/2
        // → MISSED.
        let premise = score(seed("premise-fillers"), ReferenceFormatters.fillerOnly)
        XCTAssertEqual(premise.fillers?.score, 100)
        XCTAssertEqual(premise.formatting!.casing!, 10.0 / 11.0, accuracy: 1e-9)
        XCTAssertEqual(premise.formatting!.score, 72.3, accuracy: 0.05)
        XCTAssertEqual(premise.meaning?.unresolvedRepairs, ["2"])
        XCTAssertEqual(premise.meaning!.score, 75, accuracy: 1e-9)
        XCTAssertEqual(premise.composite!, 79.2, accuracy: 0.05)
        XCTAssertEqual(premise.verdict, .missed)
        let standup = score(seed("bench-standup"), ReferenceFormatters.fillerOnly)
        XCTAssertEqual(standup.fillers?.score, 50)
        XCTAssertEqual(standup.verdict, .missed)
        XCTAssertEqual(ReferenceFormatters.fillerOnly(seed("bench-meeting")),
                       "let's move the meeting to three pm and remind me to book the flight to berlin i think it's cheaper if we fly out on a tuesday")
        // Hand-counted — recount by hand when the seed set changes: the 8
        // repair seeds and the 6 stutter-bearing ones (bench-standup,
        // numbers-01, stutter-01…04) → 14 MISSED; 3 slips → HEDGE; 4
        // already-gold → PASS; 60 PUNCT.
        let col = column(ReferenceFormatters.fillerOnly)
        XCTAssertEqual(col.verdicts["MISSED"], 14)
        XCTAssertEqual(col.verdicts["OVER_EDIT_HEDGE"], 3)
        XCTAssertEqual(col.verdicts["PASS"], 4)
        XCTAssertEqual(col.verdicts["PUNCT"], 60)
    }

    func testDeleteAllFailsTheRunWithCompositeZero() {
        // "≈ 0", not 0, for three seeds the plan's line does not foresee:
        // the all-filler seed (fragment-01, gold "") is a PASS at 100, and
        // the two mark-free fragments earn F's terminal credit for none ==
        // none with M = 0 — fragment-04 ("But": only T defined → F 100, Fi
        // undefined → C = 0.375·100 = 37.5) and fragment-03 ("Okay, and
        // the": comma 0/1, T 1 → F = 100·0.2/0.7 = 28.6, Fi 0 → C = 0.3·28.6
        // = 8.6). Column mean C = (100 + 37.5 + 8.6) / 85 = 1.7; M = 100 /
        // 85 = 1.2.
        let col = column(ReferenceFormatters.deleteAll, over: EvalCase.seeds + annotated)
        XCTAssertEqual(col.scores.c, 1.7)
        XCTAssertEqual(col.scores.m, 1.2)
        XCTAssertEqual(col.gate.status, .fail)
        let nonZero: [String: Double] = ["fragment-01": 100, "fragment-04": 37.5, "fragment-03": 8.6]
        // OVER_EDIT_FACT wherever the length collapse can fire (≥ 6 raw
        // atoms) or the deleted share can (≥ 6 gold atoms); under both
        // floors the empty output is an OVER_EDIT_HEDGE at M = 0.
        // Hand-counted — recount by hand when the seed set changes: seven
        // seeds sit under both floors — cue-is-content (5 / 5),
        // comma-leading (5 / 5), comma-double (4 / 4), comma-terminal
        // (3 / 3), fragment-02 (1 / 1), fragment-03 (4 / 3), fragment-04
        // (1 / 1) — plus stutter-only (4 / 3) among the annotated.
        let hedged: Set<String> = ["cue-is-content", "comma-leading", "comma-double", "comma-terminal",
                                   "fragment-02", "fragment-03", "fragment-04", "stutter-only"]
        for c in EvalCase.seeds + annotated {
            let q = score(c, ReferenceFormatters.deleteAll)
            if c.id == "fragment-01" {
                XCTAssertEqual(q.verdict, .pass)
                XCTAssertEqual(q.composite, 100)
                continue
            }
            XCTAssertEqual(q.composite!, nonZero[c.id] ?? 0, accuracy: 0.05, c.id)
            XCTAssertEqual(q.meaning?.score, 0, c.id)
            XCTAssertEqual(q.verdict, hedged.contains(c.id) ? .overEditHedge : .overEditFact, c.id)
        }
        let seedsOnly = column(ReferenceFormatters.deleteAll)
        XCTAssertEqual(seedsOnly.verdicts["OVER_EDIT_FACT"], 73)
        XCTAssertEqual(seedsOnly.verdicts["OVER_EDIT_HEDGE"], 7)
        XCTAssertEqual(seedsOnly.verdicts["PASS"], 1)
        XCTAssertEqual(seedsOnly.scores.c, 1.8)   // (100 + 37.5 + 8.6) / 81
        // An all-filler gold-free raw is the other place deleteAll is right.
        let uh = QualityScore.score(EvalCase(id: "uh", raw: "Uh", gold: "", goldSource: EvalCase.historyUnratedGoldSource), out: "")
        XCTAssertEqual(uh.fillers?.score, 100)
        XCTAssertEqual(uh.verdict, .unrated)
    }

    func testAnswererIsAnsweredEverywhere() {
        let col = column(ReferenceFormatters.answerer, over: EvalCase.seeds + annotated)
        XCTAssertEqual(col.verdicts["ANSWERED"], EvalCase.seeds.count + annotated.count)
        XCTAssertEqual(col.gate.answered, EvalCase.seeds.count + annotated.count)
        XCTAssertEqual(col.scores.c, 0)
        XCTAssertEqual(col.gate.status, .fail)
        // The opener echo is read against the WHOLE raw since task-023's fix
        // round — a two-token window refused the cleanups that move the
        // speaker's OWN opener to the front — so the four seeds that say
        // "make sure" no longer charge the answerer's "Sure,". That is the
        // accepted cost of the whole-raw reading, and it costs nothing here:
        // those rows gate on the other two triggers and the verdict is
        // ANSWERED on every row either way.
        let saysSure = Set((EvalCase.seeds + annotated)
            .filter { $0.raw.lowercased().contains("sure") }.map(\.id))
        XCTAssertEqual(saysSure, ["bench-code", "long-02", "asr-slip-02", "latency-150"])
        for row in col.rows {
            XCTAssertTrue(row.triggers.contains("multi-line"), row.id)
            XCTAssertTrue(row.triggers.contains("markdown"), row.id)
            XCTAssertEqual(row.triggers.contains("opener"), !saysSure.contains(row.id), row.id)
        }
    }

    func testInventorIsInventedEverywhere() {
        let col = column(ReferenceFormatters.inventor, over: EvalCase.seeds + annotated)
        XCTAssertEqual(col.verdicts["INVENTED"], EvalCase.seeds.count + annotated.count)
        XCTAssertEqual(col.scores.c, 0)
        XCTAssertEqual(col.gate.status, .fail)
        for row in col.rows {
            XCTAssertEqual(row.novelNumerals, 1, row.id)
            XCTAssertEqual(row.verdict, "INVENTED", row.id)
            // The numeral rule always fires; the share rule joins it on
            // short outputs. The raw↔out alignment pairs the appended atoms
            // with a dropped reparandum as substitutions, but the governed
            // word is not among the paired out tokens, so NEGATED stays
            // silent.
            XCTAssertTrue(row.triggers.contains("novel-numeral"), row.id)
            XCTAssertFalse(row.triggers.contains("negation-dropped"), row.id)
        }
    }

    func testHedgeDropperLandsOnTheAnnotatedWeight() {
        // Seeds with no `must_keep` are the gold copy under the dropper;
        // the five class-5 seeds (w = 2) land on OVER_EDIT_HEDGE and the
        // one fact span (numbers-03, w = 5) gates. Hand-derived M:
        //   hedge-01  25 words, 3 lost → 100·(1 − 6/25) − 8 = 68
        //   hedge-02  40 words, 3 lost → 100·(1 − 6/40) − 8 = 77 (the §9 row)
        //   hedge-03  38 words, 2 lost, 2 spans → 100·(1 − 4/38) − 16 = 73.5
        //   hedge-04  56 words, 7 lost, 3 spans → 100·(1 − 14/56) − 24 = 51
        //   hedge-05  60 words, 8 lost, 2 spans → 100·(1 − 16/60) − 16 = 57.3
        let expectedM: [String: Double] = ["hedge-01": 68, "hedge-02": 77, "hedge-03": 73.5, "hedge-04": 51, "hedge-05": 57.3]
        for c in EvalCase.seeds {
            let q = score(c, ReferenceFormatters.hedgeDropper)
            if c.mustKeep.isEmpty {
                XCTAssertEqual(ReferenceFormatters.hedgeDropper(c), c.gold, c.id)
                XCTAssertEqual(q.verdict, .pass, c.id)
            } else if c.id == "numbers-03" {
                XCTAssertEqual(q.verdict, .overEditFact)
                XCTAssertEqual(q.goldTriggers, [.mustKeepFact])   // "or" is STOP: 2 of 30 stays under the share
                XCTAssertEqual(q.composite, 0)
            } else {
                XCTAssertEqual(q.verdict, .overEditHedge, c.id)
                XCTAssertEqual(q.goldTriggers, [], c.id)
                XCTAssertEqual(q.meaning?.factLoss, 0, c.id)
                XCTAssertEqual(q.meaning!.score, expectedM[c.id]!, accuracy: 0.05, c.id)
                XCTAssertEqual(q.meaning?.missedMustKeep.count, c.mustKeep.count, c.id)
            }
        }
        XCTAssertEqual(ReferenceFormatters.hedgeDropper(seed("hedge-02")),
                       "have a look at the Fleetwing cache keys and see what changed, then write up the two options with their tradeoffs in a few lines and drop it in the channel before the standup tomorrow morning, please.")
        // hedge-03's dropped "Yeah," was the filler's previous neighbour,
        // so its "um" removal earns no Fi credit either.
        XCTAssertEqual(score(seed("hedge-03"), ReferenceFormatters.hedgeDropper).fillers?.score, 0)
        let q40 = score(annotated[1], ReferenceFormatters.hedgeDropper)
        XCTAssertEqual(ReferenceFormatters.hedgeDropper(annotated[1]),
                       "try some broad benchmarking on the gravlin tabs and see what comes up, then write me a short summary of the three options with their tradeoffs and send it to me before the standup tomorrow morning, please.")
        XCTAssertEqual(q40.verdict, .overEditHedge)
        XCTAssertEqual(q40.meaning!.score, 77, accuracy: 0.05)   // 100·(1 − 6/40) − 8
        // The §3.1 example's hedge is 3 of 15 gold words (0.2 as raw D),
        // but an annotated w = 2 span is stance by declaration: its loss
        // never feeds the deleted-share gate, so the verdict is
        // OVER_EDIT_HEDGE exactly where §9 puts it — M = 100·(1 − 6/15)
        // − 8 = 52.
        let example = score(annotated[0], ReferenceFormatters.hedgeDropper)
        XCTAssertEqual(example.verdict, .overEditHedge)
        XCTAssertEqual(example.goldTriggers, [])
        XCTAssertEqual(example.meaning?.factLoss, 0)
        XCTAssertEqual(example.meaning!.score, 52, accuracy: 0.05)
        XCTAssertEqual(example.meaning?.missedMustKeep.map(\.span), ["I don't know,"])
        // A w = 5 span: the fact trigger, joined by the share (3 content
        // words of 18 — "on" is STOP).
        let fact = score(annotated[2], ReferenceFormatters.hedgeDropper)
        XCTAssertEqual(fact.verdict, .overEditFact)
        XCTAssertEqual(fact.meaning?.factLoss, 3)
        XCTAssertEqual(fact.goldTriggers, [.mustKeepFact, .deletedShare])
        XCTAssertEqual(fact.composite, 0)
    }

    func testNegatorIsNegatedExactlyWhereAContentWordFollows() {
        // Golds holding a NEG token followed by a content word that the
        // raw↔out alignment still sees: hand-listed — recount by hand when
        // the seed set changes. The rest are untouched by the negator (no
        // NEG in gold) → PASS; repair-02's "no wait" is a NEG in raw only,
        // and its governed "wait" never survives, so it does not fire.
        let negated: Set<String> = [
            "bench-code",
            "long-01", "long-03", "long-04", "long-05", "long-06", "long-07", "long-08", "long-09", "long-10",
            "medium-04", "question-01", "question-02", "trap-02", "trap-03", "trap-04",
            "hedge-01", "hedge-02", "hedge-04", "hedge-05", "cue-control-01", "cue-control-02",
            "register-notes", "register-browser",
            "latency-030", "latency-060", "latency-100", "latency-150",
            "agent-hedge-03", "hedge-40",
        ]
        XCTAssertEqual(negated.count, 30)
        for c in EvalCase.seeds + annotated {
            let q = score(c, ReferenceFormatters.negator)
            if negated.contains(c.id) {
                XCTAssertEqual(q.verdict, .negated, c.id)
                XCTAssertEqual(q.triggerNames, ["negation-dropped"], c.id)
            } else {
                XCTAssertEqual(ReferenceFormatters.negator(c), c.gold, c.id)
                XCTAssertEqual(q.verdict, .pass, c.id)
            }
        }
        // "don't know" dropped WITH its "know" (the whole hedge) is an
        // over-edit, not a flip — the same fixture under the hedge dropper
        // stays ungated (asserted above); under the negator only "don't"
        // goes and "know" survives → NEGATED.
        let hedge = score(annotated[0], ReferenceFormatters.negator)
        XCTAssertEqual(ReferenceFormatters.negator(annotated[0]),
                       "I know, try some broad benchmarking on the gravlin tabs and 62 other things.")
        XCTAssertEqual(hedge.verdict, .negated)
        XCTAssertEqual(ReferenceFormatters.negator(seed("hedge-01")),
                       "I know, maybe dig into the Orbitr tab groups thing first and see what actually comes back before we change the sync at all.")
    }

    func testReordererIsSubstitutionsOnlyAndReworded() {
        // Hand-counted seeds with NO swappable pair (first mark-free,
        // non-initial pair of distinct content words): the eight short
        // originals and the four fragments; every other seed swaps and
        // reads REWORDED with S = 2 and nothing else moving. Named seeds
        // and the two exact outputs below — recount by hand when the seed
        // set changes.
        let unswappable: Set<String> = ["correct-day", "correct-number", "cap-mid", "abbrev-eg", "abbrev-us",
                                        "comma-double", "comma-terminal", "punct-double",
                                        "fragment-01", "fragment-02", "fragment-03", "fragment-04",
                                        "stutter-only"]
        for c in EvalCase.seeds + annotated {
            let out = ReferenceFormatters.reorderer(c)
            let q = QualityScore.score(c, out: out)
            if out == c.gold {
                XCTAssertTrue(unswappable.contains(c.id), c.id)
                XCTAssertEqual(q.verdict, .pass, c.id)
                continue
            }
            XCTAssertFalse(unswappable.contains(c.id), c.id)
            XCTAssertEqual(q.verdict, .reworded, c.id)
            XCTAssertEqual(q.gates, [], c.id)
            XCTAssertEqual([q.subs, q.dels, q.ins], [2, 0, 0], c.id)
            // Both swapped words are raw words — except where the swap
            // moves a gold-fixed product name (asr-slip-02 / -03: "fleet
            // wing" and "orbiter" are the raw forms), which counts once.
            XCTAssertEqual(q.subsFromRaw, ["asr-slip-02", "asr-slip-03"].contains(c.id) ? 1 : 2, c.id)
            XCTAssertEqual(q.meaning?.lost, 0, c.id)
            XCTAssertEqual(q.meaning?.novel, 0, c.id)
            XCTAssertEqual(q.formatting?.score, 100, c.id)
            XCTAssertEqual(q.continuity?.wordErrors, 2, c.id)
        }
        XCTAssertEqual(ReferenceFormatters.reorderer(EvalCase.seeds[0]), "Let's at meet 3.")
        XCTAssertEqual(ReferenceFormatters.reorderer(seed("correct-day")), "Send it Tuesday.")
        // A swap inside a `must_keep` span would read as a missed span; the
        // hedge seeds are worded so the first swappable pair sits outside.
        XCTAssertEqual(ReferenceFormatters.reorderer(seed("hedge-01")),
                       "I don't know, dig maybe into the Orbitr tab groups thing first and see what actually comes back before we change the sync at all.")
    }

    // MARK: - Ordering (§9)

    func testCompositeOrderingOfTheSanityFormatters() {
        // By means over the 81 seeds: goldCopy > echoStripped ≥ fillerOnly
        // ≥ echo > hedgeDropper > {inventor = answerer} = 0 ≈ deleteAll.
        // Two honest caveats the §9 line elides: the hedge link is pinned
        // over the six seeds that CARRY a `must_keep` span (elsewhere the
        // dropper is the gold copy, which lifts its 81-seed mean to 96.8 —
        // above every pass-through — without saying anything about hedge
        // handling); and deleteAll is 1.8, not 0 (the all-filler seed's
        // empty gold, and the terminal credit on the two mark-free
        // fragments — see testDeleteAllFailsTheRunWithCompositeZero).
        // Hand-derived over the must_keep seeds:
        // echo 83.1 / 73.5 / 65.0 / 88.3 / 65.8 / 81.8 (mean 76.3) vs
        // hedgeDropper 70.6 / 83.8 / 64.2 / 67.0 / 57.8 / 0 (mean 57.2).
        let means = Dictionary(uniqueKeysWithValues: ReferenceFormatters.all.map { ($0.name, column($0.format).scores.c!) })
        XCTAssertEqual(means["goldCopy"], 100)
        XCTAssertGreaterThan(means["goldCopy"]!, means["echoStripped"]!)
        XCTAssertGreaterThanOrEqual(means["echoStripped"]!, means["fillerOnly"]!)
        XCTAssertGreaterThanOrEqual(means["fillerOnly"]!, means["echo"]!)
        XCTAssertGreaterThan(means["echo"]!, 0)
        XCTAssertEqual(means["inventor"], 0)
        XCTAssertEqual(means["answerer"], 0)
        XCTAssertEqual(means["deleteAll"], 1.8)
        XCTAssertEqual(means["hedgeDropper"], 96.8)
        XCTAssertLessThan(means["hedgeDropper"]!, means["goldCopy"]!)
        // Per fixture, fillerOnly never trails echo.
        for c in EvalCase.seeds + annotated {
            XCTAssertGreaterThanOrEqual(score(c, ReferenceFormatters.fillerOnly).composite!,
                                        score(c, ReferenceFormatters.echo).composite!, c.id)
        }
        let withSpans = EvalCase.seeds.filter { !$0.mustKeep.isEmpty }
        XCTAssertEqual(withSpans.map(\.id), ["hedge-01", "hedge-02", "hedge-03", "hedge-04", "hedge-05", "numbers-03"])
        let hedgedSeeds = column(ReferenceFormatters.hedgeDropper, over: withSpans).scores.c!
        let echoedSeeds = column(ReferenceFormatters.echo, over: withSpans).scores.c!
        XCTAssertEqual(echoedSeeds, 76.3, accuracy: 0.1)
        XCTAssertEqual(hedgedSeeds, 57.2, accuracy: 0.05)
        XCTAssertGreaterThan(echoedSeeds, hedgedSeeds)
        XCTAssertGreaterThan(hedgedSeeds, 0)
        // …and the same link over the annotated set: echo 77.5 / 73.75 /
        // 73.75 / 50 (mean 68.75) vs hedgeDropper 61.8 / 83.75 / 0 / 100
        // (mean 61.4).
        let hedged = column(ReferenceFormatters.hedgeDropper, over: annotated).scores.c!
        XCTAssertEqual(column(ReferenceFormatters.echo, over: annotated).scores.c!, 68.8, accuracy: 0.05)
        XCTAssertEqual(hedged, 61.4, accuracy: 0.05)
        XCTAssertGreaterThan(column(ReferenceFormatters.echo, over: annotated).scores.c!, hedged)
        // The status line the bench will print, per formatter.
        XCTAssertEqual(column(ReferenceFormatters.goldCopy).gate.status, .pass)
        XCTAssertEqual(column(ReferenceFormatters.echo).gate.status, .pass)
        for name in ["deleteAll", "answerer", "inventor"] {
            XCTAssertEqual(column(ReferenceFormatters.all.first { $0.name == name }!.format).gate.status, .fail, name)
        }
    }

    // MARK: - Properties (§9)

    func testANovelNumeralNeverRaisesC() {
        for c in EvalCase.seeds + annotated {
            for (name, format) in ReferenceFormatters.all where name != "deleteAll" && name != "answerer" {
                let out = format(c)
                let before = QualityScore.score(c, out: out).composite!
                let after = QualityScore.score(c, out: out + " 114").composite!
                XCTAssertLessThanOrEqual(after, before, "\(c.id) \(name)")
                XCTAssertEqual(after, 0, "\(c.id) \(name)")   // one numeral gates outright
            }
        }
    }

    func testRemovingAMustKeepSpanNeverRaisesC() {
        // The pairs actually compared are pinned as a set, so a tokenizer
        // or seed change that stops the dropper finding its spans cannot
        // turn this into a test that asserts nothing. Hand-derived: every
        // span is in its gold by lint (9 goldCopy pairs); every span is
        // written in raw surface form too — the seeds spell "790 or 800"
        // and "soon to be 20," as digits in raw — except fact-5, whose
        // "42 on each wing" is "forty two" in its raw, and the chunk-level
        // dropper is number-form naive: 8 echo pairs.
        var compared: Set<String> = []
        for c in EvalCase.seeds + annotated where !c.mustKeep.isEmpty {
            for (name, format) in [("goldCopy", ReferenceFormatters.goldCopy), ("echo", ReferenceFormatters.echo)] {
                let out = format(c)
                let dropped = ReferenceFormatters.hedgeDropper(EvalCase(id: c.id, raw: c.raw, gold: out, mustKeep: c.mustKeep))
                guard dropped != out else { continue }
                compared.insert("\(name):\(c.id)")
                XCTAssertLessThanOrEqual(QualityScore.score(c, out: dropped).composite!,
                                         QualityScore.score(c, out: out).composite!, "\(c.id) \(name)")
            }
        }
        let spanned = ["hedge-01", "hedge-02", "hedge-03", "hedge-04", "hedge-05", "numbers-03",
                       "agent-hedge-03", "hedge-40", "fact-5"]
        XCTAssertEqual(compared, Set(spanned.map { "goldCopy:" + $0 } + spanned.filter { $0 != "fact-5" }.map { "echo:" + $0 }))
        XCTAssertEqual(compared.count, 17)
    }

    func testCasingOnlyEditsNeverMoveFi() {
        // Only fixtures with a defined Fi can carry the property; count
        // them so the coverage cannot silently drop to nil == nil as the
        // seed set changes (24 seeds + 2 annotated define Fi today).
        var contributing: Set<String> = []
        for c in EvalCase.seeds + annotated {
            for (name, format) in ReferenceFormatters.all {
                let out = format(c)
                guard let base = QualityScore.score(c, out: out).fillers?.score else { continue }
                contributing.insert(c.id)
                XCTAssertEqual(QualityScore.score(c, out: out.uppercased()).fillers?.score, base, "\(c.id) \(name)")
                XCTAssertEqual(QualityScore.score(c, out: out.lowercased()).fillers?.score, base, "\(c.id) \(name)")
            }
        }
        XCTAssertEqual(contributing, fiDefinedSeeds.union(["agent-hedge-03", "stutter-only"]))
        XCTAssertEqual(contributing.count, 26)
    }

    func testSentenceInitialRecasingNeverMovesCOrF() {
        // Lowercase every sentence-initial word of the gold: the casing
        // component and F are untouched, c_initial drops, verdict PASS.
        // Sentence ends are read with the scorer's own rule (a dotted
        // abbreviation's period is not one: "3 p.m. Yeah." keeps its Yeah).
        for c in EvalCase.seeds + annotated {
            var chunks = ReferenceFormatters.chunks(c.gold)
            for i in chunks.indices
            where i == 0 || Align.tokenize(chunks[i - 1]).tokens.first.map(QualityScore.endsSentence) == true {
                chunks[i] = chunks[i].lowercased()
            }
            let recased = chunks.joined(separator: " ")
            let q = QualityScore.score(c, out: recased)
            let gold = QualityScore.score(c, out: c.gold)
            XCTAssertEqual(q.formatting?.score, 100, c.id)
            XCTAssertEqual(q.formatting?.casing, gold.formatting?.casing, c.id)
            XCTAssertEqual(q.composite, gold.composite, c.id)
            XCTAssertEqual(q.verdict, .pass, c.id)
            if recased != c.gold { XCTAssertLessThan(q.formatting!.cInitial!, 1, c.id) }
        }
    }

    func testFIsInvariantUnderWordEditsThatKeepMarksKeyed() {
        // An unmarked novel word inserted after the first chunk (before it
        // on a one-chunk gold, so it never becomes the terminal word; the
        // empty gold gets it alone): every gold word still hits with its
        // marks and case, so F stays 100 while M pays for the novel token.
        // Only F and the novelty charge are the property — where the word
        // lands inside a must_keep span, or the raw↔out alignment pairs it
        // with a dropped reparandum, the verdict is that rule's.
        for c in EvalCase.seeds + annotated {
            var chunks = ReferenceFormatters.chunks(c.gold)
            chunks.insert("zorblat", at: chunks.count >= 2 ? 1 : 0)
            let q = QualityScore.score(c, out: chunks.joined(separator: " "))
            XCTAssertEqual(q.formatting?.score, 100, c.id)
            XCTAssertEqual(q.hits, Align.canonicalTokens(c.gold).count, c.id)
            XCTAssertEqual(q.ins, 1, c.id)
            XCTAssertEqual(q.meaning?.novel, 1, c.id)
            XCTAssertLessThan(q.meaning!.text, 100, c.id)
        }
        // On a plain fixture the ladder reads REWORDED.
        XCTAssertEqual(QualityScore.score(seed("cue-is-content"), out: "I zorblat actually enjoyed the movie.").verdict, .reworded)
    }
}
