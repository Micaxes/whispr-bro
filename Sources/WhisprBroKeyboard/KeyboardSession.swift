import Combine
import Foundation
import WhisprBroIPC

/// What the hero (mic) key currently is. Recomputed on every poll tick from
/// the status page plus the keyboard's own bookkeeping; `KeyboardBar` renders
/// it. The page state always wins — local intent (`starting`/`transcribing`)
/// only bridges the gap between posting a command and the app's next publish.
enum MicPhase: Equatable {
    /// No session: no readable page, page reports off, or IPC is disabled
    /// (App Group container unavailable). Tap deep-links into the app to arm.
    case idle
    /// The app is foregrounding and starting continuous capture.
    case arming
    /// Session live — tap posts `startDictation`.
    case armed
    /// `startDictation` posted, page not yet flipped to dictating. A slow
    /// CoreML model load can hold this for whole seconds; that is
    /// alive-but-busy (ack fresh or heartbeat fresh), never the bounce key.
    case starting
    /// Dictating — the mic key is ✓ (finish); a separate ✕ key cancels.
    case recording
    /// `stopDictation` posted; inference is running in the app.
    case transcribing
    /// Unclaimed transcript(s) whose nonce is not ours — never auto-inserted
    /// (`TranscriptResult` stale-target guard); tap inserts the oldest
    /// deliberately.
    case pendingResult(count: Int)
    /// The dual-condition `Liveness` verdict says the app is dead while the
    /// page still claims live/dictating — tap deep-links to reopen it.
    case bounce
}

/// The keyboard side of the session IPC (issue #13 P4): polls the status page
/// at ~20Hz while visible, posts commands into the keyboard-owned mailbox
/// (plus a Darwin hint), consumes transcript results under the
/// keyboardInstanceNonce guard, and reduces everything to a `MicPhase` + a
/// waveform level ring for the bar to draw. Main-thread only, like the rest
/// of the appex.
final class KeyboardSession: ObservableObject {
    @Published private(set) var phase: MicPhase = .idle
    /// Recent perceptual levels (0…1, newest last) for the waveform strip.
    @Published private(set) var levels: [Float]
    /// "finishing in whispr bro — swipe back when armed" — shown for a few
    /// seconds after a deep-link tap, while the page still reports no session.
    @Published private(set) var showsArmingHint = false
    /// Wispr's orange-triangle equivalent: why the session just died, held
    /// keyboard-locally for ~8s of error strip (`.none` = no error showing).
    /// Armed only on an OBSERVED page flip into `.off` carrying a non-none
    /// code — a fresh keyboard mounting over an old failed page must never
    /// resurface a stale error — and cleared early the moment the page leaves
    /// `.off` (the retry is visibly underway).
    @Published private(set) var sessionError: SessionErrorCode = .none
    /// Live preview of the open segment (the app's streaming SpeechTranscriber
    /// relayed through the partial page), shown in the status strip beside a
    /// compressed waveform. Non-nil ONLY while recording/transcribing AND the
    /// page's nonce is OUR instance nonce (a preview for a segment some other
    /// keyboard opened must never paint this host app's strip) AND the page
    /// carries text. Nil = waveform-only, exactly today's rendering — the
    /// partials-unavailable case is visually indistinguishable from before.
    @Published private(set) var partialText: String?
    /// Mirrored from `UIInputViewController.hasFullAccess` each appearance;
    /// false swaps the mic + strip for the inline explainer panel.
    @Published var hasFullAccess = true
    /// Mirrored from `UIInputViewController.needsInputModeSwitchKey` on every
    /// layout pass (it can change per host). True hides nothing; false lets
    /// the key grid drop its globe key and give the width back to the layer
    /// key. Defaults true — showing a redundant globe is safe, omitting a
    /// required one is a rejection.
    @Published var needsInputModeSwitchKey = true

    /// False = `SharedContainer.url()` found no App Group container (the
    /// documented degraded mode: entitlement absent under free-personal-team
    /// signing). The bar uses this to tell the truth in its idle status line —
    /// "tap mic to arm" can never progress without the container, so the strip
    /// says the keyboard link is off and that dictating opens the app instead.
    var ipcEnabled: Bool { container != nil }

