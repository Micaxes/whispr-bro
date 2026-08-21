import Foundation

/// The spelling/completion source `AutocorrectEngine` consults, injected so
/// the engine stays Foundation-only (and therefore macOS-buildable for
/// `swift test` — see the two-targets note on `AutocorrectEngine`). The appex
/// supplies a `UITextChecker`-backed implementation
/// (`AutocorrectController`); tests supply deterministic stubs. UIKit types
/// must never appear behind this seam.
protocol SpellService {
    /// Whether the whole word is flagged by the spelling dictionary.
    func isMisspelled(_ word: String) -> Bool
    /// Correction guesses for a misspelled word, best first
    /// (`UITextChecker.guesses`).
    func corrections(for word: String) -> [String]
    /// Completions of a partial word, best first
    /// (`UITextChecker.completions`).
    func completions(for word: String) -> [String]
}
