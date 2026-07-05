import AppKit
import Foundation
import os.log
import SwiftUI
import WhisprBroCore

/// Wires hotkey → audio → (VAD) → ASR → insertion (spec §3, §9). Task-008
/// adds VAD auto-stop, double-tap hands-free lock, secure-input refusal, the
/// HUD, and tap-health surfacing. No LLM yet (task-009).
@MainActor
final class PipelineController: ObservableObject {
    enum State: Equatable {
        case needsPermissions
        case modelsMissing
        case loadingModels
        case idle
        case recording
        case transcribing
        case inserting
        case error(String)
    }

    enum PermissionKind {
        case microphone, accessibility, inputMonitoring
        var settingsPane: String {
            switch self {
            case .microphone: "Privacy_Microphone"
            case .accessibility: "Privacy_Accessibility"
            case .inputMonitoring: "Privacy_ListenEvent"
            }
        }
    }

    struct PermissionSnapshot: Equatable {
        var microphone = false
        var accessibility = false
        var inputMonitoring = false
        var allGranted: Bool { microphone && accessibility && inputMonitoring }
    }

    /// Holds shorter than this are treated as taps (used to arm the double-tap
    /// lock), not dictations — so they never transcribe. The pre-roll makes
    /// every utterance exceed the ASR sample floor, so tap-vs-hold must be
    /// decided by DURATION, not sample count.
    private static let minHoldToTranscribe: TimeInterval = 0.22
    /// Safety cap so a locked recording (or any stuck state) can't run forever.
    private static let maxRecordingSeconds: TimeInterval = 90

    @Published private(set) var state: State = .needsPermissions
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastTimings: String = ""
    @Published private(set) var permissions = PermissionSnapshot()
    /// True while the tap is confirmed dead (Input Monitoring likely revoked).
    @Published private(set) var hotkeyDead = false

