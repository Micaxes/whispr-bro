import CoreGraphics
import Foundation

/// Whether the app's own menu-bar icon can be seen, decided from geometry alone.
///
/// Nothing in the app's own process can tell: `NSStatusItem.isVisible` stays
/// true when the bar is full, and on macOS 26 an item hidden behind the notch
/// has no window at all. What the accessibility tree still reports is where
/// the item WOULD sit, and that is enough: a notched display hides any status
/// item that would overlap the camera housing. Measured on a 1512-pt built-in
/// display with the housing at x 663-848: the item's frame was x 843 (w 44)
/// while hidden and x 914 while visible.
///
/// Pure on purpose — the live inputs (the AX frame, `NSScreen`) are glue in the
/// app; every rule worth getting wrong is here, where `swift test` reaches it.
public enum StatusItemVisibility: Equatable, Sendable {
    case visible
    /// The item overlaps the camera housing, or sits left of it. Status items
    /// live to the right of the housing; anything that does not fit there is
    /// dropped, and its frame keeps counting leftward, across and past the notch.
    case behindNotch
    /// The item lies outside every display (a menu bar too full on a display
    /// with no notch, or a display that went away).
    case offscreen
    /// No usable frame to judge by: no item reported, zero size, no displays.
    /// Never a reason to say anything.
    case unknown

    public var isHidden: Bool { self == .behindNotch || self == .offscreen }
}

/// One display, in the space the accessibility tree reports status items in:
/// global, origin at the top-left of the primary display, y growing DOWNWARD.
public struct MenuBarDisplay: Equatable, Sendable {
    public var frame: CGRect
    /// Where the camera housing sits along the top edge, in the same space.
    /// nil on a display without one.
    public var notch: ClosedRange<CGFloat>?

    public init(frame: CGRect, notch: ClosedRange<CGFloat>? = nil) {
        self.frame = frame
        self.notch = notch
    }

    /// From what `NSScreen` reports, as plain numbers (Core does not import
    /// AppKit): `appKitFrame` is its `frame` (origin at the BOTTOM-left of the
    /// primary display, y up); `primaryHeight` is the primary display's height,
    /// which is the flip into the accessibility space; the two widths are those
    /// of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, nil without a notch.
    ///
    /// The notch is the gap between the two areas, taken from their WIDTHS
    /// measured in from the display's own edges, so the answer does not depend
    /// on whether AppKit reports those rects in global or display-local
    /// coordinates.
    public init(appKitFrame: CGRect, primaryHeight: CGFloat,
                auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?) {
        frame = CGRect(x: appKitFrame.minX, y: primaryHeight - appKitFrame.maxY,
                       width: appKitFrame.width, height: appKitFrame.height)
        if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth,
           left > 0, right > 0, left + right < appKitFrame.width {
            notch = (appKitFrame.minX + left)...(appKitFrame.maxX - right)
        } else {
            notch = nil
        }
    }
}

public enum StatusItemGeometry {
    /// The accessibility tree reports a status item about 1pt wider than the
    /// slot it occupies, on each side (measured: a slot at 844-886 reads as
    /// 843-887). An item that merely TOUCHES the housing therefore overlaps it
    /// by 1pt in the tree and is visible; the smallest real overlap reads as 2.
    public static let overlapTolerance: CGFloat = 1

    /// An auto-hidden menu bar parks its items just above the display's top
    /// edge. That is not "off screen"; this much headroom still counts as the
    /// display.
    public static let hiddenBarSlack: CGFloat = 64

