import XCTest
@testable import WhisprBroCore

final class HistoryStoreTests: XCTestCase {
    private func makeStore() throws -> HistoryStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-test-\(UUID().uuidString).sqlite")
        return try HistoryStore(path: url)
    }

    private func record(_ raw: String, formatted: String? = nil, at: TimeInterval = 0) -> HistoryRecord {
        HistoryRecord(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + at),
            appBundleId: "com.apple.mail", appName: "Mail",
            rawText: raw, formattedText: formatted,
            audioMs: 5, asrMs: 90, formatMs: 300, insertMs: 50, totalMs: 445)
    }

    func testInsertAndCount() async throws {
        let store = try makeStore()
        await store.save(record("hello world"))
        await store.save(record("second one"))
        let count = await store.count()
        XCTAssertEqual(count, 2)
    }

    func testRecentIsNewestFirst() async throws {
        let store = try makeStore()
        await store.save(record("oldest", at: 0))
        await store.save(record("newest", at: 100))
        let recent = await store.recent()
        XCTAssertEqual(recent.map(\.rawText), ["newest", "oldest"])
    }

    func testFullTextSearchMatchesWholeWords() async throws {
        let store = try makeStore()
        await store.save(record("book the flight to Berlin", at: 0))
        await store.save(record("review the design doc", at: 1))
        let hits = await store.search("berlin flight")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.rawText, "book the flight to Berlin")
    }

    func testSearchMatchesFormattedTextToo() async throws {
        let store = try makeStore()
        await store.save(record("get user data", formatted: "getUserData was called"))
        let hits = await store.search("getUserData")
        XCTAssertEqual(hits.count, 1)
    }

    func testSearchWithOnlyPunctuationFallsBackToRecent() async throws {
        let store = try makeStore()
        await store.save(record("a", at: 0))
        await store.save(record("b", at: 1))
        let hits = await store.search("!!! ???")
        XCTAssertEqual(hits.count, 2) // fell back to recent, not an FTS syntax error
    }

    func testDeleteAll() async throws {
        let store = try makeStore()
        await store.save(record("x"))
        await store.deleteAll()
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    func testSecureDeletePragmaIsOn() async throws {
        let store = try makeStore()
        let value = await store.secureDeleteForTests()
        XCTAssertEqual(value, 1) // PRAGMA secure_delete = ON
    }

    func testFtsIndexStaysInSyncAfterDelete() async throws {
        let store = try makeStore()
        await store.save(record("unique-token-alpha", at: 0))
        var hits = await store.search("unique-token-alpha")
        XCTAssertEqual(hits.count, 1)
        if let id = hits.first?.id { await store.delete(id: id) }
        hits = await store.search("unique-token-alpha")
        XCTAssertEqual(hits.count, 0) // external-content triggers cleaned the index
    }
}
