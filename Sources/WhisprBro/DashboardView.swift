import Charts
import SwiftUI
import WhisprBroCore

/// Loads all-time dictation stats for Home + Insights.
@MainActor final class DashboardModel: ObservableObject {
    @Published private(set) var stats = HistoryStats()
    private let store: HistoryStore?
    init(store: HistoryStore? = HistoryStore.shared) { self.store = store }
    func load() {
        let store = store
        Task { self.stats = await store?.stats(since: nil) ?? HistoryStats() }
    }
}

// MARK: - Home (summary + history)

/// The landing page: a compact stat strip over the full History list.
struct HomeView: View {
    @StateObject private var model = DashboardModel()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Home").font(Brand.sans(22, .bold)).foregroundStyle(Brand.ink)
                let s = model.stats
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    StatTile(value: s.totalWords.formatted(), label: "words")
                    StatTile(value: s.dictations.formatted(), label: "dictations")
                    StatTile(value: "\(s.currentStreakDays)", label: "day streak")
                    StatTile(value: s.medianWpm.map { String(Int($0.rounded())) } ?? "—", label: "median WPM")
                }
            }
            .padding(24)
            Divider().overlay(Brand.ink.opacity(0.08))
            HistoryView()   // the full search + table + footer, in-page
        }
        .background(Brand.raised)
        .onAppear { model.load() }
    }
}

// MARK: - Insights (Wispr "Your Usage" style)

struct InsightsView: View {
    @StateObject private var model = DashboardModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Insights").font(Brand.sans(22, .bold)).foregroundStyle(Brand.ink)
                if model.stats.allTimeDictations == 0 {
                    emptyState
                } else {
                    let s = model.stats
                    HStack(alignment: .top, spacing: 14) {
                        WpmCard(wpm: s.medianWpm)
                        FixesCard(cleaned: s.wordsCleanedEst)
                        TotalWordsCard(total: s.totalWords, momPct: momPct)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        DesktopUsageCard(categories: s.perCategory, apps: s.apps)
                        StreakCard(current: s.currentStreakDays, longest: s.longestStreakDays, byDay: s.recentDayWords)
                    }
                    ChartCard(title: "Words over time") { WordsOverTimeChart(perDay: Array(s.perDay.suffix(30))) }
                    ChartCard(title: "Latency · on-device, offline") { LatencyChart(perDay: s.perDay) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.raised)
        .onAppear { model.load() }
    }

