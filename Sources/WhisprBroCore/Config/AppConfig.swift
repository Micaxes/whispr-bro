import Foundation

/// The hand-editable config mirrored to `config.toml` (spec §4 Config mirror).
/// Everything a user can tune without the UI: the personal dictionary, per-app
/// style-directive overrides, and extra bundle-id → category mappings.
public struct AppConfig: Sendable, Equatable {
    public struct DictEntry: Sendable, Equatable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    /// Auto-Clean (task-014): filler removal + self-correction resolution.
    /// The aggressiveness LEVEL is a live menu control (persisted in UserDefaults,
    /// see `Cleanup.Level`), NOT a config key — so the menu and config.toml can't
    /// fight. config.toml holds only the power-user knobs below.
    public struct Cleanup: Sendable, Equatable {
        /// How aggressive the stage is (spec §7a). The menu tri-state control.
        ///  - `verbatim`: whole stage off — paste dictionary-corrected text only
        ///    (no filler strip AND no LLM edit; byte-identical to what was said).
        ///  - `fillers`: deterministic filler strip + LLM formatting (GA default).
        ///  - `standard`: fillers + cued self-correction (opt-in).
        public enum Level: String, Sendable, CaseIterable {
            case verbatim, fillers, standard
            /// Menu/Settings label.
            public var displayName: String {
                switch self {
                case .verbatim: "Off (verbatim)"
                case .fillers: "Fillers only"
                case .standard: "Standard (+ corrections)"
                }
            }
        }

        /// Collapse function-word stutter runs ("I I I" → "I").
        public var collapseStutters = true
        /// Extra filler tokens appended to the built-in core set (escaped, capped).
        public var extraFillers: [String] = []
        /// Tokens removed from the built-in core set (a name/brand collision).
        public var disabledFillers: [String] = []
        /// Registers (category rawValues) where the whole stage is a no-op.
        public var verbatimCategories: [String] = ["ide", "terminal", "notes"]

        public init() {}
    }

    /// Substitution rules: spoken phrase → exact spelling.
    public var dictionary: [DictEntry] = []
    /// Category name ("mail", "messaging", …) → style directive override.
    public var style: [String: String] = [:]
    /// Bundle id → category name, extending the built-in app map.
    public var categories: [String: String] = [:]
    /// Auto-Clean settings (task-014).
    public var cleanup = Cleanup()

    public init() {}

    public var dictionaryRules: [DictionaryEngine.Rule] {
        dictionary.map { .init(from: $0.from, to: $0.to) }
    }
}
