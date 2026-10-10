import XCTest

@testable import WhisprBroCore

/// The geometry behind "your menu-bar icon is hidden behind the notch".
///
/// The numbers are the ones measured on the 14" built-in display this was
/// written on: 1512 x 982, camera housing at x 663-848, a 24pt-tall item row.
/// The status item read x 843 (w 44) while hidden and x 914 while visible; the
/// accessibility frame runs 1pt wider than the slot on each side.
final class StatusItemVisibilityTests: XCTestCase {

    private let builtIn = MenuBarDisplay(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notch: 663...848)

    private func item(x: CGFloat, w: CGFloat = 44, y: CGFloat = 0, h: CGFloat = 24) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func verdict(_ frame: CGRect?, _ displays: [MenuBarDisplay]? = nil) -> StatusItemVisibility {
        StatusItemGeometry.visibility(of: frame, on: displays ?? [builtIn])
    }

    // MARK: the notch

    /// The case that started this: 5pt of the item inside the housing's right
    /// edge. macOS hid it.
    func testItemOverlappingTheNotchIsHidden() {
        XCTAssertEqual(verdict(item(x: 843)), .behindNotch)
    }

    func testItemFullyRightOfTheNotchIsVisible() {
        XCTAssertEqual(verdict(item(x: 914)), .visible)
        XCTAssertEqual(verdict(item(x: 1400)), .visible)
    }

    /// Other items ahead of it in the bar push it deeper; its frame keeps
    /// counting leftward, entirely inside the housing.
    func testItemEntirelyInsideTheNotchIsHidden() {
        XCTAssertEqual(verdict(item(x: 803, w: 42)), .behindNotch)
        XCTAssertEqual(verdict(item(x: 700, w: 44)), .behindNotch)
    }

    /// Far enough back it clears the housing's left edge — under the app menus,
    /// where status items never are. Still hidden, not "visible by a technicality".
    func testItemFullyLeftOfTheNotchIsHidden() {
        XCTAssertEqual(verdict(item(x: 600, w: 44)), .behindNotch)
        XCTAssertEqual(verdict(item(x: 10, w: 44)), .behindNotch)
    }

    /// Touching the housing is not overlapping it: the tree pads the slot by
    /// 1pt a side, so a slot starting exactly at 848 reads as x 847.
    func testTouchingTheNotchIsVisibleAndTheSmallestRealOverlapIsNot() {
        XCTAssertEqual(verdict(item(x: 848)), .visible)
        XCTAssertEqual(verdict(item(x: 847)), .visible, "1pt of padding, not an overlap")
        XCTAssertEqual(verdict(item(x: 846)), .behindNotch, "2pt in the tree is 1pt of real overlap")
    }

    // MARK: no notch

    func testAnyOnScreenItemIsVisibleWithoutANotch() {
        let plain = MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // The same x that is hidden on the built-in display.
        XCTAssertEqual(verdict(item(x: 843), [plain]), .visible)
        XCTAssertEqual(verdict(item(x: 0), [plain]), .visible)
        XCTAssertEqual(verdict(item(x: 1876), [plain]), .visible)
    }

    func testAnItemOutsideEveryDisplayIsOffscreen() {
        let plain = MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(verdict(item(x: -80, w: 44), [plain]), .offscreen)
        XCTAssertEqual(verdict(item(x: 1930, w: 44), [plain]), .offscreen)
        XCTAssertEqual(verdict(item(x: 100, y: 1200), [plain]), .offscreen)
    }

    /// An auto-hidden bar parks its items just above the top edge. Not off screen.
    func testAnAutoHiddenBarIsNotOffscreen() {
        XCTAssertEqual(verdict(item(x: 914, y: -30)), .visible)
        XCTAssertEqual(verdict(item(x: 843, y: -30)), .behindNotch, "the notch rule still applies")
        XCTAssertEqual(verdict(item(x: 914, y: -400)), .offscreen, "but not 400pt above it")
    }

