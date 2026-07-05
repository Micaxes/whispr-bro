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
            Image(systemName: statusSymbol)
        }
        .menuBarExtraStyle(.menu)

        // A single, resizable History window. The app is LSUIElement
        // (accessory), so ActivationPolicy promotes it to .regular while the
        // window is open — otherwise the window opens unfocused/behind.
        Window("History", id: "history") {
            HistoryView()
                .frame(minWidth: 520, minHeight: 320)
                .onDisappear { ActivationPolicy.deactivateIfNoWindows() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 480)
    }

    private var statusSymbol: String {
        switch pipeline.state {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing, .loadingModels: "hourglass"
        case .inserting: "text.cursor"
        case .needsPermissions, .modelsMissing, .error: "mic.slash"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PipelineController.shared.startup()
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

    @MainActor static func deactivateIfNoWindows() {
        // Defer a tick so the closing window is gone from NSApp.windows.
        DispatchQueue.main.async {
            let hasStandardWindow = NSApp.windows.contains {
                $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
            }
            if !hasStandardWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
