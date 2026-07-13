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
            .onAppear { model.startup() }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: DictationModel
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
        #if DEBUG || SPIKE
        // whisprbro://spike arms spike mode for the NEXT launch — the
        // no-terminal entry a release gate build on device needs (see
        // SpikeMode).
        .onOpenURL { url in
            guard url.host() == "spike" else { return }
            SpikeMode.arm()
            spikeArmed = true
        }
        .alert("Spike mode armed", isPresented: $spikeArmed) {
            Button("OK") {}
        } message: {
            Text("Quit and relaunch whispr bro to enter the P1 spike screen.")
        }
        #endif
    }
}
