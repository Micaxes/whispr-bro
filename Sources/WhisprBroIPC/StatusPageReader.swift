import Foundation

/// One stable, checksummed read of the status page. `Equatable` so the
/// keyboard's ~20Hz poll can cheaply skip no-op UI updates.
public struct StatusSnapshot: Equatable {
    public let sessionState: SessionState
    /// Why the last session died (`.none` while healthy) — meaningful on an
    /// `.off` page, where the keyboard surfaces it as the error strip.
    public let errorCode: SessionErrorCode
    public let sessionUUID: UUID
    public let audioLevel: Float
    public let lastCommandAckSeq: UInt32
    public let lastAudioCallbackAtMillis: UInt64

    public init(
        sessionState: SessionState,
        errorCode: SessionErrorCode,
        sessionUUID: UUID,
        audioLevel: Float,
        lastCommandAckSeq: UInt32,
        lastAudioCallbackAtMillis: UInt64
    ) {
        self.sessionState = sessionState
        self.errorCode = errorCode
        self.sessionUUID = sessionUUID
        self.audioLevel = audioLevel
        self.lastCommandAckSeq = lastCommandAckSeq
        self.lastAudioCallbackAtMillis = lastAudioCallbackAtMillis
    }
}

/// Keyboard-side reader of the status page. `read()` returns a decoded
/// snapshot or nil — nil covers every degraded case identically (no page yet,
/// writer mid-write for the whole retry budget, dead writer, wrong version,
/// corrupt bytes) because the keyboard's response is the same for all of
/// them: this poll tick has no session truth, try again next tick and let
/// `Liveness` render the verdict from its own bookkeeping.
public final class StatusPageReader {
    private let directory: URL
    private var map: MappedFile?

    /// `directory` is the App Group container root in production (see
    /// `SharedContainer`), any temp directory in tests. Mapping is lazy: the
    /// app may not have created the page yet when the keyboard first polls.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The seqlock read from the `StatusPage` doc: load generation, skip if
    /// odd, copy bytes 0..<44, re-load generation, retry on mismatch. After a
    /// STABLE read, any magic/version/checksum failure means the page is dead
    /// (writer died mid-write or version skew) — nil immediately, no retry,
    /// and never "treat as zeroed state".
    public func read(maxRetries: Int = 8) -> StatusSnapshot? {
        guard let map = mapIfNeeded() else { return nil }
        let copiedByteCount = StatusPage.Offset.generation // payload + checksum
        var copy = [UInt8](repeating: 0, count: copiedByteCount)
        for _ in 0...maxRetries {
            let before = map.loadUInt32(at: StatusPage.Offset.generation)
            if before % 2 == 1 { continue } // write in progress
            copy.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: map.base, count: copiedByteCount))
            }
            let after = map.loadUInt32(at: StatusPage.Offset.generation)
            if before != after { continue } // torn: writer got in between
            return copy.withUnsafeBytes(Self.decode)
        }
        return nil
    }

    private func mapIfNeeded() -> MappedFile? {
        if let map { return map }
        let url = directory.appendingPathComponent(KeyboardIPC.statusPageFileName)
        map = MappedFile(url: url, byteCount: StatusPage.byteCount, mode: .readOnly)
        return map
    }

    private static func decode(_ bytes: UnsafeRawBufferPointer) -> StatusSnapshot? {
        func u16(_ offset: Int) -> UInt16 {
            UInt16(littleEndian: bytes.load(fromByteOffset: offset, as: UInt16.self))
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(littleEndian: bytes.load(fromByteOffset: offset, as: UInt32.self))
        }
        func u64(_ offset: Int) -> UInt64 {
            UInt64(littleEndian: bytes.load(fromByteOffset: offset, as: UInt64.self))
        }
        guard u32(StatusPage.Offset.magic) == StatusPage.magic,
              u16(StatusPage.Offset.version) == StatusPage.version,
              u32(StatusPage.Offset.checksum) == CRC32.checksum(
                  UnsafeRawBufferPointer(rebasing: bytes[..<StatusPage.Offset.checksum])),
              let state = SessionState(rawValue: bytes[StatusPage.Offset.sessionState])
        else { return nil }
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(
                rebasing: bytes[StatusPage.Offset.sessionUUID..<StatusPage.Offset.audioLevel]))
        }
        return StatusSnapshot(
            sessionState: state,
            // An unrecognized code (a future writer within version 1) decodes
            // as .none, not a dead page — unlike sessionState, the keyboard
            // can do nothing useful with a code it doesn't know.
            errorCode: SessionErrorCode(rawValue: bytes[StatusPage.Offset.errorCode]) ?? .none,
            sessionUUID: UUID(uuid: uuid),
            audioLevel: Float(bitPattern: u32(StatusPage.Offset.audioLevel)),
            lastCommandAckSeq: u32(StatusPage.Offset.lastCommandAckSeq),
            lastAudioCallbackAtMillis: u64(StatusPage.Offset.lastAudioCallbackAtMillis))
    }
}
