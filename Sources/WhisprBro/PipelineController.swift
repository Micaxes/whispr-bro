import AppKit
import Foundation
import os.log
import SwiftUI
import WhisprBroCore

/// Wires hotkey → audio → (VAD) → ASR → insertion (spec §3, §9). Task-008
/// adds the double-tap hands-free lock, secure-input refusal, the HUD, and
/// tap-health surfacing.
///
/// The press/release/latch rules themselves live in `DictationGesture` (Core,
/// unit-tested); this type owns only the effects — mic, HUD, timers, ASR.
/// Hands-free ends on the next press, on Cancel, or on the safety cap. It does
/// NOT end on silence: a pause is not evidence that the speaker is done.
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
    /// The shared post-capture text pipeline (trim → ASR → dictionary →
    /// Auto-Clean gating → formatter) — core-owned so the gating rules can
    /// never drift from iOS. Lazy: built from `asr` after property init.
    private lazy var pipeline = DictationPipeline(asr: asr)
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

    /// "Rules only — no AI rewrite" (`RulesOnlyMode`): every dictation takes
    /// the deterministic path (dictionary → self-repair → filler strip →
    /// layout → rule-based cleanup) and the model stays out of memory until
    /// Command Mode needs it. Saved across launches, off by default. Read per
    /// dictation (in prepareFormatter), so a flip can't race an in-flight
    /// format into an inconsistent state.
    @Published var rulesOnly = RulesOnlyMode().isOn {
        didSet {
            guard rulesOnly != oldValue else { return }
            RulesOnlyMode().isOn = rulesOnly
            applyRulesOnly()
        }
    }
    /// "Fix self-corrections" — `[cleanup] self_repair` in config.toml, the
    /// one place it lives: on, the self-repair rules run before the filler
    /// strip; off, the pre-pass is the strip alone, as before the rules.
    /// Mirrors the file (`applyConfig`); Settings flips it through
    /// `setSelfRepair`, which writes that one line.
    @Published private(set) var selfRepair = AppConfig.Cleanup().selfRepair
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
    /// The last attempt to load an installed model failed — so the AI-rewrite
    /// controls say "failed to load", not "not installed".
    @Published private(set) var llmLoadFailed = false

    /// Where the formatting model stands, as Settings and the menu bar say
    /// it: not installed, not loaded yet, failed to load, or available.
    var formattingModelStatus: FormattingModelStatus {
        FormattingModelStatus(installed: llmModel.isInstalled, available: llmAvailable, loadFailed: llmLoadFailed)
    }

    private var permissionPollTimer: Timer?
    private var maxRecordingTimer: Timer?
    private var isBringingUp = false
    private var pipelineRunning = false
    private var vadAvailable = false
    /// True while a hands-free session is latched. Published so the menu bar
    /// can say so — the HUD is not guaranteed to be on screen, and a latched
    /// mic that looks like a hold is how a session gets forgotten.
    @Published private(set) var isLocked = false
    private var recordingStartUptime: TimeInterval = 0
    /// Label of the key bound to `dictate` ("Right ⌥"), shown in the hands-free
    /// HUD and the menu hint so the way out is always on screen. `nil` when he
    /// has deleted the binding — then there IS no key to name, and the UI says
    /// Esc instead of naming one that does nothing. Refreshed on every rebind.
    @Published private(set) var dictateKeyLabel: String? = PipelineController.keyLabel(.dictate, in: .load())
    /// Same, for the Cancel key — the hands-free hint falls back to it.
    @Published private(set) var cancelKeyLabel: String? = PipelineController.keyLabel(.cancel, in: .load())

    /// Whether a hands-free session is latched right now (menu bar + HUD copy).
    var isHandsFree: Bool { state == .recording && isLocked }

    /// A dictation is in flight: mic open, transcribing, or inserting.
    var isDictating: Bool {
        switch state {
        case .recording, .transcribing, .inserting: true
        default: false
        }
    }

    /// Called each time a dictation has landed (inserted, or copied to the
    /// clipboard) and the pipeline is idle again.
    var onDictationFinished: (() -> Void)?

    /// How to end a latched session, in his words. Never names a key that
    /// isn't bound — including the Cancel fallback. The wording lives in Core
    /// so the HUD and the menu bar can't drift: both print it verbatim.
    var handsFreeExitHint: String {
        DictationGesture.exitHint(dictateKeyLabel: dictateKeyLabel, cancelKeyLabel: cancelKeyLabel)
    }
    private var errorGeneration = 0

    /// Where a finished dictation lands. A capped hands-free session goes to
    /// the clipboard instead: five minutes on, the frontmost app is not
    /// necessarily the one he was dictating into, and an unattended ⌘V of five
    /// minutes of speech is the one outcome worse than making him paste it.
    enum Delivery { case insert, clipboard }

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

    // MARK: - LLM lifecycle (preset switch + idle unload + rules-only)
    //
    // Every engine load/unload/swap runs through ONE serial chain
    // (`ModelResidency`) so they can never interleave. Without it, two rapid
    // preset switches — or a switch during the ~1–2s startup load — could
    // reassign `engine` while a load was in flight and orphan a fully-loaded
    // engine whose ≈1GB C/Metal resources would leak. Serializing also removes
    // the idle-unload↔dictation race (the dictation's reload is ordered after
    // any pending idle unload) and the rules-only one (turned back on during
    // the background load, the unload queued behind it frees what it loaded).

    /// The chain, whether an installed model is out of memory
    /// (`isUnloaded`), and the teardown latch (`isShuttingDown`: no op may
    /// reload the engine after shutdown() freed it, which would exit with a
    /// live Metal model and trip the ggml-metal teardown assert). The
    /// rules-only and on-demand ops live there, pinned by test
    /// (`ModelResidencyTests`); this controller is their host.
    private lazy var residency = ModelResidency(host: self)

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
        residency.serial { await self.reloadLLM(spec: spec) }
    }

    /// Rebuild the engine for `spec`. Serialized; coalesces — if a newer
    /// selection superseded this one while it waited, it skips without touching
    /// the (now-correct) engine.
    private func reloadLLM(spec: LlmModelSpec) async {
        guard !residency.isShuttingDown else { return }
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
        residency.isUnloaded = false
        do {
            try await formatter.load()
            llmAvailable = true
            llmLoadFailed = false
            UserDefaults.standard.set(spec.key, forKey: "llmModelKey")   // persist only good keys
            log.info("loaded LLM '\(spec.key)'")
            // Loaded to prove the file is good before it is saved as his
            // choice; in rules-only nothing uses it, so it goes again.
            if rulesOnly {
                residency.isUnloaded = true
                await newEngine.unload()
                log.info("rules only: unloaded '\(spec.key)' until something needs it")
            }
        } catch {
            llmAvailable = false
            llmLoadFailed = true
            log.warning("LLM '\(spec.key)' load failed, using raw cleanup: \(error.localizedDescription)")
        }
        armIdleUnloadTimer()
    }

    /// Load the model if it is not in memory (unloaded for idle, or left
    /// unloaded by rules-only). Called on the dictation path just before
    /// formatting and by Command Mode; serialized after any pending unload
    /// and awaited so formatting sees a loaded engine. No-op otherwise.
    private func ensureLLMLoaded() async {
        await residency.ensureLoaded()
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
        residency.serial {
            guard !self.residency.isShuttingDown, self.idleUnloadEnabled, self.llmAvailable,
                  !self.residency.isUnloaded else { return }
            // Fired while a dictation was running: don't unload mid-decode — re-
            // arm to retry once idle. (Terminal dictation paths that don't re-arm
            // — error/refuse/empty — rely on this.)
            guard self.state == .idle else { self.armIdleUnloadTimer(); return }
            // Set BEFORE the await so a dictation whose reload op is serialized
            // after this one knows to reload.
            self.residency.isUnloaded = true
            await self.engine.unload()
            self.log.info("unloaded LLM after \(self.idleUnloadMinutes)min idle (frees ~1GB; reloads on next dictation)")
        }
    }

    /// The model's side of flipping rules-only (`RulesOnlyMode.transition`,
    /// queued in order by `ModelResidency`): on frees it — always queued,
    /// behind a background load still in flight — and off loads it in the
    /// background so the next dictation does not wait ~1–2 s for it.
    private func applyRulesOnly() {
        residency.rulesOnlyChanged(to: rulesOnly)
    }

    /// Free the model for rules-only — but never under a dictation or a
    /// command that is using it: then retry once it has landed.
    private func unloadLLMForRulesOnly() {
        residency.unloadForRulesOnly()
    }

    func startup() {
        ConfigStore.ensureDefault()
        applyConfig(ConfigStore.load())
        // Open the history DB off-main so the first History-window access
        // doesn't run the SQLite open + migration on the main thread.
        Task.detached { HistoryStore.prewarm() }
        // The self-repair rules read two on-device language models (~70 ms
        // to load, once); load them now, off-main, not in the first dictation.
        if dictationLanguage == .english {
            Task.detached(priority: .utility) { SelfRepair.prewarm() }
        }
        hud.levelProvider = { [weak self] in self?.audio.lastRMS ?? 0 }
        hotkey.onAction = { [weak self] action, phase, at in
            self?.handleHotkey(action, phase, at: at)
        }
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
            // VAD is optional: without it silence-trim is disabled (nothing
            // else depends on it) and both dictation modes still work.
            do {
                try await vad.load()
                vadAvailable = true
            } catch {
                vadAvailable = false
                log.warning("VAD unavailable, continuing without it: \(error.localizedDescription)")
            }
            // LLM is optional too: without it, dictation falls back to
            // rule-based cleanup (raw mode) — never blocks bring-up.
            if RulesOnlyMode.loadsModelAtLaunch(rulesOnly: rulesOnly, modelInstalled: llmModel.isInstalled) {
                do {
                    try await formatter.load()
                    llmAvailable = true
                    llmLoadFailed = false
                    armIdleUnloadTimer()
                } catch {
                    llmAvailable = false
                    llmLoadFailed = true
                    log.warning("LLM unavailable, using raw cleanup: \(error.localizedDescription)")
                }
            } else if llmModel.isInstalled {
                // Rules only: the model stays on disk until something needs
                // it (Command Mode, or a dictation once AI rewrite is back on).
                llmAvailable = true
                if !(await formatter.isEngineLoaded) { residency.isUnloaded = true }
                log.info("rules only: formatting model not loaded at launch")
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
        selfRepair = config.cleanup.selfRepair
        fillerStripper = FillerStripper(
            core: FillerStripper.coreFillers(for: dictationLanguage),
            extra: config.cleanup.extraFillers,
            disabled: config.cleanup.disabledFillers,
            collapseStutters: config.cleanup.collapseStutters)
    }

    /// Turn the self-repair rules on or off from Settings: writes
    /// `[cleanup] self_repair` into config.toml — that line only, his
    /// comments and the rest of the file untouched — then reloads the file,
    /// so what runs is what the file says. Takes effect on the next
    /// dictation. A write that fails leaves the file and the switch as they
    /// were.
    func setSelfRepair(_ on: Bool) {
        guard on != cleanupCfg.selfRepair else { return }
        do {
            try ConfigStore.setCleanupSwitch("self_repair", to: on)
            log.info("self-repair rules \(on ? "on" : "off", privacy: .public) (config.toml [cleanup] self_repair)")
        } catch {
            log.error("could not write [cleanup] self_repair: \(String(describing: error), privacy: .public)")
        }
        reloadConfig()
        // Unchanged on a failed write: repaint the switch back to the file.
        objectWillChange.send()
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
        idleUnloadTimer?.invalidate(); idleUnloadTimer = nil
        // Latch teardown, then let the op in flight finish: every lifecycle
        // op guards on the latch, so any op still queued — or appended while
        // we drain — becomes a no-op and can't re-load the engine after we
        // free it (which would exit with a live Metal model and trip the
        // ggml-metal teardown assert).
        await residency.shutDown()
        await formatter.shutdown()
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
    ///
    /// `eventTime` is when the KEY happened, not when this runs. Everything
    /// that times a gesture uses it: delivery is an async hop to the main
    /// thread, and this thread stalls for real milliseconds opening the mic, so
    /// a hold timed by handler clocks measures the stall, not the finger.
    private func handleHotkey(_ action: HotkeyAction, _ phase: HotkeyPhase, at eventTime: TimeInterval) {
        switch (action, phase) {
        case (.dictate, .began): hotkeyPressed(mode: .dictation, at: eventTime)
        case (.dictate, .ended): hotkeyReleased(at: eventTime)
        case (.commandMode, .began): hotkeyPressed(mode: .command, at: eventTime)
        case (.commandMode, .ended): hotkeyReleased(at: eventTime)
        case (.handsFree, .fired): hotkeyDoubleTapped()
        case (.cancel, .fired): cancelActive()
        case (.pasteLast, .fired): pasteLastTranscript()
        case (.copyLast, .fired): copyLastTranscript()
        default: break
        }
    }

    /// The pipeline state as the gesture layer sees it.
    private var gesturePhase: DictationGesture.Phase {
        switch state {
        case .idle: .idle
        case .recording: .recording
        case .transcribing, .inserting: .busy
        default: .unavailable
        }
    }

    private func hotkeyPressed(mode: DictationMode = .dictation, at eventTime: TimeInterval) {
        switch DictationGesture.press(
            phase: gesturePhase, locked: isLocked, isDictateKey: mode == .dictation) {
        case .start: break
        case .finish(let trim):
            // The hands-free STOP. This press was consumed as a deliberate
            // action, so nothing about it may arm a double-tap — otherwise a
            // press moments later re-latches the mic behind his back.
            hotkey.consumePressForDoubleTap()
            finishRecording(trim: trim)
            return
        case .refuseBusy: NSSound.beep(); return
        default: return
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
        // The KEY's clock, not this handler's — see `handleHotkey`.
        recordingStartUptime = eventTime
        // Open the mic NOW — this lights the macOS mic indicator (on-demand, so
        // it's lit only while dictating). Fast because AudioEngine was prepared
        // at bring-up; the ~100ms until the built-in mic is live is hidden by
        // reaction time before the first word.
        let micOpenSeconds: Double
        do {
            micOpenSeconds = try measuredSync { try audio.startCapture() }.1
        } catch {
            log.error("mic startCapture failed: \(error.localizedDescription)")
            refuse("Microphone unavailable")
            return
        }
        // How late this handler ran, and how long the mic took to open. Both
        // are main-thread stalls that used to be charged to the hold (they no
        // longer are), and both are what a "why didn't my double-tap take"
        // report needs. Timings only.
        let lagSeconds = ProcessInfo.processInfo.systemUptime - eventTime - micOpenSeconds
        log.info("""
            press: dispatch lag \(Int(max(0, lagSeconds) * 1000), privacy: .public)ms,             mic open \(Int(micOpenSeconds * 1000), privacy: .public)ms
            """)
        state = .recording
        // beginUtterance() right after startCapture(): under mic-on-demand the
        // pre-roll is EMPTY (capture just started, nothing buffered — see
        // PreRollBuffer.beginUtterance), so the utterance is exactly the hold
        // audio.
        audio.beginUtterance()
        hud.show(.recording)
        startMaxRecordingCap()
        // Command Mode: read the selection to edit. Done AFTER recording starts
        // (it's only needed at finish) so the bounded AX IPC can't delay capture
        // or skew the tap-vs-hold timing.
        if mode == .command { capturedSelection = AXFocus.selectedText() }
    }

    private func hotkeyReleased(at eventTime: TimeInterval) {
        // Decided synchronously so the next press records cleanly. A
        // sub-threshold hold is the double-tap's arming tap: discard its audio.
        //
        // Key event to key event. Timed against this handler's own clock
        // instead, the hold picked up however long the press handler sat in
        // `startCapture` — on a USB mic, enough to push a 150ms tap past the
        // transcribe threshold. The tracker then armed a window the pipeline
        // had already spent on a doomed transcription, and the second press hit
        // a busy pipeline and beeped. That was the latch that only took when the
        // key was hammered.
        let held = eventTime - recordingStartUptime
        switch DictationGesture.release(phase: gesturePhase, locked: isLocked, heldFor: held) {
        case .finish(let trim): finishRecording(trim: trim)
        case .discard: cancelRecording()
        default: break
        }
    }

    private func hotkeyDoubleTapped() {
        // The second tap's press already started recording; this latches it.
        // From here the mic stays open until he presses the key again (or hits
        // Cancel, or the hands-free cap expires) — silence never ends it, so
        // the latch needs no VAD.
        guard DictationGesture.doubleTap(phase: gesturePhase, locked: isLocked) == .latchHandsFree
        else { return }
        isLocked = true
        hud.update(.locked(hint: handsFreeExitHint))
        startMaxRecordingCap()   // re-arm on the (much longer) hands-free cap
    }

    private func hotkeyHealthChanged(_ healthy: Bool) {
        hotkeyDead = !healthy
        // A dead tap means the stop press can no longer reach us. A HOLD is
        // already released by HotkeyManager's stuck-key reconcile; a latched
        // hands-free session has no held key to release, so land it here rather
        // than leave the mic open until the cap.
        if !healthy, state == .recording, isLocked {
            log.warning("hotkey tap died mid-hands-free — finishing the session")
            // Same staleness as the cap: he may have walked away minutes ago
            // and the frontmost app is not necessarily his. Clipboard.
            finishRecording(trim: true, delivery: .clipboard)
            return
        }
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

    /// One transient line on the HUD, for something that is not part of a
    /// dictation. It waits for a quiet moment: never while a dictation is in
    /// flight, never over a toast that is still on screen. Returns whether it
    /// was shown, so the caller can try again later instead of counting it.
    @discardableResult
    func announce(_ message: String, for seconds: TimeInterval = 6) -> Bool {
        guard !isDictating, !hud.isShowing else { return false }
        hud.show(.warning(message))
        hud.hide(after: seconds)
        return true
    }

    // MARK: - Recording lifecycle

    /// (Re)arm the safety cap for the CURRENT mode — the hold ceiling on a
    /// press, the far longer hands-free ceiling when the latch engages.
    private func startMaxRecordingCap() {
        maxRecordingTimer?.invalidate()
        let limit = isLocked ? DictationGesture.maxHandsFreeSeconds : DictationGesture.maxHoldSeconds
        maxRecordingTimer = commonTimer(interval: limit) { [weak self] in
            guard let self else { return }
            guard case .finish(let trim) = DictationGesture.durationCap(
                phase: self.gesturePhase, locked: self.isLocked) else { return }
            self.log.warning("max recording duration (\(Int(limit))s) hit — stopping")
            // A capped HOLD is a lost key-up seconds ago — he is still there,
            // so it inserts. A capped LATCH may be five minutes stale.
            self.finishRecording(trim: trim, delivery: self.isLocked ? .clipboard : .insert)
        }
    }

    private func stopTimers() {
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

    // MARK: - Finish → transcribe → insert

    private func finishRecording(trim: Bool, delivery: Delivery = .insert) {
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
            Task {
                await transcribeCommand(
                    samples, selection: selection, delivery: delivery, timings: timings)
            }
        } else {
            Task {
                await transcribeAndInsert(
                    samples, wasLocked: wasLocked, trim: trim, delivery: delivery, timings: timings)
            }
        }
    }

    private func transcribeAndInsert(
        _ samples: [Float], wasLocked: Bool, trim: Bool, delivery: Delivery, timings: StageTimings
    ) async {
        do {
            // Snapshot the dictionary/cleanup so a menu reload mid-dictation
            // can't make the substitution, the LLM allowlist, and the filler
            // pre-pass disagree.
            let dict = dictionary
            let stripper = fillerStripper
            let selfRepair = cleanupCfg.selfRepair
            let level = cleanupLevel
            let register = capturedCategory
            let verbatimRegister = isVerbatimRegister(register)
            // Formatter-stage inputs, read in prepareFormatter — after the
            // strip, right before the measured format — the same instant the
            // pre-extraction inline code read them.
            var raw = false
            var resolveCorr = false
            var style = ""
            // The shared samples → final-text path (trim → ASR → dictionary
            // ONCE → Auto-Clean gating → formatter) lives in DictationPipeline
            // so the gating rules can never drift from iOS. nil = ASR produced
            // no text.
            guard let outcome = try await pipeline.run(
                samples,
                trim: trim ? { await self.vad.trim($0) } : nil,
                dictionary: dict, stripper: stripper,
                level: level, verbatimRegister: verbatimRegister,
                register: register, language: dictationLanguage,
                selfRepair: selfRepair,
                timings: timings,
                prepareFormatter: {
                    raw = self.rulesOnly
                    // Self-correction: level=standard on a non-verbatim register.
                    // The LLM path handles it; format() also uses this to keep a
                    // short correction off the fast path (§5c).
                    resolveCorr = level == .standard && !verbatimRegister
                    style = self.effectiveStyleDirective(
                        dictionary: dict, resolveCorrections: resolveCorr)
                    // Reload the model first if it was unloaded to save idle
                    // memory (~1–2s, only after a long idle gap, only on the LLM
                    // path) — outside the measured format stage, so formatMs
                    // never absorbs a reload. In rules-only it is never loaded.
                    if RulesOnlyMode.dictationNeedsModel(rulesOnly: raw, level: level) {
                        await self.ensureLLMLoaded()
                    }
                },
                formatInput: { input in
                    // Stage 2: LLM auto-edit (or rule-based fast path / raw
                    // fallback). Formatter.format never throws — a dictation
                    // always lands. The 150-word ceiling counts the dictation
                    // before the self-repair rules (`ceilingWords`).
                    await self.formatter.format(
                        input.text, rawMode: raw, styleDirective: style,
                        preserveCasingFor: dict.lowercasedTargets,
                        resolveCorrections: resolveCorr,
                        language: self.dictationLanguage, ceilingWords: input.ceilingWords)
                })
            else {
                state = .idle
                hud.hide()
                return
            }
            var timings = outcome.timings
            let text = outcome.text

            // He hit Cancel while we were transcribing/formatting. Checked
            // BEFORE every delivery: a cancel discards the dictation, so it
            // must not reach the cursor, the clipboard, or history.
            if pendingCancel {
                pendingCancel = false
                state = .idle
                hud.hide()
                return
            }
            // A capped hands-free session never types itself into whatever app
            // is frontmost now — it lands on the clipboard, in history, and in
            // "paste last", and the HUD says where it went.
            if delivery == .clipboard {
                deliverToClipboard(outcome, timings: timings)
                return
            }
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
            let historyRaw = outcome.verbatimText   // history "raw" = what was said (dictionary-only)
            let historyBundleId = capturedBundleId
            let historyAppName = capturedAppName
            // Utterance length (transcribed audio) + language, for dashboard WPM/stats.
            let historyDurationMs = Self.ms(
                Double(outcome.transcribedSampleCount) / AudioEngine.targetSampleRate)
            let historyLanguage = dictationLanguage.code
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
                self.onDictationFinished?()
                // Persist to history OFF the insertion path — a detached Task
                // so the DB write never blocks the dictation completing. Skipped
                // entirely when the user disabled history.
                if self.historyEnabled {
                    let record = HistoryRecord(
                        createdAt: Date(), appBundleId: historyBundleId, appName: historyAppName,
                        rawText: historyRaw, formattedText: text,
                        audioMs: Self.ms(timings.audioFinalizeSeconds), asrMs: Self.ms(timings.asrSeconds),
                        formatMs: Self.ms(timings.formatSeconds), insertMs: Self.ms(timings.insertSeconds),
                        totalMs: Self.ms(timings.totalSeconds),
                        durationMs: historyDurationMs, language: historyLanguage)
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

    /// Land a dictation on the clipboard instead of at the cursor (the capped
    /// hands-free path). Same bookkeeping as an insertion — `lastTranscript`,
    /// the raw form, history — minus the keystrokes.
    private func deliverToClipboard(_ outcome: DictationPipeline.Outcome, timings: StageTimings) {
        deliverToClipboard(
            outcome.text, verbatim: outcome.verbatimText,
            durationMs: Self.ms(Double(outcome.transcribedSampleCount) / AudioEngine.targetSampleRate),
            timings: timings)
    }

    private func deliverToClipboard(
        _ text: String, verbatim: String, durationMs: Int?, timings: StageTimings
    ) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastTranscript = text
        lastRawTranscript = verbatim
        lastTimings = timings.description
        log.info("capped hands-free → clipboard: \(text, privacy: .private) [\(timings.description)]")
        state = .idle
        hud.show(.warning("Hands-free capped — copied, ⌘V to paste"))
        hud.hide(after: 4)
        armIdleUnloadTimer()
        onDictationFinished?()
        saveHistory(text: text, verbatim: verbatim, durationMs: durationMs, timings: timings)
    }

    /// Persist a finished dictation OFF the insertion path — a detached Task so
    /// the DB write never blocks the dictation completing. Skipped entirely
    /// when he turned history off.
    private func saveHistory(
        text: String, verbatim: String, durationMs: Int?, timings: StageTimings
    ) {
        guard historyEnabled else { return }
        let record = HistoryRecord(
            createdAt: Date(), appBundleId: capturedBundleId, appName: capturedAppName,
            rawText: verbatim, formattedText: text,
            audioMs: Self.ms(timings.audioFinalizeSeconds), asrMs: Self.ms(timings.asrSeconds),
            formatMs: Self.ms(timings.formatSeconds), insertMs: Self.ms(timings.insertSeconds),
            totalMs: Self.ms(timings.totalSeconds),
            durationMs: durationMs, language: dictationLanguage.code)
        Task.detached { await HistoryStore.shared?.save(record) }
    }

    // MARK: - Command Mode + quick actions (task: hotkeys)

    /// Transcribe the spoken instruction and voice-edit the captured selection
    /// via the LLM, then paste the result (which replaces the selection). With
    /// no selection, the spoken words are a dictation and take a dictation's
    /// text path. `RulesOnlyMode.command` decides what each does with the
    /// model.
    private func transcribeCommand(
        _ samples: [Float], selection: String?, delivery: Delivery, timings: StageTimings
    ) async {
        var timings = timings
        do {
            let dict = dictionary
            let (result, asrSeconds) = try await measured { try await asr.transcribe(samples) }
            timings.asrSeconds = asrSeconds
            let instruction = dict.apply(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !instruction.isEmpty else { state = .idle; hud.hide(); return }

            let output: String
            let historyRaw: String
            let plan = RulesOnlyMode.command(hasSelection: !(selection ?? "").isEmpty, rulesOnly: rulesOnly)
            if plan != .dictation, let selection {
                guard llmAvailable else {
                    state = .idle
                    refuse("Command mode needs the formatting model")
                    return
                }
                // Loaded on demand (rules-only keeps it out of memory)…
                await ensureLLMLoaded()
                let (edited, fmtSeconds) = await measured {
                    await formatter.command(instruction: instruction, selection: selection,
                                            language: dictationLanguage)
                }
                timings.formatSeconds = fmtSeconds
                // …and in rules-only freed again once this edit has landed
                // (the unload waits for idle), so one command does not leave
                // ~1 GB resident for the rest of the session.
                if plan == .editThenUnload { unloadLLMForRulesOnly() }
                guard let edited, !edited.isEmpty else {
                    state = .idle
                    refuse("Couldn't apply that edit")
                    return
                }
                output = edited
                historyRaw = selection
            } else {
                // No selection: the spoken words are a dictation — the same
                // text path (self-repair, filler strip, spoken layout, the
                // formatter stage, finishing) at his level and register. The
                // model is loaded only if a dictation would load it.
                let stripper = fillerStripper
                let selfRepair = cleanupCfg.selfRepair
                let level = cleanupLevel
                let register = capturedCategory
                let verbatimRegister = isVerbatimRegister(register)
                var raw = false
                var resolveCorr = false
                var style = ""
                let (formatted, fmtSeconds) = await DictationPipeline.finish(
                    instruction, dictionary: dict, stripper: stripper, level: level,
                    verbatimRegister: verbatimRegister, register: register, language: dictationLanguage,
                    selfRepair: selfRepair,
                    prepareFormatter: {
                        raw = self.rulesOnly
                        resolveCorr = level == .standard && !verbatimRegister
                        style = self.effectiveStyleDirective(dictionary: dict, resolveCorrections: resolveCorr)
                        if RulesOnlyMode.dictationNeedsModel(rulesOnly: raw, level: level) {
                            await self.ensureLLMLoaded()
                        }
                    },
                    formatInput: { input in
                        await self.formatter.format(
                            input.text, rawMode: raw, styleDirective: style,
                            preserveCasingFor: dict.lowercasedTargets,
                            resolveCorrections: resolveCorr,
                            language: self.dictationLanguage, ceilingWords: input.ceilingWords)
                    })
                timings.formatSeconds = fmtSeconds
                output = formatted
                historyRaw = instruction
            }

            if pendingCancel { pendingCancel = false; state = .idle; hud.hide(); return }
            // A capped session doesn't paste over his selection either — five
            // minutes on, that selection may not even exist any more.
            if delivery == .clipboard {
                deliverToClipboard(output, verbatim: historyRaw, durationMs: nil, timings: timings)
                return
            }
            if SecureInput.shouldRefuse { refuse("Won't insert into a secure field"); state = .idle; return }
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
            self.onDictationFinished?()
            if self.historyEnabled {
                let record = HistoryRecord(
                    createdAt: Date(), appBundleId: bundleId, appName: appName,
                    rawText: historyRaw, formattedText: text,
                    audioMs: Self.ms(timings.audioFinalizeSeconds), asrMs: Self.ms(timings.asrSeconds),
                    formatMs: Self.ms(timings.formatSeconds), insertMs: Self.ms(timings.insertSeconds),
                    totalMs: Self.ms(timings.totalSeconds),
                    durationMs: nil, language: self.dictationLanguage.code)   // command edits: no spoken-WPM
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
            // Same reasoning as the stop press: this key press was consumed as
            // a deliberate action, so nothing about it arms a double-tap.
            hotkey.consumePressForDoubleTap()
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

    /// Copy the last transcript to the clipboard. Idle-only, like `pasteLast`:
    /// mid-dictation it would replace the live HUD with a toast and leave a
    /// latched mic with nothing on screen.
    private func copyLastTranscript() {
        guard state == .idle, !lastTranscript.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        hud.show(.refused("Copied last transcript")); hud.hide(after: 1)
    }

    /// Apply a rebound hotkey config live (Settings recorder).
    func reloadHotkeys(_ config: HotkeyConfig) {
        hotkey.reload(config)
        dictateKeyLabel = Self.keyLabel(.dictate, in: config)
        cancelKeyLabel = Self.keyLabel(.cancel, in: config)
        // A session latched right now is showing the OLD key — repaint it, so
        // the way out on screen is the key that actually ends it.
        if isHandsFree { hud.update(.locked(hint: handsFreeExitHint)) }
    }

    /// An action's key label, or nil when nothing is bound to it.
    static func keyLabel(_ action: HotkeyAction, in config: HotkeyConfig) -> String? {
        config.bindings(for: action).first?.displayString
    }
}

// MARK: - The model's host

/// What `ModelResidency` reads and calls: the state each op checks when it
/// runs (not when it was queued), the engine, and what a load or an unload
/// changes here.
extension PipelineController: ModelResidencyHost {
    var modelIsIdle: Bool { state == .idle }
    var modelIsInstalled: Bool { llmModel.isInstalled }
    var modelIsAvailable: Bool { llmAvailable }

    func loadModel() async throws { try await formatter.load() }
    func unloadModel() async { await engine.unload() }

    func modelDidLoad(failure: Error?) {
        if let failure {
            llmAvailable = false
            llmLoadFailed = true
            log.warning("model load failed, using raw cleanup: \(failure.localizedDescription)")
            return
        }
        llmAvailable = true
        llmLoadFailed = false
        // Restart the idle countdown: this reload may be the dictation's
        // last action (e.g. it ends on the secure-field refuse path, which
        // doesn't re-arm), and the one-shot timer that unloaded us is
        // already spent — without this the model would stay resident.
        armIdleUnloadTimer()
        log.info("loaded LLM on demand")
    }

    func modelDidUnloadForRulesOnly() {
        idleUnloadTimer?.invalidate(); idleUnloadTimer = nil
        log.info("rules only: unloaded the formatting model (frees ~1GB; Command Mode loads it on demand)")
    }
}
