import AVFoundation
import Combine
import Foundation
import os.log
import SwiftUI
import UIKit
import WhisprBroCore
import WhisprBroIPC

/// The app-side dictation SESSION (issue #13 P4, rev 2 + adopted review): the
/// Wispr-style flow behind the custom keyboard's mic key. A session is
/// continuous `AudioEngine` capture started while the app is FOREGROUND (the
/// only legal mic start on iOS — a backgrounded app can never open the mic),
/// then kept alive backgrounded by the active audio session (`UIBackgroundModes
/// audio`). While live, the keyboard drives dictation segments through the
/// `KeyboardIPC` contract: it posts commands into the mailbox, this controller
/// drains + acks them and services the status page; transcripts land in the
/// result drop keyed by the request's UUID + keyboard-instance nonce.
///
/// Orange-dot honesty is the design, not a bug: the mic indicator stays lit
/// for the whole session because the mic genuinely is live — audio stays in
/// the in-process ring (never the App Group), transcription is fully local,
/// and the session is killable from the card at any moment (and from the
/// Live Activity too, when the Settings toggle opts into one). Idle
/// expiry (`IdleExpiry`) bounds how long an unused session may hold the mic;
/// interruption / route loss / termination tear it down immediately, and a
/// background restart is never attempted.
///
/// States mirror `SessionState` minus arming (arming is the sub-millisecond
/// window inside `startSession`): `.off` → `.live` (idle, capture running) ⇄
/// `.dictating` (segment open). RAM stays lean: starting a session loads no
/// model — Parakeet/VAD load on the FIRST dictation of the session via the
/// shared `DictationModel` bring-up.
@MainActor
final class SessionController: ObservableObject {
    enum Phase: Equatable {
        case off
        case live
        case dictating
    }

    /// Idle window before a live session tears itself down (persisted). NO
    /// "never" option on purpose (review cut): an unbounded hot mic is
    /// exactly the dishonesty this feature exists to avoid.
    enum IdleExpiry: String, CaseIterable {
        case immediately
        case fiveMinutes
        case fifteenMinutes
        case sixtyMinutes

        static let storageKey = "sessionIdleExpiry"

        var displayName: String {
            switch self {
            case .immediately: "Right after each dictation"
            case .fiveMinutes: "After 5 minutes idle"
            case .fifteenMinutes: "After 15 minutes idle"
            case .sixtyMinutes: "After 60 minutes idle"
            }
        }

        /// The idle-timer window. `immediately` tears down right after each
        /// RESULT (the on-brand mic-on-demand mode — see `finishDictation`);
        /// its 5-minute window here is only the armed-but-never-used cap, so
        /// a session the user opened and forgot can't hold the mic forever.
        var idleSeconds: TimeInterval {
            switch self {
            case .immediately, .fiveMinutes: 5 * 60
            case .fifteenMinutes: 15 * 60
            case .sixtyMinutes: 60 * 60
            }
        }
    }

    /// Who armed the session — the keyboard's deep link
    /// (`whisprbro://session/start?source=keyboard`) or anything else (App
    /// Intent, Control Center, Shortcuts: the plain URL). Keyboard arms get
    /// their pre-posted `startDictation` preserved across the bring-up flush
    /// and the session card's auto-switchback; external arms get neither.
    enum StartSource {
        case keyboard
        case external
    }

    @Published private(set) var phase: Phase = .off
    /// The full-screen brand card ("Session on — swipe back ←"), shown on
    /// arming and dropped the moment the app backgrounds (`SessionCardView`).
    @Published var showSessionCard = false
    /// Whether the CURRENT session was armed via the keyboard deep link — the
    /// gate on the session card's auto-switchback. Set on EVERY arm (a
    /// keyboard re-bounce over a live session is still a keyboard arm; an
    /// external arm over one must kill a stale card's switchback), reset on
    /// teardown.
    @Published private(set) var armedViaKeyboard = false
    /// The user's persisted auto-return preference (`ReturnApp.Choice`):
    /// unset until the Settings "Quick-return app" row picks a chosen app or
    /// the explicit off (the session card only points there — it never
    /// asks). Persisted in the app's own UserDefaults — never the App Group;
    /// the keyboard has no use for it.
    @Published var returnChoice: ReturnApp.Choice = ReturnApp.Choice.from(
        stored: UserDefaults.standard.string(forKey: ReturnApp.storageKey)
    ) {
        didSet {
            UserDefaults.standard.set(returnChoice.stored, forKey: ReturnApp.storageKey)
        }
    }
    @Published var idleExpiry: IdleExpiry = {
        if let raw = UserDefaults.standard.string(forKey: IdleExpiry.storageKey),
           let expiry = IdleExpiry(rawValue: raw) { return expiry }
        return .fiveMinutes
    }() {
        didSet {
            UserDefaults.standard.set(idleExpiry.rawValue, forKey: IdleExpiry.storageKey)
            if phase == .live { armIdleTimer() }
        }
    }

    /// Hard cap on ONE session dictation segment. Without it the open
    /// segment's `PreRollBuffer` grows unbounded (~230MB/hr — a jetsam, not a
    /// feature); 5 minutes matches dictation-app category norms and bounds
    /// the worst case at ~19MB of 16kHz Float32. The in-app quick-dictation
    /// path keeps its own 90s cap (`DictationModel.maxRecordingSeconds`).
    private static let maxSegmentSeconds: TimeInterval = 5 * 60

