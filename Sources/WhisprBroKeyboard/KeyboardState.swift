import Foundation

/// Keyboard ↔ app IPC contract (issue #13, phases P4/P5). Layout constants and
/// spec only — the mmap reader/writer, mailbox drain loop, and Darwin plumbing
/// land with the session work.
///
/// The App Group container carries exactly three artifacts — the status page
/// (app → keyboard), the command mailbox (keyboard → app), and transcript
/// results — and nothing else. Not UserDefaults, not CFMessagePort
/// (sandbox-blocked on iOS). Audio never enters the container: PCM lives only
/// in a bounded in-process ring inside the main app (90s cap @ 16kHz mono
/// Float32 ≈ 5.6MB — trivially in-RAM). Shared-container PCM would be flash
/// wear + file-protection complexity + sensitive audio at rest, for a reader
/// (the keyboard) that can never consume audio anyway. The keyboard's ~48MB
/// jetsam floor is the design ceiling for everything this extension maps or
/// reads; each mmap file below fits in a single 16KB VM page.
///
/// Both hot-path files are explicit fixed-layout binary, all fields
/// little-endian (every supported device is LE arm64; stated so a hex dump is
/// unambiguous). The offsets are an ABI between two independently-updated
/// processes — NEVER write a raw Swift struct dump: Swift layout is
/// unspecified and can change across compiler versions, silently breaking a
/// mixed keyboard/app pair mid-update.
enum KeyboardIPC {
    /// Shared container holding all three IPC artifacts.
    static let appGroupID = "group.com.micaxes.whispr-bro"
    /// Status page (app-owned, app is the single writer), relative to the
    /// container root. Byte layout in `StatusPage`.
    static let statusPageFileName = "session.status"
    /// Command mailbox (keyboard-owned, keyboard is the single writer). Byte
    /// layout in `CommandMailbox`.
    static let commandMailboxFileName = "session.mailbox"
    /// Directory of per-request transcript result files. See
    /// `TranscriptResult`.
    static let resultsDirectoryName = "session.results"

    /// Darwin notification names. Darwin is a HINT channel only: delivery
    /// coalesces under load, carries no payload, and can never wake a
    /// suspended process (DTS-verified) — so no notification is ever the sole
    /// carrier of state. Every hint has a file-backed recovery path: the app
    /// drains the mailbox by seq on each hint AND on foreground AND on a slow
    /// poll while a session is live; the keyboard polls the status page at
    /// ~20Hz while visible regardless of hints.
    static let commandHintName = "bro.whispr.session.command"
    static let statusHintName = "bro.whispr.session.status"
    static let resultHintName = "bro.whispr.session.result"
}

/// Session lifecycle as the keyboard sees it (raw value = the byte at
/// `StatusPage.Offset.sessionState`). Off → (mic tap deep-links to the app) →
/// arming → (app foregrounds, continuous capture starts) → live → (mailbox
/// startDictation) → dictating → live … → off on idle timeout / one-tap kill /
/// audio interruption / jetsam.
enum SessionState: UInt8 {
    case off = 0
    case arming = 1
    case live = 2
    case dictating = 3
}

/// Commands the keyboard may post (raw value = the command byte in a mailbox
/// record).
enum KeyboardCommand: UInt8 {
    case startDictation = 1
    case stopDictation = 2
    case cancel = 3
    case killSession = 4
}

/// STATUS PAGE — app → keyboard, mmap'd, exactly one writer (the app) and one
/// reader (the keyboard). 64 bytes, fixed layout:
///
///     offset  size  field
///     0       4     magic                      UInt32  0x5742_5350 "WBSP"
///     4       2     version                    UInt16  currently 1
///     6       1     sessionState               UInt8   `SessionState` raw value
///     7       1     reserved                   zero
///     8       16    sessionUUID                raw uuid_t bytes; regenerated
///                                              each time a session arms, so
///                                              the keyboard can detect a
///                                              session restart beneath it
///     24      4     audioLevel                 Float32 0…1, written per audio
///                                              callback; drives the waveform
///     28      4     lastCommandAckSeq          UInt32  highest mailbox seq the
///                                              app has DRAINED (ack ≠ done,
///                                              see `Liveness`)
///     32      8     lastAudioCallbackAtMillis  UInt64  Unix ms, stamped from
///                                              the audio tap callback — the
///                                              capture-liveness heartbeat
///     40      4     checksum                   UInt32  CRC-32 (zlib/IEEE) of
///                                              bytes 0..<40
///     44      4     generation                 UInt32  seqlock, see below
///     48      16    reserved                   zero
///
/// Seqlock protocol (generation sits deliberately outside the checksum): the
/// writer bumps generation to ODD (release store — odd = write in progress),
/// writes the payload, computes the checksum, then bumps generation to EVEN.
/// The reader acquire-loads generation, retries while odd, copies bytes
/// 0..<44, re-loads generation, and retries on mismatch. A magic/version/
/// checksum failure after a stable read means the writer died mid-write or the
/// file predates this version — treat the page as dead, never as zeroed state.
enum StatusPage {
    static let magic: UInt32 = 0x5742_5350
    static let version: UInt16 = 1
    static let byteCount = 64

