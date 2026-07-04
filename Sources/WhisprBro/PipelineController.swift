import AppKit
import Foundation
import os.log
import SwiftUI
import WhisprBroCore

/// Wires hotkey → audio → ASR → insertion (spec §3, §9 subset for the
/// walking skeleton: no VAD, no LLM, no HUD yet).
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
    @Published private(set) var lastTimings: String = ""
    /// Cached so SwiftUI renders don't issue TCC round-trips on every body
    /// evaluation; refreshed by the poll timer and bring-up attempts.
    @Published private(set) var permissions = PermissionSnapshot()

    private let audio = AudioEngine()
    private let hotkey = HotkeyManager()
    private let inserter = TextInserter()
    private let asr: AsrEngine = ParakeetEngine(modelsDir: Paths.modelsDir)
    private let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "pipeline")
    private var permissionPollTimer: Timer?
    private var isBringingUp = false
    private var pipelineRunning = false
    /// Invalidates stale self-heal timers when a newer error replaces an
    /// older one (each new error bumps the generation).
    private var errorGeneration = 0

    func startup() {
        hotkey.onKeyDown = { [weak self] in self?.hotkeyPressed() }
        hotkey.onKeyUp = { [weak self] in self?.hotkeyReleased() }
        Task { await bringUp() }
    }

    /// Attempt to bring the pipeline up; falls back to a permission-polling
    /// state if TCC grants are missing (they can only be granted by the user
    /// in System Settings). Re-entrancy safe: overlapping calls (Retry click
    /// during a poll tick) are dropped, and audio/hotkey starts are
    /// idempotent besides.
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
            if !pipelineRunning {
                try audio.start()
                try hotkey.start()
                pipelineRunning = true
            }
            state = .idle
            log.info("pipeline up: hotkey armed, audio running, models loaded")
        } catch WhisprError.modelsNotFound {
            // Partial install (e.g. deleted after a checksum failure).
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
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissions()
                if self.permissions.allGranted {
                    await self.bringUp()
                }
            }
        }
    }

    func retry() {
        Task { await bringUp() }
    }

    /// Actively invoke the OS permission requests. Requesting Input Monitoring
    /// (CGRequestListenEventAccess) is what registers the app in the Input
    /// Monitoring list — without it the app never appears there to be toggled.
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
        let url = "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)"
        if let settingsURL = URL(string: url) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Input Monitoring grants often only take effect for a freshly-launched
    /// process; relaunching from the menu avoids a confusing "granted but the
    /// hotkey still doesn't fire" state.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    private func hotkeyPressed() {
        guard state == .idle else {
            if state == .transcribing || state == .inserting {
                NSSound.beep()
            }
            return
        }
        state = .recording
        audio.beginUtterance()
    }

    private func hotkeyReleased() {
        guard state == .recording else { return }
        state = .transcribing

        Task {
            var timings = StageTimings()
            let (samples, finalizeSeconds) = measuredSync { audio.endUtterance() }
            timings.audioFinalizeSeconds = finalizeSeconds

            // Below the engine's floor (~300ms): an accidental tap, not a
            // dictation. Silently return — never surface an error for it.
            guard samples.count >= asr.minimumSamples else {
                state = .idle
                return
            }

            do {
                let (result, asrSeconds) = try await measured { try await asr.transcribe(samples) }
                timings.asrSeconds = asrSeconds
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    state = .idle
                    return
                }

                state = .inserting
                let insertClock = ContinuousClock()
                let insertStart = insertClock.now
                inserter.insert(text) { [weak self] in
                    guard let self else { return }
                    timings.insertSeconds = (insertClock.now - insertStart).seconds
                    self.lastTranscript = text
                    self.lastTimings = timings.description
                    self.log.info("dictation: \"\(text, privacy: .private)\" [\(timings.description)]")
                    self.state = .idle
                }
            } catch {
                // Transient dictation failure: show it briefly, then
                // self-heal — unless a newer error replaced this one.
                errorGeneration += 1
                let generation = errorGeneration
                state = .error(error.localizedDescription)
                log.error("dictation failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(3))
                if case .error = state, errorGeneration == generation {
                    state = .idle
                }
            }
        }
    }
}