    private let audio = AudioEngine()
    private let hotkey = HotkeyManager()
    private let inserter = TextInserter()
    private let asr: AsrEngine = ParakeetEngine(modelsDir: Paths.modelsDir)
    private let vad = VadGate(modelFile: Paths.vadModelFile)
    private let styleRules = StyleRules()
    private let hud = HUDController()
    private let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "pipeline")

    private let llmModel = LlmCatalog.default
    private let formatter: TextFormatter

    @Published private(set) var rawMode = false
    /// Apply per-app formatting register (Slack casual / Mail formal / …).
    @Published var contextAwareStyle = true

    /// App category captured at key-press for the current dictation.
    private var capturedCategory: AppCategory = .unknown
    @Published private(set) var llmAvailable = false

    private var permissionPollTimer: Timer?
    private var vadTimer: Timer?
    private var maxRecordingTimer: Timer?
    private var isBringingUp = false
    private var pipelineRunning = false
    private var vadAvailable = false
    private var isLocked = false
    private var recordingStartUptime: TimeInterval = 0
    private var errorGeneration = 0

    init() {
        let engine = LlamaCppEngine(
            modelPath: llmModel.fileURL,
            promptBuilder: PromptBuilder(family: llmModel.family)
        )
        formatter = TextFormatter(engine: engine)
    }

    func startup() {
        hud.levelProvider = { [weak self] in self?.audio.lastRMS ?? 0 }
        hotkey.onKeyDown = { [weak self] in self?.hotkeyPressed() }
        hotkey.onKeyUp = { [weak self] in self?.hotkeyReleased() }
        hotkey.onDoubleTap = { [weak self] in self?.hotkeyDoubleTapped() }
        hotkey.onHealthChange = { [weak self] healthy in self?.hotkeyHealthChanged(healthy) }
        Task { await bringUp() }
    }

    // MARK: - Bring-up

    private func bringUp() async {
        guard !isBringingUp else { return }
        isBringingUp = true
        defer { isBringingUp = false }

        refreshPermissions()
        guard permissions.allGranted else {
            state = .needsPermissions
            _ = await Permissions.requestMicrophone()
            _ = Permissions.accessibility(prompt: true)
            Permissions.requestInputMonitoring()
            refreshPermissions()
            schedulePermissionPoll()
            return
        }
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil

        let modelDir = Paths.modelsDir.appendingPathComponent(ParakeetEngine.modelFolderName)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            state = .modelsMissing
            return
        }

        do {
            state = .loadingModels
            try await asr.load()
            // VAD is optional: without it, auto-stop and trim are disabled but
            // hold-to-talk still works.
            do {
                try await vad.load()
                vadAvailable = true
            } catch {
                vadAvailable = false
                log.warning("VAD unavailable, continuing without it: \(error.localizedDescription)")
            }
            // LLM is optional too: without it, dictation falls back to
            // rule-based cleanup (raw mode) — never blocks bring-up.
            if llmModel.isInstalled {
                do {
                    try await formatter.load()
                    llmAvailable = true
                } catch {
                    llmAvailable = false
                    log.warning("LLM unavailable, using raw cleanup: \(error.localizedDescription)")
                }
            } else {
                llmAvailable = false
                log.info("LLM model not installed; raw cleanup only")
            }
            if !pipelineRunning {
                try audio.start()
                try hotkey.start()
                pipelineRunning = true
            }
            state = .idle
            log.info("pipeline up: hotkey armed, audio running, models loaded (vad: \(self.vadAvailable))")
        } catch WhisprError.modelsNotFound {
            state = .modelsMissing
        } catch {
            errorGeneration += 1
            state = .error(error.localizedDescription)
            log.error("bring-up failed: \(error.localizedDescription)")
        }
    }

    private func refreshPermissions() {
        permissions = PermissionSnapshot(
            microphone: Permissions.microphone,
            accessibility: Permissions.accessibility(),
            inputMonitoring: Permissions.inputMonitoring
        )
    }

    private func schedulePermissionPoll() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = commonTimer(interval: 2.0) { [weak self] in
            guard let self else { return }
            self.refreshPermissions()
            if self.permissions.allGranted { Task { await self.bringUp() } }
        }
    }

    func retry() { Task { await bringUp() } }

    /// Free GPU-backed models before the process exits (spec §12 clean quit).
    func shutdown() async {
        await formatter.shutdown()
    }

    /// Toggle the LLM auto-edit stage. In raw mode only rule-based cleanup
    /// runs (Parakeet already punctuates), which is instant. The flag is read
    /// per-dictation (passed into format), so a toggle can't race an in-flight
    /// format into an inconsistent state.
    func toggleRawMode() {
        rawMode.toggle()
    }

    /// Timers on the `.common` run-loop mode so they keep firing while the
    /// menu-bar menu is open (which puts the main loop in event-tracking mode).
    private func commonTimer(interval: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - Permission requests (menu)

    func requestPermission(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            Task { _ = await Permissions.requestMicrophone(); refreshPermissions() }
        case .accessibility:
            _ = Permissions.accessibility(prompt: true)
        case .inputMonitoring:
            Permissions.requestInputMonitoring()
        }
        openSettings(for: kind)
    }

    func openSettings(for kind: PermissionKind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Hotkey gestures

    private func hotkeyPressed() {
        // A press while locked-recording is the hands-free STOP.
        if state == .recording, isLocked {
            finishRecording(trim: true)
            return
        }
        guard state == .idle else {
            if state == .transcribing || state == .inserting { NSSound.beep() }
            return
        }
        // Cheap, non-blocking refusal only (system secure input). The
        // authoritative AX field check runs off the hot path before insertion.
        if SecureInput.isSystemSecureInputActive {
            refuse("Won't dictate while secure input is active")
            return
        }
        // Snapshot the app category NOW — frontmost moves during dictation.
        // Cheap (bundle-id map lookup, no AX IPC), so it's safe on the hot path.
        capturedCategory = ContextService.frontmostCategory()

        isLocked = false
        recordingStartUptime = ProcessInfo.processInfo.systemUptime
        state = .recording
        audio.beginUtterance()
        hud.show(.recording)
        startMaxRecordingCap()
    }

    private func hotkeyReleased() {
        guard state == .recording, !isLocked else { return }
        // Sub-threshold hold = a tap (e.g. arming a double-tap): discard, never
        // transcribe. Decided synchronously so the next press records cleanly.
        let held = ProcessInfo.processInfo.systemUptime - recordingStartUptime
        guard held >= Self.minHoldToTranscribe else {
            cancelRecording()
            return
        }
        finishRecording(trim: false)
    }

    private func hotkeyDoubleTapped() {
        // The second tap's press already started recording; latch hands-free —
        // but only if VAD can actually auto-stop it. Without VAD, stay in hold
        // mode (release stops) rather than implying an auto-stop that never comes.
        guard state == .recording, vadAvailable else { return }
        isLocked = true
        hud.update(.locked)
        Task {
            await vad.beginStream()
            startVadAutoStop()
        }
    }

    private func hotkeyHealthChanged(_ healthy: Bool) {
        hotkeyDead = !healthy
        // Only surface via the HUD when idle, so a mid-recording HUD is never
        // clobbered; the menu-bar flag covers the always-visible case.
        if !healthy, state == .idle {
            hud.show(.warning("Hotkey stopped — check Input Monitoring"))
            hud.hide(after: 4)
        }
    }

    private func refuse(_ message: String) {
        hud.show(.refused(message))
        hud.hide(after: 1.5)
        NSSound.beep()
    }

    // MARK: - Recording lifecycle

    private func startMaxRecordingCap() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = commonTimer(interval: Self.maxRecordingSeconds) { [weak self] in
            guard let self, self.state == .recording else { return }
            self.log.warning("max recording duration hit — stopping")
            self.finishRecording(trim: self.isLocked)
        }
    }

    private func stopTimers() {
        vadTimer?.invalidate(); vadTimer = nil
        maxRecordingTimer?.invalidate(); maxRecordingTimer = nil
    }

    /// Abandon the current recording without transcribing (short tap / empty).
    private func cancelRecording() {
        stopTimers()
        isLocked = false
        _ = audio.endUtterance()
        state = .idle
        hud.hide()
    }

    // MARK: - VAD auto-stop (locked mode)

    private func startVadAutoStop() {
        vadTimer?.invalidate()
        vadTimer = commonTimer(interval: 0.15) { [weak self] in
            guard let self else { return }
            let samples = self.audio.drainNewSamples()
            guard !samples.isEmpty else { return }
            Task { @MainActor in
                let ended = await self.vad.feed(samples)
                if ended, self.state == .recording, self.isLocked {
                    self.finishRecording(trim: true)
                }
            }
        }
    }

    // MARK: - Finish → transcribe → insert

    private func finishRecording(trim: Bool) {
        stopTimers()
        let wasLocked = isLocked
        isLocked = false

        var timings = StageTimings()
        let (samples, finalizeSeconds) = measuredSync { audio.endUtterance() }
        timings.audioFinalizeSeconds = finalizeSeconds

        // Floor guard (defense in depth; the duration gate is the real filter).
        guard samples.count >= asr.minimumSamples else {
            state = .idle
            hud.hide()
            return
        }

        state = .transcribing
        hud.update(.transcribing)
        Task { await transcribeAndInsert(samples, wasLocked: wasLocked, trim: trim, timings: timings) }
    }

    private func transcribeAndInsert(
        _ samples: [Float], wasLocked: Bool, trim: Bool, timings: StageTimings
    ) async {
        var timings = timings
        do {
            let audioForAsr = trim ? await vad.trim(samples) : samples
            let toTranscribe = audioForAsr.count >= asr.minimumSamples ? audioForAsr : samples
            let (result, asrSeconds) = try await measured { try await asr.transcribe(toTranscribe) }
            timings.asrSeconds = asrSeconds
            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else {
                state = .idle
                hud.hide()
                return
            }

            // Stage 2: LLM auto-edit (or rule-based fast path / raw fallback).
            // Formatter.format never throws — a dictation always lands.
            let raw = rawMode
            let style = contextAwareStyle ? styleRules.directive(for: capturedCategory) : ""
            let (text, formatSeconds) = await measured {
                await formatter.format(rawText, rawMode: raw, styleDirective: style)
            }
            timings.formatSeconds = formatSeconds

            // Authoritative secure check (system + focused AX field). Focus may
            // have moved to a password field while we transcribed. This is off
            // the capture hot path, so its AX IPC is acceptable here.
            if SecureInput.shouldRefuse {
                refuse("Won't insert into a secure field")
                state = .idle
                return
            }

            state = .inserting
            hud.update(.inserting)
            let insertClock = ContinuousClock()
            let insertStart = insertClock.now
            inserter.insert(text) { [weak self] in
                guard let self else { return }
                timings.insertSeconds = (insertClock.now - insertStart).seconds
                self.lastTranscript = text
                self.lastTimings = timings.description
                self.log.info("dictation (\(wasLocked ? "locked" : "hold")): \"\(text, privacy: .private)\" [\(timings.description)]")
                self.state = .idle
                self.hud.hide()
            }
        } catch {
            errorGeneration += 1
            let generation = errorGeneration
            state = .error(error.localizedDescription)
            hud.show(.warning("Transcription failed"))
            hud.hide(after: 2)
            log.error("dictation failed: \(error.localizedDescription)")
            try? await Task.sleep(for: .seconds(3))
            if case .error = state, errorGeneration == generation { state = .idle }
        }
    }
}
