import XCTest

@testable import WhisprBroIPC

/// Partial page writer→reader round-trips, the tail-kept truncation contract
/// (never splitting a multi-byte Character), and the same "never trust a bad
/// page" paths as the status page: torn reads, CRC corruption, and — new
/// here, because the layout has a variable-length field — an out-of-bounds
/// textByteCount.
final class PartialPageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-ipc-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var pageURL: URL {
        directory.appendingPathComponent(KeyboardIPC.partialPageFileName)
    }

    private let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    func testFreshWriterPublishesEmptyPage() throws {
        _ = try PartialPageWriter(directory: directory)
        let snapshot = try XCTUnwrap(PartialPageReader(directory: directory).read())
        XCTAssertEqual(snapshot.text, "")
        XCTAssertEqual(snapshot.keyboardInstanceNonce, zeroUUID)
    }

    func testRoundTripCarriesTextAndNonce() throws {
        let writer = try PartialPageWriter(directory: directory)
        let reader = PartialPageReader(directory: directory)
        let nonce = UUID()

        writer.publish(text: "hello there — céci n'est pas une 🎤", nonce: nonce)
        var snapshot = try XCTUnwrap(reader.read())
        XCTAssertEqual(snapshot.text, "hello there — céci n'est pas une 🎤")
        XCTAssertEqual(snapshot.keyboardInstanceNonce, nonce, "the START command's nonce is the render guard")

        // Republish replaces (volatile preview semantics: latest text wins).
        writer.publish(text: "hello there general", nonce: nonce)
        snapshot = try XCTUnwrap(reader.read())
        XCTAssertEqual(snapshot.text, "hello there general")
    }

    func testClearEmptiesThePage() throws {
        let writer = try PartialPageWriter(directory: directory)
        let reader = PartialPageReader(directory: directory)
        writer.publish(text: "mid-segment preview", nonce: UUID())
        XCTAssertFalse(try XCTUnwrap(reader.read()).text.isEmpty)

        writer.clear()
        let snapshot = try XCTUnwrap(reader.read())
        XCTAssertEqual(snapshot.text, "", "a cleared page is VALID and empty, not dead")
        XCTAssertEqual(snapshot.keyboardInstanceNonce, zeroUUID)
    }

    func testOverflowKeepsTheTail() throws {
        let writer = try PartialPageWriter(directory: directory)
        let reader = PartialPageReader(directory: directory)
        // 1 byte per Character, so the clamp is byte-exact: the last
        // `textCapacity` characters survive, oldest speech dropped first.
        let text = String(repeating: "a", count: 3_000) + " the newest words"
        writer.publish(text: text, nonce: UUID())
        let kept = try XCTUnwrap(reader.read()).text
        XCTAssertEqual(kept.utf8.count, PartialPage.textCapacity)
        XCTAssertTrue(text.hasSuffix(kept), "tail-kept: the preview shows the most recent speech")
        XCTAssertTrue(kept.hasSuffix(" the newest words"))
    }

    func testOverflowNeverSplitsMultiByteCharacters() throws {
        let writer = try PartialPageWriter(directory: directory)
        let reader = PartialPageReader(directory: directory)
        // 25 UTF-8 bytes per family (4 scalars + 3 ZWJs); 2016 % 25 = 16, so
        // a byte-offset cut would land mid-emoji. The clamp must drop the
        // straddling Character whole: ⌊2016/25⌋ = 80 families = 2000 bytes.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.utf8.count, 25)
        let text = String(repeating: family, count: 100)
        writer.publish(text: text, nonce: UUID())
        let kept = try XCTUnwrap(reader.read()).text
        XCTAssertEqual(kept.utf8.count, 2_000)
        XCTAssertEqual(kept.count, 80)
        XCTAssertFalse(kept.unicodeScalars.contains("\u{FFFD}"), "no replacement-char debris")
        XCTAssertTrue(text.hasSuffix(kept))
    }

    func testTailClampRespectsCombiningSequences() {
        // "é" as e + U+0301 is one Character of 3 bytes: a 2-byte budget must
        // drop it whole (splitting would strand a combining mark), a 3-byte
        // budget keeps it whole.
        let text = "ne\u{301}"
        XCTAssertEqual(String(PartialPageWriter.tailClamped(text, maxBytes: 2)), "")
        XCTAssertEqual(String(PartialPageWriter.tailClamped(text, maxBytes: 3)), "e\u{301}")
        XCTAssertEqual(String(PartialPageWriter.tailClamped(text, maxBytes: 4)), "ne\u{301}")
    }

    func testMissingPageReadsNilThenAppearsAfterWriterStarts() throws {
        let reader = PartialPageReader(directory: directory)
        XCTAssertNil(reader.read(), "no page yet — degraded, not fatal")
        _ = try PartialPageWriter(directory: directory)
        XCTAssertNotNil(reader.read(), "the reader recovers once the writer creates the page")
    }

    func testTornReadOddGenerationRetriesThenNil() throws {
        let writer = try PartialPageWriter(directory: directory)
        writer.publish(text: "stable", nonce: UUID())
        let reader = PartialPageReader(directory: directory)
        XCTAssertNotNil(reader.read())

        // Simulate a writer that died mid-write: force the seqlock odd.
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: PartialPage.byteCount, mode: .readWrite))
        let even = poke.loadUInt32(at: PartialPage.Offset.generation)
        poke.storeUInt32(even | 1, at: PartialPage.Offset.generation)
        XCTAssertNil(reader.read(), "odd generation must exhaust retries and read as no-page")

        // Back to even: the exact same reader instance recovers.
        poke.storeUInt32(even, at: PartialPage.Offset.generation)
        XCTAssertEqual(try XCTUnwrap(reader.read()).text, "stable")
    }

    func testTextCorruptionFailsTheChecksum() throws {
        let writer = try PartialPageWriter(directory: directory)
        writer.publish(text: "checksummed text", nonce: UUID())
        let reader = PartialPageReader(directory: directory)
        XCTAssertNotNil(reader.read())

        // Flip a USED text byte without touching checksum or generation: a
        // stable read that fails CRC — dead page, never someone else's words.
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: PartialPage.byteCount, mode: .readWrite))
        poke.storeUInt8(UInt8(ascii: "X"), at: PartialPage.Offset.text)
        XCTAssertNil(reader.read())
    }

    func testWrongMagicAndVersionReadAsDeadPage() throws {
        let writer = try PartialPageWriter(directory: directory)
        writer.publish(text: "x", nonce: UUID())
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: PartialPage.byteCount, mode: .readWrite))

        let goodVersion = poke.loadUInt16(at: PartialPage.Offset.version)
        poke.storeUInt16(goodVersion &+ 1, at: PartialPage.Offset.version)
        XCTAssertNil(PartialPageReader(directory: directory).read(), "future version is unreadable")
        poke.storeUInt16(goodVersion, at: PartialPage.Offset.version)

        poke.storeUInt32(0, at: PartialPage.Offset.magic)
        XCTAssertNil(PartialPageReader(directory: directory).read(), "not our file")
    }

    func testOversizedTextByteCountReadsAsDeadPage() throws {
        let writer = try PartialPageWriter(directory: directory)
        writer.publish(text: "x", nonce: UUID())
        // Claim one byte more than the region holds, with the CRC recomputed
        // over the oversized claim so the BOUNDS check (not the checksum) is
        // what this pins — the reader must reject before trusting the count.
        // The claim reaches one byte PAST the mapped page, so the CRC input
        // is mirrored into a local buffer (the whole in-bounds text region
        // plus a zero tail byte) rather than read past `poke.base`.
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: PartialPage.byteCount, mode: .readWrite))
        let oversized = PartialPage.textCapacity + 1
        poke.storeUInt16(UInt16(oversized), at: PartialPage.Offset.textByteCount)
        var claimed = [UInt8](repeating: 0, count: oversized)
        claimed.withUnsafeMutableBytes { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(
                start: poke.base + PartialPage.Offset.text, count: PartialPage.textCapacity))
        }
        let crc = claimed.withUnsafeBytes { claim in
            CRC32.checksum(regions: [
                UnsafeRawBufferPointer(start: poke.base, count: PartialPage.Offset.checksum),
                claim,
            ])
        }
        poke.storeUInt32(crc, at: PartialPage.Offset.checksum)
        XCTAssertNil(PartialPageReader(directory: directory).read())
    }

    func testInvalidUTF8ReadsAsDeadPage() throws {
        let writer = try PartialPageWriter(directory: directory)
        writer.publish(text: "ok", nonce: UUID())
        // A CRC-valid page whose text is not UTF-8 is a writer bug — strict
        // decode returns nil rather than painting U+FFFD debris.
        let poke = try XCTUnwrap(
            MappedFile(url: pageURL, byteCount: PartialPage.byteCount, mode: .readWrite))
        poke.storeBytes([0xFF, 0xFE], at: PartialPage.Offset.text)
        poke.storeUInt32(CRC32.checksum(regions: [
            UnsafeRawBufferPointer(start: poke.base, count: PartialPage.Offset.checksum),
            UnsafeRawBufferPointer(start: poke.base + PartialPage.Offset.text, count: 2),
        ]), at: PartialPage.Offset.checksum)
        XCTAssertNil(PartialPageReader(directory: directory).read())
    }

    func testWriterRestartClearsPredecessorText() throws {
        let first = try PartialPageWriter(directory: directory)
        first.publish(text: "jetsamed mid-segment", nonce: UUID())
        // App relaunch: the second writer's init must present a fresh empty
        // page to a reader that never re-mapped — never leftover preview.
        let reader = PartialPageReader(directory: directory)
        XCTAssertEqual(try XCTUnwrap(reader.read()).text, "jetsamed mid-segment")
        let second = try PartialPageWriter(directory: directory)
        _ = second
        XCTAssertEqual(try XCTUnwrap(reader.read()).text, "")
    }
}
