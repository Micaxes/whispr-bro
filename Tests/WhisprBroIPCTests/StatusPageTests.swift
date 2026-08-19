import XCTest

@testable import WhisprBroIPC

/// Status page writer→reader round-trips plus the two "never trust a bad
/// page" paths: torn reads (odd/unstable generation) and CRC corruption.
final class StatusPageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-ipc-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var pageURL: URL {
        directory.appendingPathComponent(KeyboardIPC.statusPageFileName)
    }

    func testFreshWriterPublishesOffPage() throws {
        _ = try StatusPageWriter(directory: directory)
        let snapshot = try XCTUnwrap(StatusPageReader(directory: directory).read())
        XCTAssertEqual(snapshot.sessionState, .off)
        XCTAssertEqual(snapshot.audioLevel, 0)
        XCTAssertEqual(snapshot.lastCommandAckSeq, 0)
        XCTAssertEqual(snapshot.lastAudioCallbackAtMillis, 0)
    }

    func testRoundTripThroughAFullSession() throws {
        let writer = try StatusPageWriter(directory: directory)
        let reader = StatusPageReader(directory: directory)
        let session = UUID()

        writer.beginSession(sessionUUID: session)
        var snapshot = try XCTUnwrap(reader.read())
        XCTAssertEqual(snapshot.sessionState, .arming)
        XCTAssertEqual(snapshot.sessionUUID, session)

        writer.transition(to: .live)
        writer.recordAudio(level: 0.5, callbackAtMillis: 1_720_000_000_123)
        writer.acknowledge(commandSeq: 7)
        writer.transition(to: .dictating)
        snapshot = try XCTUnwrap(reader.read())
        XCTAssertEqual(snapshot.sessionState, .dictating)
        XCTAssertEqual(snapshot.sessionUUID, session)
        XCTAssertEqual(snapshot.audioLevel, 0.5)
        XCTAssertEqual(snapshot.lastCommandAckSeq, 7)
        XCTAssertEqual(snapshot.lastAudioCallbackAtMillis, 1_720_000_000_123)
    }

    func testSessionUUIDChangesOnEachArm() throws {
        let writer = try StatusPageWriter(directory: directory)
        let reader = StatusPageReader(directory: directory)
        writer.beginSession()
        let first = try XCTUnwrap(reader.read()).sessionUUID
        writer.beginSession()
        let second = try XCTUnwrap(reader.read()).sessionUUID
        XCTAssertNotEqual(first, second, "the keyboard detects a restart by the uuid changing")
    }

    func testAckSeqIsMonotonic() throws {
        let writer = try StatusPageWriter(directory: directory)
        let reader = StatusPageReader(directory: directory)
        writer.acknowledge(commandSeq: 9)
        writer.acknowledge(commandSeq: 4) // stale replay must not lower it
        XCTAssertEqual(try XCTUnwrap(reader.read()).lastCommandAckSeq, 9)
    }

    func testMissingPageReadsNilThenAppearsAfterWriterStarts() throws {
        let reader = StatusPageReader(directory: directory)
        XCTAssertNil(reader.read(), "no page yet — degraded, not fatal")
        _ = try StatusPageWriter(directory: directory)
        XCTAssertNotNil(reader.read(), "the reader recovers once the writer creates the page")
    }

    func testTornReadOddGenerationRetriesThenNil() throws {
        let writer = try StatusPageWriter(directory: directory)
        writer.transition(to: .live)
        let reader = StatusPageReader(directory: directory)
        XCTAssertNotNil(reader.read())

        // Simulate a writer that died mid-write: force the seqlock odd.
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: StatusPage.byteCount, mode: .readWrite))
        let even = poke.loadUInt32(at: StatusPage.Offset.generation)
        poke.storeUInt32(even | 1, at: StatusPage.Offset.generation)
        XCTAssertNil(reader.read(), "odd generation must exhaust retries and read as no-page")

        // Back to even: the exact same reader instance recovers.
        poke.storeUInt32(even, at: StatusPage.Offset.generation)
        XCTAssertEqual(try XCTUnwrap(reader.read()).sessionState, .live)
    }

    func testCRCCorruptionReadsAsDeadPage() throws {
        let writer = try StatusPageWriter(directory: directory)
        writer.recordAudio(level: 0.75, callbackAtMillis: 123)
        let reader = StatusPageReader(directory: directory)
        XCTAssertNotNil(reader.read())

        // Flip payload bytes without touching checksum or generation: a
        // stable read that fails CRC — dead page, never zeroed state.
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: StatusPage.byteCount, mode: .readWrite))
        poke.storeUInt32(0xDEAD_BEEF, at: StatusPage.Offset.audioLevel)
        XCTAssertNil(reader.read())
    }

    func testWrongMagicAndVersionReadAsDeadPage() throws {
        _ = try StatusPageWriter(directory: directory)
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: StatusPage.byteCount, mode: .readWrite))

        let goodVersion = poke.loadUInt16(at: StatusPage.Offset.version)
        poke.storeUInt16(goodVersion &+ 1, at: StatusPage.Offset.version)
        XCTAssertNil(StatusPageReader(directory: directory).read(), "future version is unreadable")
        poke.storeUInt16(goodVersion, at: StatusPage.Offset.version)

        poke.storeUInt32(0, at: StatusPage.Offset.magic)
        XCTAssertNil(StatusPageReader(directory: directory).read(), "not our file")
    }

    func testWriterRestartInheritsGenerationAndStaysReadable() throws {
        let first = try StatusPageWriter(directory: directory)
        first.beginSession()
        first.transition(to: .live)
        // App relaunch: a second writer over the same page must present a
        // fresh valid .off page to a reader that never re-mapped.
        let reader = StatusPageReader(directory: directory)
        XCTAssertEqual(try XCTUnwrap(reader.read()).sessionState, .live)
        let second = try StatusPageWriter(directory: directory)
        _ = second
        XCTAssertEqual(try XCTUnwrap(reader.read()).sessionState, .off)
    }
}
