import Foundation
import GRDB
import os.log

/// Local dictation history on GRDB + SQLite FTS5 (spec §4 HistoryStore, §11.6),
/// at `~/Library/Application Support/whispr-bro/history.sqlite`. Fully offline:
/// GRDB links the system SQLite (FTS5 enabled), no network.
///
/// Privacy posture: the file is created owner-only (0600); `secure_delete` is
/// on so cleared rows are zeroed on disk; a retention cap bounds the plaintext
/// log; and recording is skippable (the pipeline gates the write).
///
/// Writes happen off the dictation critical path (call `save` from a detached
/// Task); the FTS index is external-content and maintained by triggers.
public final class HistoryStore: Sendable {
    /// Bound the plaintext transcript log — pruned oldest-first on write.
    public static let maxRows = 10_000

    private let dbQueue: DatabaseQueue
    private static let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "history")

    /// Shared instance, opened once. nil (with a logged reason) if the DB can't
    /// be opened. Prewarm it off-main via `prewarm()`.
    public static let shared: HistoryStore? = {
        do { return try HistoryStore() }
        catch { log.error("history store unavailable: \(error.localizedDescription)"); return nil }
    }()

    /// Touch `shared` so the one-time DB open + migration runs off whatever
    /// thread calls this (keep it off the main thread — see PipelineController).
    public static func prewarm() { _ = shared }

    public init(path: URL? = nil) throws {
        let url = try path ?? {
            try Paths.ensureDirectories()
            return Paths.home.appendingPathComponent("history.sqlite")
        }()
        var config = Configuration()
        // Zero freed pages on delete so a "Clear all" can't leave recoverable
        // plaintext behind.
        config.prepareDatabase { try $0.execute(sql: "PRAGMA secure_delete = ON") }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        // Owner-only, so another local user can't read the transcript log.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_history") { db in
            try db.create(table: "record") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
                t.column("appBundleId", .text)
                t.column("appName", .text)
                t.column("rawText", .text).notNull()
                t.column("formattedText", .text)
                t.column("audioMs", .integer)
                t.column("asrMs", .integer)
                t.column("formatMs", .integer)
                t.column("insertMs", .integer)
                t.column("totalMs", .integer)
            }
            try db.create(indexOn: "record", columns: ["createdAt"])
            try db.create(virtualTable: "record_ft", using: FTS5()) { t in
                t.synchronize(withTable: "record")
                t.tokenizer = .unicode61()
                t.column("rawText")
                t.column("formattedText")
            }
        }
        // v2: columns backing the dashboard's honest stats. Both nullable and
        // backfilled only going forward — old rows stay NULL and are excluded
        // from duration-dependent metrics (WPM).
        migrator.registerMigration("v2_stats") { db in
            try db.alter(table: "record") { t in
                t.add(column: "durationMs", .integer)   // utterance length → WPM
                t.add(column: "language", .text)         // dictation language code
            }
        }
        return migrator
    }

    // MARK: - Write (off the dictation path)

    public func save(_ record: HistoryRecord) async {
        do {
            try await dbQueue.write { db in
                var r = record
                try r.insert(db)
                // Prune to the retention cap: drop rows older than the
                // maxRows-th newest (index-efficient; no-op below the cap).
                try db.execute(sql: """
                    DELETE FROM record WHERE createdAt < (
                        SELECT createdAt FROM record ORDER BY createdAt DESC LIMIT 1 OFFSET ?
                    )
                    """, arguments: [Self.maxRows])
            }
        } catch {
            Self.log.error("history save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Read

    /// Recent dictations, newest first.
    public func recent(limit: Int = 200) async -> [HistoryRecord] {
        await read {
            try HistoryRecord.order(Column("createdAt").desc).limit(limit).fetchAll($0)
        } ?? []
    }

    /// Full-text search (bm25-ranked, then recency). A query of only
    /// punctuation/whitespace has no indexable token → falls back to recent.
    public func search(_ query: String, limit: Int = 200) async -> [HistoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pattern = FTS5Pattern(matchingAllTokensIn: trimmed) else {
            return await recent(limit: limit)
        }
        return await read {
            try HistoryRecord.fetchAll($0, sql: """
                SELECT record.*
                FROM record
                JOIN record_ft ON record_ft.rowid = record.id AND record_ft MATCH ?
                ORDER BY record_ft.rank, record.createdAt DESC
                LIMIT ?
                """, arguments: [pattern, limit])
        } ?? []
    }

    public func deleteAll() async {
        // secure_delete = ON (set in init) zeros the freed pages in place, in
        // both the record table and the FTS shadow tables, so a plain DELETE
        // leaves no recoverable plaintext. (VACUUM can't run in GRDB's write
        // transaction and isn't needed for content erasure.)
        do { try await dbQueue.write { db in _ = try HistoryRecord.deleteAll(db) } }
        catch { Self.log.error("history clear failed: \(error.localizedDescription)") }
    }

    public func delete(id: Int64) async {
        do { try await dbQueue.write { db in _ = try HistoryRecord.deleteOne(db, id: id) } }
        catch { Self.log.error("history delete failed: \(error.localizedDescription)") }
    }

    public func count() async -> Int {
        await read { try HistoryRecord.fetchCount($0) } ?? 0
    }

    // MARK: - Dashboard stats

    /// Aggregate dictation statistics. `since` scopes the range-based tiles and
    /// charts (nil = all time); streak and month-over-month always use the full
    /// history. Fetches the rows (≤10k) and computes in Swift — word counts,
    /// medians, and streaks have no clean SQL, and correctness beats a rough
    /// space-count for a headline number.
    public func stats(since: Date?) async -> HistoryStats {
        await read { db in
            let all = try HistoryRecord.order(Column("createdAt")).fetchAll(db)
            return Self.computeStats(all, since: since)
        } ?? HistoryStats()
    }

    /// Pure, testable core of `stats`. `now`/`calendar` are injectable for tests.
    static func computeStats(
        _ all: [HistoryRecord], since: Date?, now: Date = Date(), calendar: Calendar = .current
    ) -> HistoryStats {
        func words(_ t: String) -> Int { t.split(whereSeparator: \.isWhitespace).count }
        func median(_ xs: [Double]) -> Double? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted(); let m = s.count / 2
            return s.count.isMultiple(of: 2) ? (s[m - 1] + s[m]) / 2 : s[m]
        }
        func medianInt(_ xs: [Int]) -> Int? {
            guard !xs.isEmpty else { return nil }
            return xs.sorted()[xs.count / 2]
        }

        var s = HistoryStats()
        s.allTimeDictations = all.count
        let inRange = since.map { lo in all.filter { $0.createdAt >= lo } } ?? all

        s.dictations = inRange.count
        s.apps = Set(inRange.compactMap { $0.appBundleId }).count
        s.totalWords = inRange.reduce(0) { $0 + words($1.displayText) }
        s.wordsCleanedEst = inRange.reduce(0) { $0 + max(0, words($1.rawText) - words($1.displayText)) }

        s.medianWpm = median(inRange.compactMap { r in
            guard let ms = r.durationMs, ms > 0 else { return nil }
            let w = words(r.displayText)
            return w > 0 ? Double(w) / (Double(ms) / 60_000) : nil
        })

        var byDay: [Date: [HistoryRecord]] = [:]
        for r in inRange { byDay[calendar.startOfDay(for: r.createdAt), default: []].append(r) }
        s.perDay = byDay.keys.sorted().map { day in
            let recs = byDay[day]!
            return HistoryStats.DayBucket(
                day: day, dictations: recs.count, words: recs.reduce(0) { $0 + words($1.displayText) },
                medianTotalMs: medianInt(recs.compactMap { $0.totalMs }),
                medianAsrMs: medianInt(recs.compactMap { $0.asrMs }))
        }

        var byCategory: [AppCategory: Int] = [:]
        for r in inRange {
            byCategory[AppCategoryResolver.category(bundleId: r.appBundleId), default: 0] += words(r.displayText)
        }
        s.perCategory = byCategory.map { HistoryStats.CategoryBucket(category: $0.key, words: $0.value) }
            .filter { $0.words > 0 }.sorted { $0.words > $1.words }

        // Streak + month-over-month use ALL history, not the selected range.
        let activeDays = Set(all.map { calendar.startOfDay(for: $0.createdAt) })
        var cursor = calendar.startOfDay(for: now)
        if !activeDays.contains(cursor) {   // no dictation today yet → count up to yesterday
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while activeDays.contains(cursor) {
            s.currentStreakDays += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        if let cutoff = calendar.date(byAdding: .day, value: -119, to: calendar.startOfDay(for: now)) {
            for r in all where r.createdAt >= cutoff {
                s.recentDayWords[calendar.startOfDay(for: r.createdAt), default: 0] += words(r.displayText)
            }
        }

        let thisMonth = calendar.dateComponents([.year, .month], from: now)
        s.thisMonthWords = all.filter { calendar.dateComponents([.year, .month], from: $0.createdAt) == thisMonth }
            .reduce(0) { $0 + words($1.displayText) }
        if let prevMonthDate = calendar.date(byAdding: .month, value: -1, to: now) {
            let lm = calendar.dateComponents([.year, .month], from: prevMonthDate)
            s.lastMonthWords = all.filter { calendar.dateComponents([.year, .month], from: $0.createdAt) == lm }
                .reduce(0) { $0 + words($1.displayText) }
        }
        return s
    }

    /// Test hook: the effective `secure_delete` pragma (1 = ON).
    func secureDeleteForTests() async -> Int {
        await read { try Int.fetchOne($0, sql: "PRAGMA secure_delete") ?? -1 } ?? -1
    }

    private func read<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async -> T? {
        do { return try await dbQueue.read(block) }
        catch { Self.log.error("history read failed: \(error.localizedDescription)"); return nil }
    }
}

/// Aggregate dictation statistics for the dashboard (spec: unified window).
public struct HistoryStats: Sendable {
    public struct DayBucket: Sendable, Identifiable {
        public let day: Date            // local midnight
        public let dictations: Int
        public let words: Int
        public let medianTotalMs: Int?
        public let medianAsrMs: Int?
        public var id: Date { day }
    }
    public struct CategoryBucket: Sendable, Identifiable {
        public let category: AppCategory
        public let words: Int
        public var id: String { category.rawValue }
    }

    public var allTimeDictations = 0    // ignores the range filter (for the empty state)
    public var dictations = 0
    public var apps = 0
    public var totalWords = 0
    /// Filler / correction words removed by Auto-Clean + the LLM (estimate:
    /// raw word count − final word count; the LLM also rewrites, not only trims).
    public var wordsCleanedEst = 0
    /// Median words-per-minute over dictations that have a recorded duration
    /// (nil until v2 rows exist).
    public var medianWpm: Double?
    public var currentStreakDays = 0
    public var perDay: [DayBucket] = []
    public var perCategory: [CategoryBucket] = []
    /// Words per local day over the last ~120 days from ALL history (for the
    /// streak heatmap), independent of the selected range.
    public var recentDayWords: [Date: Int] = [:]
    public var thisMonthWords = 0
    public var lastMonthWords = 0
    public init() {}
}
