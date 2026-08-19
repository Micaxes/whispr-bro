import Foundation

/// App-side single writer of the 64-byte status page (`StatusPage` layout).
/// Every mutator republishes the whole 40-byte payload under one seqlock
/// cycle — at ~30Hz for a 40-byte CRC that is nanoseconds, and it keeps the
/// invariant trivially: any stable, checksummed read is one writer state, not
/// a mix of two.
///
/// Not thread-safe by itself: the app funnels all status writes through its
/// control queue (the same serial queue that drains the mailbox and acks), so
/// "single writer" means one process AND one queue.
public final class StatusPageWriter {
    private let map: MappedFile
    private var generation: UInt32

    // The writer's authoritative copy of the payload; the page is a
    // projection of these.
    private var sessionState: SessionState = .off
    private var sessionUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private var audioLevel: Float = 0
    private var lastCommandAckSeq: UInt32 = 0
    private var lastAudioCallbackAtMillis: UInt64 = 0

    /// Maps (creating if needed) `session.status` inside `directory` — the
    /// App Group container root in production, any temp directory in tests —
    /// and immediately publishes a valid `.off` page: after a relaunch the
    /// keyboard must see "no session" (fresh page, ack/heartbeat zeroed), not
    /// the live-looking leftovers of a jetsamed predecessor.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(KeyboardIPC.statusPageFileName)
        guard let map = MappedFile(url: url, byteCount: StatusPage.byteCount, mode: .readWrite) else {
            throw IPCError.cannotMap(url)
        }
        self.map = map
        // Continue the seqlock from whatever a previous writer left behind —
        // rounding an odd (died-mid-write) generation up to even — so a
        // reader holding the old mapping can never confuse our first publish
        // with a generation it already validated.
        let inherited = map.loadUInt32(at: StatusPage.Offset.generation)
        generation = inherited % 2 == 1 ? inherited &+ 1 : inherited
        publish()
    }

    /// A session is arming: fresh sessionUUID (the keyboard detects a session
    /// restart beneath it by this changing), audio fields reset.
    public func beginSession(sessionUUID: UUID = UUID()) {
        self.sessionUUID = sessionUUID
        sessionState = .arming
        audioLevel = 0
        lastAudioCallbackAtMillis = 0
        publish()
    }

    public func transition(to state: SessionState) {
        sessionState = state
        publish()
    }

    /// The ~30Hz hot path, called from the audio tap's callback hand-off:
    /// level for the waveform plus the capture-liveness heartbeat.
    public func recordAudio(level: Float, callbackAtMillis: UInt64 = KeyboardIPC.nowMillis()) {
        audioLevel = min(max(level, 0), 1)
        lastAudioCallbackAtMillis = callbackAtMillis
        publish()
    }

    /// Ack a drained mailbox seq (monotonic — a stale replay can never lower
    /// it). Per `Liveness`, this must be called the moment the record is
    /// drained, before any model work.
    public func acknowledge(commandSeq: UInt32) {
        lastCommandAckSeq = max(lastCommandAckSeq, commandSeq)
        publish()
    }

    /// The seqlock cycle from the `StatusPage` doc: generation to odd,
    /// payload, checksum over bytes 0..<40, generation to even.
    private func publish() {
        generation &+= 1
        map.storeUInt32(generation, at: StatusPage.Offset.generation) // odd: in progress
        map.storeUInt32(StatusPage.magic, at: StatusPage.Offset.magic)
        map.storeUInt16(StatusPage.version, at: StatusPage.Offset.version)
        map.storeUInt8(sessionState.rawValue, at: StatusPage.Offset.sessionState)
        map.storeUInt8(0, at: StatusPage.Offset.sessionState + 1) // reserved
        map.storeUUID(sessionUUID, at: StatusPage.Offset.sessionUUID)
        map.storeFloat(audioLevel, at: StatusPage.Offset.audioLevel)
        map.storeUInt32(lastCommandAckSeq, at: StatusPage.Offset.lastCommandAckSeq)
        map.storeUInt64(lastAudioCallbackAtMillis, at: StatusPage.Offset.lastAudioCallbackAtMillis)
        let crc = CRC32.checksum(
            UnsafeRawBufferPointer(start: map.base, count: StatusPage.Offset.checksum))
        map.storeUInt32(crc, at: StatusPage.Offset.checksum)
        generation &+= 1
        map.storeUInt32(generation, at: StatusPage.Offset.generation) // even: stable
    }
}
