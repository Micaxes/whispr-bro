import Foundation

/// The gesture layer of the dictation flow: what a hotkey event means for the
/// capture — with no audio, AX, timers or UI attached.
///
/// It lives in Core as a pure type for one reason: the macOS app is an
/// `executableTarget`, so `swift test` can never reach `PipelineController`,
/// and these rules — which press finishes a recording, which one is only
/// arming a latch — are exactly the ones that must not drift silently. Same
/// pattern as `WhisprBroAutocorrect` (see Package.swift).
///
/// The contract, one line each:
///  - **hold** (push-to-talk): press starts, release finishes. A release under
///    `minHoldToTranscribe` was a tap arming a double-tap, so its audio is
///    discarded rather than transcribed.
///  - **hands-free** (double-tap): a second press within `doubleTapWindow` of
///    the first (press to press) — the second press already started the
///    recording; the double-tap latches it. It then ends ONLY on the next press
///    of the key, on Cancel, or on the safety cap — **never on silence**. A
///    pause is not evidence that the speaker is done, and a dictation that
///    submits itself mid-thought costs more than one that waits.
public enum DictationGesture {
    /// Holds shorter than this are taps (the double-tap arming press), never
    /// dictations. Decided by DURATION, not sample count, so the gate cannot
    /// shift with how much audio the buffer happens to hold.
    ///
    /// 0.45s, raised from 0.22s because 0.22s is not a human tap. A deliberate
    /// press of a modifier key sits on it for 120–400ms; at 0.22s roughly half
    /// of an ordinary double-tap's FIRST press was being read as a dictation,
    /// so it armed nothing and the second press started a plain hold instead of
    /// latching. That is the bug where hands-free only took when the key was
    /// hammered.
    ///
    /// Raising it costs no real dictation. Under 0.45s of key-down there is
    /// nothing to transcribe: the mic takes ~100ms to go live, so the utterance
    /// is under 350ms — below whisper.cpp's own 1.0s floor
    /// (`minimumSamples = 16_000`) and barely over SpeechTranscriber's 0.3s, and
    /// no one says a word inside it anyway (press, speak, release is ~700ms at
    /// the very fastest).
    public static let minHoldToTranscribe: TimeInterval = 0.45

    /// How long after the FIRST press a second press still counts as a
    /// double-tap. Measured **press to press**, the way every double-click on
    /// the platform is measured — not release-to-press, which silently charged
    /// the gap for however long he happened to hold the first tap and made a
    /// slow-but-deliberate double-tap fail.
    ///
    /// 0.70s: macOS's own double-click default is 0.5s with a 1.0s slow
    /// setting, and this window must also cover the arming press itself (up to
    /// `minHoldToTranscribe`), leaving ≥0.25s of gap even for the slowest tap
    /// that still arms. Only a press that produced NO dictation opens it (see
    /// `armsDoubleTap`), so a wider window cannot make a real dictation latch.
    public static let doubleTapWindow: TimeInterval = 0.70

    /// Safety cap on a push-to-talk hold — long enough that no real hold hits
    /// it, short enough that a lost key-up can't record forever.
    public static let maxHoldSeconds: TimeInterval = 90

    /// Safety cap on a hands-free session. Nothing auto-stops it any more, so
    /// this is the only clock on it.
    ///
    /// 300s, the same number and the same reasoning as the iOS session cap
    /// (`SessionController.maxSegmentSeconds`): it matches dictation-app
    /// category norms and bounds the utterance buffer at ~19MB of 16kHz
    /// Float32. The two platforms do not get to disagree about how long "as
    /// long as you like" is.
    public static let maxHandsFreeSeconds: TimeInterval = 300

    /// What the pipeline is doing when the event lands.
    public enum Phase: Equatable, Sendable {
        /// No capture possible (permissions, models missing, error state).
        case unavailable
        case idle
        case recording
        /// Transcribing or inserting — the previous dictation is still landing.
        case busy
    }

    /// The capture action an event implies. `finish(trim:)` carries whether
    /// leading/trailing silence should be trimmed off the utterance: a hold is
    /// exactly the held audio, a latched session can have quiet at both ends.
    public enum Decision: Equatable, Sendable {
        case ignore
        /// Beep: a dictation is still landing, so this press is refused.
        case refuseBusy
        case start
        /// Sub-threshold hold — throw the audio away, never transcribe it.
        case discard
        case finish(trim: Bool)
        case latchHandsFree
    }

    /// Whether a release arms the double-tap window — i.e. whether the press
    /// that just ended was a TAP rather than a dictation. Same threshold as
    /// `minHoldToTranscribe`, and deliberately the same question: a hold long
    /// enough to transcribe was a dictation, and the press after it must not
    /// silently latch hands-free.
    ///
    /// One threshold, one meaning — there is deliberately no band where a press
    /// both transcribes and arms. `heldFor` must therefore be measured between
    /// the real key EVENTS, never between the handlers that process them: a
    /// press whose handler blocks (opening a USB mic costs real milliseconds)
    /// pushes the release's handler late, and a tap the tracker armed would be
    /// transcribed by a pipeline reading its own clock.
    public static func armsDoubleTap(heldFor: TimeInterval) -> Bool {
        heldFor < minHoldToTranscribe
    }

    /// How to end a latched session, in his words — composed ONCE, here,
    /// because two places render it (the HUD pebble and the menu bar) and a
    /// renderer that appends its own "to finish" produces "Right ⌥ to finish
    /// to finish". Renderers print this verbatim.
    ///
    /// With no dictate key bound, Cancel is the only way out that still
    /// exists — and if that is unbound too, say so rather than name a key that
    /// does nothing. Both labels come from the live config, so the hint can
    /// only ever name a key he can actually press.
    public static func exitHint(dictateKeyLabel: String?, cancelKeyLabel: String?) -> String {
        if let dictate = dictateKeyLabel { return "\(dictate) to finish" }
        if let cancel = cancelKeyLabel { return "\(cancel) to cancel" }
        return "no shortcut bound — see Settings"
    }

    /// Key-down on the dictate or command key. `isDictateKey` distinguishes
    /// them: only the dictate key toggles a latched session off. Command mode
    /// is a different key (Right ⌘ by default) and forming a ⌘ chord mid-session
    /// must not end his dictation.
    public static func press(phase: Phase, locked: Bool, isDictateKey: Bool) -> Decision {
        switch phase {
        case .recording:
            // The hands-free STOP: while latched, the dictate key is a toggle.
            return locked && isDictateKey ? .finish(trim: true) : .ignore
        case .idle:
            return .start
        case .busy:
            return .refuseBusy
        case .unavailable:
            return .ignore
        }
    }

    /// Key-up on the dictate/command key. `heldFor` is the time since the press
    /// that started the current recording.
    public static func release(phase: Phase, locked: Bool, heldFor: TimeInterval) -> Decision {
        // A release while latched is the arming tap of the double-tap (or the
        // release of the stop press) — the session keeps running either way.
        guard phase == .recording, !locked else { return .ignore }
        return heldFor >= minHoldToTranscribe ? .finish(trim: false) : .discard
    }

    /// A second press inside the double-tap window.
    public static func doubleTap(phase: Phase, locked: Bool) -> Decision {
        guard phase == .recording, !locked else { return .ignore }
        return .latchHandsFree
    }

    /// The safety cap elapsed (a hold that never got its key-up, or a latched
    /// session left running). The audio is transcribed rather than dropped —
    /// losing a real dictation is worse than inserting a long one.
    public static func durationCap(phase: Phase, locked: Bool) -> Decision {
        guard phase == .recording else { return .ignore }
        return .finish(trim: locked)
    }
}
