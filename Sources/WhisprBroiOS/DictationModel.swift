import AVFoundation
import Combine
import Foundation
import os.log
import UIKit
import WhisprBroCore

/// The iOS in-app dictation pipeline (issue #13 phase i1): tap → mic → (VAD
/// trim) → ASR → dictionary → filler strip → rule-based cleanup → pasteboard +
/// history. The macOS state machine minus hotkeys, insertion, and the LLM —
/// Apple Foundation Models formatting lands in phase i4, so cleanup here is
/// deterministic only. Mic-on-demand semantics are identical to macOS: the
/// audio session activates in `startCapture()` and deactivates at stop, so the
/// iOS mic indicator is lit only while a dictation is in progress.
@MainActor
final class DictationModel: ObservableObject {
    enum State: Equatable {
        case needsPermission
        case modelsMissing
        case loading
        case idle
        case recording
        case transcribing
        case error(String)

        #if DEBUG
        /// Stable, machine-greppable label for the `--dictate-file` smoke
        /// output (`SMOKE: state=<label>` lines).
        var smokeLabel: String {
            switch self {
            case .needsPermission: return "needsPermission"
            case .modelsMissing: return "modelsMissing"
            case .loading: return "loading"
            case .idle: return "idle"
            case .recording: return "recording"
            case .transcribing: return "transcribing"
            case .error(let message): return "error(\(message))"
            }
        }
        #endif
    }

    /// Safety cap so a forgotten recording can't run forever.
    private static let maxRecordingSeconds: TimeInterval = 90

    @Published private(set) var state: State = .needsPermission {
        didSet {
            #if DEBUG
            if Self.smokeArmed { print("SMOKE: state=\(state.smokeLabel)") }
            #endif
        }
    }
    @Published private(set) var lastTranscript: String = ""
    /// Verbatim (dictionary-only) form of the last dictation.
    @Published private(set) var lastRawTranscript: String = ""
    @Published private(set) var lastTimings: String = ""
    /// Most recent mic RMS (0…~0.3), polled while recording for the level ring.
    @Published private(set) var level: Float = 0

