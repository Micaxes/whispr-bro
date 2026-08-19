import Foundation

/// One decoded mailbox record (`CommandMailbox` record layout).
public struct CommandRecord: Equatable {
    public let seq: UInt32
    public let command: KeyboardCommand
    public let requestUUID: UUID
    public let keyboardInstanceNonce: UUID
    public let issuedAtMillis: UInt64

    public init(
        seq: UInt32,
        command: KeyboardCommand,
        requestUUID: UUID,
        keyboardInstanceNonce: UUID,
        issuedAtMillis: UInt64
    ) {
        self.seq = seq
        self.command = command
        self.requestUUID = requestUUID
        self.keyboardInstanceNonce = keyboardInstanceNonce
        self.issuedAtMillis = issuedAtMillis
    }
}

/// App-side reader of the command mailbox. `drain()` is the file-backed
/// recovery path behind every coalesced/dropped Darwin hint: it returns ALL
/// records with seq > the last drained seq, in seq order, no matter how many
/// hints were lost. The app calls it on each command hint, on foreground, and
/// on a slow poll while a session is live — and acks each drained seq on the
/// status page immediately (`StatusPageWriter.acknowledge`).
public final class CommandMailboxDrainer {
    private let directory: URL
    private var map: MappedFile?

    public private(set) var lastDrainedSeq: UInt32

    /// `lastDrainedSeq` seeds the cursor across app relaunches (the app can
    /// pass its own persisted ack watermark); 0 means "never drained, take
    /// everything present". Mapping is lazy: the keyboard may not have
    /// created the mailbox yet.
    public init(directory: URL, lastDrainedSeq: UInt32 = 0) {
        self.directory = directory
        self.lastDrainedSeq = lastDrainedSeq
    }

    public func drain() -> [CommandRecord] {
        guard let map = mapIfNeeded(),
              map.loadUInt32(at: CommandMailbox.HeaderOffset.magic) == CommandMailbox.magic,
              map.loadUInt16(at: CommandMailbox.HeaderOffset.version) == CommandMailbox.version
        else { return [] }
        let lastWritten = map.loadUInt32(at: CommandMailbox.HeaderOffset.lastWrittenSeq)
        if lastWritten < lastDrainedSeq {
            // The mailbox restarted beneath a stale cursor (container wiped /
            // keyboard reinstalled): rewind rather than ignore new commands
            // forever.
            lastDrainedSeq = 0
        }
        guard lastWritten > lastDrainedSeq else { return [] }
        var first = lastDrainedSeq &+ 1
        if lastWritten - first >= UInt32(CommandMailbox.capacity) {
            // Lapped (>64 behind — an already-dead scenario per `Liveness`,
            // but never decode overwritten slots): oldest surviving record.
            first = lastWritten - (UInt32(CommandMailbox.capacity) - 1)
        }
        var records: [CommandRecord] = []
        for seq in first...lastWritten {
            if let record = Self.record(at: seq, in: map) { records.append(record) }
        }
        lastDrainedSeq = lastWritten
        return records
    }

    private func mapIfNeeded() -> MappedFile? {
        if let map { return map }
        let url = directory.appendingPathComponent(KeyboardIPC.commandMailboxFileName)
        map = MappedFile(url: url, byteCount: CommandMailbox.byteCount, mode: .readOnly)
        return map
    }

    /// Decodes the slot for `seq`, or nil if the slot doesn't hold `seq`
    /// (overwritten by a lap between our header read and this decode) or the
    /// command byte is from a future keyboard this app doesn't know — skipped,
    /// never fatal.
    private static func record(at seq: UInt32, in map: MappedFile) -> CommandRecord? {
        let slot = Int(seq % UInt32(CommandMailbox.capacity))
        let base = CommandMailbox.headerByteCount + slot * CommandMailbox.recordByteCount
        guard map.loadUInt32(at: base + CommandMailbox.RecordOffset.seq) == seq,
              let command = KeyboardCommand(
                  rawValue: map.loadUInt8(at: base + CommandMailbox.RecordOffset.command))
        else { return nil }
        return CommandRecord(
            seq: seq,
            command: command,
            requestUUID: map.loadUUID(at: base + CommandMailbox.RecordOffset.requestUUID),
            keyboardInstanceNonce: map.loadUUID(
                at: base + CommandMailbox.RecordOffset.keyboardInstanceNonce),
            issuedAtMillis: map.loadUInt64(at: base + CommandMailbox.RecordOffset.issuedAtMillis))
    }
}
