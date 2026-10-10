import XCTest
@testable import WhisprBroCore

/// `history-export`'s pure half (plan §3.3): the register map, one fixture
/// per stored row read back through a temp `HistoryStore` (the
/// HistoryStoreTests pattern — never the live file), `--since` /
/// `--min-words`, the file shape, and the merge rule: a re-run refreshes
/// what the binary produced and never overwrites a rating. Every field is
/// hand-pinned; dates run through a fixed time zone so the note is the
/// same on every machine.
final class HistoryExportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-07T03:00:00Z — early enough that the same instant is still
    /// the 6th west of Greenwich.
    private let epoch = Date(timeIntervalSince1970: 1_788_750_000)

    private func makeStore() throws -> HistoryStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-export-test-\(UUID().uuidString).sqlite")
        return try HistoryStore(path: url)
    }

    private func record(_ raw: String, formatted: String? = nil, bundleId: String? = "com.cmuxterm.app",
                        appName: String? = "cmux", formatMs: Int? = 1073, language: String? = nil,
                        at: TimeInterval = 0) -> HistoryRecord {
        HistoryRecord(
            createdAt: epoch.addingTimeInterval(at),
            appBundleId: bundleId, appName: appName,
            rawText: raw, formattedText: formatted,
            audioMs: 5, asrMs: 90, formatMs: formatMs, insertMs: 50, totalMs: 445,
            durationMs: nil, language: language)
    }

    // MARK: - Register map

    func testRegisterMapMatchesHisHistory() {
        XCTAssertEqual(HistoryExport.register(bundleId: "com.cmuxterm.app"), .unknown)
        XCTAssertEqual(HistoryExport.register(bundleId: "com.google.Chrome"), .browser)
        XCTAssertEqual(HistoryExport.register(bundleId: "com.apple.Notes"), .notes)
        XCTAssertEqual(HistoryExport.register(bundleId: "net.whatsapp.WhatsApp"), .messaging)
        XCTAssertEqual(HistoryExport.register(bundleId: nil), .unknown)
        XCTAssertEqual(HistoryExport.register(bundleId: "com.example.never-seen"), .unknown)
        // The app's own map still applies underneath the overrides.
        XCTAssertEqual(HistoryExport.register(bundleId: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(HistoryExport.register(bundleId: "com.jetbrains.intellij"), .ide)
        // The override exists only because production keys WhatsApp by
        // its bare name — pinned so the follow-up that fixes the key can
        // drop it.
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "net.whatsapp.WhatsApp"), .unknown)
    }

    // MARK: - Row → fixture

    func testFixturePerStoredRowIsGoldFreeWithEveryFieldFromTheRecord() async throws {
        let store = try makeStore()
        await store.save(record("can you explain how the sync works between the tabs and the phone",
                                formatted: "Sure, I can explain that.\n1. **Sync** runs every minute.", at: 0))
        await store.save(record("uh", formatted: "Uh.", bundleId: "com.apple.Notes", appName: "Notes",
                                formatMs: nil, language: "it", at: 60))
        let rows = await store.recent()
        XCTAssertEqual(rows.count, 2)
        let cases = HistoryExport.export(rows, timeZone: utc)

        // Oldest row first, whatever order the store returns.
        XCTAssertEqual(cases.map(\.id), ["h1", "h2"])
        let prompt = cases[0]
        XCTAssertEqual(prompt.raw, "can you explain how the sync works between the tabs and the phone")
        XCTAssertEqual(prompt.gold, "")
        XCTAssertEqual(prompt.goldSource, "history-unrated")
        XCTAssertTrue(prompt.isGoldFree)
        XCTAssertEqual(prompt.annotationsStatus, .confirmed)
        XCTAssertFalse(prompt.isDraft)
        XCTAssertEqual(prompt.observed, "Sure, I can explain that.\n1. **Sync** runs every minute.")
        XCTAssertEqual(prompt.observedMs, 1073)
        XCTAssertEqual(prompt.register, .unknown)
        XCTAssertEqual(prompt.level, .standard)
        XCTAssertEqual(prompt.language, .english)
        XCTAssertEqual(prompt.tags, ["unrated", "unknown"])
        XCTAssertEqual(prompt.source, "history:1")
        XCTAssertEqual(prompt.note, "app=cmux date=2026-09-07 words=13")
        XCTAssertEqual(prompt.wordCount, 13)
        XCTAssertEqual(prompt.golds, [])
        XCTAssertEqual(prompt.mustKeep, [])
        XCTAssertEqual(prompt.repairs, [])
        XCTAssertNil(prompt.fillers)
        XCTAssertNil(prompt.stutters)
        XCTAssertNil(prompt.control)
        XCTAssertNil(prompt.maxMs)

        let backchannel = cases[1]
        XCTAssertEqual(backchannel.id, "h2")
        XCTAssertEqual(backchannel.register, .notes)
        XCTAssertEqual(backchannel.language, .italian)
        XCTAssertEqual(backchannel.tags, ["unrated", "notes", "backchannel"])
        XCTAssertEqual(backchannel.observed, "Uh.")
        XCTAssertNil(backchannel.observedMs)
        XCTAssertEqual(backchannel.note, "app=Notes date=2026-09-07 words=1")
        XCTAssertEqual(backchannel.source, "history:2")
    }

    func testFixtureFallsBackToBundleIdAndEnglishAndDropsAnUnsavedRecord() {
        var r = record("okay yes", bundleId: "net.whatsapp.WhatsApp", appName: nil, language: "xx")
        XCTAssertNil(HistoryExport.fixture(r, timeZone: utc), "no rowid → no fixture")
        r.id = 54
        let c = try! XCTUnwrap(HistoryExport.fixture(r, timeZone: utc))
        XCTAssertEqual(c.id, "h54")
        XCTAssertEqual(c.source, "history:54")
        XCTAssertEqual(c.register, .messaging)
        XCTAssertEqual(c.language, .english, "an unknown code reads as English, never a decode failure")
        XCTAssertEqual(c.tags, ["unrated", "messaging", "backchannel"], "two words is still a backchannel")
        XCTAssertEqual(c.note, "app=net.whatsapp.WhatsApp date=2026-09-07 words=2")
        XCTAssertNil(c.observed, "a row the binary never formatted carries no observed output")
        var three = record("okay yes please")
        three.id = 3
        XCTAssertEqual(HistoryExport.fixture(three, timeZone: utc)?.tags, ["unrated", "unknown"])
    }

    func testTheExportNeverDraftsAGoldFromTheFormattedText() {
        // The two catastrophes: if the export copied `formattedText` into
        // gold, the answered question would score itself PASS.
        var r = record("can you explain how the sync works", formatted: "Sure, I can explain that.")
        r.id = 70
        let c = try! XCTUnwrap(HistoryExport.fixture(r))
        XCTAssertEqual(c.gold, "")
        XCTAssertTrue(c.isGoldFree)
        XCTAssertTrue(QualityScore.score(c, out: c.observed!).isGated)
    }

    // MARK: - Selection

    func testSinceIsInclusiveLocalMidnightAndMinWordsCountsTokenizerWords() {
        var rows: [HistoryRecord] = []
        for (i, (raw, at)) in [("uh", -86_400.0), ("okay yes", 0.0), ("ship it now please", 3_600.0)].enumerated() {
            var r = record(raw, at: at)
            r.id = Int64(i + 1)
            rows.append(r)
        }
        let all = HistoryExport.export(rows, timeZone: utc)
        XCTAssertEqual(all.map(\.id), ["h1", "h2", "h3"])
        // 2026-09-07 00:00Z: the row at 03:00Z that day is in, the day before is out.
        let since = try! XCTUnwrap(HistoryExport.date("2026-09-07", timeZone: utc))
        XCTAssertEqual(since, Date(timeIntervalSince1970: 1_788_739_200))
        XCTAssertEqual(HistoryExport.export(rows, since: since, timeZone: utc).map(\.id), ["h2", "h3"])
        XCTAssertEqual(HistoryExport.export(rows, minWords: 2, timeZone: utc).map(\.id), ["h2", "h3"])
        XCTAssertEqual(HistoryExport.export(rows, minWords: 3, timeZone: utc).map(\.id), ["h3"])
        XCTAssertEqual(HistoryExport.export(rows, since: since, minWords: 3, timeZone: utc).map(\.id), ["h3"])
        // A punctuation-only "word" is not a word to the tokenizer either.
        var marks = record("... ...")
        marks.id = 9
        XCTAssertEqual(HistoryExport.export([marks], minWords: 1).count, 0)
    }

    func testDateParsingRefusesAnythingButYYYYMMDD() {
        XCTAssertNil(HistoryExport.date("2026-9-7", timeZone: utc))
        XCTAssertNil(HistoryExport.date("07/09/2026", timeZone: utc))
        XCTAssertNil(HistoryExport.date("yesterday", timeZone: utc))
        XCTAssertNil(HistoryExport.date("2026-09-07T10:00", timeZone: utc))
        XCTAssertEqual(HistoryExport.day(epoch, timeZone: utc), "2026-09-07")
        // The note's day follows the zone: 03:00Z is still the 6th in Tahiti.
        XCTAssertEqual(HistoryExport.day(epoch, timeZone: TimeZone(identifier: "Pacific/Tahiti")!), "2026-09-06")
    }

    // MARK: - Merge

    private var rated: EvalCase {
        EvalCase(id: "h58", raw: "I don't know um try some broad benchmarking", gold: "I don't know, try some broad benchmarking.",
                 note: "his own note", audio: nil,
                 golds: ["I don't know — try some broad benchmarking."], tags: ["hedge", "agent-prompt"],
                 register: .unknown, level: .fillers, language: .english, control: false,
                 fillers: [.init(span: "um")], stutters: [], repairs: [.init(reparandum: "um", repair: "try")],
                 mustKeep: [.init(span: "I don't know", weight: 2)], alternates: [.init(from: "deep", to: ["deep-dive"])],
                 maxMs: 900, source: "history:58", goldSource: "ship:abc123:llama", annotationsStatus: .draft,
                 observed: "Try some broad benchmarking.", observedMs: 1500)
    }

    private var freshH58: EvalCase {
        EvalCase(id: "h58", raw: "I don't know um try some broad benchmarking", gold: "", note: "app=cmux date=2026-08-30 words=8",
                 tags: ["unrated", "unknown"], source: "history:58", goldSource: "history-unrated",
                 observed: "Try some broad benchmarking.", observedMs: 1512)
    }

    private var freshH70: EvalCase {
        EvalCase(id: "h70", raw: "can you explain the sync", gold: "", note: "app=cmux date=2026-09-07 words=5",
                 tags: ["unrated", "unknown"], source: "history:70", goldSource: "history-unrated",
                 observed: "Sure, I can explain that.", observedMs: 2296)
    }

    func testMergeRefreshesOnlyObservedAndNoteAndKeepsEveryAnnotation() {
        let merge = HistoryExport.merge(existing: [rated], fresh: [freshH58, freshH70])
        XCTAssertEqual(merge.refreshed, 1)
        XCTAssertEqual(merge.added, 1)
        XCTAssertEqual(merge.retained, 0)
        XCTAssertEqual(merge.cases.map(\.id), ["h58", "h70"])

        let kept = merge.cases[0]
        // The three fields a re-run owns.
        XCTAssertEqual(kept.observed, "Try some broad benchmarking.")
        XCTAssertEqual(kept.observedMs, 1512)
        XCTAssertEqual(kept.note, "app=cmux date=2026-08-30 words=8")
        // Everything the rating loop (or his editor) wrote survives.
        XCTAssertEqual(kept.gold, "I don't know, try some broad benchmarking.")
        XCTAssertEqual(kept.golds, ["I don't know — try some broad benchmarking."])
        XCTAssertEqual(kept.goldSource, "ship:abc123:llama")
        XCTAssertEqual(kept.annotationsStatus, .draft)
        XCTAssertEqual(kept.tags, ["hedge", "agent-prompt"], "the export's `unrated` tag never comes back")
        XCTAssertEqual(kept.mustKeep, [.init(span: "I don't know", weight: 2)])
        XCTAssertEqual(kept.repairs, [.init(reparandum: "um", repair: "try")])
        XCTAssertEqual(kept.fillers, [.init(span: "um")])
        XCTAssertEqual(kept.stutters, [])
        XCTAssertEqual(kept.alternates, [.init(from: "deep", to: ["deep-dive"])])
        XCTAssertEqual(kept.level, .fillers)
        XCTAssertEqual(kept.control, false)
        XCTAssertEqual(kept.maxMs, 900)
        XCTAssertEqual(kept.raw, rated.raw)
        XCTAssertEqual(kept.register, .unknown)
        XCTAssertEqual(kept.source, "history:58")
        XCTAssertFalse(kept.isGoldFree)
        XCTAssertEqual(merge.cases[1], freshH70)
    }

    func testMergeRetainsRowsTheExportNoLongerCarriesAndIsIdempotent() {
        // `--since` narrowed the export: the rated row outside it stays.
        let merge = HistoryExport.merge(existing: [rated], fresh: [freshH70])
        XCTAssertEqual(merge.retained, 1)
        XCTAssertEqual(merge.refreshed, 0)
        XCTAssertEqual(merge.added, 1)
        XCTAssertEqual(merge.cases, [rated, freshH70])

        let again = HistoryExport.merge(existing: merge.cases, fresh: [freshH70])
        XCTAssertEqual(again.cases, merge.cases)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.refreshed, 1)
        XCTAssertEqual(try EvalCase.fixtureSetHash(again.cases), try EvalCase.fixtureSetHash(merge.cases))

        // Nothing in, everything out; nothing new, nothing lost.
        XCTAssertEqual(HistoryExport.merge(existing: [], fresh: [freshH70]).cases, [freshH70])
        XCTAssertEqual(HistoryExport.merge(existing: [rated], fresh: []).cases, [rated])
        XCTAssertEqual(HistoryExport.merge(existing: [], fresh: []).cases, [])
    }

    func testMergeNeverTurnsAnEmptyRatedGoldBackIntoUnrated() {
        // A rated "paste nothing" (all-filler row, gold "" under `edit`)
        // must not be re-read as gold-free by a re-run.
        let pasteNothing = EvalCase(id: "h12", raw: "uh", gold: "", tags: ["fragment"],
                                    source: "history:12", goldSource: "edit", observed: "Uh.", observedMs: nil)
        XCTAssertFalse(pasteNothing.isGoldFree)
        let fresh = EvalCase(id: "h12", raw: "uh", gold: "", note: "app=cmux date=2026-07-05 words=1",
                             tags: ["unrated", "unknown", "backchannel"], source: "history:12",
                             goldSource: "history-unrated", observed: "Uh.")
        let merged = HistoryExport.merge(existing: [pasteNothing], fresh: [fresh]).cases[0]
        XCTAssertEqual(merged.goldSource, "edit")
        XCTAssertFalse(merged.isGoldFree)
        XCTAssertEqual(merged.note, "app=cmux date=2026-07-05 words=1")
    }

    // MARK: - File shape

    func testEncodedFileRoundTripsLintsCleanAndIsExactlyWhatTheRepoGuardRefuses() throws {
        let cases = [freshH58, freshH70]
        let data = try HistoryExport.encode(cases)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("[\n"), "pretty-printed for hand edits")
        XCTAssertTrue(text.hasSuffix("}\n]\n"))
        XCTAssertTrue(text.contains("\"gold_source\" : \"history-unrated\""))
        XCTAssertTrue(text.contains("\"source\" : \"history:70\""))
        XCTAssertEqual(try JSONDecoder().decode([EvalCase].self, from: data), cases)
        XCTAssertEqual(try EvalCase.fixtureSetHash(try JSONDecoder().decode([EvalCase].self, from: data)),
                       try EvalCase.fixtureSetHash(cases))

        // `eval` lints before scoring: an export must clear it as-is.
        let issues = EvalLint.lint(cases)
        XCTAssertFalse(EvalLint.hasErrors(issues), "\(issues)")
        // …and is precisely what CI's repo guard refuses in the tree.
        let guarded = EvalLint.lint(cases, repoGuard: true).filter { $0.severity == .error }
        XCTAssertEqual(guarded.count, 4, "a history source and an observed field per fixture")
    }
}
