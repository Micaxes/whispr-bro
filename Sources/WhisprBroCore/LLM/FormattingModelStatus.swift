import Foundation

/// Where the formatting model stands, in the words the AI-rewrite controls
/// use — Settings' "AI rewrite" section and the menu bar. Without the model
/// there are three different states, and each says what it is: not on disk,
/// on disk but not loaded yet (the app is still starting), on disk but it
/// failed to load. They used to read alike: "not installed" whenever the
/// model was not usable, which sent him to install a model he had.
///
/// The wording lives here so the two surfaces cannot drift, and so it is
/// pinned by test (`SettingsCopyTests`).
public enum FormattingModelStatus: Equatable, Sendable {
    /// Usable: in memory, or on disk and kept out of it by "Rules only".
    case available
    /// No model file on disk.
    case notInstalled
    /// On disk, not loaded yet: the app has not finished starting.
    case notLoadedYet
    /// On disk, but loading it failed.
    case failedToLoad

    /// - Parameters:
    ///   - installed: the model file is on disk (`LlmModelSpec.isInstalled`).
    ///   - available: the app can use it (`PipelineController.llmAvailable`).
    ///   - loadFailed: the last attempt to load it failed.
    public init(installed: Bool, available: Bool, loadFailed: Bool) {
        if available {
            self = .available
        } else if !installed {
            self = .notInstalled
        } else {
            self = loadFailed ? .failedToLoad : .notLoadedYet
        }
    }

    /// Settings' "AI rewrite" caption in place of the switch, which shows
    /// only when the model is available; nil then.
    public var settingsNote: String? {
        switch self {
        case .available:
            return nil
        case .notInstalled:
            return "The formatting model is not installed, so dictations already take the rules-only path."
        case .notLoadedYet:
            return "The formatting model is installed but not loaded yet — it loads once whispr·bro has finished starting. Until then, dictations take the rules-only path."
        case .failedToLoad:
            return "The formatting model is installed but failed to load, so dictations take the rules-only path. Models → Verify on disk checks the file; relaunch to try again."
        }
    }

    /// The menu bar's line in place of the switch; nil when it shows.
    public var menuNote: String? {
        switch self {
        case .available: return nil
        case .notInstalled: return "AI cleanup off (model not installed)"
        case .notLoadedYet: return "AI cleanup off until the model loads"
        case .failedToLoad: return "AI cleanup off (model failed to load)"
        }
    }
}
