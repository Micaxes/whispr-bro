import AppKit
import SwiftUI
import WhisprBroCore

/// Knows whether the menu-bar icon can actually be seen, and says so when it
/// can't. On a notched Mac a full menu bar silently drops whatever does not fit
/// to the right of the camera housing — measured here by 4pt — and nothing in the
/// app's own process can tell (`NSStatusItem.isVisible` stays true), so without
/// this he just sees the icon "disappear" and has no way back into the app.
///
/// The decision is `StatusItemGeometry` (Core, tested); this is the glue: where
/// the item is (its own accessibility frame, read on the main thread), where
/// the displays are, and when to look. Never on a timer. The icon moves when
/// the bar's contents change, and the bar's contents change with the clock and
/// with other apps coming and going — so: shortly after launch, after a display
/// change, after each dictation (he dictates all day), when he comes back to
/// the app (he may just have fixed the bar from the banner's own button, in
/// System Settings), and when the window opens. Each is one in-process
/// accessibility query.
///
/// What it says: one line on the HUD, once a day, only in a quiet moment (see
/// `PipelineController.announce`), three times at most and not at all once he
/// has seen the banner (`MenuBarNotice.History`); and a banner in the main window
/// for as long as the icon stays hidden, so reopening the app (the app opens
/// its window when launched again) explains itself.
@MainActor
final class MenuBarWatch: ObservableObject {
    static let shared = MenuBarWatch()
    private init() {}

    @Published private(set) var visibility: StatusItemVisibility = .unknown

    /// Where the icon's frame comes from: the accessibility tree, read on the main
    /// thread (see `AXStatusItem`). A stub in a probe.
    var frameSource: @MainActor () -> CGRect? = { AXStatusItem.frame() }

    private weak var pipeline: PipelineController?
    private let defaults = UserDefaults.standard
    private let lastNoticeKey = "menuBarNoticeLastShown"
    private let countKey = "menuBarNoticeCount"
    private var scheduled: Task<Void, Never>?
    private var hasLooked = false
    private var observers: [NSObjectProtocol] = []

    func startup(pipeline: PipelineController) {
        self.pipeline = pipeline
        // Past the insertion, so the notice never lands on top of the HUD that
        // is still showing the dictation.
        pipeline.onDictationFinished = { [weak self] in self?.check(after: 1.5) }
        // Displays coming and going re-lay the bar out a moment later, and the
        // notification can fire in bursts: let it settle, then look once.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.check(after: 2) }
        })
        // Back in the app: from System Settings, where the banner's button sent
        // him to make room. The window is already open, so nothing else would
        // look, and the banner would go on saying the icon is hidden while he
        // can see it. Not before the first look, though: launching the app by
        // hand activates it, and that must not cut the launch delay short.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasLooked else { return }
                self.check(after: 0.5)
            }
        })
        check(after: 5)   // let the status item settle into its slot first
    }

    /// Look again, `delay` seconds from now. Looks coalesce: a newer request
    /// replaces one still waiting.
    func check(after delay: TimeInterval = 0) {
        scheduled?.cancel()
        scheduled = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    /// Look now. The answer is in when this returns, for a caller that must not
    /// act on an older one (the banner: see `MenuBarBannerSlot`). A look still
    /// waiting its turn is left alone: it was asked for at a better moment, such
    /// as after the status item has settled.
    ///
    /// On the main thread, where AppKit answers for this process's own
    /// accessibility tree: no IPC, milliseconds (see `AXStatusItem`). Nothing is
    /// awaited, so two looks can never overlap.
    ///
    /// `announce: false` for the window's own look: it runs before the window is
    /// ordered in, so the window guard in `announceIfDue` can't see it yet, and
    /// the banner it feeds already says what the pebble would.
    func refresh(announce: Bool = true) {
        apply(frameSource(), announce: announce)
    }

    /// The banner is on screen: he has the explanation and the way to fix it, so
    /// the pebble has nothing left to add.
    func bannerSeen() {
        var h = history
        h.recordBannerSeen()
        history = h
    }

    func openMenuBarSettings() {
        // The Control Center settings extension. On macOS 26 that is the "Menu
        // Bar" pane (checked: opening it from Displays lands on "Menu Bar"); on
        // 14 and 15 it is the Control Center pane, where the same switches live.
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func apply(_ frame: CGRect?, announce: Bool) {
        hasLooked = true
        visibility = StatusItemGeometry.visibility(of: frame, on: Self.displays())
        if announce { announceIfDue() }
    }

    private func announceIfDue() {
        // With the window up, the banner is already saying it.
        guard let line = MenuBarNotice.hudLine(for: visibility), let pipeline,
              !ActivationPolicy.hasStandardWindow else { return }
        var h = history
        guard h.isDue(now: Date()) else { return }
        // Counted only if it was actually shown: a dictation in flight, or a
        // toast still up, means the next look gets to try again.
        if pipeline.announce(line) {
            h.recordShown(at: Date())
            history = h
        }
    }

    private var history: MenuBarNotice.History {
        get {
            MenuBarNotice.History(timesShown: defaults.integer(forKey: countKey),
                                  lastShown: defaults.object(forKey: lastNoticeKey) as? Date)
        }
        set {
            defaults.set(newValue.timesShown, forKey: countKey)
            defaults.set(newValue.lastShown, forKey: lastNoticeKey)
        }
    }

    /// The displays as the accessibility tree sees them (see `MenuBarDisplay`).
    /// The first screen is the primary one — the one with the menu bar at the origin.
    private static func displays() -> [MenuBarDisplay] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        return screens.map {
            MenuBarDisplay(
                appKitFrame: $0.frame, primaryHeight: primary.frame.height,
                auxiliaryLeftWidth: $0.auxiliaryTopLeftArea?.width,
                auxiliaryRightWidth: $0.auxiliaryTopRightArea?.width)
        }
    }
}

// MARK: - The banner

/// The banner's place at the top of the main window. It shows only what a look
/// the window itself asked for says. `watch.visibility` is whatever the last look
/// said, and that can be hours old: the bar changes with the clock and with
/// other apps coming and going, and nothing looks between dictations. A banner
/// drawn from it would flash up for an icon he can already see, and push the
/// page down until the fresh look lands. A hidden icon's banner waits that long,
/// tens of milliseconds, and no look at all (no item) means no banner: unknown
/// is never a reason to say anything.
struct MenuBarBannerSlot: View {
    @ObservedObject var watch: MenuBarWatch = .shared
    @State private var looked = false

    var body: some View {
        VStack(spacing: 0) {
            if looked, watch.visibility.isHidden {
                MenuBarHiddenBanner(visibility: watch.visibility) { watch.openMenuBarSettings() }
                    .onAppear { watch.bannerSeen() }
            }
        }
        .task {
            watch.refresh(announce: false)
            looked = true
        }
    }
}

/// A strip at the top of the main window while the menu-bar icon is hidden.
/// Says why, and how to fix it — the HUD line is click-through and can only
/// send him here.
struct MenuBarHiddenBanner: View {
    let visibility: StatusItemVisibility
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 16)).foregroundStyle(Brand.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(MenuBarNotice.bannerTitle)
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.ink)
                if let detail = MenuBarNotice.bannerDetail(for: visibility) {
                    Text(detail)
                        .font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action: openSettings) {
                Text(MenuBarNotice.bannerAction)
                    .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.paper)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.ink.opacity(0.08)).frame(height: 1) }
    }
}
