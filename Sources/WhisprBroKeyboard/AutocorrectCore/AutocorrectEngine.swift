import Foundation

/// The QuickType-parity autocorrect state machine: correction-on-boundary,
/// revert-on-delete, double-space → ". ", and the three-cell suggestion bar —
/// honest appex-grade smarts over whatever `SpellService` provides (the real
/// system autocorrect model is private API; `UITextChecker` + `UILexicon` is
/// the sanctioned ceiling).
///
/// Compiled TWICE, like `DictationActivityAttributes` (ios/project.yml row-8
/// pattern): once into the appex via project.yml's folder include of
/// Sources/WhisprBroKeyboard, and once as the SwiftPM target
/// `WhisprBroAutocorrect` so `swift test` covers the machine off-device — the
/// keyboard UI itself has no unit-test target by design. Everything in
/// AutocorrectCore/ is therefore Foundation-only.
///
/// The engine never reads the (async, lag-prone) document context itself:
/// `shadowWord` — the chars typed since the last boundary — is the source of
/// truth for all replacement math, and `resync` re-grounds it whenever the
/// host reports a change. Every event returns the exact `EditCommand`s the
/// caller must apply to the text, in order.
final class AutocorrectEngine {
    /// One proxy edit. The controller replays these against
    /// `textDocumentProxy` verbatim; tests assert them directly.
    enum EditCommand: Equatable {
        case insert(String)
        case deleteBackward(Int)
    }

    /// The three QuickType cells, left to right. `literalCell` renders quoted
    /// (native convention) and is non-nil only while a correction is pending
    /// (tap = keep what I typed) or immediately after a revert.
    struct Bar: Equatable {
        /// Left: the word exactly as typed.
        var literalCell: String?
        /// Middle: the pending correction — or, with nothing pending, the
        /// word as typed (tap commits it with a trailing space).
        var primary: String?
        /// Right: the second correction guess, or the first completion.
        var alternate: String?

        static let empty = Bar()
        var isEmpty: Bool { literalCell == nil && primary == nil && alternate == nil }
    }

    /// Which bar cell was tapped.
    enum BarSlot {
        case literal, primary, alternate
    }

    /// Foundation-only mirror of UIKit's UITextAutocapitalizationType — the
    /// controller maps the host's trait into this.
    enum AutocapType {
        case none, sentences, words, allCharacters
    }

    /// Typing one of these commits (and possibly corrects) the shadow word.
    /// The apostrophe is deliberately absent — it lives inside words.
    static let boundaries = Set<Character>([" ", "\n", ".", ",", "?", "!", ";", ":"])
    /// Two spaces this close together convert to ". ".
    static let doubleSpaceWindow: TimeInterval = 0.35

    private static let sentenceTerminators = Set<Character>([".", "!", "?"])

    /// What the suggestion strip renders. Recomputed after every event.
    private(set) var bar = Bar.empty
    /// Chars typed since the last boundary — the replacement-math truth.
    private(set) var shadowWord = ""

    /// Set by a boundary that applied a correction; consumed as a revert by
    /// the IMMEDIATELY following delete, cleared by any other event.
    private var lastCorrection: (literal: String, corrected: String, boundary: String)?
    /// The correction the next boundary would apply (recomputed with `bar`).
    private var pendingCorrection: String?
    /// Lowercased literals whose corrections the user refused (bar tap or
    /// revert) — never re-offered for this keyboard instance's lifetime.
    private var rejected: Set<String> = []
    /// Lowercased `UILexicon` entries (contact names, text replacements):
    /// whitelisted — a lexicon word is never treated as misspelled.
    private var lexicon: Set<String> = []
    private var lastSpaceAt: TimeInterval = -.infinity
    /// Whether the last space landed after a word-like char (non-space,
    /// non-punctuation) — the native precondition for double-space → ". ".
    private var lastSpaceQualifies = false

    private let spell: SpellService
    private let now: () -> TimeInterval

    init(
        spell: SpellService,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.spell = spell
        self.now = now
    }

