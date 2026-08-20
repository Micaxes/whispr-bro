import Foundation

/// App-side single writer of the 2048-byte partial page (`PartialPage`
/// layout) — the live-preview transcript for the open dictation segment.
/// Every publish rewrites the whole used region under one seqlock cycle, like
/// the status page: at ~10Hz for ≤2KB the CRC is microseconds, and any
/// stable, checksummed read is one writer state, never a mix of two.
///
/// Not thread-safe by itself: the app funnels all partial-page writes through
/// the same serial control queue as the status page, so "single writer" means
/// one process AND one queue.
public final class PartialPageWriter {
    private let map: MappedFile
    private var generation: UInt32

    /// Maps (creating if needed) `session.partial` inside `directory` — the
    /// App Group container root in production, any temp directory in tests —
    /// and immediately publishes a valid EMPTY page: after a relaunch the
    /// keyboard must read "no preview", never a jetsamed predecessor's
    /// leftover text (or raw zeroes it would treat as a dead page forever).
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(KeyboardIPC.partialPageFileName)
        guard let map = MappedFile(url: url, byteCount: PartialPage.byteCount, mode: .readWrite) else {
            throw IPCError.cannotMap(url)
        }
        self.map = map
        // Continue the seqlock from whatever a previous writer left behind —
        // rounding an odd (died-mid-write) generation up to even — so a
        // reader holding the old mapping can never confuse our first publish
        // with a generation it already validated.
        let inherited = map.loadUInt32(at: PartialPage.Offset.generation)
        generation = inherited % 2 == 1 ? inherited &+ 1 : inherited
        clear()
    }

    /// Publish the segment's preview text so far for `nonce` (the START
    /// command's keyboardInstanceNonce). Text beyond `PartialPage.textCapacity`
    /// UTF-8 bytes is tail-kept per the layout contract: whole leading
    /// Characters are dropped until the rest fits, so an emoji or combining
    /// sequence is never split mid-character.
    public func publish(text: String, nonce: UUID) {
        publish(textBytes: Array(Self.tailClamped(text).utf8), nonce: nonce)
    }

    /// Back to the empty page (no text, zero nonce) — the segment closed, or
    /// a fresh writer is erasing its predecessor's state.
    public func clear() {
        publish(textBytes: [], nonce: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
    }

    /// Keep the TAIL of `text` within the text-region capacity, walking whole
    /// Characters backwards from the end — a UTF-8 sequence (emoji, combining
    /// marks) is dropped or kept atomically, never split. O(length) per call,
    /// which at ~10Hz over a few KB of dictation text is negligible.
    static func tailClamped(_ text: String, maxBytes: Int = PartialPage.textCapacity) -> Substring {
        guard text.utf8.count > maxBytes else { return text[...] }
        var start = text.endIndex
        var used = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            used += text[previous..<start].utf8.count
            if used > maxBytes { break }
            start = previous
        }
        return text[start...]
    }

    /// The seqlock cycle from the `PartialPage` doc: generation to odd,
    /// header + text, checksum over bytes 0..<24 + the used text bytes,
    /// generation to even. The unused text tail is left as-is — it sits
    /// outside the checksum and outside every reader's decoded region.
    private func publish(textBytes: [UInt8], nonce: UUID) {
        generation &+= 1
        map.storeUInt32(generation, at: PartialPage.Offset.generation) // odd: in progress
        map.storeUInt32(PartialPage.magic, at: PartialPage.Offset.magic)
        map.storeUInt16(PartialPage.version, at: PartialPage.Offset.version)
        map.storeUInt16(UInt16(textBytes.count), at: PartialPage.Offset.textByteCount)
        map.storeUUID(nonce, at: PartialPage.Offset.keyboardInstanceNonce)
        map.storeBytes(textBytes, at: PartialPage.Offset.text)
        let crc = CRC32.checksum(regions: [
            UnsafeRawBufferPointer(start: map.base, count: PartialPage.Offset.checksum),
            UnsafeRawBufferPointer(
                start: map.base + PartialPage.Offset.text, count: textBytes.count),
        ])
        map.storeUInt32(crc, at: PartialPage.Offset.checksum)
        generation &+= 1
        map.storeUInt32(generation, at: PartialPage.Offset.generation) // even: stable
    }
}