    /// `item` is the app's status item frame from the accessibility tree
    /// (global, top-left origin); nil when the tree had none.
    public static func visibility(of item: CGRect?, on displays: [MenuBarDisplay]) -> StatusItemVisibility {
        // `size`, not `width`/`height`: those standardize a negative size into a
        // plausible rectangle, and a negative size from the tree is garbage.
        guard let item, !item.isNull, !item.isInfinite,
              item.size.width > 0, item.size.height > 0,
              item.minX.isFinite, item.minY.isFinite,
              !displays.isEmpty
        else { return .unknown }

        // Whose menu bar is it on? The display holding the item's centre.
        let centre = CGPoint(x: item.midX, y: item.midY)
        guard let display = displays.first(where: { $0.menuBarRegion.contains(centre) })
        else { return .offscreen }

        if let notch = display.notch, item.minX < notch.upperBound - overlapTolerance {
            return .behindNotch
        }
        return .visible
    }
}

extension MenuBarDisplay {
    /// The display plus the headroom an auto-hidden menu bar parks items in.
    fileprivate var menuBarRegion: CGRect {
        CGRect(x: frame.minX, y: frame.minY - StatusItemGeometry.hiddenBarSlack,
               width: frame.width, height: frame.height + StatusItemGeometry.hiddenBarSlack)
    }
}

/// "At most once per calendar day" for a notice that must not nag.
public enum DailyNotice {
    /// Due when it was never shown, or last shown on an earlier (or later —
    /// the clock was moved) calendar day. Same-day is never due, however late
    /// in that day it was shown.
    public static func isDue(lastShown: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastShown else { return true }
        return !calendar.isDate(lastShown, inSameDayAs: now)
    }
}

/// What to say when the icon is hidden, and how often. The wording lives in
/// Core, like `DictationGesture.exitHint`, so the HUD line and the window banner
/// cannot drift apart — and so a test can hold the HUD line to what the pebble fits.
public enum MenuBarNotice {
    /// The HUD pebble wraps to two lines of 18 monospaced characters. It is
    /// click-through: it cannot carry a button, and with the icon hidden there
    /// is no menu to point at. What it can do is name the one way in that is
    /// left — opening the app again opens its window — and that window carries
    /// the banner, which says why and how to fix it.
    public static let hudLineWidth = 18

    /// nil unless the icon is actually hidden. Hidden is hidden: the line does
    /// not care whether it is behind the notch or off screen, the banner does.
    public static func hudLine(for visibility: StatusItemVisibility) -> String? {
        visibility.isHidden ? "Icon hidden: open whispr-bro again" : nil
    }

    /// The pebble says it this many times in all, then never again. Once a day
    /// is still a nag when he has decided to live with it (the hotkey works
    /// without the icon), and the hidden state comes and goes with whatever
    /// else is running, so "per episode" would be no better.
    public static let hudLimit = 3

    /// What the pebble has said so far, and so whether it may speak now: at
    /// most `hudLimit` times, at most once a calendar day, and not at all once
    /// he has seen the banner — the banner is the explanation the pebble only
    /// points at, so it has nothing left to add.
    public struct History: Equatable, Sendable {
        public private(set) var timesShown: Int
        public private(set) var lastShown: Date?

        public init(timesShown: Int = 0, lastShown: Date? = nil) {
            self.timesShown = timesShown
            self.lastShown = lastShown
        }

        public func isDue(now: Date, calendar: Calendar = .current) -> Bool {
            timesShown < MenuBarNotice.hudLimit
                && DailyNotice.isDue(lastShown: lastShown, now: now, calendar: calendar)
        }

        public mutating func recordShown(at now: Date) {
            timesShown += 1
            lastShown = now
        }

        public mutating func recordBannerSeen() {
            timesShown = max(timesShown, MenuBarNotice.hudLimit)
        }
    }

    public static let bannerTitle = "Menu bar is full"
    public static let bannerAction = "Open Menu Bar settings"

    /// nil unless the icon is actually hidden.
    public static func bannerDetail(for visibility: StatusItemVisibility) -> String? {
        switch visibility {
        case .behindNotch:
            "whispr-bro's icon is behind the notch. Turn a few icons off in System Settings › Menu Bar."
        case .offscreen:
            "whispr-bro's icon is off screen. Turn a few icons off in System Settings › Menu Bar."
        case .visible, .unknown: nil
        }
    }
}
