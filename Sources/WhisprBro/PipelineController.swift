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
    // Chosen at launch from the persisted engine kind (spec §11.7 fallback
    // slot). Parakeet unless whisper.cpp is both selected and installed.
    private let asr: AsrEngine = AsrEngineKind.makeSelectedEngine()
    private let vad = VadGate(modelFile: Paths.vadModelFile)
    private var styleRules = StyleRules()
    private var config = AppConfig()
    private var dictionary = DictionaryEngine(rules: [])
    private var categoryOverrides: [String: AppCategory] = [:]
    private let hud = HUDController()
    private let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "pipeline")

    /// Currently selected formatting model (persisted). The engine + formatter
    /// are rebuilt when this changes (see `selectLLM`).
    @Published private(set) var llmModelKey: String
    private var llmModel: LlmModelSpec { LlmCatalog.spec(key: llmModelKey) ?? LlmCatalog.default }
    private var engine: LlamaCppEngine
    private var formatter: TextFormatter

    /// Idle-LLM-unload (spec §11.7): free the ~1GB model + KV cache after the
    /// LLM has sat unused, reloading (~1–2s) on the next dictation. Off by
    /// default; both settings persist. Safe because the engine is an actor —
    /// an unload can never interleave with an in-flight decode.
    @Published var idleUnloadEnabled: Bool {
        didSet {
            UserDefaults.standard.set(idleUnloadEnabled, forKey: "idleUnloadEnabled")
            if idleUnloadEnabled { armIdleUnloadTimer() }
            else { idleUnloadTimer?.invalidate(); idleUnloadTimer = nil }
        }
    }
    @Published var idleUnloadMinutes: Int {
        didSet {
            UserDefaults.standard.set(idleUnloadMinutes, forKey: "idleUnloadMinutes")
            if idleUnloadEnabled { armIdleUnloadTimer() }
        }
    }
    private var idleUnloadTimer: Timer?
    /// True while the model is unloaded specifically to save idle memory, so the
    /// next dictation knows to reload it (vs. an LLM that was never available).
    private var llmUnloadedForIdle = false

    @Published private(set) var rawMode = false
    /// Apply per-app formatting register (Slack casual / Mail formal / …).
    @Published var contextAwareStyle = true
    /// Persist each dictation to the local history. Off = dictate without a
    /// stored transcript log (persisted across launches).
    @Published var historyEnabled = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: "historyEnabled") }
    }

    /// App category captured at key-press for the current dictation.
    private var capturedCategory: AppCategory = .unknown
    private var capturedBundleId: String?
    private var capturedAppName: String?
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
        // Restore the selected model (fall back to the frozen default if the
        // stored key is unknown), then build the engine for it.
        let storedKey = UserDefaults.standard.string(forKey: "llmModelKey")
        let spec = storedKey.flatMap { LlmCatalog.spec(key: $0) } ?? LlmCatalog.default
        llmModelKey = spec.key
        idleUnloadEnabled = UserDefaults.standard.object(forKey: "idleUnloadEnabled") as? Bool ?? false
        idleUnloadMinutes = UserDefaults.standard.object(forKey: "idleUnloadMinutes") as? Int ?? 5
        let engine = LlamaCppEngine(
            modelPath: spec.fileURL,
            promptBuilder: PromptBuilder(family: spec.family)
        )
        self.engine = engine
        formatter = TextFormatter(engine: engine)
    }

    // MARK: - LLM lifecycle (preset switch + idle unload)
    //
    // Every engine load/unload/swap runs through ONE serial chain (`llmChain`)
    // so they can never interleave. Without it, two rapid preset switches — or
    // a switch during the ~1–2s startup load — could reassign `engine` while a
    // load was in flight and orphan a fully-loaded engine whose ≈1GB C/Metal
    // resources would leak. Serializing also removes the idle-unload↔dictation
    // race: the dictation's reload is ordered after any pending idle unload.

    /// Serial executor for LLM engine lifecycle ops; each awaits the previous.
    private var llmChain: Task<Void, Never> = Task {}
    /// Set once at teardown so no lifecycle op reloads the engine after
    /// shutdown() has freed it (which would exit with a live Metal model and
    /// trip the ggml-metal teardown assert).
    private var llmShuttingDown = false

    @discardableResult
    private func llmSerial(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let prev = llmChain
        let t = Task { @MainActor in await prev.value; await op() }
        llmChain = t
        return t
    }

    /// Switch the formatting model. Not-installed presets are ignored (the UI
    /// disables them; this is the backstop). The choice is persisted only after
    /// a successful load, so a present-but-corrupt model can't brick formatting
    /// on every future launch.
    func selectLLM(key: String) {
        guard key != llmModelKey, let spec = LlmCatalog.spec(key: key) else { return }
        guard spec.isInstalled else {
            log.info("ignoring LLM selection '\(key)' — not installed")
            return
        }
        llmModelKey = key   // drives the picker + coalescing; persisted on success
        llmSerial { await self.reloadLLM(spec: spec) }
    }

    /// Rebuild the engine for `spec`. Serialized; coalesces — if a newer
    /// selection superseded this one while it waited, it skips without touching
    /// the (now-correct) engine.
    private func reloadLLM(spec: LlmModelSpec) async {
        guard !llmShuttingDown else { return }
        guard spec.key == llmModelKey else { return }   // superseded by a later selectLLM
        idleUnloadTimer?.invalidate(); idleUnloadTimer = nil
        await engine.unload()   // free the outgoing engine's GPU/C resources first
        let newEngine = LlamaCppEngine(
            modelPath: spec.fileURL, promptBuilder: PromptBuilder(family: spec.family))
        engine = newEngine
        formatter = TextFormatter(engine: newEngine)
        llmUnloadedForIdle = false
        do {
            try await formatter.load()
            llmAvailable = true
            UserDefaults.standard.set(spec.key, forKey: "llmModelKey")   // persist only good keys
            log.info("loaded LLM '\(spec.key)'")
        } catch {
            llmAvailable = false
            log.warning("LLM '\(spec.key)' load failed, using raw cleanup: \(error.localizedDescription)")
        }
        armIdleUnloadTimer()
    }

    /// Reload the model if it was unloaded to save idle memory. Called on the
    /// dictation path just before formatting; serialized after any pending idle
    /// unload and awaited so formatting sees a loaded engine. No-op otherwise.
    private func ensureLLMLoaded() async {
        await llmSerial {
            guard !self.llmShuttingDown, self.llmUnloadedForIdle, self.llmModel.isInstalled else { return }
            do {
                try await self.formatter.load()
                self.llmUnloadedForIdle = false
                self.llmAvailable = true
                // Restart the idle countdown: this reload may be the dictation's
                // last action (e.g. it ends on the secure-field refuse path,
                // which doesn't re-arm), and the one-shot timer that unloaded us
                // is already spent — without this the model would stay resident.
                self.armIdleUnloadTimer()
                self.log.info("reloaded LLM after idle unload")
            } catch {
                self.llmAvailable = false
                self.log.warning("idle reload failed, using raw cleanup: \(error.localizedDescription)")
            }
        }.value
    }

    private func armIdleUnloadTimer() {
        idleUnloadTimer?.invalidate()
        guard idleUnloadEnabled, llmAvailable else { idleUnloadTimer = nil; return }
        let interval = TimeInterval(max(1, idleUnloadMinutes) * 60)
        // One-shot on .common mode so an open menu-bar menu (event-tracking loop)
        // doesn't suspend the countdown — matching the controller's other timers.
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.unloadLLMForIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleUnloadTimer = timer
    }

    private func unloadLLMForIdle() {
        llmSerial {
            guard !self.llmShuttingDown, self.idleUnloadEnabled, self.llmAvailable, !self.llmUnloadedForIdle else { return }
            // Fired while a dictation was running: don't unload mid-decode — re-
            // arm to retry once idle. (Terminal dictation paths that don't re-arm
            // — error/refuse/empty — rely on this.)
            guard self.state == .idle else { self.armIdleUnloadTimer(); return }
            // Set BEFORE the await so a dictation whose reload op is serialized
            // after this one knows to reload.
            self.llmUnloadedForIdle = true
            await self.engine.unload()
            self.log.info("unloaded LLM after \(self.idleUnloadMinutes)min idle (frees ~1GB; reloads on next dictation)")
        }
    }

    func startup() {
        ConfigStore.ensureDefault()
        applyConfig(ConfigStore.load())
        // Open the history DB off-main so the first History-window access
        // doesn't run the SQLite open + migration on the main thread.
        Task.detached { HistoryStore.prewarm() }
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
                    armIdleUnloadTimer()
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

    private static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    /// Re-insert a past dictation (from the History window). The window has
    /// already dismissed, so after a short beat the frontmost app is the one
    /// the user wants — paste into it, but only if it isn't a secure field
    /// (same guard the live dictation path enforces).
    func reinsertFromHistory(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if SecureInput.shouldRefuse {
                NSSound.beep() // refuse to paste into a password field
                return
            }
            self.inserter.insert(text)
        }
    }

    /// Rebuild the dictionary, style overrides, and category map from `config`
    /// (spec §4 Config mirror; §11.5 live reload).
    private func applyConfig(_ config: AppConfig) {
        self.config = config
        dictionary = DictionaryEngine(rules: config.dictionaryRules)
        var rules = StyleRules()
        for (name, directive) in config.style {
            if let category = AppCategory(rawValue: name.lowercased()) {
                rules.setDirective(sanitizeDirective(directive), for: category)
            } else {
                log.warning("config [style] has unknown category '\(name, privacy: .public)' — ignored")
            }
        }
        styleRules = rules
        categoryOverrides = config.categories.reduce(into: [:]) { map, pair in
            if let c = AppCategory(rawValue: pair.value.lowercased()) {
                map[pair.key] = c
            } else {
                log.warning("config [categories] maps to unknown category '\(pair.value, privacy: .public)' — ignored")
            }
        }
    }

    /// Strip chat control-token markup from a hand-edited directive so a config
    /// value can't inject control tokens into the (parse_special) system prompt.
    private func sanitizeDirective(_ directive: String) -> String {
        directive.replacingOccurrences(
            of: "<\\|[^>]*\\|>", with: "", options: .regularExpression)
    }

    /// The LLM system-prompt directive: the per-app register (if enabled) plus
    /// a "preserve these spellings" allowlist of the dictionary's canonical
    /// targets (capped), so the model doesn't re-spell an unfamiliar term. Both
    /// live in the KV-cached prefix and only re-prime when they change.
    private func effectiveStyleDirective(dictionary dict: DictionaryEngine) -> String {
        var parts: [String] = []
        if contextAwareStyle {
            parts.append(styleRules.directive(for: capturedCategory))
        }
        let targets = dict.canonicalTargets.prefix(30)
        if !targets.isEmpty {
            parts.append("Preserve these spellings exactly, do not alter their "
                + "casing or spacing: " + targets.joined(separator: ", ") + ".")
        }
        // Directives were sanitized at load; targets are user config too.
        return sanitizeDirective(parts.joined(separator: "\n\n"))
    }

    /// Re-read config.toml (menu "Reload config"). Live: takes effect on the
    /// next dictation.
    func reloadConfig() { applyConfig(ConfigStore.load()) }

    /// Open config.toml in the user's default editor (creating it first).
    func openConfig() {
        ConfigStore.ensureDefault()
        NSWorkspace.shared.open(ConfigStore.url)
    }

    /// Free GPU-backed models before the process exits (spec §12 clean quit).
    func shutdown() async {
        // Latch teardown first: every lifecycle op guards on this, so any op
        // still queued — or appended while we drain below — becomes a no-op and
        // can't re-load the engine after we free it (which would exit with a
        // live Metal model and trip the ggml-metal teardown assert).
        llmShuttingDown = true
        idleUnloadTimer?.invalidate(); idleUnloadTimer = nil
        await llmChain.value   // let any in-flight (already-past-guard) op finish
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
        // Snapshot the app NOW — frontmost moves during dictation. Cheap
        // (bundle-id map lookup, no AX IPC), so it's safe on the hot path.
        let front = ContextService.frontmostApp()
        capturedBundleId = front.bundleId
        capturedAppName = front.appName
        capturedCategory = AppCategoryResolver.category(
            bundleId: front.bundleId, overrides: categoryOverrides)

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
            // Snapshot the dictionary/style so a menu reload mid-dictation
            // can't make the substitution and the LLM allowlist disagree.
            let dict = dictionary
            let (result, asrSeconds) = try await measured { try await asr.transcribe(toTranscribe) }
            timings.asrSeconds = asrSeconds
            // Personal dictionary ONCE, BEFORE formatting (so the LLM sees
            // corrected terms) and in raw mode alike (spec §4 DictionaryEngine).
            // Applied once, not before+after: a second pass would duplicate
            // words for an expanding rule (target contains its source).
            let rawText = dict.apply(
                result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !rawText.isEmpty else {
                state = .idle
                hud.hide()
                return
            }

            // Stage 2: LLM auto-edit (or rule-based fast path / raw fallback).
            // Formatter.format never throws — a dictation always lands. The LLM
            // path preserves terms via the allowlist; the raw path preserves
            // their casing via preserveCasingFor.
            let raw = rawMode
            let style = effectiveStyleDirective(dictionary: dict)
            // Reload the model first if it was unloaded to save idle memory
            // (~1–2s, only after a long idle gap and only when the LLM path is
            // actually used — raw mode / fast path skip the reload).
            if !raw { await ensureLLMLoaded() }
            let (text, formatSeconds) = await measured {
                await formatter.format(rawText, rawMode: raw, styleDirective: style,
                                       preserveCasingFor: dict.lowercasedTargets)
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
            let historyRaw = rawText
            let historyBundleId = capturedBundleId
            let historyAppName = capturedAppName
            inserter.insert(text) { [weak self] in
                guard let self else { return }
                timings.insertSeconds = (insertClock.now - insertStart).seconds
                self.lastTranscript = text
                self.lastTimings = timings.description
                self.log.info("dictation (\(wasLocked ? "locked" : "hold")): \"\(text, privacy: .private)\" [\(timings.description)]")
                self.state = .idle
                self.hud.hide()
                // Restart the idle-unload countdown now the dictation is done.
                self.armIdleUnloadTimer()
                // Persist to history OFF the insertion path — a detached Task
                // so the DB write never blocks the dictation completing. Skipped
                // entirely when the user disabled history.
                if self.historyEnabled {
                    let record = HistoryRecord(
                        createdAt: Date(), appBundleId: historyBundleId, appName: historyAppName,
                        rawText: historyRaw, formattedText: text,
                        audioMs: Self.ms(timings.audioFinalizeSeconds), asrMs: Self.ms(timings.asrSeconds),
                        formatMs: Self.ms(timings.formatSeconds), insertMs: Self.ms(timings.insertSeconds),
                        totalMs: Self.ms(timings.totalSeconds))
                    Task.detached { await HistoryStore.shared?.save(record) }
                }
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
