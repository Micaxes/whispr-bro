import ActivityKit
import AppIntents
import Foundation

/// The dictation Live Activity contract (issue #13 review amendment 1 / the
/// row-8 probe). Compiled into BOTH the app target and the WhisprBroWidgets
/// extension (see ios/project.yml): ActivityKit matches an app-requested
/// activity to the widget's `ActivityConfiguration` by this attributes type,
/// so the one definition is shared, never duplicated.
struct DictationActivityAttributes: ActivityAttributes {
    /// Dictation phase — drives the island/Lock Screen copy. `recording` is
    /// the only phase with a live Stop button; `transcribing`/`done` exist so
    /// the activity can show the pipeline landing instead of vanishing at the
    /// instant the mic closes.
    enum Phase: String, Codable, Hashable {
        case recording
        case transcribing
        case done
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Latest mic RMS (0…~0.3, the `AudioEngine.lastRMS` scale), static
        /// between activity updates — the level bar is a coarse "audio is
        /// flowing" liveness signal, not a waveform.
        var level: Double
    }

    /// Recording start — the elapsed timer renders from this via
    /// `Text(_:style:.timer)`, needing zero activity updates to tick.
    var startedAt: Date
}

/// Stops the dictation started by `StartDictationIntent`, from the Live
/// Activity's Stop button. `LiveActivityIntent` executes in the APP process —
/// the copy of this type in the widget binary exists only so `Button(intent:)`
/// can name it — so `perform()` reaches the app through
/// `DictationIntentHooks.stop`, wired before recording starts. A nil hook
/// (a stale activity outliving a terminated app) degrades to ending every
/// dictation activity, so the Stop button can never wedge.
struct StopDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription(
        "Stops the whispr bro dictation in progress.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        if let stop = DictationIntentHooks.stop {
            await stop()
        } else {
            for stale in Activity<DictationActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
        return .result()
    }
}

/// App-side handler for `StopDictationIntent` — set by `StartDictationIntent`
/// before capture begins; always nil in the widget process, where the intent
/// never executes.
@MainActor
enum DictationIntentHooks {
    static var stop: (() async -> Void)?
}
