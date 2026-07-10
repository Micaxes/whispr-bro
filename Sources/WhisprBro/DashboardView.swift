import Charts
import SwiftUI
import WhisprBroCore

/// Loads dashboard stats for a selected time range (off the main thread).
@MainActor final class DashboardModel: ObservableObject {
    @Published private(set) var stats = HistoryStats()
    @Published private(set) var range: TimeRange = .month
    private let store: HistoryStore?

    init(store: HistoryStore? = HistoryStore.shared) { self.store = store }

    enum TimeRange: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", all = "All time"
        var id: String { rawValue }
        var since: Date? {
            switch self {
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }
    }

    func load() {
        let store = store, since = range.since
        Task { self.stats = await store?.stats(since: since) ?? HistoryStats() }
    }
    func select(_ r: TimeRange) { range = r; load() }
}

struct DashboardView: View {
    @StateObject private var model = DashboardModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.stats.allTimeDictations == 0 {
                    emptyState
                } else {
                    tiles
                    ChartCard(title: "Words over time") { wordsOverTime }
                    HStack(alignment: .top, spacing: 14) {
                        ChartCard(title: "Where you flow") { appUsage }
                        ChartCard(title: "Activity") { streakHeatmap }
                    }
                    ChartCard(title: "Latency · on-device, offline") { latencyTrend }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.raised)
        .onAppear { model.load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Dashboard").font(Brand.sans(22, .bold)).foregroundStyle(Brand.ink)
            Spacer()
            HStack(spacing: 6) {
                ForEach(DashboardModel.TimeRange.allCases) { r in
                    let on = model.range == r
                    Button(r.rawValue) { model.select(r) }
                        .buttonStyle(.plain)
                        .font(Brand.mono(11, .medium))
                        .foregroundStyle(on ? Brand.paper : Brand.bodyMuted)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(on ? Brand.ink : Brand.raised))
                        .overlay(Capsule().strokeBorder(Brand.ink.opacity(on ? 0 : 0.12), lineWidth: 1))
                }
            }
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let s = model.stats
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            StatTile(value: s.totalWords.formatted(), label: "words dictated", accent: momDelta)
            StatTile(value: s.dictations.formatted(), label: "dictations")
            StatTile(value: "\(s.apps)", label: s.apps == 1 ? "app" : "apps")
            StatTile(value: "\(s.currentStreakDays)", label: "day streak")
            StatTile(value: s.wordsCleanedEst.formatted(), label: "words cleaned (est.)")
            StatTile(value: s.medianWpm.map { String(Int($0.rounded())) } ?? "—",
                     label: "median WPM",
                     footnote: s.medianWpm == nil ? "after new dictations" : "vs ~40 typing")
        }
    }

    private var momDelta: String? {
        let s = model.stats
        guard s.lastMonthWords > 0 else { return nil }
        let pct = Int((Double(s.thisMonthWords - s.lastMonthWords) / Double(s.lastMonthWords) * 100).rounded())
        return (pct >= 0 ? "+\(pct)%" : "\(pct)%") + " vs last mo"
    }

    // MARK: Charts

    private var wordsOverTime: some View {
        Chart(model.stats.perDay) { d in
            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words))
                .foregroundStyle(Brand.ink)
                .cornerRadius(3)
        }
        .frame(height: 150)
        .chartXAxis { brandDateAxis }
        .chartYAxis { brandValueAxis }
    }

    private var appUsage: some View {
        let cats = model.stats.perCategory
        return Chart(cats) { c in
            BarMark(x: .value("Words", c.words), y: .value("App", Self.categoryLabel(c.category)))
                .foregroundStyle(Brand.ink)
                .cornerRadius(3)
        }
        .chartYScale(domain: cats.map { Self.categoryLabel($0.category) }.reversed())
        .frame(height: max(90, CGFloat(cats.count) * 34))
        .chartXAxis { brandValueAxis }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel().font(Brand.sans(11)).foregroundStyle(Brand.bodyMuted)
            }
        }
    }

    private var latencyTrend: some View {
        let points = model.stats.perDay.flatMap { d -> [LatencyPoint] in
            var out: [LatencyPoint] = []
            if let t = d.medianTotalMs { out.append(.init(day: d.day, ms: t, series: "Total")) }
            if let a = d.medianAsrMs { out.append(.init(day: d.day, ms: a, series: "ASR")) }
            return out
        }
        return Chart(points) { p in
            LineMark(x: .value("Day", p.day, unit: .day), y: .value("ms", p.ms))
                .foregroundStyle(by: .value("Stage", p.series))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartForegroundStyleScale(["Total": Brand.ink, "ASR": Brand.mist])
        .frame(height: 130)
        .chartXAxis { brandDateAxis }
        .chartYAxis { brandValueAxis }
        .chartLegend(position: .top, alignment: .leading)
    }

    private struct LatencyPoint: Identifiable {
        let day: Date; let ms: Int; let series: String
        var id: String { "\(series)-\(day.timeIntervalSince1970)" }
    }

    private var brandDateAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
            AxisGridLine().foregroundStyle(Brand.ink.opacity(0.05))
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                .font(Brand.mono(9)).foregroundStyle(Brand.mist)
        }
    }
    private var brandValueAxis: some AxisContent {
        AxisMarks { _ in
            AxisGridLine().foregroundStyle(Brand.ink.opacity(0.05))
            AxisValueLabel().font(Brand.mono(9)).foregroundStyle(Brand.mist)
        }
    }

    // MARK: Streak heatmap (GitHub-style, last 12 weeks)

    private var streakHeatmap: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let days = (0..<84).compactMap { Calendar.current.date(byAdding: .day, value: -83 + $0, to: today) }
        let byDay = model.stats.recentDayWords
        let maxWords = max(1, byDay.values.max() ?? 1)
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return HStack(alignment: .top, spacing: 3) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 3) {
                    ForEach(week, id: \.self) { day in
                        let words = byDay[day] ?? 0
                        let level = words == 0 ? 0.05 : 0.28 + 0.72 * Double(words) / Double(maxWords)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Brand.paper)
                            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Brand.ink.opacity(level)))
                            .frame(width: 11, height: 11)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            EchoWMark(color: Brand.mist).frame(width: 52, height: 34)
            Text("No dictations yet").font(Brand.sans(16, .semibold)).foregroundStyle(Brand.bodyMuted)
            Text("Hold Right ⌥ and speak — your stats show up here.")
                .font(Brand.sans(12)).foregroundStyle(Brand.mist)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    static func categoryLabel(_ c: AppCategory) -> String {
        switch c {
        case .messaging: "Messaging"
        case .mail: "Mail"
        case .browser: "Browser"
        case .ide: "Code"
        case .terminal: "Terminal"
        case .notes: "Notes"
        case .unknown: "Other"
        }
    }
}

/// A KPI stat tile: big mono number, mono label, optional accent chip / footnote.
private struct StatTile: View {
    let value: String
    let label: String
    var accent: String? = nil
    var footnote: String? = nil

    var body: some View {
        BrandCard {
            Text(value).font(Brand.mono(28, .semibold)).foregroundStyle(Brand.ink)
            HStack(spacing: 6) {
                BrandSectionLabel(label)
                if let accent {
                    Text(accent).font(Brand.mono(9, .medium)).foregroundStyle(Brand.mist)
                }
            }
            if let footnote {
                Text(footnote).font(Brand.mono(9)).foregroundStyle(Brand.metaMuted)
            }
        }
    }
}

/// A titled chart container (brand card + mono section label).
private struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        BrandCard {
            BrandSectionLabel(title)
            content().padding(.top, 2)
        }
    }
}
