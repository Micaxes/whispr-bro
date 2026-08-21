import XCTest

@testable import WhisprBroAutocorrect

/// Deterministic `SpellService`: dictionary-driven, no UITextChecker (the
/// appex twin injects the real one — see `AutocorrectController`). Keys are
/// lowercased literals; `misspellings[word]` is the ordered guess list.
private struct SpellStub: SpellService {
    var misspellings: [String: [String]] = [:]
    var completionTable: [String: [String]] = [:]

    func isMisspelled(_ word: String) -> Bool {
        misspellings[word.lowercased()] != nil
    }

    func corrections(for word: String) -> [String] {
        misspellings[word.lowercased()] ?? []
    }

    func completions(for word: String) -> [String] {
        completionTable[word.lowercased()] ?? []
    }
}

/// The D5 state machine: shadow-word bookkeeping, correction-on-boundary,
/// revert-on-delete (with per-instance rejection memory), the double-space
/// shortcut, bar contents, resync grounding, and the auto-cap rules. The
/// clock is injected so double-space windows are exact, not sleep-based.
final class AutocorrectEngineTests: XCTestCase {
    private var clock: TimeInterval = 0

    /// "teh" → ["the", "ten"]; completions for "hel" → hello/help.
    private func makeEngine(spell: SpellStub? = nil) -> AutocorrectEngine {
        let spell = spell ?? SpellStub(
            misspellings: ["teh": ["the", "ten"]],
            completionTable: ["hel": ["hello", "help"]])
        return AutocorrectEngine(spell: spell) { self.clock }
    }

    private func type(_ word: String, into engine: AutocorrectEngine) {
        for character in word {
            XCTAssertEqual(
                engine.charTyped(String(character)), [.insert(String(character))])
        }
    }

    // MARK: Bar contents

    func testMisspelledWordOffersCorrectionBar() {
        let engine = makeEngine()
        type("teh", into: engine)
        XCTAssertEqual(engine.shadowWord, "teh")
        XCTAssertEqual(
            engine.bar,
            AutocorrectEngine.Bar(literalCell: "teh", primary: "the", alternate: "ten"))
    }

    func testCleanWordBarIsWordAsTypedPlusCompletion() {
        let engine = makeEngine()
        type("hel", into: engine)
        XCTAssertEqual(
            engine.bar,
            AutocorrectEngine.Bar(literalCell: nil, primary: "hel", alternate: "hello"))
    }

    func testSingleGuessFallsBackToCompletionForAlternate() {
        let engine = makeEngine(spell: SpellStub(
            misspellings: ["teh": ["the"]],
            completionTable: ["teh": ["tehran"]]))
        type("teh", into: engine)
        XCTAssertEqual(
            engine.bar,
            AutocorrectEngine.Bar(literalCell: "teh", primary: "the", alternate: "tehran"))
    }

