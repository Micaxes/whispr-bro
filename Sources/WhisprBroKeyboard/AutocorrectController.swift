import Foundation
import UIKit

/// The appex-side owner of `AutocorrectEngine` — the UIKit glue its SwiftPM
/// test twin never sees: a `UITextChecker`-backed `SpellService`, the host's
/// supplementary lexicon (`UILexicon`, fetched once by the controller), and
/// the proxy closures that replay the engine's `EditCommand`s against
/// `textDocumentProxy`. Published `bar` feeds the toolbar's suggestion strip;
/// `autoCapHint` feeds the grid's one-shot shift. Main-thread only, like the
/// rest of the appex.
final class AutocorrectController: ObservableObject {
    /// What the suggestion strip renders (mirror of the engine's bar).
    @Published private(set) var bar = AutocorrectEngine.Bar.empty
    /// Whether the next letter should be auto-uppercased, recomputed from the
    /// host context + autocapitalization trait after every event. `KeyGrid`
    /// turns a rise into a one-shot shift.
    @Published private(set) var autoCapHint = false

    private let engine: AutocorrectEngine
    private let insertText: (String) -> Void
    private let deleteBackwardOne: () -> Void
    private let contextBefore: () -> String?
    private let contextAfter: () -> String?
    private let autocapitalization: () -> UITextAutocapitalizationType

    init(
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        contextBefore: @escaping () -> String?,
        contextAfter: @escaping () -> String?,
        autocapitalization: @escaping () -> UITextAutocapitalizationType
    ) {
        engine = AutocorrectEngine(spell: TextCheckerSpellService())
        self.insertText = insertText
        self.deleteBackwardOne = deleteBackward
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.autocapitalization = autocapitalization
    }

    /// The user dictionary (contact names, text replacements) — whitelisted
    /// in the engine so it never "corrects" a name the user taught iOS.
    func setLexicon(_ words: [String]) {
        engine.setLexicon(words)
        publish()
    }

    // MARK: Key events (routed here by KeyboardViewController's closures)

    /// The grid's single insert path: boundary chars (space, `.` `,` …) go
    /// through the engine's boundary event — which is where corrections and
    /// the double-space shortcut fire — everything else is a character.
    func typeCharacter(_ text: String) {
        if text.count == 1, let character = text.first,
           AutocorrectEngine.isBoundary(character) {
            apply(engine.boundaryTyped(character))
        } else {
            apply(engine.charTyped(text))
        }
    }

    /// The return key (newline is a boundary too — it commits corrections).
    func typeBoundary(_ character: Character) {
        apply(engine.boundaryTyped(character))
    }

    func tapDelete() {
        apply(engine.deleteTapped())
    }

    func tapSuggestion(_ slot: AutocorrectEngine.BarSlot) {
        apply(engine.suggestionTapped(slot))
    }

    /// Dictation transcripts bypass the key grid (the session's insertText
    /// path) — tell the engine so its shadow word stays grounded.
    func noteTranscriptInserted(_ text: String) {
        engine.externalTextInserted(text)
        publish()
    }

    /// `textDidChange` re-grounding: cursor moves, host-side edits, and the
    /// echo of our own inserts all land here.
    func resync() {
        engine.resync(before: contextBefore() ?? "", after: contextAfter() ?? "")
        publish()
    }

    /// The delete key's ~2s escalation target: one whole word plus the
    /// whitespace run after it, in a single burst, then a resync so the
    /// engine agrees with the new tail.
    func deleteWordBackward() {
        let before = contextBefore() ?? ""
        var remaining = Substring(before)
        while let last = remaining.last, last.isWhitespace { remaining = remaining.dropLast() }
        while let last = remaining.last, !last.isWhitespace { remaining = remaining.dropLast() }
        let count = max(1, before.count - remaining.count)
        for _ in 0..<count { deleteBackwardOne() }
        engine.resync(before: String(remaining), after: contextAfter() ?? "")
        publish()
    }

    // MARK: Internals

    private func apply(_ commands: [AutocorrectEngine.EditCommand]) {
        for command in commands {
            switch command {
            case .insert(let text):
                insertText(text)
            case .deleteBackward(let count):
                for _ in 0..<count { deleteBackwardOne() }
            }
        }
        publish()
    }

    private func publish() {
        if bar != engine.bar { bar = engine.bar }
        let hint = AutocorrectEngine.autoCapitalize(
            contextBefore: contextBefore(), type: autocapType())
        if hint != autoCapHint { autoCapHint = hint }
    }

    private func autocapType() -> AutocorrectEngine.AutocapType {
        switch autocapitalization() {
        case .words: .words
        case .allCharacters: .allCharacters
        case .none: AutocorrectEngine.AutocapType.none
        default: .sentences
        }
    }
}

// MARK: - UITextChecker adapter

/// The honest appex-grade spell source: `UITextChecker` (which needs no Full
/// Access). Language follows the user's first preferred language when the
/// checker knows it, else en_US.
private struct TextCheckerSpellService: SpellService {
    private let checker = UITextChecker()
    private let language: String

    init() {
        let available = UITextChecker.availableLanguages
        let preferred = Locale.preferredLanguages.first?
            .replacingOccurrences(of: "-", with: "_") ?? "en_US"
        language = available.first {
            $0 == preferred || $0.hasPrefix(String(preferred.prefix(2)))
        } ?? "en_US"
    }

    func isMisspelled(_ word: String) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: language
        ).location != NSNotFound
    }

    func corrections(for word: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.guesses(forWordRange: range, in: word, language: language) ?? []
    }

    func completions(for word: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.completions(
            forPartialWordRange: range, in: word, language: language) ?? []
    }
}
