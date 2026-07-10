import XCTest

@testable import WhisprBroCore

/// Covers the pure `HistoryStore.computeStats` — word counts, apps, streak, WPM,
/// range filtering, month-over-month.
final class HistoryStatsTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var now = cal.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))!

    /// `words` raw words; `cleaned` = words removed (final = words − cleaned).
    private func rec(_ daysAgo: Int, words raw: Int, cleaned: Int = 0,
                     durationMs: Int? = nil, bundle: String? = "com.tinyspeck.slackmacgap") -> HistoryRecord {
        let created = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        return HistoryRecord(
            createdAt: created, appBundleId: bundle, appName: "X",
            rawText: String(repeating: "w ", count: raw),
            formattedText: String(repeating: "w ", count: max(0, raw - cleaned)),
            audioMs: nil, asrMs: 100, formatMs: nil, insertMs: nil, totalMs: 200,
            durationMs: durationMs, language: "en")
    }

    func testHeadlineStats() {
        let records = [
            rec(0, words: 10, cleaned: 2, durationMs: 5000),                       // today: 8 final, 96 wpm
            rec(1, words: 20),                                                     // yesterday
            rec(2, words: 5, cleaned: 1, durationMs: 3000, bundle: "com.apple.mail"), // 2d: 4 final, 80 wpm
            rec(5, words: 7),                                                      // gap at day 3–4
        ]
        let s = HistoryStore.computeStats(records, since: nil, now: now, calendar: cal)
        XCTAssertEqual(s.dictations, 4)
        XCTAssertEqual(s.apps, 2)                    // slack + mail
        XCTAssertEqual(s.totalWords, 8 + 20 + 4 + 7) // final word counts
        XCTAssertEqual(s.wordsCleanedEst, 2 + 0 + 1 + 0)
        XCTAssertEqual(s.currentStreakDays, 3)       // today, −1, −2 then a gap
        XCTAssertEqual(s.perDay.count, 4)            // four distinct days
        XCTAssertEqual(s.medianWpm ?? 0, 88, accuracy: 0.5) // median of {96, 80}
        XCTAssertEqual(s.perDay.map(\.day), s.perDay.map(\.day).sorted()) // ascending
    }

    func testStreakCountsFromYesterdayWhenNoneToday() {
        let records = [rec(1, words: 5), rec(2, words: 5)]   // none today
        let s = HistoryStore.computeStats(records, since: nil, now: now, calendar: cal)
        XCTAssertEqual(s.currentStreakDays, 2)
    }

    func testRangeFiltersTilesButNotStreak() {
        let records = [rec(0, words: 10), rec(20, words: 100)] // one recent, one old
        let since = cal.date(byAdding: .day, value: -7, to: now)!
        let s = HistoryStore.computeStats(records, since: since, now: now, calendar: cal)
        XCTAssertEqual(s.dictations, 1)   // only the in-range one
        XCTAssertEqual(s.totalWords, 10)
        XCTAssertEqual(s.currentStreakDays, 1) // streak uses ALL history (today present)
    }

    func testEmptyIsZeroed() {
        let s = HistoryStore.computeStats([], since: nil, now: now, calendar: cal)
        XCTAssertEqual(s.dictations, 0)
        XCTAssertEqual(s.totalWords, 0)
        XCTAssertEqual(s.currentStreakDays, 0)
        XCTAssertNil(s.medianWpm)
        XCTAssertTrue(s.perDay.isEmpty)
    }
}
