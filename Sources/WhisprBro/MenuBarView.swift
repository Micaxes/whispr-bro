import AppKit
import SwiftUI
import WhisprBroCore

/// Menu content: pipeline status, permission walkthrough, and quick actions.
/// (Dedicated onboarding + settings windows arrive in later tasks; the menu
/// is the walking skeleton's UI.)
struct MenuBarView: View {
    @ObservedObject var pipeline: PipelineController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)

        if case .needsPermissions = pipeline.state {
            Divider()
            Text("Grant all three, then whispr-bro arms itself:")
            permissionRow("Microphone", granted: pipeline.permissions.microphone, kind: .microphone)
            permissionRow("Accessibility", granted: pipeline.permissions.accessibility, kind: .accessibility)
            permissionRow("Input Monitoring", granted: pipeline.permissions.inputMonitoring, kind: .inputMonitoring)
            Divider()
            Text("After granting Input Monitoring, relaunch:").font(.caption)
            Button("Relaunch whispr-bro") { pipeline.relaunch() }
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

        if pipeline.hotkeyDead {
            Divider()
            Text("⚠️ Hotkey stopped working — re-grant Input Monitoring")
            Button("Open Input Monitoring settings…") {
                pipeline.openSettings(for: .inputMonitoring)
            }
            Button("Relaunch whispr-bro") { pipeline.relaunch() }
        }

        if !pipeline.lastTranscript.isEmpty {
            Divider()
            Text("Last: \(String(pipeline.lastTranscript.prefix(60)))")
            Text(pipeline.lastTimings).font(.caption)
        }

        Divider()
        Picker("Auto-Clean", selection: Binding(
            get: { pipeline.cleanupLevel },
            set: { pipeline.cleanupLevel = $0 }
        )) {
            ForEach(AppConfig.Cleanup.Level.allCases, id: \.self) { level in
                Text(level.displayName).tag(level)
            }
        }
        if pipeline.canUndoToRaw {
            Button("Undo last Auto-Clean (paste raw)") { pipeline.reinsertLastRaw() }
        }
        if pipeline.llmAvailable {
            Toggle("Raw mode (skip AI cleanup)", isOn: Binding(
                get: { pipeline.rawMode },
                set: { _ in pipeline.toggleRawMode() }
            ))
            Toggle("Match app style (Slack casual, Mail formal…)", isOn: Binding(
                get: { pipeline.contextAwareStyle },
                set: { pipeline.contextAwareStyle = $0 }
            ))
        } else if case .idle = pipeline.state {
            Text("AI cleanup off (model not installed)").font(.caption)
        }
        Divider()
        Button("History…") {
            ActivationPolicy.activate()
            openWindow(id: "history")
        }
        Toggle("Save history", isOn: Binding(
            get: { pipeline.historyEnabled },
            set: { pipeline.historyEnabled = $0 }
        ))
        Button("Settings…") {
            ActivationPolicy.activate()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Button("Edit dictionary & config…") { pipeline.openConfig() }
        Button("Reload config") { pipeline.reloadConfig() }

        Text("Hold Right ⌥ to dictate · double-tap to lock hands-free")
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
    private func permissionRow(_ name: String, granted: Bool, kind: PipelineController.PermissionKind) -> some View {
        if granted {
            Text("✓ \(name)")
        } else {
            // Actively request (registers the app + shows the system prompt),
            // then jump to the relevant Settings pane.
            Button("✗ \(name) — grant…") {
                pipeline.requestPermission(kind)
            }
        }
    }
}