    enum Offset {
        static let magic = 0
        static let version = 4
        static let sessionState = 6
        static let sessionUUID = 8
        static let audioLevel = 24
        static let lastCommandAckSeq = 28
        static let lastAudioCallbackAtMillis = 32
        static let checksum = 40
        static let generation = 44
    }
}

/// COMMAND MAILBOX — keyboard → app, mmap'd ring, exactly one writer (the
/// keyboard) and one reader (the app). The Darwin command hint only says
/// "look at the mailbox"; because hints coalesce and drop, the app recovers
/// losses by draining every record with seq > its last-drained seq, in seq
/// order. 16-byte header + 64 records × 48 bytes = 3088 bytes:
///
///     header offset  size  field
///     0              4     magic           UInt32  0x5742_4D42 "WBMB"
///     4              2     version         UInt16  currently 1
///     6              2     reserved        zero
///     8              4     lastWrittenSeq  UInt32  0 = no command ever posted
///     12             4     reserved        zero
///
///     record offset  size  field
///     0              4     seq                    UInt32  starts at 1, never 0
///     4              1     command                UInt8   `KeyboardCommand`
///     5              3     reserved               zero
///     8              16    requestUUID            raw uuid_t; fresh per
///                                                 command, keys the result
///     24             16    keyboardInstanceNonce  raw uuid_t; see
///                                                 `TranscriptResult`
///     40             8     issuedAtMillis         UInt64  Unix ms
///
/// The record for seq N lives in slot N % 64 (byte offset 16 + slot × 48).
/// Write order: fill the record bytes fully, then publish lastWrittenSeq = N
/// (release store) — the reader never sees a seq whose record is torn. 64
/// slots is far beyond any real backlog: a keyboard that laps an unresponsive
/// app has long since flipped to the bounce key (`Liveness`).
enum CommandMailbox {
    static let magic: UInt32 = 0x5742_4D42
    static let version: UInt16 = 1
    static let capacity = 64
    static let headerByteCount = 16
    static let recordByteCount = 48
    static let byteCount = 3088

    enum HeaderOffset {
        static let magic = 0
        static let version = 4
        static let lastWrittenSeq = 8
    }

    enum RecordOffset {
        static let seq = 0
        static let command = 4
        static let requestUUID = 8
        static let keyboardInstanceNonce = 24
        static let issuedAtMillis = 40
    }
}

/// TRANSCRIPT RESULTS — app → keyboard, one JSON file per request at
/// `session.results/<requestUUID>.json`. JSON is fine here: results are not
/// polled and not hot-path, so only the two mmap files above are binary ABI.
///
/// STALE-TARGET INSERTION GUARD. The failure this kills: inference finishes
/// AFTER the user has switched apps or moved fields, and the late transcript
/// inserts into the wrong app or the wrong text field. Defense: every keyboard
/// instance generates a fresh `keyboardInstanceNonce` in viewDidLoad, stamps
/// it into every command record, and the app echoes it into the result. The
/// keyboard auto-inserts via textDocumentProxy ONLY when the result's nonce
/// equals its own live nonce — a match proves the same keyboard instance,
/// hence the same host app and field, is still frontmost. On mismatch, or when
/// a result lands with no keyboard on screen, nothing is ever auto-inserted:
/// the next keyboard instance finds the unclaimed file and offers it as a
/// pending-result key the user taps to insert deliberately. The keyboard
/// deletes a result file once inserted or dismissed; the app garbage-collects
/// unclaimed results after `unclaimedTTLSeconds`.
enum TranscriptResult {
    static let requestUUIDKey = "requestUUID"
    static let keyboardInstanceNonceKey = "keyboardInstanceNonce"
    static let textKey = "text"
    static let completedAtMillisKey = "completedAtMillis"
    static let unclaimedTTLSeconds: TimeInterval = 600
}

/// LIVENESS RULE — how the mic key decides the app is gone. The app acks every
/// command IMMEDIATELY on a dedicated control queue: it bumps
/// lastCommandAckSeq on the status page the moment the record is drained,
/// BEFORE loading Parakeet/CoreML or Foundation Models — an ack proves only
/// "the process is alive and heard me", never "the work is done".
///
/// While the status page reports live/dictating, the dead-session verdict (mic
/// key morphs into the "open whispr bro" bounce key) requires BOTH:
///   1. ack stale — the keyboard posted seq N over `commandAckTimeoutMillis`
///      ago and lastCommandAckSeq is still < N, AND
///   2. heartbeat stale — lastAudioCallbackAtMillis is over
///      `audioHeartbeatTimeoutMillis` old; the audio tap stamps it every
///      callback, so a silent second means capture itself is dead.
/// Either alone is NOT a verdict: a slow CoreML/FM model load can starve
/// non-control work for whole seconds and must never flip the mic key into
/// the bounce key (ack-stale + heartbeat-fresh = alive-but-busy, keep
/// waiting), and the heartbeat alone goes legitimately stale while arming or
/// tearing down after an interruption. When sessionState is off the mic key is
/// already the bounce key — no verdict needed. This pair of file-backed
/// timestamps is what lets a keyboard detect a jetsamed app that Darwin, by
/// design, can never wake or make answer.
enum Liveness {
    static let commandAckTimeoutMillis: UInt64 = 300
    static let audioHeartbeatTimeoutMillis: UInt64 = 1_000
}