    /// Fresh per keyboard instance (the controller builds this object in
    /// `viewDidLoad`) — the stale-target insertion guard of the
    /// `TranscriptResult` contract. Stamped into every command; a result is
    /// auto-inserted ONLY when the app echoes this exact value back.
    let nonce = UUID()

    /// Set by the controller: the ONE auto/manual insertion path
    /// (`textDocumentProxy.insertText`) and the deep-link opener.
    var insertText: ((String) -> Void)?
    var openApp: (() -> Void)?

    static let waveformBarCount = 28
    private static let pollInterval: TimeInterval = 0.05 // ~20Hz while visible
    /// Consecutive unreadable polls (~250ms) before "no truth" hardens into
    /// "no session" — a single torn-read tick must not drop a live phase.
    private static let nilReadsForNoSession = 5
    private static let armingHintMillis: UInt64 = 12_000
    /// How long the error strip holds after a session dies with a code.
    private static let sessionErrorMillis: UInt64 = 8_000
    /// A posted stop whose result never lands falls back to the page state
    /// after this long (the result may still arrive later as a pending key).
    private static let resultWaitMillis: UInt64 = 30_000

    private let container: URL?
    private let reader: StatusPageReader?
    private let partialReader: PartialPageReader?
    private var writer: CommandMailboxWriter?

    private var pollTimer: Timer?
    private var hintTokens: [DarwinHintToken] = []

    /// Keyboard-side `Liveness` bookkeeping: what was last posted, and when.
    private var lastPostedSeq: UInt32 = 0
    private var lastPostedAtMillis: UInt64 = 0

    /// Local overlay bridging command-post → page-flip gaps.
    private enum Intent: Equatable {
        case none
        case startPosted
        case stopPosted(atMillis: UInt64)
    }

    private var intent: Intent = .none
    private var lastSessionUUID: UUID?
    private var consecutiveNilReads = 0
    private var pendingResults: [TranscriptResultRecord] = []
    private var armingHintExpiresAtMillis: UInt64 = 0
    /// Last stable page (state + uuid) for the error-strip transition gate:
    /// separate from `lastSessionUUID` (which `tick` mutates before the phase
    /// pass) and nil until the FIRST stable read, so mounting over a page
    /// that already says off-with-error shows nothing.
    private var lastPageState: SessionState?
    private var lastPageUUID: UUID?
    private var sessionErrorExpiresAtMillis: UInt64 = 0

    /// `container` nil (App Group entitlement absent — the current
    /// free-personal-team configuration) is the degraded mode: no reader, no
    /// writer, phase stays `.idle`, the mic key deep-links only.
    /// `SharedContainer` logs the reason once.
    init(container: URL? = SharedContainer.url()) {
        self.container = container
        reader = container.map { StatusPageReader(directory: $0) }
        partialReader = container.map { PartialPageReader(directory: $0) }
        levels = Array(repeating: 0, count: Self.waveformBarCount)
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: Lifecycle

    /// Starts the ~20Hz poll plus the two Darwin hint observations. Hints are
    /// accelerators only — every hint-driven read also happens on the poll,
    /// which is the file-backed recovery path behind coalesced/dropped hints.
    func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = Self.pollInterval / 5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        hintTokens = [
            DarwinHint.observe(KeyboardIPC.statusHintName) { [weak self] in self?.tick() },
            DarwinHint.observe(KeyboardIPC.resultHintName) { [weak self] in self?.tick() },
        ]
        tick()
    }

