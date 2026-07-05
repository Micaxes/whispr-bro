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

    /// Substitution rules: spoken phrase → exact spelling.
    public var dictionary: [DictEntry] = []
    /// Category name ("mail", "messaging", …) → style directive override.
    public var style: [String: String] = [:]
    /// Bundle id → category name, extending the built-in app map.
    public var categories: [String: String] = [:]

    public init() {}

    public var dictionaryRules: [DictionaryEngine.Rule] {
        dictionary.map { .init(from: $0.from, to: $0.to) }
    }
}
