import Foundation

/// One stable, checksummed read of the partial page. `Equatable` so the
/// keyboard's ~20Hz poll can cheaply skip no-op UI updates. An EMPTY page
/// (cleared: no text, zero nonce) is a valid snapshot meaning "no preview
/// right now" — distinct from `read()` returning nil (no truth this tick).
public struct PartialSnapshot: Equatable {
    /// The START command's keyboardInstanceNonce, echoed by the app —
    /// diagnostic identity of the instance that OPENED the segment. NOT the
    /// keyboard's render gate: display is phase-gated instead (see
    /// `KeyboardSession.updatePartialText` — a fresh instance after the
    /// arming round trip must still render the auto-started segment's
    /// preview); only transcript INSERTION is nonce-strict.
    public let keyboardInstanceNonce: UUID
    /// Tail-kept UTF-8 preview text (`PartialPage` layout); empty when no
    /// segment is streaming.
    public let text: String

    public init(keyboardInstanceNonce: UUID, text: String) {
        self.keyboardInstanceNonce = keyboardInstanceNonce
        self.text = text
    }
}

/// Keyboard-side reader of the partial page, the sibling of
/// `StatusPageReader` with the same nil philosophy: nil covers every degraded
/// case identically (no page yet, writer mid-write for the whole retry
/// budget, dead writer, wrong version, corrupt bytes, invalid UTF-8) because
/// the keyboard's response is the same for all of them — hold the current
/// preview this tick and try again next tick. The preview is display-only, so
/// nothing downstream ever needs to distinguish the failures.
public final class PartialPageReader {
    private let directory: URL
    private var map: MappedFile?

    /// `directory` is the App Group container root in production (see
    /// `SharedContainer`), any temp directory in tests. Mapping is lazy: the
    /// app may not have created the page yet when the keyboard first polls.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The seqlock read, adapted for a generation word that sits mid-page
    /// (offset 28, between header and text): load generation, skip if odd,
    /// copy the WHOLE page, re-load generation, retry on mismatch. Decoding
    /// then works entirely on the copy and never looks at its bytes 28..<32.
    /// After a stable read, any magic/version/bounds/checksum failure means
    /// the page is dead — nil immediately, no retry, never "zeroed state".
    public func read(maxRetries: Int = 8) -> PartialSnapshot? {
        guard let map = mapIfNeeded() else { return nil }
        var copy = [UInt8](repeating: 0, count: PartialPage.byteCount)
        for _ in 0...maxRetries {
            let before = map.loadUInt32(at: PartialPage.Offset.generation)
            if before % 2 == 1 { continue } // write in progress
            copy.withUnsafeMutableBytes { dst in
                dst.copyMemory(
                    from: UnsafeRawBufferPointer(start: map.base, count: PartialPage.byteCount))
            }
            let after = map.loadUInt32(at: PartialPage.Offset.generation)
            if before != after { continue } // torn: writer got in between
            return copy.withUnsafeBytes(Self.decode)
        }
        return nil
    }

    private func mapIfNeeded() -> MappedFile? {
        if let map { return map }
        let url = directory.appendingPathComponent(KeyboardIPC.partialPageFileName)
        map = MappedFile(url: url, byteCount: PartialPage.byteCount, mode: .readOnly)
        return map
    }

    private static func decode(_ bytes: UnsafeRawBufferPointer) -> PartialSnapshot? {
        func u16(_ offset: Int) -> UInt16 {
            UInt16(littleEndian: bytes.load(fromByteOffset: offset, as: UInt16.self))
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(littleEndian: bytes.load(fromByteOffset: offset, as: UInt32.self))
        }
        let textByteCount = Int(u16(PartialPage.Offset.textByteCount))
        guard u32(PartialPage.Offset.magic) == PartialPage.magic,
              u16(PartialPage.Offset.version) == PartialPage.version,
              textByteCount <= PartialPage.textCapacity
        else { return nil }
        let textRegion = bytes[
            PartialPage.Offset.text..<(PartialPage.Offset.text + textByteCount)]
        guard u32(PartialPage.Offset.checksum) == CRC32.checksum(regions: [
            UnsafeRawBufferPointer(rebasing: bytes[..<PartialPage.Offset.checksum]),
            UnsafeRawBufferPointer(rebasing: textRegion),
        ])
        else { return nil }
        // Strict UTF-8: the writer only ever emits whole Characters, so a
        // checksummed page that fails to decode is a writer bug — dead page,
        // never U+FFFD garbage on the user's screen.
        guard let text = String(bytes: textRegion, encoding: .utf8) else { return nil }
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[
                PartialPage.Offset.keyboardInstanceNonce..<PartialPage.Offset.checksum]))
        }
        return PartialSnapshot(keyboardInstanceNonce: UUID(uuid: uuid), text: text)
    }
}