    // MARK: more than one display

    /// An external display stacked above the built-in one (global y runs
    /// downward, so it is at negative y).
    private var stacked: [MenuBarDisplay] {
        [builtIn, MenuBarDisplay(frame: CGRect(x: -500, y: -1440, width: 2560, height: 1440))]
    }

    func testTheNotchOnlyHidesItemsOnTheDisplayThatHasIt() {
        // x 700 is inside the housing on the built-in display …
        XCTAssertEqual(verdict(item(x: 700, y: 0), stacked), .behindNotch)
        // … and nothing special on the external display above it.
        XCTAssertEqual(verdict(item(x: 700, y: -1440), stacked), .visible)
    }

    func testSideBySideDisplaysPickTheOneUnderTheItem() {
        let right = MenuBarDisplay(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(verdict(item(x: 2400), [builtIn, right]), .visible)
        XCTAssertEqual(verdict(item(x: 843), [builtIn, right]), .behindNotch)
        // Display order does not matter.
        XCTAssertEqual(verdict(item(x: 843), [right, builtIn]), .behindNotch)
    }

    func testAnItemInTheGapBetweenDisplaysIsOffscreen() {
        let right = MenuBarDisplay(frame: CGRect(x: 1700, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(verdict(item(x: 1580, w: 44), [builtIn, right]), .offscreen)
    }

    // MARK: no frame, no verdict

    func testNoUsableFrameIsUnknownNeverHidden() {
        XCTAssertEqual(verdict(nil), .unknown, "the tree reported no item")
        XCTAssertEqual(verdict(CGRect(x: 843, y: 0, width: 0, height: 24)), .unknown)
        XCTAssertEqual(verdict(CGRect(x: 843, y: 0, width: 44, height: 0)), .unknown)
        XCTAssertEqual(verdict(.zero), .unknown, "the (0,0,0,0) rows the tree gives items it has not laid out")
        XCTAssertEqual(verdict(CGRect(x: 843, y: 0, width: -44, height: 24)), .unknown)
        XCTAssertEqual(verdict(.null), .unknown)
        XCTAssertEqual(verdict(.infinite), .unknown)
        XCTAssertEqual(verdict(CGRect(x: CGFloat.nan, y: 0, width: 44, height: 24)), .unknown)
        XCTAssertEqual(verdict(item(x: 843), []), .unknown, "no displays to judge against")
    }

    func testOnlyAHiddenVerdictIsHidden() {
        XCTAssertTrue(StatusItemVisibility.behindNotch.isHidden)
        XCTAssertTrue(StatusItemVisibility.offscreen.isHidden)
        XCTAssertFalse(StatusItemVisibility.visible.isHidden)
        XCTAssertFalse(StatusItemVisibility.unknown.isHidden)
    }

    // MARK: building a display from NSScreen's numbers

    func testDisplayFromAppKitValuesFlipsAndFindsTheNotch() {
        // The measured built-in display: aux areas 663 and 664 wide.
        let d = MenuBarDisplay(
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), primaryHeight: 982,
            auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664)
        XCTAssertEqual(d, builtIn)
    }

    func testDisplayAboveThePrimaryFlipsToNegativeY() {
        // AppKit: bottom-left origin, y up. 982 is the primary's height, so a
        // 1440-tall display sitting on top of it spans y 982-2422.
        let d = MenuBarDisplay(
            appKitFrame: CGRect(x: -500, y: 982, width: 2560, height: 1440), primaryHeight: 982,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil)
        XCTAssertEqual(d.frame, CGRect(x: -500, y: -1440, width: 2560, height: 1440))
        XCTAssertNil(d.notch)
    }

    func testTheNotchIsMeasuredFromTheDisplaysOwnEdges() {
        // A notched display that is not at x 0: same widths, same gap, shifted.
        let d = MenuBarDisplay(
            appKitFrame: CGRect(x: 1512, y: 0, width: 1512, height: 982), primaryHeight: 982,
            auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664)
        XCTAssertEqual(d.notch, (1512 + 663)...(3024 - 664))
    }

    func testHalfAnAuxiliaryPairOrNonsenseIsNoNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func notch(_ l: CGFloat?, _ r: CGFloat?) -> ClosedRange<CGFloat>? {
            MenuBarDisplay(appKitFrame: frame, primaryHeight: 982,
                           auxiliaryLeftWidth: l, auxiliaryRightWidth: r).notch
        }
        XCTAssertNil(notch(663, nil))
        XCTAssertNil(notch(nil, 664))
        XCTAssertNil(notch(0, 0))
        XCTAssertNil(notch(900, 900), "the areas would overlap — not a notch")
    }

    // MARK: once a day

    func testDailyNoticeIsDueOncePerCalendarDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }

