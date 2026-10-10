/// Pipeline phases the HUD can show.
///
/// Lives in Core for the same reason `DictationGesture` does: the macOS app is
/// an `executableTarget`, so `swift test` can never reach the panel, and the
/// one rule here that cost him CPU — which phases are LIVE, and what a hidden
/// panel is left holding — has to be pinned somewhere a test can run.
public enum HUDPhase: Equatable, Sendable {
    case recording
    /// Hands-free (double-tap lock). Carries the way OUT, ready to render
    /// ("Right ⌥ to finish", or "Esc to cancel" when no dictate key is bound),
    /// so it is on screen the whole time the mic is latched. The caller owns
    /// the wording — `PipelineController.handsFreeExitHint` — because the menu
    /// bar prints the same string. Nothing else stops a hands-free session.
    case locked(hint: String)
    case transcribing
    case inserting
    case refused(String)
    case warning(String)
    /// Ordered out. `hide()` lands here so a hidden panel never holds a live
    /// phase — cancelRecording() and the floor guard hide straight from
    /// .recording, which kept the ripple animating off-screen.
    case idle

    /// Mic open: the pebble shows the live waveform instead of a status line,
    /// and the echo-w mark ripples. Nothing live may outlive the panel.
    public var isLive: Bool {
        switch self {
        case .recording, .locked: true
        default: false
        }
    }
}
