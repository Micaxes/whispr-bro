import XCTest
@testable import WhisprBroCore

final class TranscriptScoreTests: XCTestCase {
    // MARK: - Identity / axis independence

    func testIdentityIsPerfect() {
        let s = TranscriptScore.score(
            hypothesis: "Hello, world. It's fine.", gold: "Hello, world. It's fine.")
        XCTAssertEqual(s.wordErrors, 0)
        XCTAssertEqual(s.wer, 0)
        XCTAssertEqual(s.punctF1, 1)
        XCTAssertEqual(s.caseAccuracy, 1)
    }

    func testPunctuationOnlyDiffLeavesWerAtZero() {
        // WER is punctuation-blind by construction; only the punct axis moves.
        let s = TranscriptScore.score(hypothesis: "Hello world.", gold: "Hello, world.")
        XCTAssertEqual(s.wer, 0)
        XCTAssertLessThan(s.punctF1, 1)
        // The one emitted mark is correct → perfect precision, partial recall.
        XCTAssertEqual(s.punctPrecision, 1)
        XCTAssertEqual(s.punctRecall, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.caseAccuracy, 1)
    }

    func testCaseOnlyDiffLeavesWerAndPunctAtOne() {
        let s = TranscriptScore.score(hypothesis: "meet bob.", gold: "Meet Bob.")
        XCTAssertEqual(s.wer, 0)
        XCTAssertEqual(s.punctF1, 1)
        XCTAssertEqual(s.caseAccuracy, 0)
        let half = TranscriptScore.score(hypothesis: "Meet bob.", gold: "Meet Bob.")
        XCTAssertEqual(half.caseAccuracy, 0.5, accuracy: 1e-9)
    }

    // MARK: - Hand-counted word errors

    func testHandCountedSubstitutionAndInsertion() {
        // S=1 (quick→fast), I=1 (jumps) → 2 errors over 4 gold words.
        let s = TranscriptScore.score(
            hypothesis: "the fast brown fox jumps", gold: "the quick brown fox")
        XCTAssertEqual(s.wordErrors, 2)
        XCTAssertEqual(s.goldWordCount, 4)
        XCTAssertEqual(s.wer, 0.5, accuracy: 1e-9)
    }

    func testHandCountedDeletion() {
        let s = TranscriptScore.score(hypothesis: "the quick fox", gold: "the quick brown fox")
        XCTAssertEqual(s.wordErrors, 1)
        XCTAssertEqual(s.wer, 0.25, accuracy: 1e-9)
    }

    // MARK: - Punctuation keying

    func testMisplacedMarkIsNotAMatch() {
        // The same mark on the WRONG word must not count.
        let s = TranscriptScore.score(hypothesis: "eggs milk, and bread", gold: "eggs, milk and bread")
        XCTAssertEqual(s.wer, 0)
        XCTAssertEqual(s.punctPrecision, 0)
        XCTAssertEqual(s.punctRecall, 0)
        XCTAssertEqual(s.punctF1, 0)
    }

    func testSpanishInvertedMarksAreScored() {
        let s = TranscriptScore.score(hypothesis: "¿qué hora es?", gold: "¿Qué hora es?")
        XCTAssertEqual(s.wer, 0)
        XCTAssertEqual(s.punctF1, 1)
        XCTAssertEqual(s.caseAccuracy, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testPunctuationOnlyHypothesisCountsAgainstPrecision() {
        // A dangling mark with no word core still counts as emitted.
        let s = TranscriptScore.score(hypothesis: ",", gold: "hi.")
        XCTAssertEqual(s.punctPrecision, 0)
        XCTAssertEqual(s.wer, 1, accuracy: 1e-9)   // "hi" deleted
    }

    func testMarksAdjacentToQuotesAndBracketsAreCounted() {
        // «plan."» — the period sits inside a closing quote; it must count
        // (and match) instead of vanishing with the quote.
        let s = TranscriptScore.score(
            hypothesis: "stick to the plan.\"", gold: "stick to the plan.\"")
        XCTAssertEqual(s.punctInGold, 1)
        XCTAssertEqual(s.punctF1, 1)
        // A hypothesis that drops that period now loses recall.
        let missing = TranscriptScore.score(
            hypothesis: "stick to the plan\"", gold: "stick to the plan.\"")
        XCTAssertEqual(missing.punctRecall, 0)
        // Bracketed: "(see fig.)" keeps its period through the paren.
        let bracketed = TranscriptScore.score(hypothesis: "(see fig.)", gold: "(see fig.)")
        XCTAssertEqual(bracketed.punctInGold, 1)
    }

    // MARK: - Edge cases

    func testEmptyStringsAreSafe() {
        let both = TranscriptScore.score(hypothesis: "", gold: "")
        XCTAssertEqual(both.wer, 0)
        XCTAssertEqual(both.punctF1, 1)
        XCTAssertEqual(both.caseAccuracy, 1)
        let emptyHyp = TranscriptScore.score(hypothesis: "", gold: "hello there.")
        XCTAssertEqual(emptyHyp.wordErrors, 2)     // two deletions
        XCTAssertEqual(emptyHyp.wer, 1, accuracy: 1e-9)
        XCTAssertEqual(emptyHyp.punctF1, 0)
        let emptyGold = TranscriptScore.score(hypothesis: "hello", gold: "")
        XCTAssertEqual(emptyGold.wer, 1)           // insertions against nothing
    }

    func testApostropheAndHyphenStayInWord() {
        // "it's" ≠ "its"; "top-notch" is ONE token, not two.
        let s = TranscriptScore.score(hypothesis: "its a top notch plan", gold: "it's a top-notch plan")
        XCTAssertEqual(s.goldWordCount, 4)
        XCTAssertEqual(s.wordErrors, 3)            // 2 substitutions + 1 insertion
        let ok = TranscriptScore.score(hypothesis: "it's a top-notch plan", gold: "it's a top-notch plan")
        XCTAssertEqual(ok.wer, 0)
    }

    // MARK: - Aggregation

    func testAggregateSumsCountsAcrossFixtures() {
        let a = TranscriptScore.score(hypothesis: "Hello world.", gold: "Hello, world.")
        let b = TranscriptScore.score(hypothesis: "Bye now.", gold: "Bye now.")
        let agg = TranscriptScore.aggregate([a, b])
        XCTAssertEqual(agg.goldWordCount, 4)
        XCTAssertEqual(agg.punctInGold, 3)
        XCTAssertEqual(agg.punctMatched, 2)
        XCTAssertEqual(agg.punctRecall, 2.0 / 3.0, accuracy: 1e-9)
    }
}