        XCTAssertTrue(DailyNotice.isDue(lastShown: nil, now: at(2026, 10, 7, 9), calendar: cal))
        // Same day, however far apart.
        XCTAssertFalse(DailyNotice.isDue(lastShown: at(2026, 10, 7, 0, 1), now: at(2026, 10, 7, 23, 59), calendar: cal))
        XCTAssertFalse(DailyNotice.isDue(lastShown: at(2026, 10, 7, 9), now: at(2026, 10, 7, 9, 1), calendar: cal))
        // Next calendar day, even a minute later.
        XCTAssertTrue(DailyNotice.isDue(lastShown: at(2026, 10, 7, 23, 59), now: at(2026, 10, 8, 0, 1), calendar: cal))
        XCTAssertTrue(DailyNotice.isDue(lastShown: at(2026, 10, 7, 9), now: at(2026, 10, 9, 9), calendar: cal))
        // The day the clocks go back has 25 hours; still one notice.
        XCTAssertFalse(DailyNotice.isDue(lastShown: at(2026, 11, 1, 0, 30), now: at(2026, 11, 1, 23, 30), calendar: cal))
        // A clock moved backwards (last shown "tomorrow") is a different day: due.
        XCTAssertTrue(DailyNotice.isDue(lastShown: at(2026, 10, 8, 9), now: at(2026, 10, 7, 9), calendar: cal))
    }

    // MARK: how often it says it

    private var la: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return cal
    }

    private func day(_ d: Int, _ h: Int = 9) -> Date {
        la.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))!
    }

    /// The pebble is for telling him, not for reminding him: a few days, then it
    /// stops, even though the icon may well still be hidden. (Once a day with no
    /// end is a nag when he has chosen to live with it — the hotkey needs no icon.)
    func testThePebbleStopsAfterTheLimitEvenWithTheIconStillHidden() {
        XCTAssertEqual(MenuBarNotice.hudLimit, 3)
        var h = MenuBarNotice.History()
        for d in 7...9 {
            XCTAssertTrue(h.isDue(now: day(d), calendar: la), "notice #\(d - 6) on day \(d)")
            h.recordShown(at: day(d))
        }
        XCTAssertEqual(h.timesShown, 3)
        XCTAssertFalse(h.isDue(now: day(10), calendar: la), "three is enough")
        XCTAssertFalse(h.isDue(now: day(30), calendar: la), "a month on, still not")
    }

    /// The cap does not loosen the daily rule: still once per calendar day.
    func testWithinTheLimitItIsStillOncePerCalendarDay() {
        var h = MenuBarNotice.History()
        XCTAssertTrue(h.isDue(now: day(7, 9), calendar: la), "never shown")
        h.recordShown(at: day(7, 9))
        XCTAssertFalse(h.isDue(now: day(7, 23), calendar: la), "later the same day")
        XCTAssertTrue(h.isDue(now: day(8, 0), calendar: la), "the next calendar day, even an hour past midnight")
        h.recordShown(at: day(8, 0))
        XCTAssertFalse(h.isDue(now: day(8, 23), calendar: la))
    }

    /// Seeing the banner is what the pebble was for, so it silences the pebble
    /// from then on, whether or not the pebble ever spoke.
    func testSeeingTheBannerSilencesThePebbleFromThenOn() {
        var fresh = MenuBarNotice.History()
        fresh.recordBannerSeen()
        XCTAssertFalse(fresh.isDue(now: day(7), calendar: la), "never shown by the pebble, but he has read the banner")
        XCTAssertFalse(fresh.isDue(now: day(30), calendar: la))

        var mid = MenuBarNotice.History()
        mid.recordShown(at: day(7))
        mid.recordBannerSeen()
        XCTAssertFalse(mid.isDue(now: day(9), calendar: la))
    }

    /// Seeing the banner never lowers a count that is already past the limit.
    func testSeeingTheBannerNeverLowersTheCount() {
        var h = MenuBarNotice.History(timesShown: 40, lastShown: nil)
        h.recordBannerSeen()
        XCTAssertEqual(h.timesShown, 40)
        XCTAssertFalse(h.isDue(now: day(7), calendar: la))
    }

    /// Nothing recorded (a fresh install, or defaults wiped) is a pebble that has
    /// not spoken yet.
    func testAnEmptyHistoryIsDue() {
        XCTAssertTrue(MenuBarNotice.History().isDue(now: day(7), calendar: la))
        XCTAssertEqual(MenuBarNotice.History(), MenuBarNotice.History(timesShown: 0, lastShown: nil))
    }

    // MARK: what it says

    func testNoticeTextExistsOnlyWhileHidden() {
        for v in [StatusItemVisibility.visible, .unknown] {
            XCTAssertNil(MenuBarNotice.hudLine(for: v))
            XCTAssertNil(MenuBarNotice.bannerDetail(for: v))
        }
        for v in [StatusItemVisibility.behindNotch, .offscreen] {
            XCTAssertNotNil(MenuBarNotice.hudLine(for: v))
            XCTAssertNotNil(MenuBarNotice.bannerDetail(for: v))
        }
    }

    /// The pebble is click-through and the menu is out of reach, so the line has
    /// to say the one thing he can do: open the app again. The window that opens
    /// carries the banner with the fix. (The first version only named the
    /// problem — "Menu bar is full — icon behind notch" — and left him as stuck
    /// as before.)
    func testTheHudLinePointsAtTheWayIn() {
        for v in [StatusItemVisibility.behindNotch, .offscreen] {
            let line = MenuBarNotice.hudLine(for: v)!
            XCTAssertTrue(line.localizedCaseInsensitiveContains("open whispr-bro"), "\"\(line)\" names no way in")
        }
        XCTAssertEqual(MenuBarNotice.hudLine(for: .behindNotch), MenuBarNotice.hudLine(for: .offscreen),
                       "the pebble can't tell the two apart usefully; the banner does")
    }

    /// The pebble wraps at word boundaries to two lines of 18 monospaced
    /// characters; a third line is truncated with "…". Hold the wording to that.
    func testTheHudLineFitsThePebble() {
        for v in [StatusItemVisibility.behindNotch, .offscreen] {
            let line = MenuBarNotice.hudLine(for: v)!
            let lines = wrap(line, width: MenuBarNotice.hudLineWidth)
            XCTAssertLessThanOrEqual(lines.count, 2, "\"\(line)\" wraps to \(lines)")
            XCTAssertTrue(lines.allSatisfy { $0.count <= MenuBarNotice.hudLineWidth }, "\(lines)")
        }
    }

    /// Greedy word wrap, as SwiftUI's Text does for a fixed-pitch font.
    private func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty { current = String(word) }
            else if current.count + 1 + word.count <= width { current += " " + word }
            else { lines.append(current); current = String(word) }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