    func testMisspelledWordWithNoGuessesShowsNoCorrection() {
        let engine = makeEngine(spell: SpellStub(misspellings: ["zzq": []]))
        type("zzq", into: engine)
        XCTAssertNil(engine.bar.literalCell)
        // …and a boundary must insert literally, no replacement.
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    func testBarClearsOnBoundary() {
        let engine = makeEngine()
        type("hel", into: engine)
        _ = engine.boundaryTyped(" ")
        XCTAssertTrue(engine.bar.isEmpty)
        XCTAssertEqual(engine.shadowWord, "")
    }

    // MARK: Correction on boundary

    func testCorrectionAppliedOnSpace() {
        let engine = makeEngine()
        type("teh", into: engine)
        XCTAssertEqual(
            engine.boundaryTyped(" "),
            [.deleteBackward(3), .insert("the ")])
    }

    func testCorrectionAppliedOnPunctuation() {
        let engine = makeEngine()
        type("teh", into: engine)
        XCTAssertEqual(
            engine.boundaryTyped("."),
            [.deleteBackward(3), .insert("the.")])
    }

    func testLexiconWordIsNeverCorrected() {
        let engine = makeEngine(spell: SpellStub(misspellings: ["goracci": ["goracci"]]))
        engine.setLexicon(["Goracci"])
        type("Goracci", into: engine)
        XCTAssertNil(engine.bar.literalCell)
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    // MARK: Revert on delete

    func testDeleteImmediatelyAfterCorrectionReverts() {
        let engine = makeEngine()
        type("teh", into: engine)
        _ = engine.boundaryTyped(" ")
        // The revert consumes the whole keystroke: swap corrected+boundary
        // back for literal+boundary, nothing else deleted.
        XCTAssertEqual(
            engine.deleteTapped(),
            [.deleteBackward(4), .insert("teh ")])
        // The literal is re-offered in the bar (quoted cell).
        XCTAssertEqual(engine.bar.literalCell, "teh")
    }

    func testRevertRejectsLiteralForTheInstanceLifetime() {
        let engine = makeEngine()
        type("teh", into: engine)
        _ = engine.boundaryTyped(" ")
        _ = engine.deleteTapped() // revert = rejection
        type("teh", into: engine)
        XCTAssertNil(engine.bar.literalCell) // no correction re-offered
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    func testRevertIsConsumedOnce() {
        let engine = makeEngine()
        type("teh", into: engine)
        _ = engine.boundaryTyped(" ")
        _ = engine.deleteTapped()
        // The next delete is a plain single-char delete.
        XCTAssertEqual(engine.deleteTapped(), [.deleteBackward(1)])
    }

    func testInterveningEventDisarmsTheRevert() {
        let engine = makeEngine()
        type("teh", into: engine)
        _ = engine.boundaryTyped(" ")
        _ = engine.charTyped("x") // any event other than delete clears it
        XCTAssertEqual(engine.deleteTapped(), [.deleteBackward(1)])
    }

    func testPlainDeletePopsShadowWord() {
        let engine = makeEngine()
        type("teh", into: engine)
        XCTAssertEqual(engine.deleteTapped(), [.deleteBackward(1)])
        XCTAssertEqual(engine.shadowWord, "te")
        // Deleting past the word start stays a plain delete (resync covers
        // cross-word drift).
        _ = engine.deleteTapped()
        _ = engine.deleteTapped()
        XCTAssertEqual(engine.deleteTapped(), [.deleteBackward(1)])
        XCTAssertEqual(engine.shadowWord, "")
    }

    // MARK: Suggestion taps

    func testLiteralCellTapRejectsWithoutTextEdit() {
        let engine = makeEngine()
        type("teh", into: engine)
        XCTAssertEqual(engine.suggestionTapped(.literal), [])
        XCTAssertNil(engine.bar.literalCell) // correction offer gone
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")]) // kept as typed
    }

    func testPrimaryTapReplacesShadowWordAndAddsSpace() {
        let engine = makeEngine()
        type("teh", into: engine)
        XCTAssertEqual(
            engine.suggestionTapped(.primary),
            [.deleteBackward(3), .insert("the ")])
        XCTAssertEqual(engine.shadowWord, "")
        XCTAssertTrue(engine.bar.isEmpty)
    }

    func testAlternateTapInsertsCompletion() {
        let engine = makeEngine()
        type("hel", into: engine)
        XCTAssertEqual(
            engine.suggestionTapped(.alternate),
            [.deleteBackward(3), .insert("hello ")])
    }

    func testTapOnEmptySlotDoesNothing() {
        let engine = makeEngine()
        XCTAssertEqual(engine.suggestionTapped(.primary), [])
        XCTAssertEqual(engine.suggestionTapped(.literal), [])
    }

    // MARK: Double space

    func testDoubleSpaceMakesPeriod() {
        let engine = makeEngine()
        type("hi", into: engine)
        clock = 0
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
        clock = 0.2
        XCTAssertEqual(
            engine.boundaryTyped(" "),
            [.deleteBackward(1), .insert(". ")])
    }

    func testDoubleSpaceOutsideWindowStaysASpace() {
        let engine = makeEngine()
        type("hi", into: engine)
        clock = 0
        _ = engine.boundaryTyped(" ")
        clock = 0.4 // window is 0.35
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    func testDoubleSpaceAfterPunctuationDoesNotFire() {
        let engine = makeEngine()
        type("hi", into: engine)
        _ = engine.boundaryTyped(",")
        clock = 0.1
        _ = engine.boundaryTyped(" ")
        clock = 0.2
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    func testDoubleSpaceWithInterveningCharDoesNotFire() {
        let engine = makeEngine()
        type("hi", into: engine)
        clock = 0
        _ = engine.boundaryTyped(" ")
        _ = engine.charTyped("a")
        clock = 0.2
        // "a" is the shadow word now — this space just commits it.
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    func testTripleSpaceFiresOnlyOnce() {
        let engine = makeEngine()
        type("hi", into: engine)
        clock = 0
        _ = engine.boundaryTyped(" ")
        clock = 0.1
        XCTAssertEqual(engine.boundaryTyped(" "), [.deleteBackward(1), .insert(". ")])
        clock = 0.2
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    func testDoubleSpaceAfterAppliedCorrection() {
        let engine = makeEngine()
        type("teh", into: engine)
        clock = 0
        _ = engine.boundaryTyped(" ") // → "the "
        clock = 0.2
        XCTAssertEqual(
            engine.boundaryTyped(" "),
            [.deleteBackward(1), .insert(". ")]) // → "the. "
    }

    func testQuickSpaceAfterSuggestionTapMakesPeriod() {
        let engine = makeEngine()
        type("hel", into: engine)
        clock = 0
        _ = engine.suggestionTapped(.alternate) // inserted "hello "
        clock = 0.2
        XCTAssertEqual(
            engine.boundaryTyped(" "),
            [.deleteBackward(1), .insert(". ")])
    }

    func testDeleteDisarmsTheDoubleSpaceWindow() {
        let engine = makeEngine()
        type("hi", into: engine)
        clock = 0
        _ = engine.boundaryTyped(" ")
        _ = engine.deleteTapped() // the space is gone — the window must be too
        clock = 0.2
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    // MARK: Resync + external text

    func testResyncAgreementPreservesPendingCorrection() {
        let engine = makeEngine()
        type("teh", into: engine)
        // The echo of our own inserts landing in the host context.
        engine.resync(before: "hello teh", after: "")
        XCTAssertEqual(
            engine.boundaryTyped(" "),
            [.deleteBackward(3), .insert("the ")])
    }

    func testResyncEchoAfterCorrectionPreservesTheRevert() {
        let engine = makeEngine()
        type("teh", into: engine)
        _ = engine.boundaryTyped(" ") // correction applied → "the "
        // The textDidChange echo of that correction landing: the rebuilt
        // tail ("the " ends on a boundary → empty word) AGREES with the
        // already-empty shadow word, so the early return must keep the
        // revert armed — without it, delete-after-correction degrades to a
        // plain single-char delete.
        engine.resync(before: "hello the ", after: "")
        XCTAssertEqual(
            engine.deleteTapped(),
            [.deleteBackward(4), .insert("teh ")])
    }

    func testResyncDisagreementAbortsAndAdopts() {
        let engine = makeEngine()
        type("teh", into: engine)
        engine.resync(before: "abc", after: "")
        XCTAssertEqual(engine.shadowWord, "abc")
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")]) // no correction
    }

    func testResyncDisarmsTheRevert() {
        let engine = makeEngine()
        type("teh", into: engine)
        _ = engine.boundaryTyped(" ")
        engine.resync(before: "something else", after: "")
        XCTAssertEqual(engine.deleteTapped(), [.deleteBackward(1)])
    }

    func testResyncMidWordCursorSuppressesTheBar() {
        let engine = makeEngine()
        // Cursor sits inside "teh|ran": backward replacement math can't
        // rewrite the head of a word alone — no offers.
        engine.resync(before: "teh", after: "ran and more")
        XCTAssertTrue(engine.bar.isEmpty)
        XCTAssertEqual(engine.boundaryTyped(" "), [.insert(" ")])
    }

    func testResyncTrailingBoundaryMeansEmptyShadowWord() {
        let engine = makeEngine()
        type("teh", into: engine)
        engine.resync(before: "hello teh ", after: "")
        XCTAssertEqual(engine.shadowWord, "")
        XCTAssertTrue(engine.bar.isEmpty)
    }

    func testExternalTextRebuildsShadowFromTranscriptTail() {
        let engine = makeEngine()
        engine.externalTextInserted("dictated teh")
        XCTAssertEqual(engine.shadowWord, "teh")
        XCTAssertEqual(engine.bar.primary, "the") // correction offered on the tail
        engine.externalTextInserted("ends with space ")
        XCTAssertEqual(engine.shadowWord, "")
        XCTAssertTrue(engine.bar.isEmpty)
    }

    func testExternalTextAbortsPendingCorrection() {
        let engine = makeEngine()
        type("teh", into: engine)
        _ = engine.boundaryTyped(" ")
        engine.externalTextInserted("transcript. ")
        XCTAssertEqual(engine.deleteTapped(), [.deleteBackward(1)]) // no revert
    }

    // MARK: Auto-capitalization

    func testAutoCapitalizeSentences() {
        typealias Engine = AutocorrectEngine
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: nil, type: .sentences))
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: "", type: .sentences))
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: "Done.", type: .sentences))
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: "Done. ", type: .sentences))
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: "Really?  ", type: .sentences))
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: "line\n", type: .sentences))
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: "   ", type: .sentences))
        XCTAssertFalse(Engine.autoCapitalize(contextBefore: "word", type: .sentences))
        XCTAssertFalse(Engine.autoCapitalize(contextBefore: "word ", type: .sentences))
        XCTAssertFalse(Engine.autoCapitalize(contextBefore: "a, ", type: .sentences))
    }

    func testAutoCapitalizeWords() {
        typealias Engine = AutocorrectEngine
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: nil, type: .words))
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: "two words ", type: .words))
        XCTAssertFalse(Engine.autoCapitalize(contextBefore: "mid-wo", type: .words))
    }

    func testAutoCapitalizeAllCharactersAndNone() {
        typealias Engine = AutocorrectEngine
        XCTAssertTrue(Engine.autoCapitalize(contextBefore: "word", type: .allCharacters))
        XCTAssertFalse(Engine.autoCapitalize(contextBefore: "", type: .none))
        XCTAssertFalse(Engine.autoCapitalize(contextBefore: "Done. ", type: .none))
    }

    // MARK: Boundary set

    func testBoundaryCharacterSet() {
        for character in [" ", "\n", ".", ",", "?", "!", ";", ":"] {
            XCTAssertTrue(AutocorrectEngine.isBoundary(Character(character)))
        }
        // The apostrophe lives INSIDE words ("don't") — never a boundary.
        XCTAssertFalse(AutocorrectEngine.isBoundary("'"))
        XCTAssertFalse(AutocorrectEngine.isBoundary("-"))
    }
}
