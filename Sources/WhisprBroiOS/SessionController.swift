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
/// and the session is killable from the Live Activity at any moment. Idle
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

        static let storageKey = "sessionIdleExpiry"

        var displayName: String {
            switch self {
            case .immediately: "Right after each dictation"
            case .fiveMinutes: "After 5 minutes idle"
            case .fifteenMinutes: "After 15 minutes idle"
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
            }
        }
    }

    @Published private(set) var phase: Phase = .off
    /// The full-screen brand card ("Session on — swipe back ←"), shown on
    /// arming and dropped the moment the app backgrounds (`SessionCardView`).
    @Published var showSessionCard = false
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

    private let model: DictationModel
    /// The session's own continuous-capture engine, separate from the model's
    /// mic-on-demand one — a session must never inherit the in-app engine's
    /// activate/deactivate-per-dictation lifecycle. Its 0.5s pre-roll is
    /// genuinely LIVE here (capture runs the whole session), unlike both
    /// mic-on-demand paths where it is always empty.
    private let audio = AudioEngine()
    private var ipc: SessionIPC?
    private var idleTimer: Timer?
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
    /// link (the keyboard's mic key) — i.e. while the app is foregrounding,
    /// the one legal place to start the mic.
    func startSession() {
        startup() // defensive: a cold deep-link launch races onAppear
        guard phase == .off else {
            // Already live — the mic key just bounced us back; re-surface the
            // card so the user gets the "swipe back" hint again.
            showSessionCard = true
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            log.error("session start refused: app is backgrounded (mic sessions start foreground-only)")
            return
        }
        sessionGeneration += 1
        ipc?.begin(sessionUUID: UUID()) // status → .arming, stale mailbox flushed
        do {
            // Lights the mic indicator — and it stays lit for the whole
            // session, on purpose (see the class doc + Settings caption).
            try audio.startCapture()
        } catch {
            log.error("session mic start failed: \(error.localizedDescription)")
            ipc?.transition(to: .off)
            return
        }
        phase = .live
        ipc?.goLive() // status → .live, heartbeat + command pump running
        showSessionCard = true
        observeSystemNotifications()
        armIdleTimer()
        // Live Activity: session state + Stop (reuses the row-8 probe's
        // controller). Its `.recording` phase is honest here — the mic IS
        // live for the whole session. Stop routes into `endSession`.
        DictationIntentHooks.stop = { [weak self] in
            await MainActor.run { self?.endSession(reason: "Live Activity stop") }
        }
        Task {
            do { try await DictationActivityController.start() }
            catch { log.notice("Live Activity unavailable: \(error.localizedDescription)") }
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
        idleTimer?.invalidate()
        idleTimer = nil
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
        case .stopDictation:
            guard phase == .dictating else { return }
            var timings = StageTimings()
            let (samples, finalizeSeconds) = measuredSync { audio.endUtterance() }
            timings.audioFinalizeSeconds = finalizeSeconds
            phase = .live
            ipc?.transition(to: .live)
            Task { await finishDictation(samples, timings: timings, request: record) }
        case .cancel:
            guard phase == .dictating else { return }
            _ = audio.endUtterance() // discard
            phase = .live
            ipc?.transition(to: .live)
            armIdleTimer()
        case .killSession:
            endSession(reason: "keyboard kill command")
        }
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
            MainActor.assumeIsolated { self?.endSession(reason: "audio session interrupted") }
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

/// Session-side failure, logged (never user-facing UI — the keyboard's
/// liveness verdict is the user-visible signal).
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
    private var drainer: CommandMailboxDrainer?
    private var hintToken: DarwinHintToken?
    private var pollTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?

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
        let seed = UInt32(clamping: UserDefaults.standard.integer(forKey: Self.drainWatermarkKey))
        drainer = CommandMailboxDrainer(directory: container, lastDrainedSeq: seed)
        ResultDrop.collectGarbage(in: container)
    }

    /// Status → `.arming` with a fresh sessionUUID, and the mailbox flushed:
    /// anything still in it was posted before this session went live (the
    /// keyboard only posts against a live page), so it targets a session that
    /// no longer exists — ack + discard, never execute.
    func begin(sessionUUID: UUID) {
        queue.async {
            guard let status = self.status else { return }
            status.beginSession(sessionUUID: sessionUUID)
            if let drainer = self.drainer {
                let stale = drainer.drain()
                for record in stale { status.acknowledge(commandSeq: record.seq) }
                self.persistWatermark()
                if !stale.isEmpty {
                    self.log.notice("flushed \(stale.count) stale mailbox command(s)")
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
        }
    }

    func transition(to state: SessionState) {
        queue.async {
            self.status?.transition(to: state)
            DarwinHint.post(KeyboardIPC.statusHintName)
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
            self.status?.transition(to: .off)
            DarwinHint.post(KeyboardIPC.statusHintName)
        }
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
    }
}

// MARK: - Session card

/// The full-screen brand card shown when a session arms — the deep-link
/// landing: dark ink, the echo-w listening pulse, and an animated "swipe
/// back ←" hint (à la Wispr's setup guide). Its one job is telling the user
/// the mic is now honestly live and how to get back to what they were doing;
/// it auto-dismisses the moment the app backgrounds.
struct SessionCardView: View {
    @ObservedObject var session: SessionController
    @State private var slide = false

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                EchoWMark(color: Brand.paper, listening: true)
                    .frame(width: 150, height: 68)
                Text("Session on")
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
                    Text("swipe back — the whispr key dictates anywhere")
                        .font(Brand.sans(16, .medium))
                }
                .foregroundStyle(Brand.paper)
                .padding(.top, 44)
                Text(expiryLine)
                    .font(Brand.mono(11)).foregroundStyle(Brand.lightMono)
                    .padding(.top, 12)
                Spacer()
                Button {
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
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                slide = true
            }
        }
    }

    private var expiryLine: String {
        switch session.idleExpiry {
        case .immediately: "closes right after each dictation · stop any time from the Live Activity"
        case .fiveMinutes: "closes after 5 min idle · stop any time from the Live Activity"
        case .fifteenMinutes: "closes after 15 min idle · stop any time from the Live Activity"
        }
    }
}

extension AppModel {
    /// The one process-wide session controller, next to `dictation`: the
    /// deep-link router, the Settings sheet, and the Live Activity Stop hook
    /// all drive this instance.
    static let session = SessionController(model: dictation)
}
