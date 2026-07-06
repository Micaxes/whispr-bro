import XCTest
@testable import WhisprBroCore

final class FillerStripperTests: XCTestCase {
    private let s = FillerStripper()   // core set, collapse on

    func testStripsStandaloneFillers() {
        XCTAssertEqual(s.strip("she uh liked it"), "she liked it")
        // Bias-to-keep: a set-off filler leaves one stray comma rather than risk
        // eating a list delimiter.
        XCTAssertEqual(s.strip("can we, um, look at the plan"), "can we, look at the plan")
        XCTAssertEqual(s.strip("er, I think so"), "I think so")
    }

    func testKeepsListSeparatorCommas() {
        // A filler BETWEEN list items must not destroy the list commas.
        XCTAssertEqual(s.strip("eggs, uh, milk, uh, bread"), "eggs, milk, bread")
        XCTAssertEqual(s.strip("red, um, black, um, blue"), "red, black, blue")
    }

    func testOneSidedCommaLeavesNoDanglingComma() {
        // A trailing hesitation must not leave a dangling comma.
        XCTAssertEqual(s.strip("remind me to buy milk, uh"), "remind me to buy milk")
        // A comma orphaned against a terminator is cleaned up (capitalization of
        // the next sentence is a downstream ruleBasedCleanup concern, not here).
        XCTAssertEqual(s.strip("Yes. Um, no."), "Yes. no.")
        XCTAssertEqual(s.strip("buy milk, uh."), "buy milk.")
    }

