#if DEBUG || SPIKE
import Foundation
import os
import SwiftUI
import UIKit
import WhisprBroCore

/// Launch-time gate for the spike root (see WhisprBroiOSApp): the `--spike`
/// argument (simulator, or on device via `xcrun devicectl device process
/// launch <bundle-id> --spike` — no debugger attached) or the `spikeMode`
/// default armed by opening whisprbro://spike (a Springboard launch carries
/// no arguments, so the release gate build needs a no-terminal entry path).
enum SpikeMode {
    static let active = CommandLine.arguments.contains("--spike")
        || UserDefaults.standard.bool(forKey: "spikeMode")

    static func arm() { UserDefaults.standard.set(true, forKey: "spikeMode") }
    static func disarm() { UserDefaults.standard.set(false, forKey: "spikeMode") }
}

/// The P1 kill-switch gate driver (issue #13 review amendment 1): the port
/// lives or dies on backgrounded INFERENCE — segment end → ASR → format while
/// backgrounded/locked under jetsam pressure — not on background capture. This
/// screen runs N (default 30) full-pipeline dictations (VAD trim → Parakeet →
/// dictionary → filler strip → rule-based cleanup, the exact `runPipeline`
/// stages) against one fixed fixture, logging per run what the gate needs:
/// `os_proc_available_memory` headroom, `ProcessInfo.thermalState`, Low Power
/// Mode, app state, stage timings, success/fail — as UI rows, `SPIKE:` print
/// markers, `p1-spike` os_signposts, and a report persisted to Caches after
/// every run so a jetsam kill leaves evidence for the relaunch.
///
/// Gate protocol (issue #13 three-way review, amendment 1):
///  1. RELEASE build, NO debugger. This screen is compiled under
///     `DEBUG || SPIKE`, so the gate build archives with
///     `SWIFT_ACTIVE_COMPILATION_CONDITIONS=SPIKE`.
///  2. Low Power Mode ON, device warm from a few minutes of use.
///  3. Enter spike mode, load or record a fixture, keep "Hold mic open" ON
///     (active audio I/O is the background keepalive), start the loop, then
///     LOCK THE SCREEN / background the app for the whole run.
///  4. GO = 30 consecutive successes with memory headroom (min available
///     memory comfortably above the working set). Any jetsam kill, failed
///     run, or headroom collapse = NO-GO.
///
/// The spike owns its own AudioEngine/ASR/VAD stack: spike mode replaces the
/// normal root at launch, so the app's `DictationModel` never loads a second
/// Parakeet instance that would poison the headroom numbers.
struct SpikeView: View {
    @StateObject private var runner = SpikeRunner()

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                fixtureSection
                loopSection
                resultsSection
                exportSection
            }
            .navigationTitle("P1 spike")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await runner.setUp() }
    }

    private var statusSection: some View {
        Section("Stack") {
            LabeledContent("Setup", value: runner.setupLabel)
            LabeledContent("Language", value: runner.languageCode)
            if !Permissions.microphone {
                Button("Allow microphone (needed for hold-open + recording)") {
                    Task { _ = await Permissions.requestMicrophone() }
                }
            }
        }
    }

    private var fixtureSection: some View {
        Section {
            LabeledContent("Fixture", value: runner.fixtureLabel)
            if runner.recordingFixture {
                Button("Stop fixture recording") { runner.endFixtureRecording() }
                    .foregroundStyle(.red)
            } else {
                Button("Record fixture (speak a sentence)") {
                    runner.beginFixtureRecording()
                }
                .disabled(!runner.ready || runner.running)
            }
        } footer: {
            Text("Also loads from a `--spike-file <path>` launch argument or a "
                + "bundled Models/spike-fixture.wav (drop one into ios/Models "
                + "before scripts/make-ios-app.sh release).")
        }
    }

    private var loopSection: some View {
        Section("Loop") {
            Stepper("Runs: \(runner.runCount)", value: $runner.runCount, in: 1...100)
                .disabled(runner.running)
            Toggle("Hold mic open (background keepalive)", isOn: $runner.holdMicOpen)
                .disabled(runner.running)
            Toggle("Reload ASR each run (cold-resume fidelity)", isOn: $runner.reloadAsrEachRun)
                .disabled(runner.running)
            if runner.running {
                Button("Cancel (run \(runner.currentRun)/\(runner.runCount))") {
                    runner.cancel()
                }
                .foregroundStyle(.red)
            } else {
                Button("Run \(runner.runCount) dictations") { runner.startLoop() }
                    .disabled(!runner.ready || runner.fixture == nil)
            }
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            Text(runner.verdictLine)
                .font(Brand.mono(12, .semibold))
            if let previous = runner.previousReport, runner.results.isEmpty {
                DisclosureGroup("Last session (persisted before relaunch)") {
                    Text(previous)
                        .font(Brand.mono(10))
                        .textSelection(.enabled)
                }
            }
            ForEach(runner.results.reversed()) { result in
                Text(result.line)
                    .font(Brand.mono(10))
                    .foregroundStyle(result.ok ? Color.primary : Color.red)
            }
        }
    }

    private var exportSection: some View {
        Section {
            ShareLink(item: runner.reportText) {
                Label("Export report", systemImage: "square.and.arrow.up")
            }
            .disabled(runner.results.isEmpty && runner.previousReport == nil)
            Button("Exit spike mode (takes effect on relaunch)") {
                SpikeMode.disarm()
            }
        }
    }
}

