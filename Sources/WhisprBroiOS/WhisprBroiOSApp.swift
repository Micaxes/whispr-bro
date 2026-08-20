import SwiftUI

/// The iOS app (issue #13 phase i1): in-app dictation only. The keyboard
/// extension (phase i2) will drive sessions through the App Group; for now the
/// app is a single window with Dictate + History tabs and a Settings sheet.
@main
struct WhisprBroiOSApp: App {
    /// The one process-wide model, owned by `AppModel` so the App Intents
    /// entry points (StartDictationIntent can launch the app in the
    /// background, before any scene exists) drive the same instance the UI
    /// observes.
    @ObservedObject private var model = AppModel.dictation

    var body: some Scene {
        WindowGroup {
            #if DEBUG || SPIKE
            if SpikeMode.active {
                // P1 gate: the spike owns its own ASR stack, so the normal
                // root (and its model load) is skipped entirely — one
                // Parakeet in memory, honest headroom numbers.
                SpikeView()
            } else {
                root
            }
            #else
            root
            #endif
        }
    }

    private var root: some View {
        RootView()
            .environmentObject(model)
            .onAppear {
                model.startup()
                // Session IPC bring-up beside the model's: republishes a
                // fresh `.off` status page so the keyboard never trusts a
                // jetsamed predecessor's leftovers (issue #13 P4).
                AppModel.session.startup()
            }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: DictationModel
    @ObservedObject private var session = AppModel.session
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettingsFromLink = false
    #if DEBUG || SPIKE
    @State private var spikeArmed = false
    #endif

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Dictate", systemImage: "mic") }
            NavigationStack { HistoryListView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(Brand.ink)
        // The whisprbro:// router. session/start is the arming deep link
        // (issue #13 P4): foreground-start the continuous-capture session and
        // show the brand card until the user swipes back. The keyboard's mic
        // key appends ?source=keyboard — that arm preserves the keyboard's
        // pre-posted start and enables the card's auto-switchback; the App
        // Intent / Control Center arms use the plain URL and stay `.external`.
        // settings is the keyboard toolbar's gear key: present the same
        // Settings sheet HomeView offers.
        .onOpenURL { url in
            switch url.host() {
            case "session":
                guard url.path() == "/start" else { return }
                let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "source" })?.value
                session.startSession(source: source == "keyboard" ? .keyboard : .external)
            case "settings":
                showSettingsFromLink = true
            #if DEBUG || SPIKE
            case "spike":
                // whisprbro://spike arms spike mode for the NEXT launch — the
                // no-terminal entry a release gate build on device needs (see
                // SpikeMode).
                SpikeMode.arm()
                spikeArmed = true
            #endif
            default:
                break
            }
        }
        .fullScreenCover(isPresented: $session.showSessionCard) {
            SessionCardView(session: session)
        }
        // Same presentation as HomeView's gear: SettingsSheet inherits the
        // environmentObject model from this view.
        .sheet(isPresented: $showSettingsFromLink) { SettingsSheet() }
        .onChange(of: scenePhase) { _, newPhase in
            session.scenePhaseChanged(newPhase)
        }
        #if DEBUG || SPIKE
        .alert("Spike mode armed", isPresented: $spikeArmed) {
            Button("OK") {}
        } message: {
            Text("Quit and relaunch whispr bro to enter the P1 spike screen.")
        }
        #endif
    }
}