    private var momPct: Int? {
        let s = model.stats
        guard s.lastMonthWords > 0 else { return nil }
        return Int((Double(s.thisMonthWords - s.lastMonthWords) / Double(s.lastMonthWords) * 100).rounded())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            EchoWMark(color: Brand.mist).frame(width: 52, height: 34)
            Text("No dictations yet").font(Brand.sans(16, .semibold)).foregroundStyle(Brand.bodyMuted)
            Text("Hold Right ⌥ and speak — your insights show up here.")
                .font(Brand.sans(12)).foregroundStyle(Brand.mist)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

// MARK: - Insights cards

private struct WpmCard: View {
    let wpm: Double?
    var body: some View {
        BrandCard {
            BrandSectionLabel("Words per minute")
            ZStack {
                ArcGauge(fraction: (wpm ?? 0) / 160).frame(height: 88)
                VStack(spacing: 0) {
                    Text(wpm.map { String(Int($0.rounded())) } ?? "—")
                        .font(Brand.mono(26, .semibold)).foregroundStyle(Brand.ink)
                    Text("wpm").font(Brand.mono(9)).foregroundStyle(Brand.mist)
                }
                .offset(y: 12)
            }
            .frame(maxWidth: .infinity)
            Text(wpm == nil ? "after a few dictations" : "vs ~40 wpm typing")
                .font(Brand.mono(9)).foregroundStyle(Brand.metaMuted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct FixesCard: View {
    let cleaned: Int
    var body: some View {
        BrandCard {
            BrandSectionLabel("Cleaned by Auto-Clean")
            Text(cleaned.formatted()).font(Brand.mono(34, .semibold)).foregroundStyle(Brand.ink)
            Rectangle().fill(Brand.ink.opacity(0.08)).frame(height: 1)
            Text("filler + self-correction words removed (est.)")
                .font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TotalWordsCard: View {
    let total: Int
    let momPct: Int?
    private var tweets: Int { max(0, total / 46) }
    var body: some View {
        BrandCard {
            HStack {
                BrandSectionLabel("Total words dictated")
                Spacer()
                if let momPct {
                    Text("\(momPct >= 0 ? "↑" : "↓") \(abs(momPct))% this month")
                        .font(Brand.mono(9, .medium)).foregroundStyle(Brand.bodyMuted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Brand.paper))
                        .overlay(Capsule().strokeBorder(Brand.ink.opacity(0.1), lineWidth: 1))
                }
            }
            Text(total.formatted()).font(Brand.mono(34, .semibold)).foregroundStyle(Brand.ink)
            Rectangle().fill(Brand.ink.opacity(0.08)).frame(height: 1)
            Text("≈ \(tweets.formatted()) tweets' worth").font(Brand.sans(13)).foregroundStyle(Brand.bodyMuted)
        }
    }
}

private struct DesktopUsageCard: View {
    let categories: [HistoryStats.CategoryBucket]
    let apps: Int
    private var total: Int { max(1, categories.reduce(0) { $0 + $1.words }) }
    private var maxWords: Int { max(1, categories.map(\.words).max() ?? 1) }

    var body: some View {
        BrandCard {
            HStack(alignment: .firstTextBaseline) {
                Text("Desktop usage").font(Brand.sans(17, .bold)).foregroundStyle(Brand.ink)
                Spacer()
                Text("APPS USED | \(apps)").font(Brand.mono(10, .medium)).tracking(0.6).foregroundStyle(Brand.mist)
            }
            ForEach(categories) { c in
                let frac = Double(c.words) / Double(maxWords)
                let pct = Int((Double(c.words) / Double(total) * 100).rounded())
                HStack(spacing: 12) {
                    Image(systemName: DashboardView.categoryIcon(c.category))
                        .font(.system(size: 13)).foregroundStyle(Brand.bodyMuted).frame(width: 20)
                    UsageBar(fraction: frac, percent: pct)
                    Text("\(c.dictations) \(DashboardView.categoryLabel(c.category).uppercased())")
                        .font(Brand.mono(10)).foregroundStyle(Brand.bodyMuted).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A horizontal usage bar with the % inside the fill (Wispr "Desktop usage").
private struct UsageBar: View {
    let fraction: Double
    let percent: Int
    var body: some View {
        GeometryReader { geo in
            let w = max(26, fraction * geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.paper)
                Capsule()
                    .fill(Brand.ink.opacity(0.4 + 0.5 * fraction))
                    .frame(width: w)
                Text("\(percent)%")
                    .font(Brand.mono(10, .medium))
                    .foregroundStyle(fraction > 0.22 ? Brand.paper : Brand.bodyMuted)
                    .padding(.leading, fraction > 0.22 ? 12 : w + 8)
            }
        }
        .frame(width: 150, height: 28)
    }
}

private struct StreakCard: View {
    let current: Int
    let longest: Int
    let byDay: [Date: Int]
    var body: some View {
        BrandCard {
            HStack(alignment: .firstTextBaseline) {
                Text("\(current) day streak").font(Brand.sans(17, .bold)).foregroundStyle(Brand.ink)
                Spacer()
                Text("LONGEST | \(longest) DAYS").font(Brand.mono(10, .medium)).tracking(0.6).foregroundStyle(Brand.mist)
            }
            StreakCalendar(byDay: byDay)
        }
    }
}

// MARK: - Streak calendar (GitHub / Wispr style)

private struct StreakCalendar: View {
    let byDay: [Date: Int]
    private let weeks = 18
    private let cell: CGFloat = 13
    private let gap: CGFloat = 3

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)          // 1 = Sun
        let sat = cal.date(byAdding: .day, value: 7 - weekday, to: today)!
        let start = cal.date(byAdding: .day, value: -(weeks * 7 - 1), to: sat)!
        let maxWords = max(1, byDay.values.max() ?? 1)
        let columns = (0..<weeks).map { wk in
            (0..<7).map { row in cal.date(byAdding: .day, value: wk * 7 + row, to: start)! }
        }

        return VStack(alignment: .leading, spacing: 6) {
            // Month labels row.
            HStack(spacing: gap) {
                Spacer().frame(width: 26)
                ForEach(0..<weeks, id: \.self) { wk in
                    Text(monthLabel(columns[wk].first!, previous: wk > 0 ? columns[wk - 1].first! : nil, cal: cal))
                        .font(Brand.mono(8)).foregroundStyle(Brand.mist)
                        .fixedSize().frame(width: cell, alignment: .leading)   // overflow, don't wrap
                }
            }
            HStack(alignment: .top, spacing: gap) {
                // Weekday labels.
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { d in
                        Text(d).font(Brand.mono(8)).foregroundStyle(Brand.mist)
                            .frame(width: 22, height: cell, alignment: .leading)
                    }
                }
                ForEach(0..<weeks, id: \.self) { wk in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            let day = columns[wk][row]
                            cellView(words: day <= today ? (byDay[day] ?? 0) : -1, maxWords: maxWords)
                        }
                    }
                }
            }
            // Legend.
            HStack(spacing: 4) {
                Text("Less").font(Brand.mono(8)).foregroundStyle(Brand.mist)
                ForEach([0.06, 0.3, 0.55, 0.85], id: \.self) { op in
                    RoundedRectangle(cornerRadius: 2).fill(Brand.ink.opacity(op)).frame(width: cell, height: cell)
                }
                Text("More").font(Brand.mono(8)).foregroundStyle(Brand.mist)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func cellView(words: Int, maxWords: Int) -> some View {
        if words < 0 {
            RoundedRectangle(cornerRadius: 2).fill(.clear).frame(width: cell, height: cell)  // future day
        } else {
            let op: Double = {
                if words == 0 { return 0.06 }
                let f = Double(words) / Double(maxWords)
                if f < 0.25 { return 0.3 } else if f < 0.5 { return 0.5 } else if f < 0.75 { return 0.68 } else { return 0.88 }
            }()
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Brand.ink.opacity(op))
                .frame(width: cell, height: cell)
        }
    }

    private func monthLabel(_ day: Date, previous: Date?, cal: Calendar) -> String {
        let m = cal.component(.month, from: day)
        if let previous, cal.component(.month, from: previous) == m { return "" }
        return day.formatted(.dateTime.month(.abbreviated))
    }
}

// MARK: - Charts

private struct WordsOverTimeChart: View {
    let perDay: [HistoryStats.DayBucket]
    var body: some View {
        Chart(perDay) { d in
            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words))
                .foregroundStyle(Brand.ink).cornerRadius(3)
        }
        .frame(height: 150)
        .chartXAxis { brandDateAxis }
        .chartYAxis { brandValueAxis }
    }
}

private struct LatencyChart: View {
    let perDay: [HistoryStats.DayBucket]
    private struct P: Identifiable { let day: Date; let ms: Int; let s: String; var id: String { "\(s)\(day.timeIntervalSince1970)" } }
    var body: some View {
        let points = perDay.flatMap { d -> [P] in
            var out: [P] = []
            if let t = d.medianTotalMs { out.append(.init(day: d.day, ms: t, s: "Total")) }
            if let a = d.medianAsrMs { out.append(.init(day: d.day, ms: a, s: "ASR")) }
            return out
        }
        return Chart(points) { p in
            LineMark(x: .value("Day", p.day, unit: .day), y: .value("ms", p.ms))
                .foregroundStyle(by: .value("Stage", p.s))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartForegroundStyleScale(["Total": Brand.ink, "ASR": Brand.mist])
        .frame(height: 130)
        .chartXAxis { brandDateAxis }
        .chartYAxis { brandValueAxis }
        .chartLegend(position: .top, alignment: .leading)
    }
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

// MARK: - Shared components

/// A semicircular arc gauge (opens downward), filled left→right by `fraction`.
private struct ArcGauge: View {
    let fraction: Double
    var body: some View {
        ZStack {
            ArcShape().stroke(Brand.ink.opacity(0.10), style: .init(lineWidth: 13, lineCap: .round))
            ArcShape().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Brand.ink, style: .init(lineWidth: 13, lineCap: .round))
        }
    }
    private struct ArcShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let r = min(rect.width / 2, rect.height) - 8
            let c = CGPoint(x: rect.midX, y: rect.maxY - 4)
            p.addArc(center: c, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            return p
        }
    }
}

/// A KPI stat tile: big mono number, mono label, optional accent + footnote.
struct StatTile: View {
    let value: String
    let label: String
    var accent: String? = nil
    var footnote: String? = nil
    var body: some View {
        BrandCard {
            Text(value).font(Brand.mono(26, .semibold)).foregroundStyle(Brand.ink)
            HStack(spacing: 6) {
                BrandSectionLabel(label)
                if let accent { Text(accent).font(Brand.mono(9, .medium)).foregroundStyle(Brand.mist) }
            }
            if let footnote { Text(footnote).font(Brand.mono(9)).foregroundStyle(Brand.metaMuted) }
        }
    }
}

/// A titled chart/content container (brand card + mono section label).
struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        BrandCard {
            BrandSectionLabel(title)
            content().padding(.top, 2)
        }
    }
}

enum DashboardView {
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
    static func categoryIcon(_ c: AppCategory) -> String {
        switch c {
        case .messaging: "bubble.left.and.bubble.right"
        case .mail: "envelope"
        case .browser: "globe"
        case .ide: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        case .notes: "note.text"
        case .unknown: "app.dashed"
        }
    }
}
