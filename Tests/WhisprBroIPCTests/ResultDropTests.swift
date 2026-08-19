import XCTest

@testable import WhisprBroIPC

/// Result-drop round-trips, the on-disk JSON contract keys, unclaimed
/// scanning, and TTL garbage collection.
final class ResultDropTests: XCTestCase {
    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-ipc-results-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    func testWriteReadRemoveRoundTrip() throws {
        let record = TranscriptResultRecord(
            requestUUID: UUID(), keyboardInstanceNonce: UUID(),
            text: "ciao bro, dettato locale", completedAtMillis: 1_720_000_000_000)
        let url = try ResultDrop.write(record, in: container)
        XCTAssertEqual(url.lastPathComponent, record.requestUUID.uuidString + ".json")
        XCTAssertEqual(ResultDrop.read(requestUUID: record.requestUUID, in: container), record)

        ResultDrop.remove(requestUUID: record.requestUUID, in: container)
        XCTAssertNil(ResultDrop.read(requestUUID: record.requestUUID, in: container))
    }

    func testJSONKeysMatchTheContractConstants() throws {
        let record = TranscriptResultRecord(
            requestUUID: UUID(), keyboardInstanceNonce: UUID(),
            text: "keys are ABI", completedAtMillis: 42)
        let url = try ResultDrop.write(record, in: container)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            [TranscriptResult.requestUUIDKey, TranscriptResult.keyboardInstanceNonceKey,
             TranscriptResult.textKey, TranscriptResult.completedAtMillisKey])
        XCTAssertEqual(object[TranscriptResult.textKey] as? String, "keys are ABI")
        XCTAssertEqual(
            object[TranscriptResult.requestUUIDKey] as? String, record.requestUUID.uuidString)
    }

    func testAtomicReplaceKeepsOneFilePerRequest() throws {
        let request = UUID()
        let nonce = UUID()
        try ResultDrop.write(
            TranscriptResultRecord(requestUUID: request, keyboardInstanceNonce: nonce,
                                   text: "first pass", completedAtMillis: 1),
            in: container)
        try ResultDrop.write(
            TranscriptResultRecord(requestUUID: request, keyboardInstanceNonce: nonce,
                                   text: "second pass", completedAtMillis: 2),
            in: container)
        XCTAssertEqual(ResultDrop.unclaimed(in: container).count, 1)
        XCTAssertEqual(
            ResultDrop.read(requestUUID: request, in: container)?.text, "second pass")
    }

    func testUnclaimedListsOldestFirst() throws {
        let missingDirectory = container.appendingPathComponent("nothing-here")
        XCTAssertEqual(ResultDrop.unclaimed(in: missingDirectory), [])
        for millis: UInt64 in [30, 10, 20] {
            try ResultDrop.write(
                TranscriptResultRecord(requestUUID: UUID(), keyboardInstanceNonce: UUID(),
                                       text: "t\(millis)", completedAtMillis: millis),
                in: container)
        }
        XCTAssertEqual(ResultDrop.unclaimed(in: container).map(\.completedAtMillis), [10, 20, 30])
    }

    func testGarbageCollectionDropsExpiredAndUnparseable() throws {
        let ttlMillis = UInt64(TranscriptResult.unclaimedTTLSeconds * 1000)
        let now: UInt64 = 10_000_000
        let expired = TranscriptResultRecord(
            requestUUID: UUID(), keyboardInstanceNonce: UUID(),
            text: "too old", completedAtMillis: now - ttlMillis - 1)
        let fresh = TranscriptResultRecord(
            requestUUID: UUID(), keyboardInstanceNonce: UUID(),
            text: "still claimable", completedAtMillis: now - ttlMillis) // exactly TTL: kept
        try ResultDrop.write(expired, in: container)
        try ResultDrop.write(fresh, in: container)
        let junk = ResultDrop.resultsDirectory(in: container)
            .appendingPathComponent("not-a-result.json")
        try Data("{broken".utf8).write(to: junk)

        ResultDrop.collectGarbage(in: container, nowMillis: now)

        XCTAssertNil(ResultDrop.read(requestUUID: expired.requestUUID, in: container))
        XCTAssertEqual(
            ResultDrop.read(requestUUID: fresh.requestUUID, in: container), fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
    }
}