    static func isBoundary(_ character: Character) -> Bool {
        boundaries.contains(character)
    }

    func setLexicon(_ words: [String]) {
        lexicon = Set(words.map { $0.lowercased() })
    }

    // MARK: Events

    /// A character key (letter, digit, non-boundary punctuation): append to
    /// the shadow word, insert as-is, refresh the bar.
    func charTyped(_ text: String) -> [EditCommand] {
        lastCorrection = nil
        shadowWord += text
        recomputeBar()
        return [.insert(text)]
    }

    /// A boundary key. Precedence: apply the pending correction → double-space
    /// shortcut → plain insert. Always ends the shadow word.
    func boundaryTyped(_ boundary: Character) -> [EditCommand] {
        lastCorrection = nil
        let literal = shadowWord
        let corrected = pendingCorrection
        shadowWord = ""
        pendingCorrection = nil
        clearBar()

        if let corrected, !literal.isEmpty {
            // The delete count is the shadow word by construction — never the
            // proxy context — so it can never eat text we didn't watch being
            // typed (the D5 clamp).
            lastCorrection = (literal: literal, corrected: corrected, boundary: String(boundary))
            noteBoundaryForDoubleSpace(boundary, precededBy: corrected.last)
            return [.deleteBackward(literal.count), .insert(corrected + String(boundary))]
        }
        if boundary == " ", literal.isEmpty, lastSpaceQualifies,
           now() - lastSpaceAt < Self.doubleSpaceWindow {
            // Double space: replace the first space with ". ". Disarm so a
            // third space can't fire again off the same window.
            lastSpaceAt = -.infinity
            lastSpaceQualifies = false
            return [.deleteBackward(1), .insert(". ")]
        }
        noteBoundaryForDoubleSpace(boundary, precededBy: literal.last)
        return [.insert(String(boundary))]
    }

    /// Backspace. A delete IMMEDIATELY after an applied correction is the
    /// revert: restore the literal (keystroke fully consumed), remember the
    /// rejection, and re-offer the literal in the bar. Any other delete is a
    /// plain single-char delete that pops the shadow word (cross-word drift
    /// is `resync`'s job).
    func deleteTapped() -> [EditCommand] {
        lastSpaceAt = -.infinity
        lastSpaceQualifies = false
        if let correction = lastCorrection {
            lastCorrection = nil
            rejected.insert(correction.literal.lowercased())
            shadowWord = ""
            pendingCorrection = nil
            bar = Bar(literalCell: correction.literal, primary: nil, alternate: nil)
            return [
                .deleteBackward(correction.corrected.count + correction.boundary.count),
                .insert(correction.literal + correction.boundary),
            ]
        }
        if !shadowWord.isEmpty { shadowWord.removeLast() }
        recomputeBar()
        return [.deleteBackward(1)]
    }

    /// A bar cell tap. Literal = native "keep what I typed": kill the pending
    /// correction, remember the rejection, touch no text. Primary/alternate =
    /// replace the shadow word with the candidate plus a trailing space.
    func suggestionTapped(_ slot: BarSlot) -> [EditCommand] {
        lastCorrection = nil
        switch slot {
        case .literal:
            guard let literal = bar.literalCell else { return [] }
            rejected.insert(literal.lowercased())
            pendingCorrection = nil
            recomputeBar()
            return []
        case .primary, .alternate:
            guard let candidate = slot == .primary ? bar.primary : bar.alternate else {
                return []
            }
            let count = shadowWord.count
            shadowWord = ""
            pendingCorrection = nil
            clearBar()
            // The trailing space is a real space for double-space purposes:
            // a quick space right after an accepted suggestion makes ". ",
            // like the system keyboard.
            lastSpaceAt = now()
            lastSpaceQualifies = true
            return [.deleteBackward(count), .insert(candidate + " ")]
        }
    }

    /// A dictation transcript landed through the session's insertText path —
    /// no key events to watch, so rebuild the shadow word from the
    /// transcript's tail and drop any pending/revertible correction.
    func externalTextInserted(_ text: String) {
        lastCorrection = nil
        pendingCorrection = nil
        lastSpaceAt = -.infinity
        lastSpaceQualifies = false
        shadowWord = Self.trailingWord(of: text)
        recomputeBar()
    }