    private let model: DictationModel
    /// The session's own continuous-capture engine, separate from the model's
    /// mic-on-demand one — a session must never inherit the in-app engine's
    /// activate/deactivate-per-dictation lifecycle. Its 0.5s pre-roll is
    /// genuinely LIVE here (capture runs the whole session), unlike both
    /// mic-on-demand paths where it is always empty.
    private let audio = AudioEngine()
    private var ipc: SessionIPC?
    private var idleTimer: Timer?
    /// One-shot `maxSegmentSeconds` timer, armed with every segment.
    private var segmentCapTimer: Timer?
    /// The START command that opened the current segment, retained so a
    /// cap-forced stop can key its result on the same requestUUID +
    /// keyboardInstanceNonce — the keyboard's nonce-matched auto-insert then
    /// works exactly as for a tapped stop.
    private var segmentStartRequest: CommandRecord?
    /// The open segment's live-preview drain loop (`startPartialPreview`);
    /// nil while no segment is streaming partials.
    private var partialPreviewTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Bumped on every session start/teardown so async work that outlives a
    /// session (a transcription racing a kill) can detect it and stand down.
    private var sessionGeneration = 0
    private let log = Logger(subsystem: "com.micaxes.whispr-bro.ios", category: "session")

    init(model: DictationModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    /// App-launch bring-up (idempotent, next to `DictationModel.startup`):
    /// builds the IPC plumbing, which republishes a fresh `.off` status page —
    /// after a jetsam mid-session the keyboard must see "no session" on our
    /// next launch, not the live-looking leftovers — and GCs stale results.
    /// Maps one 64-byte page; loads nothing else.
    func startup() {
        guard ipc == nil else { return }
        ipc = SessionIPC(
            level: { [audio] in AudioLevel.perceptual(audio.lastRMS) },
            onCommands: { [weak self] records in
                Task { @MainActor in self?.process(records) }
            })
    }

    /// The arming flow, entered ONLY from the `whisprbro://session/start` deep
    /// link (the keyboard's mic key, App Intents, Control Center — the router
    /// maps `?source=keyboard` to `.keyboard`) — i.e. while the app is
    /// foregrounding, the one legal place to start the mic. A keyboard arm
    /// additionally preserves the mic tap's pre-posted `startDictation`
    /// through the bring-up flush (`SessionIPC.begin`), so segment 1 starts
    /// recording the moment the session goes live — while the user is still
    /// on the card or mid swipe-back.
    func startSession(source: StartSource) {
        startup() // defensive: a cold deep-link launch races onAppear
        guard phase == .off else {
            // Already live — the mic key just bounced us back; re-surface the
            // card so the user gets the "swipe back" hint again. The arm
            // SOURCE still updates: a keyboard re-bounce is a keyboard arm,
            // and an external arm over a live session must never leave a
            // stale card able to switch back.
            armedViaKeyboard = source == .keyboard
            showSessionCard = true
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            log.error("session start refused: app is backgrounded (mic sessions start foreground-only)")
            return
        }
        armedViaKeyboard = source == .keyboard
        sessionGeneration += 1
        // Status → .arming, stale mailbox flushed — except a keyboard arm's
        // own young startDictation, preserved to open segment 1 at goLive.
        ipc?.begin(sessionUUID: UUID(), preserveKeyboardStart: source == .keyboard)
        do {
            // Lights the mic indicator — and it stays lit for the whole
            // session, on purpose (see the class doc + Settings caption).
            try audio.startCapture()
        } catch {
            log.error("session mic start failed: \(error.localizedDescription)")
            ipc?.fail(code: .micStartFailed) // stamped BEFORE the terminal .off
            ipc?.transition(to: .off) // also drops any preserved start
            armedViaKeyboard = false
            return
        }
        phase = .live
        ipc?.goLive() // status → .live, heartbeat + command pump running
        showSessionCard = true
        observeSystemNotifications()
        armIdleTimer()
        // Live Activity: session state + Stop (reuses the row-8 probe's
        // controller), armed as `.sessionLive` — steady mic, "dictate from
        // the whispr key" — and flipped to `.recording` per segment. Honest
        // either way: the mic IS live for the whole session. Stop routes
        // into `endSession` from BOTH phases. OPT-IN since the Settings
        // "Live Activity" toggle (default off — the owner's call that the
        // island pill is noise during dictation): `start` self-gates on it,
        // so when off no activity is ever requested and every update/end
        // downstream is a nil-safe no-op. Display-only either way — capture
        // stays alive via the active audio session (`UIBackgroundModes
        // audio`), never via the activity. The stop hook is armed regardless:
        // it only fires from an island End button, so with no activity it
        // simply never runs.
        DictationIntentHooks.stop = { [weak self] in
            await MainActor.run { self?.endSession(reason: "Live Activity stop") }
        }
        let generation = sessionGeneration
        Task {
            do {
                try await DictationActivityController.start(phase: .sessionLive)
                // `start` can suspend awaiting a stale predecessor's end —
                // long enough for the preserved keyboard start to open
                // segment 1, whose `updateSession(.recording)` then hit a
                // nil activity and was lost, stranding the island on the
                // steady mic for the whole segment. Re-derive the phase now
                // that the activity exists. Generation-checked: a session
                // that died (or was replaced) while we waited must not be
                // repainted as recording.
                if sessionGeneration == generation, phase == .dictating {
                    await DictationActivityController.updateSession(phase: .recording)
                }
            } catch {
                log.notice("Live Activity unavailable: \(error.localizedDescription)")
            }
        }
        log.info("session started (idle expiry: \(self.idleExpiry.rawValue, privacy: .public))")
    }

    /// Clean teardown, the ONLY exit: capture stopped (mic indicator clears),
    /// status page → `.off`, Live Activity ended, open segment discarded —
    /// never transcribed on the way down.
    func endSession(reason: String) {
        guard phase != .off else { return }
        log.notice("session teardown: \(reason, privacy: .public)")
        sessionGeneration += 1
        if phase == .dictating { _ = audio.endUtterance() }
        phase = .off
        showSessionCard = false
        armedViaKeyboard = false
        idleTimer?.invalidate()
        idleTimer = nil
        cancelSegmentCap()
        stopPartialPreview()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        ipc?.end() // synchronous: the willTerminate path must land the .off page before the process dies
        audio.stopCapture()
        DictationIntentHooks.stop = nil
        Task { await DictationActivityController.end() }
    }

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            // The card's one job (say "mic is live, swipe back") is done the
            // moment the user leaves; drop it so returning lands on the app.
            showSessionCard = false
        case .active:
            // Contract: drain on foreground too — Darwin hints never wake a
            // suspended app, so becoming active is a natural catch-up point.
            if phase != .off { ipc?.drainNow() }
        default:
            break
        }
    }

    // MARK: - Commands (drained + acked on the control queue, executed here)

    private func process(_ records: [CommandRecord]) {
        for record in records { handle(record) }
    }

    private func handle(_ record: CommandRecord) {
        // Post-teardown races (a command drained just as the session died)
        // are dropped: the ack already landed on the control queue, and with
        // the page `.off` the keyboard is already showing the bounce key.
        guard phase != .off else { return }
        switch record.command {
        case .startDictation:
            guard phase == .live else { return } // duplicate tap mid-segment
            // The pre-roll is genuinely live in session mode: capture has
            // been running the whole time, so up to 0.5s of audio from just
            // before the keyboard tap is spliced onto the segment
            // (`PreRollBuffer.beginUtterance`) — no clipped first word.
            audio.beginUtterance()
            phase = .dictating
            ipc?.transition(to: .dictating)
            idleTimer?.invalidate()
            idleTimer = nil
            segmentStartRequest = record
            armSegmentCapTimer()
            startPartialPreview(request: record)
            updateActivityPhase(.recording)
        case .stopDictation:
            guard phase == .dictating else { return }
            cancelSegmentCap()
            // Keyed by the stop record because that is the request the
            // keyboard is waiting on.
            finishSegment(request: record)
        case .cancel:
            guard phase == .dictating else { return }
            cancelSegmentCap()
            stopPartialPreview()
            _ = audio.endUtterance() // discard
            phase = .live
            ipc?.transition(to: .live)
            armIdleTimer()
            updateActivityPhase(.sessionLive)
        case .killSession:
            endSession(reason: "keyboard kill command")
        }
    }

    /// The one stop path: closes the open segment (both the tapped stop and
    /// the cap-forced stop land here, differing only in which `CommandRecord`
    /// keys the result) and hands the samples to `finishDictation`.
    private func finishSegment(request: CommandRecord) {
        stopPartialPreview()
        var timings = StageTimings()
        let (samples, finalizeSeconds) = measuredSync { audio.endUtterance() }
        timings.audioFinalizeSeconds = finalizeSeconds
        phase = .live
        ipc?.transition(to: .live)
        updateActivityPhase(.sessionLive)
        Task { await finishDictation(samples, timings: timings, request: request) }
    }

    /// Live Activity mirror of the session's live⇄dictating flips (armed
    /// steady mic vs pulsing recording mic). Fire-and-forget: the activity is
    /// display-only, so an ActivityKit hiccup must never gate a segment.
    private func updateActivityPhase(_ phase: DictationActivityAttributes.Phase) {
        Task { await DictationActivityController.updateSession(phase: phase) }
    }

    /// Segment → the SHARED pipeline (`DictationModel.transcribeSessionSamples`
    /// runs the exact `runPipeline` stages: VAD trim → Parakeet → dictionary →
    /// filler strip → rule-based cleanup, plus pasteboard fallback + history)
    /// → result drop keyed by the STOP command's requestUUID + nonce → Darwin
    /// result hint. Keyed by the stop record because that is the request the
    /// keyboard is waiting on.
    private func finishDictation(
        _ samples: [Float], timings: StageTimings, request: CommandRecord
    ) async {
        let generation = sessionGeneration
        do {
            try await awaitModelReady() // first dictation of the session loads the models
        } catch {
            log.error("session model bring-up failed: \(error.localizedDescription)")
            failDictation(code: .modelLoadFailed, generation: generation)
            return
        }
        do {
            if let text = try await model.transcribeSessionSamples(samples, timings: timings) {
                ipc?.publishResult(
                    requestUUID: request.requestUUID,
                    keyboardInstanceNonce: request.keyboardInstanceNonce,
                    text: text)
            } else {
                log.notice("session dictation produced no text (short segment or busy pipeline)")
            }
        } catch {
            log.error("session dictation failed: \(error.localizedDescription)")
            failDictation(code: .transcriptionFailed, generation: generation)
            return
        }
        // The session may have died (kill / interruption) while we worked —
        // the result above still landed for the pending-result key, but the
        // expiry bookkeeping below belongs to the live session only.
        guard sessionGeneration == generation, phase != .off else { return }
        if idleExpiry == .immediately {
            // The on-brand mic-on-demand mode: mic closes the moment the text
            // lands; the next dictation re-arms via the keyboard's bounce key.
            endSession(reason: "immediate expiry after result")
        } else {
            armIdleTimer()
        }
    }

    /// Failure tail of `finishDictation`: stamp WHY on the status page, then
    /// tear down — the keyboard reads the code off the terminal `.off` page
    /// and shows its error strip instead of a silent flip to the bounce key.
    /// Ending the session (rather than staying live) is what makes the code
    /// visible at all — the keyboard only surfaces errors on the `.off`
    /// transition — and a session whose pipeline just failed would otherwise
    /// hold the mic while failing identically on every retry. Generation-
    /// checked like the success tail: if the session already died while we
    /// worked, our stale code must not be stamped over whatever ended it.
    private func failDictation(code: SessionErrorCode, generation: Int) {
        guard sessionGeneration == generation, phase != .off else { return }
        ipc?.fail(code: code)
        endSession(reason: "dictation failure (\(code))")
    }

    // MARK: - Live preview (hybrid partials)

    /// The hybrid live preview: a per-segment `StreamingPartialTranscriber`
    /// (SpeechTranscriber volatile + finalized results — a SYSTEM model,
    /// gated query-only on installed assets, never downloading) fed by a
    /// ~100ms drain of the session's continuous capture, relayed to the
    /// keyboard through the partial page at ~10Hz (`SessionIPC`). Display-
    /// only and strictly best-effort by design: assets missing, start
    /// failing, or a mid-segment death all mean NO preview — never a delayed
    /// or altered final. The Parakeet path is untouched because
    /// `drainNewSamples` only advances its own incremental cursor;
    /// `endUtterance` still returns the FULL segment (`PreRollBuffer`).
    private func startPartialPreview(request: CommandRecord) {
        // The START command's requestUUID doubles as the segment identity for
        // the partial stream: the keyboardInstanceNonce alone can't tell two
        // segments of the same keyboard apart, and a cancelled segment's
        // transcriber can fire one last volatile callback AFTER the next
        // segment re-armed the pump — same nonce, stale text.
        let segment = request.requestUUID
        partialPreviewTask?.cancel()
        partialPreviewTask = Task { [weak self] in
            guard let self else { return }
            guard let transcriber = await StreamingPartialTranscriber.makeIfAvailable(
                language: self.model.dictationLanguage)
            else { return } // partials off for this locale/build — silently
            guard !Task.isCancelled else { return } // segment already closed
            self.ipc?.beginPartialStream(nonce: request.keyboardInstanceNonce, segment: segment)
            do {
                // The callback hops onto the control queue, where it is
                // segment-guarded — a late result after `endPartialStream` is
                // dropped, never resurrected onto the cleared page NOR
                // published into a newer segment of the same keyboard.
                try await transcriber.start { [weak ipc = self.ipc] text in
                    ipc?.updatePartial(text: text, segment: segment)
                }
            } catch {
                self.log.notice("partial preview unavailable: \(error.localizedDescription)")
                self.ipc?.endPartialStream()
                return
            }
            while !Task.isCancelled {
                let chunk = self.audio.drainNewSamples()
                if !chunk.isEmpty { await transcriber.feed(chunk) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            await transcriber.finish()
        }
    }

    /// Preview teardown, on EVERY segment exit (tapped stop, cancel, cap
    /// fire, kill, session teardown): cancel the drain loop — its tail
    /// finishes the analyzer — and clear the partial page so the keyboard's
    /// next poll drops the text. Cancel + async queue post only: this can
    /// never block or reorder the final-transcript work that follows it.
    private func stopPartialPreview() {
        partialPreviewTask?.cancel()
        partialPreviewTask = nil
        ipc?.endPartialStream()
    }

    /// Wait for the shared model to reach `.idle`. The scene's onAppear
    /// already ran `startup()`, so normally this is just the tail of that
    /// load; error states get one retry kick. `.recording`/`.transcribing`
    /// (an in-app dictation in flight) simply wait their turn.
    private func awaitModelReady(timeout: Duration = .seconds(30)) async throws {
        switch model.state {
        case .error, .needsPermission:
            // A live session proves the mic grant exists; retry re-runs
            // bring-up without ever prompting.
            model.retry()
        default:
            break
        }
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < timeout {
            switch model.state {
            case .idle:
                return
            case .modelsMissing:
                throw SessionFailure("speech models are not installed in this build")
            case .error(let message):
                throw SessionFailure(message)
            case .needsPermission where clock.now - start > .seconds(2):
                throw SessionFailure("microphone permission missing")
            default:
                break // .loading / .recording / .transcribing — keep waiting
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SessionFailure("pipeline not ready within \(Int(timeout.seconds))s")
    }

    // MARK: - Idle expiry + interruptions

    /// The forgotten-session guard. A main-run-loop timer is enough: the
    /// active audio session keeps the backgrounded app scheduled, so it fires
    /// there too. Never armed while `.dictating` (an open segment is not
    /// idle).
    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: idleExpiry.idleSeconds, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .live else { return }
                self.endSession(reason: "idle expiry (\(self.idleExpiry.rawValue))")
            }
        }
    }

    /// The unbounded-segment guard, `armIdleTimer`'s complement (that one is
    /// never armed while `.dictating`; this one ONLY is). On fire the open
    /// segment is stopped exactly as if the keyboard had posted stop, keyed
    /// on the retained START record — its nonce matches the same keyboard
    /// instance, so the transcript still auto-inserts; the keyboard's phase
    /// falls back via the `.live` page state on its next tick.
    private func armSegmentCapTimer() {
        segmentCapTimer?.invalidate()
        segmentCapTimer = Timer.scheduledTimer(
            withTimeInterval: Self.maxSegmentSeconds, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .dictating,
                      let request = self.segmentStartRequest else { return }
                self.log.notice("segment cap (\(Int(Self.maxSegmentSeconds))s) hit — auto-stopping dictation")
                self.cancelSegmentCap()
                self.finishSegment(request: request)
            }
        }
    }

    private func cancelSegmentCap() {
        segmentCapTimer?.invalidate()
        segmentCapTimer = nil
        segmentStartRequest = nil
    }

    /// Interruption / route loss / termination → teardown, always. A
    /// backgrounded app cannot legally restart the mic, so a resume is never
    /// attempted — the keyboard sees `.off` and offers the bounce key.
    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            MainActor.assumeIsolated {
                guard let self, self.phase != .off else { return }
                // The one teardown that carries an error code to the keyboard
                // (call/Siri/another app took the mic mid-session); route
                // change and termination below stay code-free — they read as
                // ordinary session ends, not failures.
                self.ipc?.fail(code: .micInterrupted)
                self.endSession(reason: "audio session interrupted")
            }
        })
        // Only the reasons that change the input device set: the capture
        // graph was built for the old route, and rebuilding may happen while
        // backgrounded — teardown instead. (.categoryChange/.override fire
        // from our own activation and must not self-destruct the session.)
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
            MainActor.assumeIsolated { self?.endSession(reason: "audio route changed") }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endSession(reason: "app terminating") }
        })
    }
}

