import SwiftUI
import WhisprBroCore

/// Where the single app window is currently pointed, and whether the Settings
/// pop-up is open. Menu-bar items set these before calling `openWindow`.
@MainActor final class NavModel: ObservableObject {
    static let shared = NavModel()
    @Published var selection: SidebarItem = .home
    @Published var showSettings = false
}

enum SidebarItem: Hashable { case home, insights }

/// The unified app window: a branded sidebar (Home, Insights) + a detail pane.
/// Settings live in a pop-up sheet. Cream `.hiddenTitleBar` chrome.
struct MainWindowView: View {
    @ObservedObject var pipeline: PipelineController
    @ObservedObject private var nav = NavModel.shared

    var body: some View {
        BrandWindow(title: "whispr·bro") {
            HStack(spacing: 0) {
                sidebar
                detail
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .sheet(isPresented: $nav.showSettings) {
            SettingsSheet(pipeline: pipeline)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            BrandTab(title: "Home", selected: nav.selection == .home) { nav.selection = .home }
            BrandTab(title: "Insights", selected: nav.selection == .insights) { nav.selection = .insights }

            Spacer(minLength: 12)

            Button { nav.showSettings = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(Brand.bodyMuted)
                    Text("Settings").font(Brand.sans(13)).foregroundStyle(Brand.bodyMuted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            OfflineCard()
        }
        .padding(12)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.raised)
        .overlay(alignment: .trailing) { Rectangle().fill(Brand.ink.opacity(0.08)).frame(width: 1) }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch nav.selection {
        case .home: HomeView()
        case .insights: InsightsView()
        }
    }
}

/// Settings pop-up: the tab rail + the SettingsView detail pane, in a sheet.
struct SettingsSheet: View {
    @ObservedObject var pipeline: PipelineController
    @StateObject private var models = ModelStatusModel()
    @State private var tab: SettingsView.Tab = .models
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with a close button.
            ZStack {
                HStack(spacing: 8) {
                    EchoWMark(color: Brand.ink).frame(width: 22, height: 15)
                    Text("Settings").font(Brand.sans(13, .semibold)).foregroundStyle(Brand.ink)
                }
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(Brand.mist)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 14)
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Brand.paper)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.ink.opacity(0.08)).frame(height: 1) }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(SettingsView.Tab.allCases, id: \.self) { t in
                        BrandTab(title: t.title, selected: tab == t) { tab = t }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(width: 176)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Brand.raised)
                .overlay(alignment: .trailing) { Rectangle().fill(Brand.ink.opacity(0.08)).frame(width: 1) }

                SettingsView(pipeline: pipeline, models: models, tab: tab)
            }
        }
        .frame(width: 680, height: 560)
        .background(Brand.raised)
        .task { await models.refresh() }
    }
}
