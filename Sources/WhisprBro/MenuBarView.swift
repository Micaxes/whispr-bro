import AppKit
import SwiftUI
import WhisprBroCore

/// Menu content: pipeline status, permission walkthrough, and quick actions.
/// (Dedicated onboarding + settings windows arrive in later tasks; the menu
/// is the walking skeleton's UI.)
struct MenuBarView: View {
    @ObservedObject var pipeline: PipelineController

    var body: some View {
        Text(statusLine)

        if case .needsPermissions = pipeline.state {
            Divider()
            Text("Grant all three, then whispr-bro arms itself:")
            permissionRow("Microphone", granted: pipeline.permissions.microphone, pane: "Privacy_Microphone")
            permissionRow("Accessibility", granted: pipeline.permissions.accessibility, pane: "Privacy_Accessibility")
            permissionRow("Input Monitoring", granted: pipeline.permissions.inputMonitoring, pane: "Privacy_ListenEvent")
        }

        if case .modelsMissing = pipeline.state {
            Divider()
            Text("Models missing — run: scripts/fetch-models.sh")
            Button("Reveal models folder") {
                NSWorkspace.shared.activateFileViewerSelecting([Paths.modelsDir])
            }
            Button("Retry") { pipeline.retry() }
        }

        if case .error(let message) = pipeline.state {
            Divider()
            Text(message).lineLimit(3)
            Button("Retry") { pipeline.retry() }
        }

        if !pipeline.lastTranscript.isEmpty {
            Divider()
            Text("Last: \(String(pipeline.lastTranscript.prefix(60)))")
            Text(pipeline.lastTimings).font(.caption)
        }

        Divider()
        Text("Hold Right Option (⌥) to dictate")
        Button("Quit whispr-bro") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch pipeline.state {
        case .needsPermissions: "⚠️ Permissions needed"
        case .modelsMissing: "⚠️ ASR models not installed"
        case .loadingModels: "Loading models…"
        case .idle: "Ready — hold Right ⌥ and speak"
        case .recording: "● Recording…"
        case .transcribing: "Transcribing…"
        case .inserting: "Inserting…"
        case .error: "⚠️ Error"
        }
    }

    @ViewBuilder
    private func permissionRow(_ name: String, granted: Bool, pane: String) -> some View {
        if granted {
            Text("✓ \(name)")
        } else {
            Button("✗ \(name) — open settings…") {
                let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
                if let settingsURL = URL(string: url) {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
        }
    }
}
