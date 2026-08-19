import XCTest

@testable import WhisprBroIPC

/// Mailbox append/drain ordering, partial drains, lap behavior, and the
/// cursor-recovery paths a coalescing hint channel forces on the drainer.
final class CommandMailboxTests: XCTestCase {
    private var directory: URL!
    private var nonce: UUID!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-ipc-mailbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        nonce = UUID()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAppendDrainPreservesOrderAndFields() throws {
        let writer = try CommandMailboxWriter(directory: directory)
        let drainer = CommandMailboxDrainer(directory: directory)
        let request = UUID()

        XCTAssertEqual(writer.post(.startDictation, requestUUID: request,
                                   keyboardInstanceNonce: nonce, issuedAtMillis: 100), 1)
        writer.post(.stopDictation, keyboardInstanceNonce: nonce, issuedAtMillis: 200)
        writer.post(.killSession, keyboardInstanceNonce: nonce, issuedAtMillis: 300)

        let records = drainer.drain()
        XCTAssertEqual(records.map(\.seq), [1, 2, 3])
        XCTAssertEqual(records.map(\.command), [.startDictation, .stopDictation, .killSession])
        XCTAssertEqual(records.map(\.issuedAtMillis), [100, 200, 300])
        XCTAssertEqual(records[0].requestUUID, request)
        XCTAssertEqual(records.map(\.keyboardInstanceNonce), [nonce, nonce, nonce])
        XCTAssertEqual(drainer.lastDrainedSeq, 3)
    }

    func testPartialDrainsReturnOnlyNewRecords() throws {
        let writer = try CommandMailboxWriter(directory: directory)
        let drainer = CommandMailboxDrainer(directory: directory)

        writer.post(.startDictation, keyboardInstanceNonce: nonce)
        writer.post(.cancel, keyboardInstanceNonce: nonce)
        XCTAssertEqual(drainer.drain().map(\.seq), [1, 2])
        XCTAssertEqual(drainer.drain(), [], "drained twice — a coalesced hint must be a no-op")

        writer.post(.startDictation, keyboardInstanceNonce: nonce)
        writer.post(.stopDictation, keyboardInstanceNonce: nonce)
        XCTAssertEqual(drainer.drain().map(\.seq), [3, 4])
    }

    func testDrainWithoutMailboxOrRecordsIsEmpty() throws {
        let drainer = CommandMailboxDrainer(directory: directory)
        XCTAssertEqual(drainer.drain(), [], "no mailbox file yet — degraded, not fatal")
        _ = try CommandMailboxWriter(directory: directory)
        XCTAssertEqual(drainer.drain(), [], "mailbox exists but nothing was ever posted")
    }

    func testLapReturnsOnlyTheSurvivingWindow() throws {
        let writer = try CommandMailboxWriter(directory: directory)
        let drainer = CommandMailboxDrainer(directory: directory)
        let posted = CommandMailbox.capacity + 5 // seqs 1…69; 1…5 overwritten
        for index in 1...posted {
            writer.post(.startDictation, keyboardInstanceNonce: nonce,
                        issuedAtMillis: UInt64(index))
        }
        let records = drainer.drain()
        XCTAssertEqual(records.count, CommandMailbox.capacity)
        XCTAssertEqual(records.first?.seq, 6, "oldest surviving record after the lap")
        XCTAssertEqual(records.last?.seq, UInt32(posted))
        XCTAssertEqual(records.map(\.seq), records.map(\.seq).sorted())
    }

    func testWriterReopenContinuesSeq() throws {
        try CommandMailboxWriter(directory: directory)
            .post(.startDictation, keyboardInstanceNonce: nonce)
        // New keyboard instance over the same mailbox file.
        let seq = try CommandMailboxWriter(directory: directory)
            .post(.stopDictation, keyboardInstanceNonce: UUID())
        XCTAssertEqual(seq, 2)
        XCTAssertEqual(CommandMailboxDrainer(directory: directory).drain().map(\.seq), [1, 2])
    }

    func testSeededCursorSkipsAlreadyDrainedRecords() throws {
        let writer = try CommandMailboxWriter(directory: directory)
        writer.post(.startDictation, keyboardInstanceNonce: nonce)
        writer.post(.stopDictation, keyboardInstanceNonce: nonce)
        writer.post(.cancel, keyboardInstanceNonce: nonce)
        // App relaunch, persisted ack watermark = 2.
        let drainer = CommandMailboxDrainer(directory: directory, lastDrainedSeq: 2)
        XCTAssertEqual(drainer.drain().map(\.seq), [3])
    }

    func testStaleCursorAgainstRecreatedMailboxRewinds() throws {
        let writer = try CommandMailboxWriter(directory: directory)
        writer.post(.startDictation, keyboardInstanceNonce: nonce)
        // The app remembers seq 100 from a mailbox that no longer exists
        // (container wiped / keyboard reinstalled) — it must not go deaf.
        let drainer = CommandMailboxDrainer(directory: directory, lastDrainedSeq: 100)
        XCTAssertEqual(drainer.drain().map(\.seq), [1])
    }

    func testCorruptHeaderDrainsNothing() throws {
        _ = try CommandMailboxWriter(directory: directory)
        let url = directory.appendingPathComponent(KeyboardIPC.commandMailboxFileName)
        let poke = try XCTUnwrap(
            MappedFile(url: url, byteCount: CommandMailbox.byteCount, mode: .readWrite))
        poke.storeUInt32(0, at: CommandMailbox.HeaderOffset.magic)
        XCTAssertEqual(CommandMailboxDrainer(directory: directory).drain(), [])
    }
}
