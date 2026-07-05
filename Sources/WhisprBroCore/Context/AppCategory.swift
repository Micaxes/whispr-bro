import Foundation

/// Coarse category of the app being dictated into (spec §4 StyleRules). Kept
/// deliberately coarse (6 buckets) so an in-bucket app switch (Slack→Discord,
/// VS Code→Xcode) never re-primes the LLM prefix.
public enum AppCategory: String, Sendable, CaseIterable {
    case messaging
    case mail
    case browser
    case ide
    case terminal
    case notes
    case unknown
}

public enum AppCategoryResolver {
    /// Curated bundle-id → category map (the reliable, IPC-free primary source;
    /// `LSApplicationCategoryType` is absent on most Electron/direct-download
    /// apps, so it is not trusted).
    public static let byBundleId: [String: AppCategory] = [
        "com.tinyspeck.slackmacgap": .messaging,
        "com.hnc.Discord": .messaging,
        "com.apple.MobileSMS": .messaging,
        "WhatsApp": .messaging,
        "com.apple.mail": .mail,
        "com.readdle.smartemail-Mac": .mail,
        "com.microsoft.Outlook": .mail,
        "com.apple.Safari": .browser,
        "com.google.Chrome": .browser,
        "company.thebrowser.Browser": .browser,
        "org.mozilla.firefox": .browser,
        "com.microsoft.VSCode": .ide,
        "com.apple.dt.Xcode": .ide,
        "com.google.android.studio": .ide,
        "com.sublimetext.4": .ide,
        "dev.zed.Zed": .ide,
        "com.apple.Terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "com.github.wez.wezterm": .terminal,
        "net.kovidgoyal.kitty": .terminal,
        "com.apple.Notes": .notes,
        "md.obsidian": .notes,
        "notion.id": .notes,
    ]

    /// Resolve a bundle id to a category. IPC-free: just a map + prefix match.
    public static func category(bundleId: String?) -> AppCategory {
        guard let id = bundleId else { return .unknown }
        if let c = byBundleId[id] { return c }
        if id.hasPrefix("com.jetbrains.") { return .ide } // whole JetBrains family
        return .unknown
    }
}
