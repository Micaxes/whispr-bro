import AppIntents
import SwiftUI
import WidgetKit

/// Control Center entry point for a whispr SESSION (issue #13 P5): a button
/// the user can place in Control Center (and, from there, bind to the Action
/// Button or Lock Screen) that deep-links into the app's session-arming flow —
/// the SAME `whisprbro://session/start` URL the keyboard's mic key posts, so
/// every entry point funnels through `SessionController.startSession` and its
/// foreground-only mic rule. This is the session flow, never the pasteboard
/// quick-dictation path (`StartDictationIntent`, app target).
struct StartSessionControl: ControlWidget {
    static let kind = "com.micaxes.whispr-bro.ios.widgets.start-session"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartSessionControlIntent()) {
                Label("Start whispr session", systemImage: "mic.badge.plus")
            }
        }
        .displayName("Start whispr session")
        .description("Arms a whispr bro dictation session — then dictate anywhere from the whispr key.")
    }
}

/// The control's thin intent, deliberately widget-target-local (this appex
/// links NO app-target code — see ios/project.yml): all it does is foreground
/// the app onto the arming deep link via `OpenURLIntent`; the app's
/// `RootView.onOpenURL` router does the rest.
struct StartSessionControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Whispr Session"
    static let description = IntentDescription(
        "Opens whispr bro and arms a dictation session for the whispr keyboard.")
    /// Foreground on purpose: iOS only lets a mic session START in a
    /// foreground app (`SessionController.startSession` refuses otherwise).
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "whisprbro://session/start")!))
    }
}
