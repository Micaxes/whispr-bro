import Foundation

/// The pure half of `whispr-bench history-export` (plan §3.3): one
/// gold-free v2 fixture per `HistoryRecord`, the register map, the
/// `--since` / `--min-words` selection, and the merge with a file he has
/// already rated. Nothing here touches a file or a database — the bench
/// snapshots the DB and reads the rows; this turns rows into fixtures so
/// XCTest can pin every field and the merge rule without a store.
///
/// Two rules carry the design (three judges agreed on both):
/// - **`gold` is always `""` with `gold_source: "history-unrated"`.** The
///   export never drafts `gold = formattedText` — that would hide exactly
///   the rows the benchmark exists to catch (the answered question, the
///   invented math). Golds come only from the rating loop (§7).
/// - **A re-run never undoes a rating.** Merging by id keeps every
///   annotation of an existing fixture; only what the binary produced
///   (`observed`, `observed_ms`) and the machine-written `note` refresh.
public enum HistoryExport {
    /// Bundle ids the app's own resolver leaves at `.unknown` but the
    /// export maps elsewhere. WhatsApp's production key is the bare string
    /// "WhatsApp" (`AppCategoryResolver.byBundleId`), so its real bundle id
    /// would export as `unknown`; cmux (`com.cmuxterm.app`) is deliberately
    /// NOT mapped — `.unknown` is the register his prompts actually ran
    /// under, and `.terminal` (no caps, no periods) would wreck them.
    public static let registerOverrides: [String: AppCategory] = [
        "net.whatsapp.WhatsApp": .messaging,
    ]

    /// The register a history row ran under: the app's resolver plus
    /// `registerOverrides`; nil / unmapped → `.unknown`.
    public static func register(bundleId: String?) -> AppCategory {
        AppCategoryResolver.category(bundleId: bundleId, overrides: registerOverrides)
    }

    /// Every exported fixture carries this tag until a rating confirms a
    /// gold (§7.3 drops it on confirm).
    public static let unratedTag = "unrated"
    /// One- or two-word rows ("Uh", "Mm-hmm.", "Okay yes") — 19/70 of his
    /// history; tagged so `--tag` can keep them out of a long-form run.
    public static let backchannelTag = "backchannel"
    public static let backchannelMaxWords = 2

    /// `"h<rowid>"` — the fixture id a history row keeps across re-runs.
    public static func fixtureId(rowId: Int64) -> String { "h\(rowId)" }

    /// `"history:<rowid>"` — the `source` `lint --repo-guard` refuses.
    public static func source(rowId: Int64) -> String { EvalLint.historySourcePrefix + String(rowId) }

    // MARK: - Row → fixture

    /// One gold-free fixture for a stored row; nil for a record that was
    /// never inserted (no rowid — cannot come from a store read).
    /// `register` from the bundle id, `language` from the row's code (nil,
    /// pre-v2, → English), `observed` / `observed_ms` from what the binary
    /// pasted and how long its model stage took, `tags` = `unrated`, the
    /// register, `backchannel` when ≤ 2 words. `note` is machine-written
    /// (`app=… date=… words=…`) and refreshes on every run. `timeZone` is
    /// injectable so the date in the note is pinned by test.
    public static func fixture(_ record: HistoryRecord, timeZone: TimeZone = .current) -> EvalCase? {
        guard let rowId = record.id else { return nil }
        let register = register(bundleId: record.appBundleId)
        let words = Align.tokenize(record.rawText).tokens.count
        var tags = [unratedTag, register.rawValue]
        if words <= backchannelMaxWords { tags.append(backchannelTag) }
        let app = record.appName ?? record.appBundleId ?? "unknown"
        return EvalCase(
            id: fixtureId(rowId: rowId),
            raw: record.rawText,
            gold: "",
            note: "app=\(app) date=\(day(record.createdAt, timeZone: timeZone)) words=\(words)",
            tags: tags,
            register: register,
            language: language(code: record.language),
            source: source(rowId: rowId),
            goldSource: EvalCase.historyUnratedGoldSource,
            observed: record.formattedText,
            observedMs: record.formatMs)
    }

