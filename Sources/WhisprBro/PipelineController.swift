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
    /// Verbatim (dictionary-only) form of the last dictation — for "undo AI edit
    /// → paste raw" (task-014 §7c).
    @Published private(set) var lastRawTranscript: String = ""
    @Published private(set) var lastTimings: String = ""
    @Published private(set) var permissions = PermissionSnapshot()
    /// True while the tap is confirmed dead (Input Monitoring likely revoked).
    @Published private(set) var hotkeyDead = false

    private let audio = AudioEngine()
    private let hotkey = HotkeyManager()
    private let inserter = TextInserter()
    /// Selected dictation language (English default). Chosen at launch; changing
    /// it requires relaunch (the ASR engine, like the model, is built once).
    private let dictationLanguage = DictationLanguage.selected
    // ASR engine for the selected language: English → Parakeet v2 (fast,
    // English-only); Italian/Spanish → Parakeet v3 (multilingual, auto-detecting).
    private let asr: AsrEngine = ParakeetEngine(
        modelsDir: Paths.modelsDir, version: DictationLanguage.selected.parakeetVersion)
    private let vad = VadGate(modelFile: Paths.vadModelFile)
    private var styleRules = StyleRules()
    private var config = AppConfig()
    private var dictionary = DictionaryEngine(rules: [])
    private var categoryOverrides: [String: AppCategory] = [:]
    /// Auto-Clean (task-014): the deterministic filler pre-pass + the effective
    /// cleanup settings, rebuilt from config. The live LEVEL is the menu control
    /// (`cleanupLevel`); the other knobs come from config.toml.
    private var fillerStripper = FillerStripper()
    private var cleanupCfg = AppConfig.Cleanup()
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
    /// Auto-Clean level — the menu tri-state control (task-014 §7c). Persisted in
    /// UserDefaults and authoritative for the level (there is no config.toml
    /// `level` key — that would fight the menu). The other cleanup knobs (filler
    /// set, verbatim categories, stutter collapse) come from config.toml.
    @Published var cleanupLevel: AppConfig.Cleanup.Level = {
        if let raw = UserDefaults.standard.string(forKey: "cleanupLevel"),
           let lvl = AppConfig.Cleanup.Level(rawValue: raw) { return lvl }
        return .fillers
    }() {
        didSet { UserDefaults.standard.set(cleanupLevel.rawValue, forKey: "cleanupLevel") }
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

    /// Whether the current recording is a normal dictation or a Command-Mode
    /// voice edit (task: hotkeys). Set at key-down, read at finish.
    enum DictationMode { case dictation, command }
    private var pendingMode: DictationMode = .dictation
    /// Selected text captured at Command-Mode key-down (the edit target).
    private var capturedSelection: String?
    /// Set when the user hits Cancel mid-dictation so the in-flight transcribe
    /// task skips its insert. Cleared at the start of each recording.
    private var pendingCancel = false

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
            promptBuilder: PromptBuilder(
                family: spec.family,
                systemPrompt: PromptBuilder.systemPrompt(for: DictationLanguage.selected))
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
            modelPath: spec.fileURL,
            promptBuilder: PromptBuilder(
                family: spec.family,
                systemPrompt: PromptBuilder.systemPrompt(for: dictationLanguage)))
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
        hotkey.onAction = { [weak self] action, phase in self?.handleHotkey(action, phase) }
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

        let modelDir = Paths.modelsDir.appendingPathComponent(
            ParakeetEngine.folderName(for: dictationLanguage.parakeetVersion))
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
                // Prepare the capture graph WITHOUT opening the mic: the input
                // IOProc (and the macOS mic indicator) starts only while a
                // dictation is in progress (see AudioEngine "prepare-ahead").
                try audio.prepare()
                try hotkey.start()
                pipelineRunning = true
            }
            state = .idle
            log.info("pipeline up: hotkey armed, audio prepared (mic opens on dictation), models loaded (vad: \(self.vadAvailable))")
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

    /// Re-insert the last dictation's VERBATIM (dictionary-only) text — "undo the
    /// AI edit" (task-014 §7c). Weaker than a partial undo: it restores fillers
    /// and drops LLM punctuation/capitalization, so the caller's UI copy must say
    /// so. No-op if there's no prior dictation this session.
    /// Offer undo only when idle AND the last dictation was actually edited
    /// (cleaned/corrected differs from the verbatim) — no point re-pasting an
    /// identical string (e.g. verbatim level, or an utterance with no fillers).
    var canUndoToRaw: Bool {
        state == .idle && !lastRawTranscript.isEmpty && lastTranscript != lastRawTranscript
    }
    func reinsertLastRaw() {
        // Only when idle — never race a live insertion through the pasteboard.
        guard canUndoToRaw else { return }
        reinsertFromHistory(lastRawTranscript)
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
        // Auto-Clean: rebuild the filler pre-pass from config. The aggressiveness
        // LEVEL is the menu control (cleanupLevel), not a config key.
        cleanupCfg = config.cleanup
        fillerStripper = FillerStripper(
            core: FillerStripper.coreFillers(for: dictationLanguage),
            extra: config.cleanup.extraFillers,
            disabled: config.cleanup.disabledFillers,
            collapseStutters: config.cleanup.collapseStutters)
    }

    /// Whether the current register disables Auto-Clean entirely (verbatim).
    /// Case-insensitive so a hand-edited "IDE" matches the "ide" rawValue.
    private func isVerbatimRegister(_ category: AppCategory) -> Bool {
        cleanupCfg.verbatimCategories.contains { $0.lowercased() == category.rawValue }
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
    private func effectiveStyleDirective(dictionary dict: DictionaryEngine, resolveCorrections: Bool) -> String {
        var parts: [String] = []
        if contextAwareStyle {
            parts.append(styleRules.directive(for: capturedCategory))
        }
        // Self-correction clause (task-014 §6.2) — only at level=standard on a
        // non-verbatim register. Lives in the KV-cached prefix, so it re-primes
        // only when the register/level changes, not per dictation.
        if resolveCorrections {
            parts.append(PromptBuilder.correctionClause(for: dictationLanguage))
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

    /// Central dispatch for all configurable hotkey actions (task: hotkeys).
    private func handleHotkey(_ action: HotkeyAction, _ phase: HotkeyPhase) {
        switch (action, phase) {
        case (.dictate, .began): hotkeyPressed(mode: .dictation)
        case (.dictate, .ended): hotkeyReleased()
        case (.commandMode, .began): hotkeyPressed(mode: .command)
        case (.commandMode, .ended): hotkeyReleased()
        case (.handsFree, .fired): hotkeyDoubleTapped()
        case (.cancel, .fired): cancelActive()
        case (.pasteLast, .fired): pasteLastTranscript()
        case (.copyLast, .fired): copyLastTranscript()
        default: break
        }
    }

    private func hotkeyPressed(mode: DictationMode = .dictation) {
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
        pendingMode = mode
        pendingCancel = false
        capturedSelection = nil

        isLocked = false
        recordingStartUptime = ProcessInfo.processInfo.systemUptime
        // Open the mic NOW — this lights the macOS mic indicator (on-demand, so
        // it's lit only while dictating). Fast because AudioEngine was prepared
        // at bring-up; the ~100ms until the built-in mic is live is hidden by
        // reaction time before the first word.
        do {
            try audio.startCapture()
        } catch {
            log.error("mic startCapture failed: \(error.localizedDescription)")
            refuse("Microphone unavailable")
            return
        }
        state = .recording
        audio.beginUtterance()
        hud.show(.recording)
        startMaxRecordingCap()
        // Command Mode: read the selection to edit. Done AFTER recording starts
        // (it's only needed at finish) so the bounded AX IPC can't delay capture
        // or skew the tap-vs-hold timing.
        if mode == .command { capturedSelection = AXFocus.selectedText() }
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
        audio.stopCapture()   // close the mic → clears the macOS mic indicator
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
        // Utterance audio is now in hand — close the mic so the macOS mic
        // indicator clears immediately at end-of-speech, while ASR/LLM run.
        audio.stopCapture()

        // Floor guard (defense in depth; the duration gate is the real filter).
        guard samples.count >= asr.minimumSamples else {
            state = .idle
            hud.hide()
            return
        }

        state = .transcribing
        hud.update(.transcribing)
        if pendingMode == .command {
            let selection = capturedSelection
            Task { await transcribeCommand(samples, selection: selection, timings: timings) }
        } else {
            Task { await transcribeAndInsert(samples, wasLocked: wasLocked, trim: trim, timings: timings) }
        }
    }

    private func transcribeAndInsert(
        _ samples: [Float], wasLocked: Bool, trim: Bool, timings: StageTimings
    ) async {
        var timings = timings
        do {
            let audioForAsr = trim ? await vad.trim(samples) : samples
            let toTranscribe = audioForAsr.count >= asr.minimumSamples ? audioForAsr : samples
            // Snapshot the dictionary/cleanup so a menu reload mid-dictation
            // can't make the substitution, the LLM allowlist, and the filler
            // pre-pass disagree.
            let dict = dictionary
            let stripper = fillerStripper
            let level = cleanupLevel
            let verbatimRegister = isVerbatimRegister(capturedCategory)
            let (result, asrSeconds) = try await measured { try await asr.transcribe(toTranscribe) }
            timings.asrSeconds = asrSeconds
            // Personal dictionary ONCE, BEFORE formatting (so the LLM sees
            // corrected terms) and in raw mode alike (spec §4 DictionaryEngine).
            // Applied once, not before+after: a second pass would duplicate
            // words for an expanding rule (target contains its source).
            // `verbatimText` is the TRUE verbatim form (dictionary only) — it is
            // what history stores as rawText.
            let verbatimText = dict.apply(
                result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !verbatimText.isEmpty else {
                state = .idle
                hud.hide()
                return
            }

            // Auto-Clean level "Off (verbatim)" = the WHOLE stage is a no-op:
            // no filler strip AND no LLM — paste the dictionary-corrected text
            // exactly as spoken (spec §7a / AC #6). Verbatim registers
            // (ide/terminal/notes) only skip the Auto-Clean strip+correction;
            // they still run the LLM with their own verbatim-ish directive.
            let stageOff = level == .verbatim

            // Stage 1 (task-014 §5a): deterministic filler strip on ALL routes,
            // unless the stage is off / verbatim register. Protects dictionary
            // targets from a case-insensitive filler collision.
            let stripFillers = !stageOff && !verbatimRegister
            let stripped = stripFillers
                ? stripper.strip(verbatimText, protecting: dict.lowercasedTargets)
                : verbatimText
            // Never emit empty: an all-filler utterance ("um", or "um, uh." which
            // strips to bare punctuation) falls back to the verbatim text so a
            // dictation always lands (spec §3.2 #17). "Meaningful" = has a letter
            // or digit, so a punctuation-only residue also triggers the fallback.
            let hasContent = stripped.contains { $0.isLetter || $0.isNumber }
            let cleanedInput = hasContent ? stripped : verbatimText

            let text: String
            let formatSeconds: Double
            if stageOff {
                // Byte-identical to the dictionary-corrected text — proven no-op.
                text = verbatimText
                formatSeconds = 0
            } else {
                // Stage 2: LLM auto-edit (or rule-based fast path / raw fallback).
                // Formatter.format never throws — a dictation always lands.
                let raw = rawMode
                // Self-correction: level=standard on a non-verbatim register. The
                // LLM path handles it; format() also uses this to keep a short
                // correction off the fast path (§5c).
                let resolveCorr = level == .standard && !verbatimRegister
                let style = effectiveStyleDirective(dictionary: dict, resolveCorrections: resolveCorr)
                // Reload the model first if it was unloaded to save idle memory
                // (~1–2s, only after a long idle gap, only on the LLM path).
                if !raw { await ensureLLMLoaded() }
                (text, formatSeconds) = await measured {
                    await formatter.format(cleanedInput, rawMode: raw, styleDirective: style,
                                           preserveCasingFor: dict.lowercasedTargets,
                                           resolveCorrections: resolveCorr,
                                           language: dictationLanguage)
                }
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
            // The user hit Cancel while we were transcribing/formatting — don't paste.
            if pendingCancel {
                pendingCancel = false
                state = .idle
                hud.hide()
                return
            }

            state = .inserting
            hud.update(.inserting)
            let insertClock = ContinuousClock()
            let insertStart = insertClock.now
            let historyRaw = verbatimText   // history "raw" = what was said (dictionary-only)
            let historyBundleId = capturedBundleId
            let historyAppName = capturedAppName
            inserter.insert(text) { [weak self] in
                guard let self else { return }
                timings.insertSeconds = (insertClock.now - insertStart).seconds
                self.lastTranscript = text
                self.lastRawTranscript = historyRaw   // for "undo AI edit → raw"
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

    // MARK: - Command Mode + quick actions (task: hotkeys)

    /// Transcribe the spoken instruction and voice-edit the captured selection
    /// via the LLM, then paste the result (which replaces the selection). With
    /// no selection, falls back to a normal dictation of the spoken words.
    private func transcribeCommand(_ samples: [Float], selection: String?, timings: StageTimings) async {
        var timings = timings
        do {
            let dict = dictionary
            let (result, asrSeconds) = try await measured { try await asr.transcribe(samples) }
            timings.asrSeconds = asrSeconds
            let instruction = dict.apply(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !instruction.isEmpty else { state = .idle; hud.hide(); return }

            guard llmAvailable else {
                state = .idle
                refuse("Command mode needs the formatting model")
                return
            }
            await ensureLLMLoaded()

            let output: String
            let historyRaw: String
            if let selection, !selection.isEmpty {
                let (edited, fmtSeconds) = await measured {
                    await formatter.command(instruction: instruction, selection: selection,
                                            language: dictationLanguage)
                }
                timings.formatSeconds = fmtSeconds
                guard let edited, !edited.isEmpty else {
                    state = .idle
                    refuse("Couldn't apply that edit")
                    return
                }
                output = edited
                historyRaw = selection
            } else {
                // No selection: treat the spoken words as a normal dictation.
                let (formatted, fmtSeconds) = await measured {
                    await formatter.format(instruction, rawMode: rawMode, language: dictationLanguage)
                }
                timings.formatSeconds = fmtSeconds
                output = formatted
                historyRaw = instruction
            }

            if SecureInput.shouldRefuse { refuse("Won't insert into a secure field"); state = .idle; return }
            if pendingCancel { pendingCancel = false; state = .idle; hud.hide(); return }
            insertCommandResult(output, historyRaw: historyRaw, timings: timings)
        } catch {
            state = .idle
            hud.show(.warning("Command failed"))
            hud.hide(after: 2)
            log.error("command mode failed: \(error.localizedDescription)")
        }
    }

    /// Insert a Command-Mode result (paste replaces the selection) + history.
    /// Kept separate from the dictation insert so that proven path is untouched.
    private func insertCommandResult(_ text: String, historyRaw: String, timings: StageTimings) {
        state = .inserting
        hud.update(.inserting)
        var timings = timings
        let insertClock = ContinuousClock()
        let insertStart = insertClock.now
        let bundleId = capturedBundleId
        let appName = capturedAppName
        inserter.insert(text) { [weak self] in
            guard let self else { return }
            timings.insertSeconds = (insertClock.now - insertStart).seconds
            self.lastTranscript = text
            self.lastRawTranscript = historyRaw
            self.lastTimings = timings.description
            self.log.info("command: \"\(text, privacy: .private)\" [\(timings.description)]")
            self.state = .idle
            self.hud.hide()
            self.armIdleUnloadTimer()
            if self.historyEnabled {
                let record = HistoryRecord(
                    createdAt: Date(), appBundleId: bundleId, appName: appName,
                    rawText: historyRaw, formattedText: text,
                    audioMs: Self.ms(timings.audioFinalizeSeconds), asrMs: Self.ms(timings.asrSeconds),
                    formatMs: Self.ms(timings.formatSeconds), insertMs: Self.ms(timings.insertSeconds),
                    totalMs: Self.ms(timings.totalSeconds))
                Task.detached { await HistoryStore.shared?.save(record) }
            }
        }
    }

    /// Cancel (Esc): abort an in-flight dictation/command. If recording, stop the
    /// mic and discard; if already transcribing/formatting, flag the running task
    /// to skip its insert.
    private func cancelActive() {
        switch state {
        case .recording:
            stopTimers()
            isLocked = false
            _ = audio.endUtterance()
            audio.stopCapture()
            state = .idle
            hud.show(.refused("Canceled")); hud.hide(after: 1)
        case .transcribing, .inserting:
            pendingCancel = true
            hud.show(.refused("Canceling…")); hud.hide(after: 1)
        default:
            break
        }
    }

    /// Paste the last transcript at the cursor (quick re-insert).
    private func pasteLastTranscript() {
        guard state == .idle, !lastTranscript.isEmpty else { return }
        if SecureInput.shouldRefuse { NSSound.beep(); return }
        inserter.insert(lastTranscript)
    }

    /// Copy the last transcript to the clipboard.
    private func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        hud.show(.refused("Copied last transcript")); hud.hide(after: 1)
    }

    /// Apply a rebound hotkey config live (Settings recorder).
    func reloadHotkeys(_ config: HotkeyConfig) {
        hotkey.reload(config)
    }
}