/// Session-side failure, logged; the user-facing signal is the coarse
/// `SessionErrorCode` on the status page (the keyboard's error strip), never
/// this message text.
private struct SessionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - IPC plumbing (control queue)

/// The IPC half of a session, funneled through ONE serial control queue:
/// `StatusPageWriter` is single-queue by contract, and the ack rule — bump
/// `lastCommandAckSeq` the moment a record is drained, BEFORE any model work —
/// needs a lane that a multi-second CoreML load on the main actor can never
/// starve (ack-stale + heartbeat-fresh must keep reading "alive but busy").
///
/// Degrades gracefully when the App Group container is unavailable (the
/// current free-personal-team entitlements): the session itself still runs —
/// card, Live Activity, idle expiry — the keyboard just can't see or drive it
/// (`SharedContainer` logs why, once).
private final class SessionIPC: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bro.whispr.session.control", qos: .userInitiated)
    /// Current perceptual mic level, read on the control queue at ~30Hz.
    private let level: () -> Float
    /// Freshly drained (and already acked) records, delivered ON the control
    /// queue — the owner hops them to the main actor.
    private let onCommands: ([CommandRecord]) -> Void
    private let log = Logger(subsystem: "com.micaxes.whispr-bro.ios", category: "session-ipc")

    /// Persisted drain cursor, so a relaunch never re-executes commands an
    /// earlier life already drained (the mailbox file outlives the process).
    private static let drainWatermarkKey = "sessionMailboxDrainedSeq"

    private var container: URL?
    private var status: StatusPageWriter?
    private var partial: PartialPageWriter?
    private var drainer: CommandMailboxDrainer?
    private var hintToken: DarwinHintToken?
    private var pollTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    /// ~10Hz partial-page pump (armed only while a segment streams partials):
    /// the throttle between the transcriber's bursty result callbacks and the
    /// mmap page. Latest text wins; unchanged text is never republished.
    private var partialPumpTimer: DispatchSourceTimer?
    private var partialNonce: UUID?
    /// The open segment's identity (its START command's requestUUID) — the
    /// `updatePartial` guard. The nonce alone can't distinguish two segments
    /// opened by the SAME keyboard instance, so a cancelled segment's late
    /// transcriber callback would otherwise publish stale text into its
    /// successor's stream.
    private var partialSegment: UUID?
    private var partialText: String?
    private var partialDirty = false
    /// A keyboard arm's own pre-posted startDictation — at most one record
    /// (`SessionStartFlush.partition` is newest-only), stashed by `begin`
    /// (already acked there — never re-acked) and delivered exactly once at
    /// the end of `goLive`'s queue block. Control-queue-confined, like the
    /// partial ivars; cleared on every path where goLive never comes
    /// (`transition(to: .off)`, `end()`) so a preserved start can never leak
    /// into a later session.
    private var preservedStartRecords: [CommandRecord] = []

    init(level: @escaping () -> Float, onCommands: @escaping ([CommandRecord]) -> Void) {
        self.level = level
        self.onCommands = onCommands
        queue.async { self.bringUp() }
    }

    /// App-launch plumbing: resolve the container (nil → IPC disabled, one
    /// log), map the status page — its init republishes a valid `.off` page,
    /// erasing a jetsamed predecessor's live-looking state — seed the mailbox
    /// cursor from the persisted watermark, and GC expired results.
    private func bringUp() {
        guard let container = SharedContainer.url() else {
            log.warning("no App Group container — sessions will run without keyboard IPC")
            return
        }
        self.container = container
        do {
            status = try StatusPageWriter(directory: container)
        } catch {
            log.error("status page unavailable (\(error.localizedDescription)) — keyboard IPC disabled")
        }
        // The partial page (live preview) degrades independently and quietly:
        // sessions, commands, and results all work without it.
        partial = try? PartialPageWriter(directory: container)
        let seed = UInt32(clamping: UserDefaults.standard.integer(forKey: Self.drainWatermarkKey))
        drainer = CommandMailboxDrainer(directory: container, lastDrainedSeq: seed)
        ResultDrop.collectGarbage(in: container)
    }

    /// Status → `.arming` with a fresh sessionUUID, and the mailbox flushed:
    /// everything still in it is acked (ack proves "drained", never "done"),
    /// then discarded — EXCEPT, on a keyboard arm, the NEWEST `startDictation`
    /// younger than `SessionStartFlush.preservedStartMaxAgeMillis` (newest
    /// only: an older young start is a jetsammed session's orphan, and its
    /// dead keyboard's nonce must not key segment 1). That command IS
    /// the arming tap itself (the keyboard posts start before deep-linking):
    /// it is stashed here and executed the moment the session goes live
    /// (`goLive`), so segment 1 records while the user swipes back. The
    /// drainer's cursor advances wholesale, so a stash-then-redeliver is the
    /// only way a pre-posted command can ever execute — and because it was
    /// acked here, it is never re-acked on delivery.
    func begin(sessionUUID: UUID, preserveKeyboardStart: Bool) {
        queue.async {
            guard let status = self.status else { return }
            status.beginSession(sessionUUID: sessionUUID)
            if let drainer = self.drainer {
                let stale = drainer.drain()
                for record in stale { status.acknowledge(commandSeq: record.seq) }
                self.persistWatermark()
                let discarded: [CommandRecord]
                if preserveKeyboardStart {
                    (self.preservedStartRecords, discarded) = SessionStartFlush.partition(
                        stale, nowMillis: KeyboardIPC.nowMillis())
                } else {
                    discarded = stale
                }
                if !discarded.isEmpty {
                    self.log.notice("flushed \(discarded.count) stale mailbox command(s)")
                }
            }
            DarwinHint.post(KeyboardIPC.statusHintName)
        }
    }

    /// Status → `.live`; heartbeat + command pump start. The ~30Hz heartbeat
    /// stamps level + `lastAudioCallbackAtMillis` from the tap-fed
    /// `AudioEngine.lastRMS` on this queue (core owns the tap closure, so the
    /// stamp rides the callback PATH one hop removed): if the process is
    /// suspended or jetsamed the stamps stop — exactly the death the
    /// heartbeat exists to expose — while an engine the OS tore down with the
    /// process alive is caught by the interruption/route observers flipping
    /// the page to `.off`. The 250ms poll is the file-backed recovery for
    /// coalesced/dropped Darwin hints (they never wake a suspended app; the
    /// active audio session is what keeps us scheduled to run it).
    ///
    /// Tail of the block: deliver any start `begin` preserved. Sequencing is
    /// deterministic — goLive is queued from the main actor AFTER `phase =
    /// .live`, and `onCommands` hops back via `Task { @MainActor }`, which
    /// lands after `startSession` returns — so `handle(.startDictation)`'s
    /// `guard phase == .live` passes. The partition preserves at most ONE
    /// start (newest-only — `SessionStartFlush.partition`), and the record
    /// was acked in `begin` — never re-acked here.
    func goLive() {
        queue.async {
            self.status?.transition(to: .live)
            DarwinHint.post(KeyboardIPC.statusHintName)
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = self.makeTimer(milliseconds: 33) { [weak self] in
                guard let self else { return }
                self.status?.recordAudio(level: self.level())
            }
            self.pollTimer?.cancel()
            self.pollTimer = self.makeTimer(milliseconds: 250) { [weak self] in
                self?.drainLocked()
            }
            self.hintToken?.cancel()
            self.hintToken = DarwinHint.observe(KeyboardIPC.commandHintName) { [weak self] in
                self?.drainNow() // hint lands on the main run loop; hop over
            }
            let preserved = self.preservedStartRecords
            self.preservedStartRecords = []
            if !preserved.isEmpty { self.onCommands(preserved) }
        }
    }

    func transition(to state: SessionState) {
        queue.async {
            // `.off` before goLive ever ran (mic start failed): the preserved
            // start's session never happened — drop it, or it would execute
            // in a LATER session's goLive.
            if state == .off { self.preservedStartRecords = [] }
            self.status?.transition(to: state)
            DarwinHint.post(KeyboardIPC.statusHintName)
        }
    }

    /// Stamp why the session is dying (`SessionErrorCode`). No hint of its
    /// own: every caller follows up with `transition(to: .off)` or `end()` on
    /// this same serial queue, and THAT publish (which the keyboard reacts
    /// to) is guaranteed to already carry the code.
    func fail(code: SessionErrorCode) {
        queue.async {
            self.status?.fail(code: code)
        }
    }

    /// Teardown. Synchronous (`queue.sync`) on purpose: the willTerminate
    /// path must land the `.off` page before the process dies, and the queue
    /// only ever runs sub-millisecond work, so the hop is safe from the main
    /// actor.
    func end() {
        queue.sync {
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.hintToken?.cancel()
            self.hintToken = nil
            self.preservedStartRecords = [] // must never leak into a later session
            self.tearDownPartialLocked()
            self.status?.transition(to: .off)
            DarwinHint.post(KeyboardIPC.statusHintName)
        }
    }

    /// A segment opened: arm the ~10Hz publish pump for `nonce` (the START
    /// command's keyboardInstanceNonce, echoed onto the page as the segment's
    /// diagnostic identity — the keyboard's DISPLAY gate is its phase, not
    /// this nonce; see `KeyboardSession.updatePartialText`) and `segment`
    /// (the START command's requestUUID — the
    /// `updatePartial` stale-callback guard). All partial-page writes ride
    /// this one queue with the status page — the single-writer contract is
    /// one process AND one queue.
    func beginPartialStream(nonce: UUID, segment: UUID) {
        queue.async {
            guard self.partial != nil else { return } // page unavailable: partials off
            self.partialNonce = nonce
            self.partialSegment = segment
            self.partialText = nil
            self.partialDirty = false
            self.partialPumpTimer?.cancel()
            self.partialPumpTimer = self.makeTimer(milliseconds: 100) { [weak self] in
                guard let self, self.partialDirty,
                      let text = self.partialText, let nonce = self.partialNonce else { return }
                self.partialDirty = false
                self.partial?.publish(text: text, nonce: nonce)
            }
        }
    }

    /// Newest preview text from the streaming transcriber; the pump publishes
    /// it on its next 100ms tick. No Darwin hint — the keyboard's ~20Hz poll
    /// outpaces the pump already. Guarded on the SEGMENT identity, not mere
    /// stream presence: a late callback landing after `endPartialStream` is
    /// dropped (never republished over a cleared page), and so is one from a
    /// cancelled segment's transcriber racing the NEXT segment's stream —
    /// same keyboard nonce, different requestUUID, stale text.
    func updatePartial(text: String, segment: UUID) {
        queue.async {
            guard segment == self.partialSegment, text != self.partialText else { return }
            self.partialText = text
            self.partialDirty = true
        }
    }

    /// The segment closed (stop / cancel / cap / kill / teardown): pump
    /// stopped, page cleared — the keyboard's next poll drops the preview.
    func endPartialStream() {
        queue.async { self.tearDownPartialLocked() }
    }

    private func tearDownPartialLocked() {
        partialPumpTimer?.cancel()
        partialPumpTimer = nil
        partialNonce = nil
        partialSegment = nil
        partialText = nil
        partialDirty = false
        partial?.clear()
    }

    func drainNow() {
        queue.async { self.drainLocked() }
    }

    /// Write the transcript to the result drop + post the result hint. With
    /// no container the transcript is pasteboard-only (already published by
    /// the pipeline) — log it clearly, the keyboard will never see the file.
    func publishResult(requestUUID: UUID, keyboardInstanceNonce: UUID, text: String) {
        queue.async {
            guard let container = self.container else {
                self.log.notice("result stays pasteboard-only — no App Group container")
                return
            }
            let record = TranscriptResultRecord(
                requestUUID: requestUUID,
                keyboardInstanceNonce: keyboardInstanceNonce,
                text: text,
                completedAtMillis: KeyboardIPC.nowMillis())
            do {
                try ResultDrop.write(record, in: container)
                DarwinHint.post(KeyboardIPC.resultHintName)
            } catch {
                self.log.error("result drop failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: control-queue internals

    private func drainLocked() {
        guard let drainer, let status else { return }
        let records = drainer.drain()
        guard !records.isEmpty else { return }
        // Ack FIRST, before any model work can begin (`Liveness`): an ack
        // proves "alive and heard you", never "done".
        for record in records { status.acknowledge(commandSeq: record.seq) }
        persistWatermark()
        onCommands(records)
    }

    private func persistWatermark() {
        guard let drainer else { return }
        UserDefaults.standard.set(Int(drainer.lastDrainedSeq), forKey: Self.drainWatermarkKey)
    }

    private func makeTimer(milliseconds: Int, handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(milliseconds),
            repeating: .milliseconds(milliseconds))
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    deinit {
        heartbeatTimer?.cancel()
        pollTimer?.cancel()
        partialPumpTimer?.cancel()
    }
}

// MARK: - Session card

/// The full-screen brand card shown when a session arms — the deep-link
/// landing: dark ink, the echo-w listening pulse, and an animated "swipe
/// back ←" hint (à la Wispr's setup guide). Its one job is telling the user
/// the mic is now honestly live and how to get back to what they were doing;
/// it auto-dismisses the moment the app backgrounds. Phase-aware since the
/// keyboard's arming tap pre-posts its own startDictation: by the time this
/// card renders the session is usually already `.dictating`, and the copy
/// must say so ("already recording — swipe back and keep talking").
///
/// KEYBOARD-ARMED SESSIONS ONLY additionally get the return affordance
/// (`ReturnApp.Choice`): with a remembered target the card announces
/// "returning to <app>…" and deep-links its scheme after `autoReturnDelay` —
/// short enough to feel automatic, though a tap anywhere still cancels.
/// Choosing that target lives ONLY in Settings ("Quick-return app"): the
/// card never asks — `.unset` renders a single non-interactive pointer line
/// to the Settings row and `.off` renders nothing, so the arming screen
/// never blocks on input. The swipe-back line always remains — it is the
/// only return path for apps outside the allowlist.
struct SessionCardView: View {
    @ObservedObject var session: SessionController
    @State private var slide = false
    /// Curated return apps actually installed, resolved once per presentation
    /// (`canOpenURL` — every scheme is declared in App-Info.plist's
    /// LSApplicationQueriesSchemes, so the answers are real).
    @State private var installedReturnApps: [ReturnApp] = []
    /// Non-nil while the auto-switchback countdown runs.
    @State private var pendingReturn: ReturnApp?
    @State private var returnTask: Task<Void, Never>?

    /// Delay between the card appearing with a remembered target and its
    /// scheme being opened. Everything the mic needs is already settled
    /// SYNCHRONOUSLY before the card can render (`startSession` ran
    /// `startCapture` and flipped the phase first); this only has to cover
    /// the async tail — `goLive`'s control-queue hop redelivering the
    /// keyboard's preserved startDictation to the main actor, i.e. segment 1
    /// actually opening — plus one perceptible frame of the card so the
    /// bounce is explained. 250ms does both with margin; the previous 800ms
    /// "cancel window" read as the app waiting to be told (owner-tested,
    /// user swiped back before it fired). A tap within the window still
    /// cancels.
    private static let autoReturnDelay: Duration = .milliseconds(250)

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                EchoWMark(color: Brand.paper, listening: true)
                    .frame(width: 150, height: 68)
                Text(session.phase == .dictating ? "Recording" : "Session on")
                    .font(Brand.sans(32, .semibold)).foregroundStyle(Brand.paper)
                    .padding(.top, 28)
                Text("MIC LIVE · AUDIO NEVER LEAVES THIS DEVICE")
                    .font(Brand.mono(11, .medium)).tracking(1.5)
                    .foregroundStyle(Brand.lightMono)
                    .padding(.top, 10)
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 17, weight: .semibold))
                        .offset(x: slide ? -7 : 3)
                    Text(session.phase == .dictating
                        ? "already recording — swipe back and keep talking"
                        : "swipe back — the whispr key dictates anywhere")
                        .font(Brand.sans(16, .medium))
                }
                .foregroundStyle(Brand.paper)
                .padding(.top, 44)
                Text(expiryLine)
                    .font(Brand.mono(11)).foregroundStyle(Brand.lightMono)
                    .padding(.top, 12)
                returnAffordance
                    .padding(.top, 28)
                Spacer()
                Button {
                    // Cancel the countdown AT TAP TIME: relying on the
                    // card's onDisappear would leave a window where a tap in
                    // the final milliseconds ends the session but the
                    // already-sleeping return task still opens the other app.
                    cancelAutoReturn()
                    session.endSession(reason: "ended from session card")
                } label: {
                    Text("END SESSION")
                        .font(Brand.mono(12, .medium)).tracking(1.5)
                        .foregroundStyle(Brand.lightMono)
                        .padding(.vertical, 12).padding(.horizontal, 22)
                        .overlay(Capsule().stroke(Brand.lightMono.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
            .multilineTextAlignment(.center)
        }
        // The auto-switchback cancel: any tap on the card within the window
        // stays here (END SESSION still wins its own tap). A no-op when no
        // countdown is running.
        .contentShape(Rectangle())
        .onTapGesture { cancelAutoReturn() }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                slide = true
            }
            installedReturnApps = ReturnApp.installed()
            armAutoReturn()
        }
        .onDisappear {
            returnTask?.cancel()
            returnTask = nil
        }
    }

    /// The switchback affordance, keyboard-armed sessions only (an Action
    /// Button / Control Center / Shortcuts arm has no "app the user was
    /// typing in" to return to). Exactly three states: the countdown
    /// announcement while one runs; `.unset` → one static pointer line to
    /// the Settings "Quick-return app" row (deliberately NOT a button — the
    /// arming screen never blocks on input, and a tappable line here would
    /// race the tap-to-cancel gesture); `.off` → nothing, the swipe-back
    /// line above is the whole story. Also nothing when no curated app is
    /// installed — pointing at an empty Settings list would be a dead end.
    @ViewBuilder private var returnAffordance: some View {
        if let app = pendingReturn {
            Text("returning to \(app.name)… tap anywhere to stay")
                .font(Brand.mono(11, .medium)).tracking(0.5)
                .foregroundStyle(Brand.lightMono)
        } else if session.armedViaKeyboard, !installedReturnApps.isEmpty,
                  effectiveChoice == .unset {
            Text("auto-return is off — pick a quick-return app in whispr settings")
                .font(Brand.mono(11)).foregroundStyle(Brand.lightMono)
        }
    }

    /// The remembered choice with an uninstalled target degraded to `unset`:
    /// an app deleted since it was picked simply shows the Settings pointer
    /// again — never a dead countdown.
    private var effectiveChoice: ReturnApp.Choice {
        if case .app(let app) = session.returnChoice,
           !installedReturnApps.contains(app) {
            return .unset
        }
        return session.returnChoice
    }

    /// Arms the auto-switchback countdown: keyboard-armed session + a
    /// remembered target that is still installed. The open lands from the
    /// APP — plain public `UIApplication.open`, nothing appex-restricted —
    /// and backgrounding us auto-dismisses this card (`scenePhaseChanged`).
    private func armAutoReturn() {
        guard session.armedViaKeyboard,
              case .app(let app) = session.returnChoice,
              installedReturnApps.contains(app) else { return }
        pendingReturn = app
        returnTask = Task {
            try? await Task.sleep(for: Self.autoReturnDelay)
            // Re-check the arming conditions AFTER the sleep, not just
            // cancellation: the session can die (END SESSION, idle expiry,
            // interruption) or be re-armed EXTERNALLY (which flips
            // `armedViaKeyboard` off) inside the window, and cancellation
            // only covers the paths that knew to cancel us. A switchback for
            // a session that no longer wants one must never fire.
            guard !Task.isCancelled,
                  session.armedViaKeyboard,
                  session.phase != .off else { return }
            open(app)
        }
    }

    private func cancelAutoReturn() {
        guard pendingReturn != nil else { return }
        returnTask?.cancel()
        returnTask = nil
        pendingReturn = nil
    }

    /// Opens the remembered target. A failed `open` (scheme dead despite an
    /// earlier `canOpenURL` yes — restricted, the scheme changed across
    /// versions, or a TRANSIENT failure like the app mid-update) skips the
    /// return for this session only: the countdown line clears and the
    /// Settings-chosen `returnChoice` is KEPT — wiping a deliberate choice
    /// over a possibly transient failure would silently undo the user's
    /// configuration. A CONFIRMED uninstall needs no handling here: it
    /// already degrades at card appearance (`canOpenURL` false drops the app
    /// from `installedReturnApps`, so `effectiveChoice` shows the Settings
    /// pointer and `armAutoReturn` never arms). Retargeting on failure is
    /// impossible either way: learning the host app is impossible on this OS
    /// (see ReturnApp's head doc).
    private func open(_ app: ReturnApp) {
        guard let url = URL(string: app.scheme) else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success { pendingReturn = nil }
        }
    }

    private var expiryLine: String {
        // The stop-affordance half stays honest per the Settings toggle: a
        // Live Activity only exists when the user opted in (default off).
        let stop = DictationActivityController.isEnabled
            ? "stop any time from the Live Activity"
            : "end it below any time"
        return switch session.idleExpiry {
        case .immediately: "closes right after each dictation · \(stop)"
        case .fiveMinutes: "closes after 5 min idle · \(stop)"
        case .fifteenMinutes: "closes after 15 min idle · \(stop)"
        case .sixtyMinutes: "closes after 60 min idle · \(stop)"
        }
    }
}

extension AppModel {
    /// The one process-wide session controller, next to `dictation`: the
    /// deep-link router, the Settings sheet, and the Live Activity Stop hook
    /// all drive this instance.
    static let session = SessionController(model: dictation)
}
