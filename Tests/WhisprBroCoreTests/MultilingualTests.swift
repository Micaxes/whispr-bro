import XCTest

@testable import WhisprBroCore

/// Covers the multilingual seam: language→model-version routing, per-language
/// system prompts / correction cues / filler sets. English behavior must be
/// unchanged (regression guard).
final class MultilingualTests: XCTestCase {

    // MARK: DictationLanguage

    func testParakeetVersionRouting() {
        // English stays on the fast v2 English model; it/es use multilingual v3.
        XCTAssertEqual(DictationLanguage.english.parakeetVersion, .v2)
        XCTAssertEqual(DictationLanguage.italian.parakeetVersion, .v3)
        XCTAssertEqual(DictationLanguage.spanish.parakeetVersion, .v3)
    }

    func testVersionFolderNames() {
        XCTAssertEqual(ParakeetEngine.Version.v2.folderName, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(ParakeetEngine.Version.v3.folderName, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(ParakeetEngine.folderName(for: .v3), "parakeet-tdt-0.6b-v3")
        // Back-compat default folder is still v2.
        XCTAssertEqual(ParakeetEngine.modelFolderName, "parakeet-tdt-0.6b-v2")
    }

    func testLanguageRawValueRoundTrip() {
        XCTAssertEqual(DictationLanguage(rawValue: "italian"), .italian)
        XCTAssertNil(DictationLanguage(rawValue: "klingon"))
    }

    // MARK: PromptBuilder

    func testSystemPromptPerLanguage() {
        // English is the frozen default, unchanged.
        XCTAssertEqual(PromptBuilder.systemPrompt(for: .english), PromptBuilder.defaultSystemPrompt)
        let it = PromptBuilder.systemPrompt(for: .italian)
        let es = PromptBuilder.systemPrompt(for: .spanish)
        XCTAssertFalse(it.isEmpty)
        XCTAssertFalse(es.isEmpty)
        XCTAssertNotEqual(it, es)
        // Each must carry an explicit never-translate / keep-language clause.
        XCTAssertTrue(PromptBuilder.defaultSystemPrompt.contains("translate"))
        XCTAssertTrue(it.lowercased().contains("tradurre"))
        XCTAssertTrue(es.lowercased().contains("traduzcas"))
        // Spanish reminds the model about opening marks.
        XCTAssertTrue(es.contains("¿"))
    }

    func testCorrectionClauseBackCompatAndPerLanguage() {
        // The parameterless clause is the English one (back-compat).
        XCTAssertEqual(PromptBuilder.correctionClause, PromptBuilder.correctionClause(for: .english))
        XCTAssertNotEqual(
            PromptBuilder.correctionClause(for: .italian),
            PromptBuilder.correctionClause(for: .spanish))
        XCTAssertFalse(PromptBuilder.correctionClause(for: .italian).isEmpty)
    }

    // MARK: CorrectionCues

    func testCuePhrasesPerLanguage() {
        for lang in DictationLanguage.allCases {
            let prompt = CorrectionCues.promptPhrases(for: lang).map { $0.lowercased() }
            let bypass = CorrectionCues.bypassPhrases(for: lang).map { $0.lowercased() }
            XCTAssertFalse(prompt.isEmpty, "\(lang) has prompt cues")
            XCTAssertFalse(bypass.isEmpty, "\(lang) has bypass cues")
            // Bypass cues must be a subset of prompt cues (shared lexicon, AC #14).
            XCTAssertTrue(Set(bypass).isSubset(of: Set(prompt)), "\(lang) bypass ⊂ prompt")
        }
        // English delegates to the existing static arrays.
        XCTAssertEqual(CorrectionCues.promptPhrases(for: .english), CorrectionCues.promptPhrases)
    }

    func testPlausibleCorrectionItalian() {
        // Mid-utterance strong cue + a replacement word → routed to the LLM.
        XCTAssertTrue(CorrectionCues.plausibleCorrection(
            in: "ci vediamo lunedì no aspetta martedì", language: .italian))
        // A leading cue with nothing to correct → not a correction.
        XCTAssertFalse(CorrectionCues.plausibleCorrection(in: "anzi", language: .italian))
    }

    // MARK: FillerStripper

    func testCoreFillerSetsPerLanguage() {
        XCTAssertEqual(FillerStripper.coreFillers(for: .english), FillerStripper.coreFillers)
        XCTAssertTrue(FillerStripper.coreFillers(for: .italian).contains("ehm"))
        XCTAssertTrue(FillerStripper.coreFillers(for: .spanish).contains("eh"))
        // "este"/"esto" are real Spanish words — never stripped deterministically.
        XCTAssertFalse(FillerStripper.coreFillers(for: .spanish).contains("este"))
    }

    func testItalianFillerStrip() {
        let stripper = FillerStripper(core: FillerStripper.coreFillers(for: .italian))
        let out = stripper.strip("ciao ehm come stai")
        XCTAssertFalse(out.lowercased().contains("ehm"))
        XCTAssertTrue(out.contains("ciao"))
        XCTAssertTrue(out.contains("come stai"))
    }

    func testEnglishFillerStripUnchanged() {
        // Regression: the default (English) core set still strips "um".
        let out = FillerStripper().strip("so um yeah")
        XCTAssertFalse(out.lowercased().contains("um"))
        XCTAssertTrue(out.lowercased().contains("yeah"))
    }
}
