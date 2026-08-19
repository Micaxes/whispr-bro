import Foundation

/// Keyboard-side single writer of the command mailbox ring (`CommandMailbox`
/// layout). Not thread-safe by itself — the keyboard posts from the main
/// thread only.
public final class CommandMailboxWriter {
    private let map: MappedFile
    private var nextSeq: UInt32

    /// Maps (creating if needed) `session.mailbox` inside `directory`. A
    /// pre-existing valid mailbox is continued — seq keeps rising across
    /// keyboard instances, which is what lets the app's drainer trust "new =
    /// seq > lastDrained". An invalid header (fresh file, or garbage) is
    /// (re)initialized with lastWrittenSeq = 0.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(KeyboardIPC.commandMailboxFileName)
        guard let map = MappedFile(url: url, byteCount: CommandMailbox.byteCount, mode: .readWrite) else {
            throw IPCError.cannotMap(url)
        }
        self.map = map
        let headerValid = map.loadUInt32(at: CommandMailbox.HeaderOffset.magic) == CommandMailbox.magic
            && map.loadUInt16(at: CommandMailbox.HeaderOffset.version) == CommandMailbox.version
        if !headerValid {
            map.storeUInt32(0, at: CommandMailbox.HeaderOffset.lastWrittenSeq)
            map.storeUInt16(CommandMailbox.version, at: CommandMailbox.HeaderOffset.version)
            // Magic last: a drainer racing this init sees either not-a-mailbox
            // or a fully initialized one.
            map.storeUInt32(CommandMailbox.magic, at: CommandMailbox.HeaderOffset.magic)
        }
        nextSeq = map.loadUInt32(at: CommandMailbox.HeaderOffset.lastWrittenSeq) &+ 1
    }

    /// Appends one record and returns its seq (the keyboard remembers it,
    /// with `issuedAtMillis`, as the `Liveness` ack-stale inputs). Write
    /// order per the contract: fill the slot fully, then publish
    /// lastWrittenSeq — the drainer never sees a seq whose record is torn.
    @discardableResult
    public func post(
        _ command: KeyboardCommand,
        requestUUID: UUID = UUID(),
        keyboardInstanceNonce: UUID,
        issuedAtMillis: UInt64 = KeyboardIPC.nowMillis()
    ) -> UInt32 {
        if nextSeq == 0 { nextSeq = 1 } // seq is never 0 (= "nothing posted")
        let seq = nextSeq
        nextSeq &+= 1
        let slot = Int(seq % UInt32(CommandMailbox.capacity))
        let base = CommandMailbox.headerByteCount + slot * CommandMailbox.recordByteCount
        map.storeUInt32(seq, at: base + CommandMailbox.RecordOffset.seq)
        map.storeUInt8(command.rawValue, at: base + CommandMailbox.RecordOffset.command)
        for reserved in 1...3 { // reserved bytes 5..<8
            map.storeUInt8(0, at: base + CommandMailbox.RecordOffset.command + reserved)
        }
        map.storeUUID(requestUUID, at: base + CommandMailbox.RecordOffset.requestUUID)
        map.storeUUID(keyboardInstanceNonce, at: base + CommandMailbox.RecordOffset.keyboardInstanceNonce)
        map.storeUInt64(issuedAtMillis, at: base + CommandMailbox.RecordOffset.issuedAtMillis)
        map.storeUInt32(seq, at: CommandMailbox.HeaderOffset.lastWrittenSeq) // publish
        return seq
    }
}
