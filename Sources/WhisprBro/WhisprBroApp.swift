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
}

extension PipelineController {
    static let shared = PipelineController()
}
