import SwiftUI
import WhisprBroCore

/// Where the single app window is currently pointed. Menu-bar items set this
/// before calling `openWindow` (which can't carry a payload).
@MainActor final class NavModel: ObservableObject {
    static let shared = NavModel()
    @Published var selection: SidebarItem = .dashboard
}

enum SidebarItem: Hashable {
    case dashboard
    case history
    case settings(SettingsView.Tab)
}

/// The unified app window (replaces the separate History + Settings windows): a
/// branded sidebar + a detail pane hosting the Dashboard, History, and every
/// Settings sub-section. Cream `.hiddenTitleBar` chrome via `BrandWindow`.
struct MainWindowView: View {
    @ObservedObject var pipeline: PipelineController
    @ObservedObject private var nav = NavModel.shared
    /// Shared so re-entering the Models tab doesn't re-hash every time.
    @StateObject private var models = ModelStatusModel()

    var body: some View {
        BrandWindow(title: "whispr·bro") {
            HStack(spacing: 0) {
                sidebar
                detail
            }
        }
        .frame(minWidth: 920, minHeight: 600)
        .task { await models.refresh() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            navRow("Dashboard", .dashboard)
            navRow("History", .history)

            BrandSectionLabel("Settings")
                .padding(.horizontal, 11).padding(.top, 16).padding(.bottom, 4)
            ForEach(SettingsView.Tab.allCases, id: \.self) { t in
                navRow(t.title, .settings(t))
            }

            Spacer(minLength: 12)
            OfflineCard()
        }
        .padding(12)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.raised)
        .overlay(alignment: .trailing) { Rectangle().fill(Brand.ink.opacity(0.08)).frame(width: 1) }
    }

    private func navRow(_ title: String, _ item: SidebarItem) -> some View {
        BrandTab(title: title, selected: nav.selection == item) { nav.selection = item }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch nav.selection {
        case .dashboard:
            DashboardView()
        case .history:
            HistoryView()
        case .settings(let tab):
            SettingsView(pipeline: pipeline, models: models, tab: tab)
        }
    }
}