    /// `textDidChange` ground-truthing. A resync that AGREES with the current
    /// shadow word (word rebuilt from `before`'s tail matches, cursor not
    /// mid-word) is the echo of our own edit landing and preserves the
    /// pending/revertible correction. ANY disagreement aborts both and adopts
    /// the rebuilt word — corrections must never run replacement math against
    /// text the engine didn't watch. A mid-word cursor additionally keeps the
    /// bar empty: replacing only the head of a word can't be done with
    /// backward deletes.
    func resync(before: String, after: String) {
        let rebuilt = Self.trailingWord(of: before)
        let midWord = after.first.map { !$0.isWhitespace && !Self.isBoundary($0) } ?? false
        if rebuilt == shadowWord, !midWord { return }
        lastCorrection = nil
        pendingCorrection = nil
        lastSpaceAt = -.infinity
        lastSpaceQualifies = false
        shadowWord = rebuilt
        if midWord {
            clearBar()
        } else {
            recomputeBar()
        }
    }

    // MARK: Auto-capitalization

    /// Whether the next typed letter should be uppercased, per the host's
    /// autocapitalization trait: sentences = empty context, a newline, or a
    /// sentence terminator (optionally followed by whitespace); words = any
    /// trailing whitespace; allCharacters = always.
    static func autoCapitalize(contextBefore context: String?, type: AutocapType) -> Bool {
        switch type {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard let last = context?.last else { return true }
            return last.isWhitespace
        case .sentences:
            guard let context, !context.isEmpty else { return true }
            var index = context.endIndex
            while index > context.startIndex {
                let previous = context.index(before: index)
                let character = context[previous]
                if character.isNewline { return true }
                if !character.isWhitespace { return sentenceTerminators.contains(character) }
                index = previous
            }
            return true // whitespace-only context = start of the document
        }
    }

    // MARK: Internals

    /// Double-space bookkeeping: only a space arms the window, and only when
    /// it lands after a word-like char ("word,␣␣" must never become
    /// "word,.␣").
    private func noteBoundaryForDoubleSpace(_ boundary: Character, precededBy prior: Character?) {
        if boundary == " ", let prior, !prior.isWhitespace, !Self.isBoundary(prior) {
            lastSpaceAt = now()
            lastSpaceQualifies = true
        } else {
            lastSpaceAt = -.infinity
            lastSpaceQualifies = false
        }
    }

    /// The bar for the current shadow word: a misspelled, unrejected,
    /// non-lexicon word with at least one guess offers the correction
    /// (quoted literal | guess 1 | guess 2 ?? completion); anything else
    /// shows the word as typed flanked by its first distinct completion.
    private func recomputeBar() {
        let word = shadowWord
        pendingCorrection = nil
        guard !word.isEmpty else {
            clearBar()
            return
        }
        if spell.isMisspelled(word),
           !rejected.contains(word.lowercased()),
           !lexicon.contains(word.lowercased()) {
            let corrections = spell.corrections(for: word)
            if let first = corrections.first {
                pendingCorrection = first
                let alternate = corrections.count > 1
                    ? corrections[1]
                    : spell.completions(for: word).first
                setBar(Bar(literalCell: word, primary: first, alternate: alternate))
                return
            }
        }
        let completion = spell.completions(for: word)
            .first { $0.lowercased() != word.lowercased() }
        setBar(Bar(literalCell: nil, primary: word, alternate: completion))
    }

    private func setBar(_ next: Bar) {
        if bar != next { bar = next }
    }

    private func clearBar() {
        if !bar.isEmpty { bar = .empty }
    }

    /// The trailing run of word-like chars (no whitespace, no boundary) —
    /// what the shadow word must be if the text ends mid-word.
    private static func trailingWord(of text: String) -> String {
        let tail = text.reversed().prefix { !$0.isWhitespace && !isBoundary($0) }
        return String(tail.reversed())
    }
}