    /// Stops polling AND hint delivery while off screen — with no keyboard on
    /// screen nothing may ever be auto-inserted (`TranscriptResult` guard),
    /// and `consumeResults` is only reachable from the paths stopped here.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        hintTokens = [] // tokens deregister on deinit
    }

    // MARK: Key actions

    func micTapped() {
        switch phase {
        case .idle, .bounce:
            openApp?()
            // "swipe back when armed" is only true when this keyboard can
            // actually SEE the arm — without the App Group container the
            // phase can never leave .idle, so the hint would be a lie.
            if ipcEnabled {
                armingHintExpiresAtMillis = KeyboardIPC.nowMillis() + Self.armingHintMillis
            }
        case .armed:
            if post(.startDictation) {
                intent = .startPosted
            } else {
                openApp?() // mailbox unwritable: the app can still re-arm
            }
        case .recording:
            if post(.stopDictation) {
                intent = .stopPosted(atMillis: KeyboardIPC.nowMillis())
            }
        case .pendingResult:
            insertOldestPending()
        case .arming, .starting, .transcribing:
            break // command already in flight — nothing sensible to add
        }
        tick()
    }

    func cancelTapped() {
        switch phase {
        case .starting, .recording:
            post(.cancel)
            intent = .none
        default:
            break
        }
        tick()
    }

    // MARK: Poll tick

    private func tick() {
        let snapshot = reader?.read()
        if let snapshot {
            consecutiveNilReads = 0
            if snapshot.sessionUUID != lastSessionUUID {
                // Session restarted (or first seen) beneath this keyboard —
                // any local intent belonged to the old session.
                lastSessionUUID = snapshot.sessionUUID
                intent = .none
            }
        } else {
            consecutiveNilReads += 1
        }
        consumeResults() // poll backstop behind the coalescing result hint
        updateSessionError(snapshot)
        updateLevels(snapshot)
        updatePhase(snapshot)
        updatePartialText()
    }

    /// The live-preview leg of the tick, after `updatePhase` so it sees this
    /// tick's phase. Read only while recording/transcribing (transcribing
    /// keeps the last preview up the few ticks until the app's stop-path
    /// clear lands, instead of blanking a frame early); any other phase
    /// clears immediately. A nil page read (torn/no truth) HOLDS the current
    /// preview — same philosophy as the status page, flicker-free by
    /// construction. The nonce gate is the render guard documented on
    /// `PartialSnapshot`.
    private func updatePartialText() {
        guard phase == .recording || phase == .transcribing else {
            if partialText != nil { partialText = nil }
            return
        }
        guard let snapshot = partialReader?.read() else { return } // hold this tick
        let next = snapshot.keyboardInstanceNonce == nonce && !snapshot.text.isEmpty
            ? snapshot.text : nil
        if next != partialText { partialText = next }
    }

    /// The error-strip state machine (see `sessionError`). The trigger is a
    /// page CHANGE landing on `.off` with a code: either the state flipped
    /// off beneath us, or the sessionUUID changed while off — that second leg
    /// catches an arm-and-die faster than one poll tick (mic start fails
    /// within `beginSession`'s arming window, so the only trace is a new uuid
    /// on an off page). Requiring a previously-observed page keeps a fresh
    /// keyboard from resurfacing a failure of unknowable age, and gating on
    /// change (not presence) is what lets the ~8s hold actually expire while
    /// the failed page sits there unchanged.
    private func updateSessionError(_ snapshot: StatusSnapshot?) {
        guard let snapshot else { return } // no truth this tick: hold as-is
        let now = KeyboardIPC.nowMillis()
        let pageChanged = lastPageState != snapshot.sessionState
            || lastPageUUID != snapshot.sessionUUID
        if snapshot.sessionState != .off {
            if sessionError != .none { sessionError = .none } // retry underway
        } else if lastPageState != nil, pageChanged, snapshot.errorCode != .none {
            sessionError = snapshot.errorCode
            sessionErrorExpiresAtMillis = now + Self.sessionErrorMillis
            // The mic tap that opened this failed arming attempt also opened
            // a 12s arming hint — longer than the 8s error hold, so left
            // alive it would mask the error strip for its whole life
            // (micStartFailed would never render). An error latching kills
            // the hint; only a fresh RETRY tap re-arms it, and that hint
            // rightly supersedes the complaint (see `StatusStrip.showsError`).
            armingHintExpiresAtMillis = 0
        } else if sessionError != .none, now >= sessionErrorExpiresAtMillis {
            sessionError = .none
        }
        lastPageState = snapshot.sessionState
        lastPageUUID = snapshot.sessionUUID
    }

    private func updatePhase(_ snapshot: StatusSnapshot?) {
        let now = KeyboardIPC.nowMillis()
        if case .stopPosted(let atMillis) = intent, now > atMillis,
           now - atMillis > Self.resultWaitMillis {
            intent = .none // result never came; fall back to the page state
        }
        let next: MicPhase
        if let snapshot, snapshot.sessionState == .arming {
            next = .arming
        } else if let snapshot, snapshot.sessionState != .off {
            // live/dictating: the only states where the dead-session verdict
            // is meaningful (when the page says off the mic key is already
            // the deep-link key — no verdict needed, per `Liveness`).
            if Liveness.sessionIsDead(
                nowMillis: now,
                lastPostedSeq: lastPostedSeq,
                lastPostedAtMillis: lastPostedAtMillis,
                lastCommandAckSeq: snapshot.lastCommandAckSeq,
                lastAudioCallbackAtMillis: snapshot.lastAudioCallbackAtMillis
            ) {
                next = .bounce
            } else if snapshot.sessionState == .dictating {
                if intent == .startPosted { intent = .none } // page caught up
                next = .recording
            } else {
                switch intent {
                case .startPosted: next = .starting
                case .stopPosted: next = .transcribing
                case .none: next = pendingOr(.armed)
                }
            }
        } else if snapshot != nil || consecutiveNilReads >= Self.nilReadsForNoSession {
            // Page reports off, or no readable page for ~250ms (missing, dead
            // writer, version skew, IPC disabled): no session.
            intent = .none
            next = pendingOr(.idle)
        } else {
            next = phase // transient no-truth tick: hold, retry next tick
        }
        if next != phase { phase = next }
        // `ipcEnabled` re-checked here (belt and braces with `micTapped`): a
        // hint that can never come true must never render in degraded mode.
        let hint = ipcEnabled && next == .idle && now < armingHintExpiresAtMillis
        if hint != showsArmingHint { showsArmingHint = hint }
    }

    private func updateLevels(_ snapshot: StatusSnapshot?) {
        var next = levels
        next.removeFirst()
        if let snapshot, snapshot.sessionState == .dictating {
            next.append(min(max(snapshot.audioLevel, 0), 1))
        } else {
            next.append(0)
        }
        if next != levels { levels = next } // settles all-zero when not recording
    }

    // MARK: Results

    /// Reads the result drop (hint-driven and on every poll as backstop).
    /// A record carrying OUR nonce proves this same keyboard instance — hence
    /// the same host app and text field — is still frontmost: auto-insert via
    /// one `insertText` call and clear the file. Any other nonce is offered
    /// as the pending-result key, never auto-inserted.
    private func consumeResults() {
        guard let container, pollTimer != nil else { return }
        let records = ResultDrop.unclaimed(in: container)
        var unclaimed: [TranscriptResultRecord] = []
        for record in records {
            if record.keyboardInstanceNonce == nonce {
                insertText?(record.text)
                ResultDrop.remove(requestUUID: record.requestUUID, in: container)
                if case .stopPosted = intent { intent = .none }
            } else {
                unclaimed.append(record)
            }
        }
        pendingResults = unclaimed // already oldest-first
    }

    /// Deliberate tap on the pending-result key = manual insert of the oldest
    /// unclaimed transcript, then clear its file.
    private func insertOldestPending() {
        guard let container, let record = pendingResults.first else { return }
        insertText?(record.text)
        ResultDrop.remove(requestUUID: record.requestUUID, in: container)
        pendingResults.removeFirst()
    }

    private func pendingOr(_ fallback: MicPhase) -> MicPhase {
        pendingResults.isEmpty ? fallback : .pendingResult(count: pendingResults.count)
    }

    // MARK: Commands

    /// Posts one command into the mailbox (recording the seq + timestamp as
    /// the `Liveness` ack-stale inputs) and fires the Darwin command hint.
    /// False = the mailbox could not be created/mapped (no container, or no
    /// Full Access) — the caller falls back to the deep link.
    @discardableResult
    private func post(_ command: KeyboardCommand) -> Bool {
        guard let container else { return false }
        if writer == nil {
            writer = try? CommandMailboxWriter(directory: container)
        }
        guard let writer else { return false }
        let issuedAt = KeyboardIPC.nowMillis()
        lastPostedSeq = writer.post(
            command, keyboardInstanceNonce: nonce, issuedAtMillis: issuedAt)
        lastPostedAtMillis = issuedAt
        DarwinHint.post(KeyboardIPC.commandHintName)
        return true
    }
}