/// One spike run's row — everything the gate verdict needs, one line.
struct SpikeRunResult: Identifiable {
    let index: Int
    let ok: Bool
    let detail: String
    let asrMs: Int
    let formatMs: Int
    let totalMs: Int
    /// `os_proc_available_memory` in MB; 0 on the simulator (no limit) — the
    /// verdict reports headroom as n/a there.
    let availableBeforeMB: Int
    let availableAfterMB: Int
    let thermal: String
    let lowPower: Bool
    let background: Bool

    var id: Int { index }

    var line: String {
        let mem = availableBeforeMB > 0 || availableAfterMB > 0
            ? "mem \(availableBeforeMB)→\(availableAfterMB)MB" : "mem n/a"
        return String(
            format: "%02d %@ asr %dms fmt %dms total %dms · %@ · %@%@%@ · %@",
            index, ok ? "ok " : "FAIL", asrMs, formatMs, totalMs, mem, thermal,
            lowPower ? " lpm" : "", background ? " bg" : " fg", detail)
    }
}

@MainActor
final class SpikeRunner: ObservableObject {
    enum SetupState {
        case pending
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var setupState: SetupState = .pending
    @Published private(set) var fixture: [Float]?
    @Published private(set) var fixtureLabel = "none"
    @Published private(set) var recordingFixture = false
    @Published private(set) var results: [SpikeRunResult] = []
    @Published private(set) var running = false
    @Published private(set) var currentRun = 0
    @Published var runCount = 30
    @Published var holdMicOpen = true
    @Published var reloadAsrEachRun = false

    /// Report persisted by the previous spike session, if any — the evidence
    /// trail when a run was jetsam-killed mid-loop.
    let previousReport: String?

    let languageCode: String

    private let audio = AudioEngine()
    private var asr: AsrEngine
    private var pipeline: DictationPipeline
    private let vad: VadGate
    private var vadAvailable = false
    private var dictionary = DictionaryEngine(rules: [])
    private var stripper = FillerStripper()
    private let modelsDir: URL
    private let modelDir: URL
    private let language = DictationLanguage.selected
    private var loopTask: Task<Void, Never>?
    private static let signposter = OSSignposter(
        subsystem: "com.micaxes.whispr-bro.ios", category: "p1-spike")
    private static let reportURL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("spike-report.txt")

