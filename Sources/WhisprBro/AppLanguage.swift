import Foundation

/// The app's preferred UI language (distinct from the DICTATION language). Sets
/// `AppleLanguages`, which takes effect on the next launch. The interface isn't
/// fully localized yet, so today this mainly affects system-provided text and
/// locale formatting; the picker is here for parity + future translations.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english, italian, spanish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .italian: "Italiano"
        case .spanish: "Español"
        }
    }

    /// ISO code, or nil for "follow the system".
    var code: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .italian: "it"
        case .spanish: "es"
        }
    }

    static let storageKey = "appLanguage"

    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}
