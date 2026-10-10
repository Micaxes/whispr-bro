import AppKit
import SwiftUI
import WhisprBroCore

@main
struct WhisprBroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var pipeline = PipelineController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(pipeline: pipeline)
        } label: {
            MenuBarLabel(pipeline: pipeline)
        }
        .menuBarExtraStyle(.menu)

        // A single, resizable History window. The app is LSUIElement
        // (accessory), so ActivationPolicy promotes it to .regular while the
        // window is open — otherwise the window opens unfocused/behind.
        // One unified window: a branded sidebar + a detail pane hosting the
        // Dashboard, History, and every Settings sub-section. Cream full-bleed
        // chrome (brand); OS traffic lights float over the echo-w header.
        Window("whispr-bro", id: "main") {
            MainWindowView(pipeline: pipeline)
                .onDisappear { ActivationPolicy.deactivateIfNoWindows() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 660)
        // `whisprbro://open` (see MainWindowOpener) creates this window even
        // when no view exists to ask for it.
        .handlesExternalEvents(matching: MainWindowOpener.externalEvents)
    }
}

/// Menu-bar mark: the echo-w brand glyph (a tinted template image that adapts
/// to the menu bar), or a warning triangle when something needs attention.
///
/// It is also the one view that belongs to the status item rather than to the
/// menu (whose content is not run until the menu is opened) — which is why it
/// is where `MainWindowOpener` gets its `openWindow` action.
private struct MenuBarLabel: View {
    @ObservedObject var pipeline: PipelineController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        glyph.onAppear { MainWindowOpener.shared.capture(openWindow) }
    }

    @ViewBuilder private var glyph: some View {
        switch pipeline.state {
        case .needsPermissions, .modelsMissing, .error:
            Image(systemName: "exclamationmark.triangle")
        default:
            Image(nsImage: EchoWImage.menuBar())
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconVariant.selected.applyToDock()   // restore the chosen Dock icon
        PipelineController.shared.startup()
        UpdateModel.shared.startup()            // on-by-default, out-of-process update check
        MenuBarWatch.shared.startup(pipeline: PipelineController.shared)   // is the icon hidden behind the notch?
    }

    /// Launched again while already running (Spotlight, Finder, Raycast,
    /// `open -a`, a Dock click): open the window. Not sent for the first launch,
    /// so a login launch stays silent. `hasVisibleWindows` is ignored on purpose
    /// — with the window already up, the right answer is to raise it. `false`:
    /// nothing is left for the default handler to do.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowOpener.shared.open()
        return false
    }

    /// `whisprbro://open`, from the app itself (MainWindowOpener's second path)
    /// or from anything else that opens it. SwiftUI creates the window; an
    /// accessory app still has to be made focusable to show it properly.
    /// Only for that URL: any other (the iOS app's router shares the scheme, and
    /// `open -a` takes files) gets no window, and making the app focusable for
    /// nothing leaves a Dock icon with nothing behind it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: MainWindowOpener.isOpenURL) else { return }
        ActivationPolicy.activate()
    }

    /// Defer termination so GPU-backed models are freed first (ggml-metal
    /// asserts if the Metal device is torn down with the model still loaded).
    /// Two INDEPENDENT unstructured tasks — shutdown and a 3s deadline — each
    /// fire the reply gate; whichever wins lets the app quit. (A structured
    /// task group would await ALL children, so a wedged shutdown would still
    /// block the reply — the very bug this avoids.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let gate = ReplyGate(sender)
        Task { @MainActor in await PipelineController.shared.shutdown(); gate.fire() }
        Task { @MainActor in try? await Task.sleep(for: .seconds(3)); gate.fire() }
        return .terminateLater
    }
}

/// Calls `reply(toApplicationShouldTerminate:)` at most once, from whichever
/// task (shutdown or deadline) completes first.
@MainActor
private final class ReplyGate {
    private var fired = false
    private let sender: NSApplication
    init(_ sender: NSApplication) { self.sender = sender }
    func fire() {
        guard !fired else { return }
        fired = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}

extension PipelineController {
    static let shared = PipelineController()
}

/// Toggles the app between accessory (menu-bar only) and regular (Dock icon +
/// focusable windows), so the History window is only a full app while it's open.
enum ActivationPolicy {
    @MainActor static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A real window is up (the HUD and other panels don't count).
    @MainActor static var hasStandardWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    @MainActor static func deactivateIfNoWindows() {
        // Defer a tick so the closing window is gone from NSApp.windows.
        DispatchQueue.main.async {
            if !hasStandardWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
