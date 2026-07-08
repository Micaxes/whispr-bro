import Foundation

/// The user-selected dictation language (spec: multilingual, task-015 candidate).
///
/// English is the default and keeps the fast English-only Parakeet **v2** model;
/// Italian and Spanish route to the multilingual Parakeet **v3** model (25
/// European languages, ANE, auto-detecting). Simplified Chinese is deliberately
/// out of scope — Parakeet is European-only and CJK needs a separate engine.
///
/// The active language is a live UserDefaults toggle (like `cleanupLevel` and
/// `asrEngineKind`), NOT a config.toml key, so the menu/Settings and the file
/// can never disagree. Changing it takes effect on the next launch (the ASR
/// engine, like `asrEngineKind`, is built once at bring-up).
public enum DictationLanguage: String, CaseIterable, Sendable {
    case english
    case italian
    case spanish

    public static let storageKey = "dictationLanguage"

    /// The persisted selection (defaults to English).
    public static var selected: DictationLanguage {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(DictationLanguage.init) ?? .english
    }

    /// Native display name for the picker.
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        }
    }

    /// ISO 639-1 code (used by whisper-style engines; Parakeet v3 auto-detects
    /// and ignores it).
    public var code: String {
        switch self {
        case .english: return "en"
        case .italian: return "it"
        case .spanish: return "es"
        }
    }

    /// Which Parakeet model serves this language. English stays on the fast
    /// English-only v2; Italian/Spanish use the multilingual v3.
    public var parakeetVersion: ParakeetEngine.Version {
        switch self {
        case .english: return .v2
        case .italian, .spanish: return .v3
        }
    }
}
