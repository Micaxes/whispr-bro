import UIKit

/// A curated switchback target for keyboard-armed sessions — the honest
/// version of Wispr's v1.63 "auto-switchback". On iOS 26.4+ every
/// programmatic return-to-host path is dead (DTS-confirmed: _hostBundleID,
/// LSApplicationWorkspace, suspend — all closed) and the keyboard cannot even
/// NAME its host app, so the only thing the app can do is deep-link an app
/// the USER chose and remember that choice (`SessionController.returnChoice`).
/// The list is a fixed allowlist of public URL schemes, each also declared in
/// ios/App-Info.plist's LSApplicationQueriesSchemes (the `canOpenURL`
/// requirement — keep the two lists in EXACT step; Apple caps declarations at
/// 50, this list stays well under); apps without a public scheme can never be
/// targets — which is why the session card's swipe-back line is permanent,
/// not transitional.
/// Opening a scheme is plain `UIApplication.open` from the app: a public API,
/// zero networking (the offline audit's NET_API surface is untouched).
///
/// Deliberately ABSENT: Messages (`sms:`) and Mail (`mailto:`). Both schemes
/// are rock-solid, but `open` on them COMPOSES a blank draft instead of
/// returning to the thread/mailbox the user left — a "return" that lands
/// somewhere surprising reads as a bug, not a feature, so they stay off the
/// list and those users keep the always-present swipe-back path.
struct ReturnApp: Identifiable, Equatable {
    /// Stable identity, persisted (as a string) in the app's UserDefaults.
    let id: String
    let name: String
    /// The scheme URL opened on switchback.
    let scheme: String

    /// UserDefaults key for the remembered choice (`Choice.stored`) —
    /// app-side only, never the App Group (the keyboard has no use for it).
    static let storageKey = "sessionReturnApp"

    /// The allowlist. Order is the picker order; keep it to apps with a
    /// stable, documented public scheme (and an unsurprising open — see the
    /// sms:/mailto: exclusion above).
    static let curated: [ReturnApp] = [
        ReturnApp(id: "claude", name: "Claude", scheme: "claude://"),
        ReturnApp(id: "chatgpt", name: "ChatGPT", scheme: "chatgpt://"),
        ReturnApp(id: "notes", name: "Notes", scheme: "mobilenotes://"),
        ReturnApp(id: "whatsapp", name: "WhatsApp", scheme: "whatsapp://"),
        ReturnApp(id: "telegram", name: "Telegram", scheme: "tg://"),
        ReturnApp(id: "slack", name: "Slack", scheme: "slack://"),
        ReturnApp(id: "gmail", name: "Gmail", scheme: "googlegmail://"),
        ReturnApp(id: "x", name: "X", scheme: "twitter://"),
        ReturnApp(id: "messenger", name: "Messenger", scheme: "fb-messenger://"),
        ReturnApp(id: "signal", name: "Signal", scheme: "sgnl://"),
        ReturnApp(id: "discord", name: "Discord", scheme: "discord://"),
        ReturnApp(id: "instagram", name: "Instagram", scheme: "instagram://"),
        ReturnApp(id: "reddit", name: "Reddit", scheme: "reddit://"),
        ReturnApp(id: "linkedin", name: "LinkedIn", scheme: "linkedin://"),
        ReturnApp(id: "chrome", name: "Chrome", scheme: "googlechrome://"),
        ReturnApp(id: "obsidian", name: "Obsidian", scheme: "obsidian://"),
        // Things documents the triple-slash (empty-host) form as canonical.
        ReturnApp(id: "things", name: "Things", scheme: "things:///"),
        ReturnApp(id: "todoist", name: "Todoist", scheme: "todoist://"),
        ReturnApp(id: "bear", name: "Bear", scheme: "bear://"),
    ]

    /// The curated apps actually installed on this device, via `canOpenURL`
    /// (main-thread UIKit — call from view appearance, never a background
    /// queue). A remembered app that was since uninstalled simply drops out,
    /// and the card quietly falls back to the picker row.
    @MainActor static func installed() -> [ReturnApp] {
        curated.filter { app in
            guard let url = URL(string: app.scheme) else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    /// Resolves a persisted id back to its curated entry; nil for nil, an
    /// unknown id (allowlist edited across versions), or never-chosen.
    static func byID(_ id: String?) -> ReturnApp? {
        guard let id else { return nil }
        return curated.first { $0.id == id }
    }

    /// The persisted auto-return preference — one UserDefaults slot, three
    /// honest states: never asked (`unset` — the session card leads with the
    /// hero picker), explicitly declined (`off` — the swipe-back line is the
    /// whole story), or a chosen app. `off` is a sentinel VALUE in the same
    /// slot so "asked and declined" survives relaunches distinctly from
    /// "never asked".
    enum Choice: Equatable {
        case unset
        case off
        case app(ReturnApp)

        /// Sentinel stored for `off`; no curated id may ever collide with it.
        private static let offValue = "off"

        /// Decodes the persisted string. An unknown id (allowlist edited
        /// across versions) decodes as `unset` — the card simply asks again.
        static func from(stored: String?) -> Choice {
            guard let stored else { return .unset }
            if stored == offValue { return .off }
            guard let app = ReturnApp.byID(stored) else { return .unset }
            return .app(app)
        }

        /// The string to persist; nil (`unset`) clears the slot.
        var stored: String? {
            switch self {
            case .unset: nil
            case .off: Self.offValue
            case .app(let app): app.id
            }
        }
    }
}
