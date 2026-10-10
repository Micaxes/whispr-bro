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
        "com.sublimetext.3": .ide,
        "dev.zed.Zed": .ide,
        "com.todesktop.230313mzl4w4u92": .ide,   // Cursor
        "com.exafunction.windsurf": .ide,
        "com.microsoft.VSCodeInsiders": .ide,
        "com.vscodium": .ide,
        "com.neovim.neovim": .ide,
        // Every terminal here matters more than it used to: since
        // SpokenStructure, a shell that resolves to .unknown would accept a
        // spoken line break, and a newline in a shell is Return — it RUNS the
        // half-typed command.
        "com.apple.Terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "com.github.wez.wezterm": .terminal,
        "net.kovidgoyal.kitty": .terminal,
        "com.mitchellh.ghostty": .terminal,
        "dev.warp.Warp-Stable": .terminal,
        "dev.warp.Warp-Preview": .terminal,
        "org.alacritty": .terminal,   // upstream Info.plist
        "io.alacritty": .terminal,    // some third-party builds
        "co.zeit.hyper": .terminal,
        "com.eugeny.tabby": .terminal,
        "com.tabby": .terminal,
        "org.tabby": .terminal,
        "com.apple.Notes": .notes,
        "md.obsidian": .notes,
        "notion.id": .notes,
    ]

    /// Resolve a bundle id to a category. IPC-free: user `overrides` (from
    /// config.toml) win, then the built-in map, then the JetBrains prefix.
    public static func category(bundleId: String?, overrides: [String: AppCategory] = [:]) -> AppCategory {
        guard let id = bundleId else { return .unknown }
        if let c = overrides[id] { return c }
        if let c = byBundleId[id] { return c }
        if id.hasPrefix("com.jetbrains.") { return .ide } // whole JetBrains family
        return .unknown
    }
}