    func testStutterInQuotePreserved() {
        XCTAssertEqual(s.strip(#"she wrote "we we need more""#), #"she wrote "we we need more""#)
    }

    func testAllFillerVariants() {
        XCTAssertEqual(s.strip("um"), "")               // caller falls back to verbatim
        XCTAssertTrue(s.strip("um, uh.").allSatisfy { !$0.isLetter }) // no letters left → caller falls back
    }

    func testAllCapsInitialismSurvives() {
        // "ER"/"UM" as an initialism (all caps) is not a filled pause.
        XCTAssertEqual(s.strip("take her to the ER"), "take her to the ER")
        XCTAssertEqual(s.strip("the UM division"), "the UM division")
        // …but sentence-case "Er,"/"Um," (a real filler) is still stripped.
        XCTAssertEqual(s.strip("Um, hello"), "hello")
    }

    func testPreservesFillerInsideQuotes() {
        XCTAssertEqual(s.strip(#"he said "I, uh, I don't know""#), #"he said "I, uh, I don't know""#)
        XCTAssertEqual(s.strip(#"uh, she said "um yes""#), #"she said "um yes""#) // outside stripped, inside kept
    }

    func testDoesNotMergeLines() {
        XCTAssertEqual(s.strip("first line um\nsecond line"), "first line\nsecond line")
    }

    func testRealParakeetOutput() {
        // Exactly what Parakeet emitted for the premise-check fixture.
        let input = "Um, so I was uh thinking that we should uh meet at 2, uh, actually 3 p.m. Um, yeah."
        let out = s.strip(input)
        XCTAssertFalse(out.lowercased().contains(" um "))
        XCTAssertFalse(out.lowercased().hasPrefix("um"))
        XCTAssertTrue(out.contains("so I was thinking that we should meet at 2"))
        XCTAssertTrue(out.contains("actually 3 p.m"))
        XCTAssertTrue(out.hasSuffix("yeah."))
        XCTAssertFalse(out.contains("  ")) // no double spaces
        XCTAssertFalse(out.contains(" ,")) // no space-before-comma
    }

    func testNeverFiresMidWordOrHyphenated() {
        XCTAssertEqual(s.strip("Umberto called"), "Umberto called")
        XCTAssertEqual(s.strip("the file is uh_oh.txt"), "the file is uh_oh.txt")
        XCTAssertEqual(s.strip("she said uh-huh to me"), "she said uh-huh to me")
        XCTAssertEqual(s.strip("mm-hmm was the reply"), "mm-hmm was the reply")
        XCTAssertEqual(s.strip("the summer heat"), "the summer heat") // "summer" contains "um"
    }

    func testProtectedDictionaryTokenSurvives() {
        // A dictionary acronym "UM" (case-insensitive collides with filler).
        XCTAssertEqual(s.strip("the UM report is ready", protecting: ["um"]), "the UM report is ready")
    }

    func testExtendedFillersAreOptInOnly() {
        XCTAssertEqual(s.strip("ah, I see. oh well."), "ah, I see. oh well.") // default: kept
        let ext = FillerStripper(extra: ["oh", "ah"])
        XCTAssertEqual(ext.strip("ah, I see"), "I see")
    }

    func testDisableAFiller() {
        let noUh = FillerStripper(disabled: ["uh"])
        XCTAssertEqual(noUh.strip("uh, the Uh brand"), "uh, the Uh brand") // uh not stripped
        XCTAssertEqual(noUh.strip("um, hello"), "hello")                    // um still stripped
    }

    func testCollapseStuttersFunctionWordsOnly() {
        XCTAssertEqual(s.strip("I I I think so"), "I think so")
        XCTAssertEqual(s.strip("the the meeting"), "the meeting")
        // Content-word repeats are PRESERVED (emphasis / rhetorical / list).
        XCTAssertEqual(s.strip("this is very very important"), "this is very very important")
        XCTAssertEqual(s.strip("no no no don't send it"), "no no no don't send it")
    }

    func testCollapseStuttersKeepsLegitimateDoubles() {
        // Words that legitimately double must NOT collapse.
        XCTAssertEqual(s.strip("what it is is a problem"), "what it is is a problem")
        XCTAssertEqual(s.strip("the fact that that happened"), "the fact that that happened")
        XCTAssertEqual(s.strip("the food was so so"), "the food was so so")
    }

    func testCollapseStuttersOff() {
        let noCollapse = FillerStripper(collapseStutters: false)
        XCTAssertEqual(noCollapse.strip("I I I think"), "I I I think")
    }

    func testIdempotent() {
        let inputs = [
            "Um, so I was uh thinking that we should uh meet at 2, uh, actually 3 p.m. Um, yeah.",
            "can we, um, look at the plan",
            "I I I think so",
            "she said uh-huh",
        ]
        for i in inputs {
            let once = s.strip(i)
            XCTAssertEqual(s.strip(once), once, "not idempotent for: \(i)")
        }
    }

    func testEmptyAndNoFillers() {
        XCTAssertEqual(s.strip(""), "")
        XCTAssertEqual(s.strip("a clean sentence with no fillers"), "a clean sentence with no fillers")
    }

    func testNoFillerInputCommasUntouched() {
        // Comma repair must NOT run when nothing was removed — a legit
        // abbreviation/appositive comma must survive.
        XCTAssertEqual(s.strip("I went to the U.S., the big one"), "I went to the U.S., the big one")
        XCTAssertEqual(s.strip("done, etc., and more"), "done, etc., and more")
        XCTAssertEqual(s.strip("red, green, blue"), "red, green, blue")
    }

    func testCorrectionCuesAgreeWithPrompt() {
        // AC #14: bypass cues must be a subset of the prompt-named cues.
        let prompt = Set(CorrectionCues.promptPhrases.map { $0.lowercased() })
        for cue in CorrectionCues.bypassPhrases {
            XCTAssertTrue(prompt.contains(cue.lowercased()), "bypass cue not named in prompt: \(cue)")
        }
    }

    func testPlausibleCorrectionHeuristic() {
        XCTAssertTrue(CorrectionCues.plausibleCorrection(in: "send it monday no wait tuesday"))
        XCTAssertTrue(CorrectionCues.plausibleCorrection(in: "meet at 3, no wait, 4pm")) // comma-split cue
        XCTAssertTrue(CorrectionCues.plausibleCorrection(in: "the plan i mean the backup"))
        // "actually" is deliberately NOT a bypass cue (too ambiguous) — short
        // "actually" corrections stay on the fast path (the spec's safe failure).
        XCTAssertFalse(CorrectionCues.plausibleCorrection(in: "meet at 2 actually 3"))
        XCTAssertFalse(CorrectionCues.plausibleCorrection(in: "I actually enjoyed the movie"))
        XCTAssertFalse(CorrectionCues.plausibleCorrection(in: "no thanks"))
        XCTAssertFalse(CorrectionCues.plausibleCorrection(in: "scratch that")) // lone cue, no replacement
    }
}