    /// `--since` / `--min-words` over a store read, as fixtures, oldest
    /// row first (rowid order — the order he dictated them, and the order
    /// the file reads in; the set hash is order-free anyway). `since` is
    /// inclusive; `minWords` counts `Align.tokenize` words, the same count
    /// `EvalCase.wordCount` reports, so `--min-words 3` and the
    /// `backchannel` tag agree on what a word is.
    public static func export(_ records: [HistoryRecord], since: Date? = nil, minWords: Int = 1,
                              timeZone: TimeZone = .current) -> [EvalCase] {
        records
            .filter { record in since.map { record.createdAt >= $0 } ?? true }
            .sorted { ($0.id ?? 0) < ($1.id ?? 0) }
            .compactMap { fixture($0, timeZone: timeZone) }
            .filter { $0.wordCount >= minWords }
    }

    // MARK: - Merge

    /// What a merge did, so the bench can say it and a test can pin it.
    public struct Merge: Sendable, Equatable {
        public let cases: [EvalCase]
        /// Existing ids the fresh export also carries: annotations kept,
        /// `observed` / `observed_ms` / `note` refreshed.
        public let refreshed: Int
        /// Fresh ids the file did not have yet, appended in export order.
        public let added: Int
        /// Existing ids the fresh export does not carry (a row outside
        /// `--since`, or deleted from history): kept untouched — a filter
        /// on the export is never a deletion from his file.
        public let retained: Int

        public init(cases: [EvalCase], refreshed: Int, added: Int, retained: Int) {
            self.cases = cases
            self.refreshed = refreshed
            self.added = added
            self.retained = retained
        }
    }

    /// Merges a fresh export into the fixtures already in the file, by
    /// id. For an id on both sides the EXISTING fixture wins on every
    /// field but three — `observed`, `observed_ms`, `note` — so a gold, an
    /// alternate, a `must_keep`, a repair, a stutter or filler annotation,
    /// a tag, `gold_source` and `annotations_status` written by the rating
    /// loop (or by hand) survive any number of re-runs. Existing order is
    /// kept; new ids follow in export order. Idempotent: merging a merge
    /// with the same export changes nothing.
    public static func merge(existing: [EvalCase], fresh: [EvalCase]) -> Merge {
        let freshById = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var cases: [EvalCase] = []
        var refreshed = 0, retained = 0
        for old in existing {
            if let new = freshById[old.id] {
                cases.append(refresh(old, from: new))
                refreshed += 1
            } else {
                cases.append(old)
                retained += 1
            }
        }
        let known = Set(existing.map(\.id))
        let added = fresh.filter { !known.contains($0.id) }
        cases += added
        return Merge(cases: cases, refreshed: refreshed, added: added.count, retained: retained)
    }

    /// `old` with `new`'s observed output, its latency, and its note.
    static func refresh(_ old: EvalCase, from new: EvalCase) -> EvalCase {
        EvalCase(id: old.id, raw: old.raw, gold: old.gold, note: new.note, audio: old.audio,
                 golds: old.golds, tags: old.tags, register: old.register, level: old.level,
                 language: old.language, control: old.control, fillers: old.fillers,
                 stutters: old.stutters, repairs: old.repairs, mustKeep: old.mustKeep,
                 alternates: old.alternates, maxMs: old.maxMs, source: old.source,
                 goldSource: old.goldSource, annotationsStatus: old.annotationsStatus,
                 observed: new.observed, observedMs: new.observedMs)
    }

    // MARK: - File shape

    /// The fixture file's bytes: pretty-printed, sorted keys, slashes
    /// unescaped — the file is edited by hand in the rating loop (§7.1
    /// `e`), so it must read as JSON a person can diff. Decodes back to
    /// the same cases (`EvalCase.encode` writes explicit fields only).
    public static func encode(_ cases: [EvalCase]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(cases) + Data("\n".utf8)
    }

    // MARK: - Dates

    /// `--since YYYY-MM-DD` as local midnight in `timeZone`; nil for
    /// anything else (a typo must not silently export everything).
    /// `DateFormatter` accepts a matching prefix and ignores the rest
    /// ("2026-09-07T10:00" parses as the 7th), so the parse is accepted
    /// only when it prints back as the exact text.
    public static func date(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let f = formatter(timeZone)
        guard let date = f.date(from: text), f.string(from: date) == text else { return nil }
        return date
    }

    /// `YYYY-MM-DD` of `date` in `timeZone`, for the note.
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone).string(from: date)
    }

    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }

    /// The row's language code → the fixture's language; nil (pre-v2
    /// rows) and unknown codes read as English.
    private static func language(code: String?) -> DictationLanguage {
        guard let code else { return .english }
        return DictationLanguage.allCases.first { $0.code == code } ?? .english
    }
}
