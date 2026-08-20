import AppIntents
import Foundation

/// Session-arming App Intent (issue #13 P5) — the Siri / Shortcuts / Action
/// Button / Back Tap twin of the keyboard's mic key: foregrounds the app onto
/// the SAME deep link the keyboard posts (`whisprbro://session/start` →
/// `RootView.onOpenURL` → `SessionController.startSession`), so every entry
/// point shares one arming flow. Deliberately NOT an `AudioRecordingIntent`
/// like `StartDictationIntent`: a session may never start backgrounded
/// (`startSession` refuses — the foreground-only mic rule), and routing
/// through the URL keeps this intent free of any model bring-up.
struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Whispr Session"
    static let description = IntentDescription(
        "Opens whispr bro and arms a dictation session — then dictate anywhere from the whispr keyboard key. Fully on-device, no network.")
    /// Foreground on purpose (the inverse of `StartDictationIntent`'s
    /// background probe): arming a session IS a foregrounding act.
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "whisprbro://session/start")!))
    }
}
