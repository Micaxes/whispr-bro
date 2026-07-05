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

    /// Test hook: the effective `secure_delete` pragma (1 = ON).
    func secureDeleteForTests() async -> Int {
        await read { try Int.fetchOne($0, sql: "PRAGMA secure_delete") ?? -1 } ?? -1
    }

    private func read<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async -> T? {
        do { return try await dbQueue.read(block) }
        catch { Self.log.error("history read failed: \(error.localizedDescription)"); return nil }
    }
}
