import AppKit
import SwiftUI

/// Opens and focuses the unified "whispr-bro" window from OUTSIDE the view tree.
/// This is what running the app a second time does (Spotlight, Finder, Raycast,
/// `open -a`): macOS sends the already-running app a reopen event, and until
/// now nothing answered it — so with the menu-bar icon hidden behind the notch
/// there was no way into Home, History or Settings at all.
///
/// The menu-bar menu cannot be the way in. A MenuBarExtra's menu content is
/// not run until the menu is opened, so an `openWindow` read there cannot be
/// relied on to exist, and an icon he cannot see he cannot click. Two
/// independent paths, so neither has to be perfect:
///
///  1. `capture` — the menu-bar LABEL belongs to the status item itself, not
///     to the menu, and hands over its `openWindow` action as soon as it
///     appears. Direct, no round trip.
///  2. `whisprbro://open` — the app hands that URL to itself and the Window
///     scene's `handlesExternalEvents` makes SwiftUI create the window. Needs
///     no view at all, so it covers a reopen that lands before the label has
///     appeared, and an action that was captured but silently did nothing.
///     The scheme is declared once, in Info.plist (scripts/make-app.sh); an
///     unbundled `swift run` has none and simply has no second path.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    private init() {}

    private var openWindow: OpenWindowAction?

    /// Called from the menu-bar label as soon as it exists.
    func capture(_ action: OpenWindowAction) {
        openWindow = action
    }

    /// Bring the window up and put him in it: open it if it is closed, raise it
    /// if it is open, and make the app focusable either way (the same
    /// `ActivationPolicy` path the menu items use).
    func open() {
        ActivationPolicy.activate()
        guard let openWindow else { return openViaURL() }
        openWindow(id: "main")
        // An action that was handed over is not an action that worked. If no
        // window is up a moment later, ask SwiftUI the other way.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if !ActivationPolicy.hasStandardWindow { openViaURL() }
        }
    }

    private func openViaURL() {
        guard let url = Self.selfURL else { return }
        // Aimed at THIS bundle: a second copy of the app on disk (dist/ and
        // /Applications) must not be the one that answers.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false   // `open()` has already activated the app
        NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: config)
    }

    /// What the Window scene claims via `handlesExternalEvents`: exactly that
    /// URL, so it is the only event that makes SwiftUI create the window. Empty
    /// (claims nothing) when the bundle declares no scheme.
    static var externalEvents: Set<String> {
        selfURL.map { [$0.absoluteString] } ?? []
    }

    /// Whether `url` is one the Window scene claims, i.e. one that will get a
    /// window and so is worth making the app focusable for.
    static func isOpenURL(_ url: URL) -> Bool {
        externalEvents.contains(url.absoluteString)
    }

    /// `<first declared scheme>://open`, or nil when the bundle declares none.
    private static var selfURL: URL? {
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              let scheme = types.lazy.compactMap({ ($0["CFBundleURLSchemes"] as? [String])?.first }).first
        else { return nil }
        return URL(string: "\(scheme)://open")
    }
}
