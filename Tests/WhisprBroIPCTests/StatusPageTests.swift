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

    func testErrorCodeRoundTripsAndSurvivesTheOffTransition() throws {
        let writer = try StatusPageWriter(directory: directory)
        let reader = StatusPageReader(directory: directory)
        writer.beginSession()
        writer.transition(to: .live)
        XCTAssertEqual(try XCTUnwrap(reader.read()).errorCode, .none)

        // The app-side order: fail() stamps the code, THEN the terminal .off
        // publish — the off page the keyboard reacts to must carry it.
        writer.fail(code: .transcriptionFailed)
        XCTAssertEqual(try XCTUnwrap(reader.read()).errorCode, .transcriptionFailed)
        writer.transition(to: .off)
        let snapshot = try XCTUnwrap(reader.read())
        XCTAssertEqual(snapshot.sessionState, .off)
        XCTAssertEqual(snapshot.errorCode, .transcriptionFailed)
    }

    func testErrorCodeClearsWhenTheNextSessionArms() throws {
        let writer = try StatusPageWriter(directory: directory)
        let reader = StatusPageReader(directory: directory)
        writer.fail(code: .micStartFailed)
        writer.transition(to: .off)
        XCTAssertEqual(try XCTUnwrap(reader.read()).errorCode, .micStartFailed)
        writer.beginSession()
        XCTAssertEqual(
            try XCTUnwrap(reader.read()).errorCode, .none,
            "the error belongs to the session that died, never to the one arming over it")
    }

    func testLegacyReservedZeroByteDecodesAsNoError() throws {
        // The no-version-bump compatibility argument from the layout doc: an
        // old writer's page has byte 7 hardwired to zero with the CRC computed
        // over it — byte-identical to a current writer at .none. Pin the byte
        // and decode it explicitly.
        let writer = try StatusPageWriter(directory: directory)
        writer.transition(to: .live)
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: StatusPage.byteCount, mode: .readOnly))
        XCTAssertEqual(poke.loadUInt8(at: StatusPage.Offset.errorCode), 0)
        let snapshot = try XCTUnwrap(StatusPageReader(directory: directory).read())
        XCTAssertEqual(snapshot.errorCode, .none)
        XCTAssertEqual(snapshot.sessionState, .live, "checksum still validates over the zero byte")
    }

    func testUnknownErrorCodeReadsAsNoneNotDeadPage() throws {
        let writer = try StatusPageWriter(directory: directory)
        writer.transition(to: .live)
        // A future version-1 writer stamps a code this reader doesn't know;
        // fix up the CRC so the page is stable and valid, not corrupt.
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: StatusPage.byteCount, mode: .readWrite))
        poke.storeUInt8(200, at: StatusPage.Offset.errorCode)
        poke.storeUInt32(
            CRC32.checksum(UnsafeRawBufferPointer(start: poke.base, count: StatusPage.Offset.checksum)),
            at: StatusPage.Offset.checksum)
        let snapshot = try XCTUnwrap(StatusPageReader(directory: directory).read())
        XCTAssertEqual(snapshot.errorCode, .none, "an unknown code is ignorable, unlike an unknown state")
        XCTAssertEqual(snapshot.sessionState, .live)
    }

    func testErrorCodeCorruptionFailsTheChecksum() throws {
        let writer = try StatusPageWriter(directory: directory)
        writer.transition(to: .live)
        let reader = StatusPageReader(directory: directory)
        XCTAssertNotNil(reader.read())
        // Flip byte 7 WITHOUT fixing the CRC: it sits inside the checksummed
        // region, so this must read as a dead page, never as a phantom error.
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: StatusPage.byteCount, mode: .readWrite))
        poke.storeUInt8(SessionErrorCode.micInterrupted.rawValue, at: StatusPage.Offset.errorCode)
        XCTAssertNil(reader.read())
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
