import ActivityKit
import AppIntents
import Foundation
import os
import UIKit
import WhisprBroCore

/// Process-wide owner of the one `DictationModel`, so the App Intents entry
/// points (which can launch the app in the BACKGROUND, before any scene
/// exists) and the SwiftUI scene drive the same pipeline instance.
@MainActor
enum AppModel {
    static let dictation = DictationModel()
}

/// The row-8 probe (issue #13 three-way review): does `AudioRecordingIntent`
/// really start the mic from the Action Button / Control Center / Shortcuts
/// WITHOUT foregrounding the app? The review scored that ground-truth row
/// "most overstated — directionally right but unproven: cold/terminated
/// launch, stop behavior, Live Activity lifecycle all need a device spike";
/// this intent is the instrumented probe that answers it. It:
///  1. starts the Live Activity FIRST — the platform contract: the system
///     stops an `AudioRecordingIntent` recording that has no visible Live
///     Activity;
///  2. brings up + starts capture through the SAME `DictationModel` path the
///     in-app record key uses (mic-on-demand semantics preserved);
///  3. stops via `StopDictationIntent` from the Live Activity's Stop button.
///
/// Probe instrumentation — `PROBE:` print markers + `row8-probe` os_signposts,
/// so a device run needs only Console.app/Instruments, no debugger:
///  - invocation wall time, `UIApplication.applicationState` and scene count
///    at entry AND after capture starts (background throughout = the
///    no-bounce result the review wants proven; active = the system
///    foregrounded us);
///  - time-to-first-audio-sample, observed via the model's published level
///    (a 24Hz poll feeds it, so the number is quantized to ~42ms — fine at
///    the 100ms–3s scales the probe cares about).
struct StartDictationIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription(
        "Starts whispr bro dictation — fully on-device, no network.")
    /// Background-only on purpose: whether the system honors it IS the probe
    /// (any foregrounding is logged, never assumed away).
    static let supportedModes: IntentModes = .background

    fileprivate static let signposter = OSSignposter(
        subsystem: "com.micaxes.whispr-bro.ios", category: "row8-probe")

    @MainActor
    func perform() async throws -> some IntentResult {
        let clock = ContinuousClock()
        let invoked = clock.now
        let model = AppModel.dictation
        print("PROBE: intent=start invoked_at=\(Date()) "
            + "app_state=\(Self.describe(UIApplication.shared.applicationState)) "
            + "scenes=\(UIApplication.shared.connectedScenes.count) "
            + "model_state=\(model.state)")
        let spid = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("intent.start", id: spid)
        defer { Self.signposter.endInterval("intent.start", interval) }

        guard model.state != .recording else {
            print("PROBE: intent=start already_recording no_op=true")
            return .result()
        }

        // (1) Live Activity FIRST. A request failure here is probe data, not
        // an abort: proceed and let the device show whether recording
        // survives without one (the contract says it will be stopped).
        do {
            try await DictationActivityController.start()
            print("PROBE: intent=start live_activity=ok "
                + "activity_ms=\(Self.ms(clock.now - invoked))")
        } catch {
            print("PROBE: intent=start live_activity=FAILED "
                + "error=\(error.localizedDescription)")
        }

        do {
            // (2) Bring-up (idempotent — the scene's onAppear runs the same
            // call) + capture through the shared model.
            model.startup()
            try await Self.awaitBringUp(model)
            let bringUpMs = Self.ms(clock.now - invoked)
            model.toggleRecording()
            guard model.state == .recording else {
                throw ProbeFailure("capture did not start (state \(model.state))")
            }
            // (3) Time-to-first-audio-sample via the published level.
            let firstSampleMs = await Self.awaitFirstSample(model, clock: clock, since: invoked)
            Self.signposter.emitEvent("first-sample", id: spid)
            print("PROBE: intent=start recording=true bring_up_ms=\(bringUpMs) "
                + "first_sample_ms=\(firstSampleMs.map(String.init) ?? "none-within-5s") "
                + "app_state_now=\(Self.describe(UIApplication.shared.applicationState)) "
                + "scenes=\(UIApplication.shared.connectedScenes.count)")
        } catch {
            await DictationActivityController.end()
            print("PROBE: intent=start FAILED error=\(error.localizedDescription)")
            throw error
        }

        DictationIntentHooks.stop = { await Self.stopFromActivity() }
        DictationActivityController.observe(model)
        return .result()
    }

    /// Poll until bring-up lands in `.idle`. `.needsPermission` gets a grace
    /// period (it is also the pre-bring-up initial state), then fails —
    /// intents must not prompt; the fix is opening the app once.
    @MainActor
    private static func awaitBringUp(
        _ model: DictationModel, timeout: Duration = .seconds(25)
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < timeout {
            switch model.state {
            case .idle:
                return
            case .modelsMissing:
                throw ProbeFailure("speech models are not installed in this build")
            case .error(let message):
                throw ProbeFailure(message)
            case .needsPermission where clock.now - start > .milliseconds(1500):
                throw ProbeFailure("microphone permission missing — open whispr bro once")
            default:
                break // .loading / .transcribing / early .needsPermission — keep waiting
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProbeFailure("bring-up timed out")
    }

    /// First-audio-sample instant ≈ first nonzero published level (the mic
    /// noise floor makes RMS nonzero from the first callback). Returns nil if
    /// none arrives within 5s — logged, not fatal: a silent stall is exactly
    /// what the probe exists to catch.
    @MainActor
    private static func awaitFirstSample(
        _ model: DictationModel, clock: ContinuousClock, since: ContinuousClock.Instant
    ) async -> Int? {
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline, model.state == .recording {
            if model.level > 0 { return ms(clock.now - since) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// The Live Activity Stop path: finish through the same state machine as
    /// the in-app key, then let the activity show the pipeline landing.
    @MainActor
    fileprivate static func stopFromActivity() async {
        let model = AppModel.dictation
        print("PROBE: intent=stop "
            + "app_state=\(describe(UIApplication.shared.applicationState)) "
            + "model_state=\(model.state)")
        signposter.emitEvent("intent.stop")
        if model.state == .recording { model.toggleRecording() }
        await DictationActivityController.finish(model)
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private static func ms(_ duration: Duration) -> Int {
        Int((duration.seconds * 1000).rounded())
    }
}

/// Owns the one dictation Live Activity: request/update/end, plus a 1Hz
/// observer mirroring the model's level into the activity while recording
/// (the level bar is a liveness signal, not a waveform — no update budget
/// worth burning).
@MainActor
enum DictationActivityController {
    private static var activity: Activity<DictationActivityAttributes>?
    private static var observer: Task<Void, Never>?

    static func start() async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ProbeFailure("Live Activities are disabled for whispr bro")
        }
        // A stale activity (app died mid-dictation) would strand a second
        // Stop button — clear before requesting.
        for stale in Activity<DictationActivityAttributes>.activities {
            await stale.end(nil, dismissalPolicy: .immediate)
        }
        activity = try Activity.request(
            attributes: DictationActivityAttributes(startedAt: Date()),
            content: ActivityContent(
                state: .init(phase: .recording, level: 0), staleDate: nil))
    }

    static func observe(_ model: DictationModel) {
        observer?.cancel()
        observer = Task {
            while !Task.isCancelled, model.state == .recording {
                await update(phase: .recording, level: Double(model.level))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stop pressed: show `transcribing` until the pipeline lands (≤30s),
    /// then end, keeping the final state on the Lock Screen briefly.
    static func finish(_ model: DictationModel) async {
        observer?.cancel()
        observer = nil
        await update(phase: .transcribing, level: 0)
        let clock = ContinuousClock()
        let start = clock.now
        while model.state == .transcribing, clock.now - start < .seconds(30) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await activity?.end(
            ActivityContent(state: .init(phase: .done, level: 0), staleDate: nil),
            dismissalPolicy: .after(Date.now + 2))
        activity = nil
    }

    /// Failure path: tear the activity down immediately.
    static func end() async {
        observer?.cancel()
        observer = nil
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }

    private static func update(
        phase: DictationActivityAttributes.Phase, level: Double
    ) async {
        await activity?.update(ActivityContent(
            state: .init(phase: phase, level: level), staleDate: nil))
    }
}

/// Row-8 probe failure, surfaced verbatim in the Shortcuts / Action Button UI.
struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Registers the intent as an App Shortcut: assignable to the Action Button
/// and visible in Spotlight/Shortcuts with zero user setup.
struct WhisprBroShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation with \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill")
    }
}
