import Foundation

/// The one exception to "the bring-up flush acks + discards, never executes"
/// (`SessionIPC.begin`): a keyboard-armed session's own `startDictation`. The
/// keyboard's arming tap posts start into the mailbox BEFORE deep-linking, so
/// the command is already waiting when the app arms — preserving it across
/// the flush and executing it the moment the session goes live is what makes
/// segment 1 record while the user is still swiping back (Wispr parity: one
/// tap, no second tap on return).
public enum SessionStartFlush {
    /// Age ceiling for a startDictation preserved across session bring-up:
    /// generous against a slow cold launch (the deep link can take seconds to
    /// foreground the app), but far below any plausible "the user tapped mic
    /// yesterday and this start is a fossil" window.
    public static let preservedStartMaxAgeMillis: UInt64 = 20_000

    /// Partition a bring-up flush: ONLY the newest startDictation no older
    /// than the ceiling is preserved (stashed by `begin`, executed once the
    /// session goes live); every other record — older starts even when
    /// young, and all non-starts — is discarded. Newest-only because two
    /// young starts in one flush means an ORPHAN is among them (a jetsammed
    /// prior session's never-drained arming tap): delivered first, it would
    /// key segment 1's result and partial stream to a dead keyboard's nonce.
    /// The tap that armed THIS session is by construction the last one
    /// posted, so "newest" is mailbox order (records drain oldest-first) —
    /// not issuedAtMillis, which cross-process clock skew can reorder.
    /// Callers ack ALL records either way (ack proves "drained", never
    /// "executed"). "Older than" is strict, mirroring `Liveness`: age exactly
    /// at the ceiling still preserves. Age math is underflow-safe — a future
    /// issuedAtMillis (clock skew) counts as young. Discards keep input
    /// order (oldest first).
    public static func partition(
        _ records: [CommandRecord], nowMillis: UInt64
    ) -> (preserved: [CommandRecord], discarded: [CommandRecord]) {
        var newestYoungStart: CommandRecord?
        for record in records {
            let age = nowMillis >= record.issuedAtMillis
                ? nowMillis - record.issuedAtMillis : 0
            if record.command == .startDictation, age <= preservedStartMaxAgeMillis {
                newestYoungStart = record // last young start in drain order wins
            }
        }
        guard let preserved = newestYoungStart else { return ([], records) }
        return ([preserved], records.filter { $0.seq != preserved.seq })
    }
}