    /// Persist each dictation to the local history (same key as macOS).
    @Published var historyEnabled = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: "historyEnabled") }
    }
    /// Auto-Clean level — same UserDefaults key as the macOS menu control, so a
    /// future synced-settings story has one source of truth per platform.
    @Published var cleanupLevel: AppConfig.Cleanup.Level = {
        if let raw = UserDefaults.standard.string(forKey: "cleanupLevel"),
           let lvl = AppConfig.Cleanup.Level(rawValue: raw) { return lvl }
        return .fillers
    }() {
        didSet { UserDefaults.standard.set(cleanupLevel.rawValue, forKey: "cleanupLevel") }
    }

    /// Selected dictation language (English default). Chosen at launch;
    /// changing it applies on next launch (the ASR engine is built once).
    let dictationLanguage = DictationLanguage.selected

    private let audio = AudioEngine()
    private let asr: AsrEngine
    private let vad: VadGate
    /// The shared post-capture text pipeline (trim → ASR → dictionary →
    /// Auto-Clean gating → formatter) — core-owned so the gating rules can
    /// never drift from macOS.
    private let pipeline: DictationPipeline
    private var dictionary = DictionaryEngine(rules: [])
    private var fillerStripper = FillerStripper()
    private let modelDir: URL
    private let log = Logger(subsystem: "com.micaxes.whispr-bro.ios", category: "pipeline")

    private var levelTimer: Timer?
    private var maxRecordingTimer: Timer?
    private var isBringingUp = false
    private var vadAvailable = false
    private var errorGeneration = 0
    #if DEBUG
    private var smokeFileURL = DictationModel.smokeArgument()
    #endif

    init() {
        // Bundled models win (make-ios-app.sh release stages Models/ into the
        // app bundle) so a release build never depends on sandbox state; dev
        // builds fall back to the Application Support dir (Paths).
        let folder = ParakeetEngine.folderName(for: dictationLanguage.parakeetVersion)
        let modelsDir = Self.installLocation(of: folder) ?? Paths.modelsDir
        modelDir = modelsDir.appendingPathComponent(folder, isDirectory: true)
        #if DEBUG
        // A/B hook (`--asr system`): Apple SpeechTranscriber instead of
        // Parakeet, DEBUG builds only — release always ships Parakeet.
        if Self.debugSystemAsr {
            asr = SpeechTranscriberEngine(language: dictationLanguage)
        } else {
            asr = ParakeetEngine(modelsDir: modelsDir, version: dictationLanguage.parakeetVersion)
        }
        #else
        asr = ParakeetEngine(modelsDir: modelsDir, version: dictationLanguage.parakeetVersion)
        #endif
        pipeline = DictationPipeline(asr: asr)
        let vadRelative = "silero-vad/\(Paths.vadModelFile.lastPathComponent)"
        let vadDir = Self.installLocation(of: vadRelative) ?? Paths.modelsDir
        vad = VadGate(modelFile: vadDir.appendingPathComponent(vadRelative, isDirectory: true))
    }

    /// The bundled `Models/` dir if it contains `relativePath`, else the
    /// on-disk models dir if that does, else nil (not installed).
    private static func installLocation(of relativePath: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true),
            Paths.modelsDir,
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(relativePath).path)
        }
    }

    /// Whether a Parakeet version is present (bundle or on-disk) — gates the
    /// Italian/Spanish rows in Settings the way `LlmModelSpec.isInstalled`
    /// gates presets on macOS.
    static func isInstalled(_ version: ParakeetEngine.Version) -> Bool {
        installLocation(of: ParakeetEngine.folderName(for: version)) != nil
    }

    // MARK: - Bring-up

    func startup() {
        ConfigStore.ensureDefault()
        applyConfig(ConfigStore.load())
        // Open the history DB off-main so the first History-tab access doesn't
        // run the SQLite open + migration on the main thread.
        Task.detached { HistoryStore.prewarm() }
        Task {
            await bringUp()
            #if DEBUG
            await runSmokeDictationIfRequested()
            #endif
        }
    }

    private func bringUp() async {
        guard !isBringingUp else { return }
        isBringingUp = true
        defer { isBringingUp = false }

        guard Permissions.microphone else {
            state = .needsPermission
            return
        }
        // The system engine's model is an OS asset — the Parakeet folder
        // check must not gate it (asr.load() reports its own availability).
        #if DEBUG
        let needsLocalModels = !Self.debugSystemAsr
        #else
        let needsLocalModels = true
        #endif
        guard !needsLocalModels || FileManager.default.fileExists(atPath: modelDir.path) else {
            state = .modelsMissing
            return
        }

        do {
            state = .loading
            try await asr.load()
            // VAD is optional: without it, trim is disabled but tap-to-talk
            // still works.
            do {
                try await vad.load()
                vadAvailable = true
            } catch {
                vadAvailable = false
                log.warning("VAD unavailable, continuing without it: \(error.localizedDescription)")
            }
            // Prepare the capture graph WITHOUT activating the session: the
            // mic indicator lights only while a dictation is in progress (see
            // AudioEngine "prepare-ahead").
            try audio.prepare()
            state = .idle
            log.info("pipeline up: audio prepared (mic opens on dictation), models loaded (vad: \(self.vadAvailable))")
        } catch WhisprError.modelsNotFound {
            state = .modelsMissing
        } catch {
            errorGeneration += 1
            state = .error(error.localizedDescription)
            log.error("bring-up failed: \(error.localizedDescription)")
        }
    }

    /// True once the user has explicitly denied mic access (re-requesting is a
    /// no-op then — the only fix is the Settings app).
    var microphoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    func requestMicrophone() {
        Task {
            _ = await Permissions.requestMicrophone()
            await bringUp()
        }
    }

    func retry() { Task { await bringUp() } }

    // MARK: - Record (tap to start / tap to stop)

    func toggleRecording() {
        switch state {
        case .idle: startRecording()
        case .recording: finishRecording()
        case .needsPermission: requestMicrophone()
        case .error: retry()
        default: break
        }
    }

    private func startRecording() {
        // Activate the session + start the IOProc NOW — this lights the iOS
        // mic indicator (on-demand, so it's lit only while recording). Fast
        // because the graph was prepared at bring-up.
        do {
            try audio.startCapture()
        } catch {
            log.error("mic startCapture failed: \(error.localizedDescription)")
            errorGeneration += 1
            state = .error("Microphone unavailable")
            return
        }
        state = .recording
        // beginUtterance() right after startCapture(): under mic-on-demand the
        // pre-roll is EMPTY (capture just started, nothing buffered — see
        // PreRollBuffer.beginUtterance), so the utterance is exactly the tap-
        // to-tap audio. The pre-roll becomes live only in a future session
        // mode where capture already runs.
        audio.beginUtterance()
        startLevelPoll()
        startMaxRecordingCap()
    }

    private func finishRecording() {
        stopTimers()
        var timings = StageTimings()
        let (samples, finalizeSeconds) = measuredSync { audio.endUtterance() }
        timings.audioFinalizeSeconds = finalizeSeconds
        // Utterance audio is in hand — deactivate the session so the mic
        // indicator clears immediately at end-of-speech, while ASR runs.
        audio.stopCapture()
        level = 0

        guard samples.count >= asr.minimumSamples else {
            state = .idle
            return
        }
        state = .transcribing
        Task { await transcribe(samples, timings: timings) }
    }

    private func stopTimers() {
        levelTimer?.invalidate(); levelTimer = nil
        maxRecordingTimer?.invalidate(); maxRecordingTimer = nil
    }

    private func startLevelPoll() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.level = self.audio.lastRMS
            }
        }
    }

    private func startMaxRecordingCap() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.maxRecordingSeconds, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.log.warning("max recording duration hit — stopping")
                self.finishRecording()
            }
        }
    }

    // MARK: - Transcribe → clean → pasteboard + history

    /// The one post-capture pipeline — the shared `DictationPipeline` (VAD
    /// trim → ASR → dictionary ONCE → Auto-Clean gating) with rule-based
    /// cleanup as the injected formatter stage (no LLM until phase i4) —
    /// publishing to the UI + pasteboard and persisting history. Shared by
    /// the mic stop path and the DEBUG `--dictate-file` smoke hook so a
    /// file-driven run proves the exact stages a live dictation uses.
    /// Returns nil when ASR produced no text.
    private func runPipeline(
        _ samples: [Float], timings: StageTimings
    ) async throws -> (rawText: String, text: String, timings: StageTimings)? {
        // Snapshot so a config reload mid-dictation can't make the
        // substitution and the filler pre-pass disagree.
        let dict = dictionary
        guard let outcome = try await pipeline.run(
            samples,
            trim: vadAvailable ? { await self.vad.trim($0) } : nil,
            dictionary: dict, stripper: fillerStripper,
            level: cleanupLevel, verbatimRegister: false,
            timings: timings,
            format: {
                TextFormatter.ruleBasedCleanup($0, preserveCasingFor: dict.lowercasedTargets)
            })
        else {
            state = .idle
            return nil
        }
        let text = outcome.text
        let verbatimText = outcome.verbatimText
        let timings = outcome.timings

        UIPasteboard.general.string = text
        lastTranscript = text
        lastRawTranscript = verbatimText
        lastTimings = timings.description
        state = .idle
        log.info("dictation: \"\(text, privacy: .private)\" [\(timings.description)]")

        // Persist to history OFF the hot path — a detached Task so the DB
        // write never blocks the dictation completing.
        if historyEnabled {
            let record = HistoryRecord(
                createdAt: Date(), appBundleId: nil, appName: nil,
                rawText: verbatimText, formattedText: text,
                audioMs: Self.ms(timings.audioFinalizeSeconds), asrMs: Self.ms(timings.asrSeconds),
                formatMs: Self.ms(timings.formatSeconds), insertMs: nil,
                totalMs: Self.ms(timings.totalSeconds),
                durationMs: Self.ms(
                    Double(outcome.transcribedSampleCount) / AudioEngine.targetSampleRate),
                language: dictationLanguage.code)
            Task.detached { await HistoryStore.shared?.save(record) }
        }
        return (rawText: verbatimText, text: text, timings: timings)
    }

    private func transcribe(_ samples: [Float], timings: StageTimings) async {
        do {
            _ = try await runPipeline(samples, timings: timings)
        } catch {
            errorGeneration += 1
            let generation = errorGeneration
            state = .error(error.localizedDescription)
            log.error("dictation failed: \(error.localizedDescription)")
            try? await Task.sleep(for: .seconds(3))
            if case .error = state, errorGeneration == generation { state = .idle }
        }
    }

    private static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    /// Rebuild the dictionary + filler pre-pass from `config` (spec §4 Config
    /// mirror). Style rules and category overrides are macOS-only (they exist
    /// to steer the per-app LLM register, which iOS doesn't have yet).
    private func applyConfig(_ config: AppConfig) {
        dictionary = DictionaryEngine(rules: config.dictionaryRules)
        fillerStripper = FillerStripper(
            core: FillerStripper.coreFillers(for: dictationLanguage),
            extra: config.cleanup.extraFillers,
            disabled: config.cleanup.disabledFillers,
            collapseStutters: config.cleanup.collapseStutters)
    }

    #if DEBUG
    // MARK: - Smoke test (--dictate-file, DEBUG builds only)

    /// True for the whole process when launched with `--dictate-file` — gates
    /// the `SMOKE: state=` transition prints in `state.didSet`. Without the
    /// argument every smoke hook is a no-op, so normal behavior is unchanged.
    private static let smokeArmed = CommandLine.arguments.contains("--dictate-file")

    /// `--asr system|parakeet` (default parakeet): the engine A/B selector,
    /// picked up alongside `--dictate-file`. Any value other than `system`
    /// (including a missing one) keeps Parakeet, so a typo can't silently
    /// change what a smoke run measured.
    private static let debugSystemAsr: Bool = {
        guard let flag = CommandLine.arguments.firstIndex(of: "--asr"),
              CommandLine.arguments.indices.contains(flag + 1)
        else { return false }
        return CommandLine.arguments[flag + 1] == "system"
    }()

    /// The path following `--dictate-file`, or nil. Consumed by the first
    /// bring-up completion so a re-appearing scene can't re-run the smoke.
    private static func smokeArgument() -> URL? {
        guard let flag = CommandLine.arguments.firstIndex(of: "--dictate-file"),
              CommandLine.arguments.indices.contains(flag + 1)
        else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    }

    /// Simulator smoke hook: runs the file through the EXACT mic pipeline
    /// (`runPipeline`: VAD trim → ASR → dictionary → filler strip →
    /// rule-based cleanup), publishing to the UI and history like a real
    /// dictation, and prints machine-greppable `SMOKE:` lines. Never records —
    /// the audio session is untouched. Requires bring-up to have reached
    /// `.idle` (mic permission granted + models installed).
    private func runSmokeDictationIfRequested() async {
        guard let url = smokeFileURL else { return }
        smokeFileURL = nil
        let engineName = Self.debugSystemAsr ? "system" : "parakeet"
        print("SMOKE: engine=\(engineName)")
        NSLog("SMOKE: engine=%@", engineName)
        if state != .idle, Self.debugSystemAsr, let engine = asr as? SpeechTranscriberEngine {
            await smokeInstallSystemAssets(engine)
        }
        guard state == .idle else {
            smokeFail("bring-up ended in state \(state.smokeLabel), not idle "
                + "(grant mic permission via `simctl privacy` / install models first)")
            return
        }
        let samples: [Float]
        do {
            samples = try AudioFileLoader.loadSamples16k(url)
        } catch {
            smokeFail("cannot load \(url.path): \(error.localizedDescription)")
            return
        }
        guard samples.count >= asr.minimumSamples else {
            smokeFail("file too short: \(samples.count) samples < \(asr.minimumSamples) minimum")
            return
        }
        state = .transcribing
        do {
            guard let outcome = try await runPipeline(samples, timings: StageTimings()) else {
                smokeFail("empty transcript")
                return
            }
            let asrMs = Self.ms(outcome.timings.asrSeconds)
            let totalMs = Self.ms(outcome.timings.totalSeconds)
            print("SMOKE: raw=\(outcome.rawText)")
            print("SMOKE: transcript=\(outcome.text)")
            print("SMOKE: timings asr_ms=\(asrMs) total_ms=\(totalMs)")
            print("SMOKE: DONE")
            NSLog("SMOKE: DONE transcript=\"%@\" asr_ms=%d total_ms=%d",
                  outcome.text, asrMs, totalMs)
        } catch {
            state = .idle
            smokeFail(error.localizedDescription)
        }
    }

    /// System-ASR smoke only: bring-up failed, so surface the EXACT asset
    /// availability (the honest A/B finding when the simulator refuses), and
    /// — standing in for the deliberate Settings-UI action that
    /// `requestAssetInstallation` requires — ask the OS to install, then
    /// retry bring-up. Never runs for Parakeet, never in release builds.
    private func smokeInstallSystemAssets(_ engine: SpeechTranscriberEngine) async {
        let availability = await engine.assetAvailability()
        print("SMOKE: system-asr availability=\(availability.rawValue)")
        NSLog("SMOKE: system-asr availability=%@", availability.rawValue)
        guard availability == .downloadable || availability == .downloading else { return }
        print("SMOKE: requesting OS-mediated speech asset install")
        do {
            try await engine.requestAssetInstallation()
            await bringUp()
        } catch {
            print("SMOKE: asset install failed: \(error.localizedDescription)")
            NSLog("SMOKE: asset install failed: %@", error.localizedDescription)
        }
    }

    /// Failure line on stdout AND os_log — simulator stdout capture can drop
    /// lines; `NSLog` survives in `log stream`/`simctl spawn booted log`.
    private func smokeFail(_ reason: String) {
        print("SMOKE: FAIL reason=\(reason)")
        NSLog("SMOKE: FAIL reason=%@", reason)
    }
    #endif
}
