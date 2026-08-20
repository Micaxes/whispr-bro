import UIKit

/// A curated switchback target for keyboard-armed sessions — the honest
/// version of Wispr's v1.63 "auto-switchback". On iOS 26.4+ every
/// programmatic return-to-host path is dead (DTS-confirmed: _hostBundleID,
/// LSApplicationWorkspace, suspend — all closed) and the keyboard cannot even
/// NAME its host app, so the only thing the app can do is deep-link an app
/// the USER chose and remember that choice (`SessionController.returnApp`).
/// The list is a fixed allowlist of public URL schemes, each also declared in
/// ios/App-Info.plist's LSApplicationQueriesSchemes (the `canOpenURL`
/// requirement); apps without a public scheme can never be targets — which is
/// why the session card's swipe-back line is permanent, not transitional.
/// Opening a scheme is plain `UIApplication.open` from the app: a public API,
/// zero networking (the offline audit's NET_API surface is untouched).
struct ReturnApp: Identifiable, Equatable {
    /// Stable identity, persisted (as a string) in the app's UserDefaults.
    let id: String
    let name: String
    /// The scheme URL opened on switchback.
    let scheme: String

    /// UserDefaults key for the remembered choice — app-side only, never the
    /// App Group (the keyboard has no use for it).
    static let storageKey = "sessionReturnApp"

    /// The allowlist. Order is the picker-row order; keep it to apps with a
    /// stable, documented public scheme.
    static let curated: [ReturnApp] = [
        ReturnApp(id: "claude", name: "Claude", scheme: "claude://"),
        ReturnApp(id: "chatgpt", name: "ChatGPT", scheme: "chatgpt://"),
        ReturnApp(id: "notes", name: "Notes", scheme: "mobilenotes://"),
        ReturnApp(id: "whatsapp", name: "WhatsApp", scheme: "whatsapp://"),
        ReturnApp(id: "telegram", name: "Telegram", scheme: "tg://"),
        ReturnApp(id: "slack", name: "Slack", scheme: "slack://"),
        ReturnApp(id: "gmail", name: "Gmail", scheme: "googlegmail://"),
        ReturnApp(id: "x", name: "X", scheme: "twitter://"),
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
}