    init() {
        languageCode = language.code
        // Same install resolution as DictationModel: bundled Models/ wins,
        // Application Support fallback for dev builds.
        let folder = ParakeetEngine.folderName(for: language.parakeetVersion)
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models", isDirectory: true)
        let candidates = [bundled, Paths.modelsDir].compactMap { $0 }
        modelsDir = candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(folder).path)
        } ?? Paths.modelsDir
        modelDir = modelsDir.appendingPathComponent(folder, isDirectory: true)
        asr = ParakeetEngine(modelsDir: modelsDir, version: language.parakeetVersion)
        pipeline = DictationPipeline(asr: asr)
        let vadRelative = "silero-vad/\(Paths.vadModelFile.lastPathComponent)"
        let vadDir = candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(vadRelative).path)
        } ?? Paths.modelsDir
        vad = VadGate(modelFile: vadDir.appendingPathComponent(vadRelative, isDirectory: true))
        previousReport = try? String(contentsOf: Self.reportURL, encoding: .utf8)
    }

    var ready: Bool {
        if case .ready = setupState { return true }
        return false
    }

    var setupLabel: String {
        switch setupState {
        case .pending: "pending"
        case .loading: "loading models…"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
    }

    // MARK: - Bring-up

    func setUp() async {
        guard case .pending = setupState else { return }
        setupState = .loading
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            setupState = .failed("models missing at \(modelDir.path)")
            return
        }
        do {
            ConfigStore.ensureDefault()
            let config = ConfigStore.load()
            dictionary = DictionaryEngine(rules: config.dictionaryRules)
            stripper = FillerStripper(
                core: FillerStripper.coreFillers(for: language),
                extra: config.cleanup.extraFillers,
                disabled: config.cleanup.disabledFillers,
                collapseStutters: config.cleanup.collapseStutters)
            try await asr.load()
            do {
                try await vad.load()
                vadAvailable = true
            } catch {
                vadAvailable = false
            }
            // No eager audio.prepare(): the inference loop needs no mic, and
            // the capture paths (hold-open, fixture recording) prepare inside
            // startCapture() anyway — a wedged CoreAudio HAL (seen on shared
            // simulators) must not stall the gate.
            setupState = .ready
            loadFixtureFromDisk()
            // Unattended entry (simulator smoke / `devicectl ... launch`):
            // --spike-autostart runs the loop immediately once a fixture
            // loaded; --spike-runs N overrides the default 30.
            if let flag = CommandLine.arguments.firstIndex(of: "--spike-runs"),
               CommandLine.arguments.indices.contains(flag + 1),
               let runs = Int(CommandLine.arguments[flag + 1]) {
                runCount = max(1, min(100, runs))
            }
            if CommandLine.arguments.contains("--spike-autostart"), fixture != nil {
                startLoop()
            }
        } catch {
            setupState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Fixture

    /// `--spike-file <path>` argument first (simulator convenience), then a
    /// bundled Models/spike-fixture.wav, then one dropped next to the
    /// on-device models dir.
    private func loadFixtureFromDisk() {
        var candidates: [URL] = []
        if let flag = CommandLine.arguments.firstIndex(of: "--spike-file"),
           CommandLine.arguments.indices.contains(flag + 1) {
            candidates.append(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        candidates.append(modelsDir.appendingPathComponent("spike-fixture.wav"))
        candidates.append(Paths.modelsDir.appendingPathComponent("spike-fixture.wav"))
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                let samples = try AudioFileLoader.loadSamples16k(url)
                guard samples.count >= asr.minimumSamples else { continue }
                fixture = samples
                fixtureLabel = "\(url.lastPathComponent) (\(Self.seconds(samples))s)"
                return
            } catch {
                fixtureLabel = "unreadable: \(url.lastPathComponent)"
            }
        }
    }

    func beginFixtureRecording() {
        guard !recordingFixture, !running else { return }
        do {
            try audio.startCapture()
        } catch {
            fixtureLabel = "mic failed: \(error.localizedDescription)"
            return
        }
        audio.beginUtterance()
        recordingFixture = true
    }

    func endFixtureRecording() {
        guard recordingFixture else { return }
        let samples = audio.endUtterance()
        audio.stopCapture()
        recordingFixture = false
        guard samples.count >= asr.minimumSamples else {
            fixtureLabel = "recording too short — try again"
            return
        }
        fixture = samples
        fixtureLabel = "recorded (\(Self.seconds(samples))s)"
    }

    // MARK: - The loop

    func startLoop() {
        guard let fixture, ready, !running else { return }
        running = true
        results = []
        loopTask = Task { await runLoop(fixture) }
    }

    func cancel() {
        loopTask?.cancel()
    }

    private func runLoop(_ fixture: [Float]) async {
        print("SPIKE: loop=start runs=\(runCount) hold_mic=\(holdMicOpen) "
            + "reload_asr=\(reloadAsrEachRun) fixture_s=\(Self.seconds(fixture)) "
            + "build=\(Self.buildConfiguration)")
        if holdMicOpen { try? audio.startCapture() }
        for index in 1...runCount {
            guard !Task.isCancelled else { break }
            currentRun = index
            results.append(await oneRun(index, fixture: fixture))
            persistReport()
            if index < runCount {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if holdMicOpen { audio.stopCapture() }
        currentRun = 0
        running = false
        print("SPIKE: loop=end verdict=\(verdictLine)")
        persistReport()
    }

    private func oneRun(_ index: Int, fixture: [Float]) async -> SpikeRunResult {
        let before = Self.availableMemoryMB()
        let processInfo = ProcessInfo.processInfo
        let thermal = Self.describe(processInfo.thermalState)
        let lowPower = processInfo.isLowPowerModeEnabled
        let background = UIApplication.shared.applicationState != .active
        let spid = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("spike.run", id: spid)

        var ok = false
        var detail = ""
        var timings = StageTimings()
        do {
            if reloadAsrEachRun {
                // A fresh engine instance is a true cold load — the exact
                // "segment end → load Parakeet" step the review doubts.
                asr = ParakeetEngine(modelsDir: modelsDir, version: language.parakeetVersion)
                pipeline = DictationPipeline(asr: asr)
                let (_, loadSeconds) = try await measured { try await asr.load() }
                detail = "load \(Int(loadSeconds * 1000))ms · "
            }
            let dict = dictionary
            let outcome = try await pipeline.run(
                fixture,
                trim: vadAvailable ? { await self.vad.trim($0) } : nil,
                dictionary: dict, stripper: stripper,
                level: .fillers,
                format: {
                    TextFormatter.ruleBasedCleanup($0, preserveCasingFor: dict.lowercasedTargets)
                })
            if let outcome {
                ok = true
                timings = outcome.timings
                detail += "\"\(outcome.text.prefix(40))\""
            } else {
                detail += "empty transcript"
            }
        } catch {
            detail += error.localizedDescription
        }
        Self.signposter.endInterval("spike.run", interval)

        let result = SpikeRunResult(
            index: index, ok: ok, detail: detail,
            asrMs: Int(timings.asrSeconds * 1000),
            formatMs: Int(timings.formatSeconds * 1000),
            totalMs: Int(timings.totalSeconds * 1000),
            availableBeforeMB: before, availableAfterMB: Self.availableMemoryMB(),
            thermal: thermal, lowPower: lowPower, background: background)
        print("SPIKE: run=\(index)/\(runCount) \(result.line)")
        return result
    }

    // MARK: - Verdict + report

    var verdictLine: String {
        guard !results.isEmpty else { return "no runs yet" }
        let ok = results.filter(\.ok).count
        var consecutive = 0
        for result in results {
            guard result.ok else { break }
            consecutive += 1
        }
        let headrooms = results
            .flatMap { [$0.availableBeforeMB, $0.availableAfterMB] }
            .filter { $0 > 0 }
        let minHeadroom = headrooms.min().map { "\($0) MB" } ?? "n/a (simulator)"
        let gate = !running && results.count >= runCount && consecutive >= runCount
            ? " · GATE PASS (headroom judgment is yours)"
            : (results.contains { !$0.ok } ? " · GATE FAIL" : "")
        return "\(ok)/\(results.count) ok · \(consecutive) consecutive · "
            + "min headroom \(minHeadroom)\(gate)"
    }

    var reportText: String {
        let device = UIDevice.current
        var lines = [
            "whispr bro P1 spike — \(Date())",
            "\(device.model) iOS \(device.systemVersion) · build=\(Self.buildConfiguration) "
                + "· physical \(Int(ProcessInfo.processInfo.physicalMemory / 1_048_576))MB",
            "lang=\(languageCode) fixture=\(fixtureLabel) hold_mic=\(holdMicOpen) "
                + "reload_asr=\(reloadAsrEachRun)",
            "gate: release build, no debugger, Low Power Mode on, screen locked, "
                + "backgrounded — \(runCount) consecutive with headroom = go",
            "",
        ]
        lines += results.map(\.line)
        lines += ["", "verdict: \(verdictLine)"]
        return lines.joined(separator: "\n")
    }

    /// Written after EVERY run: a jetsam kill mid-loop leaves the completed
    /// rows in Caches for the relaunch (`previousReport`).
    private func persistReport() {
        try? reportText.write(to: Self.reportURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Probes

    private static func availableMemoryMB() -> Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func seconds(_ samples: [Float]) -> String {
        String(format: "%.1f", Double(samples.count) / AudioEngine.targetSampleRate)
    }
}
#endif
