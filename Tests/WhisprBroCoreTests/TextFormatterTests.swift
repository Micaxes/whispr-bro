import XCTest
@testable import WhisprBroCore

final class TextFormatterTests: XCTestCase {
    // MARK: - Output sanitizer

    func testSanitizeStripsOnlyAllowlistedPreambles() {
        XCTAssertEqual(
            TextFormatter.sanitize("Here is the cleaned text: Hello world."),
            "Hello world."
        )
        XCTAssertEqual(TextFormatter.sanitize("Corrected text: Hi."), "Hi.")
        // NOT in the allowlist — a dictation that starts "Here is the plan:" or
        // "Sure, here you go:" must be preserved verbatim.
        XCTAssertEqual(TextFormatter.sanitize("Here is the plan: ship Friday."),
                       "Here is the plan: ship Friday.")
        XCTAssertEqual(TextFormatter.sanitize("Sure, here you go: Hello."),
                       "Sure, here you go: Hello.")
    }

    func testSanitizeStripsFencesButNotQuotes() {
        // Code fences are a clear model artifact.
        XCTAssertEqual(TextFormatter.sanitize("```Hello.```"), "Hello.")
        // Ordinary quotes are preserved — a dictation may itself be a quote.
        XCTAssertEqual(TextFormatter.sanitize("\"Hello world.\""), "\"Hello world.\"")
    }

    func testSanitizeStripsThinkBlock() {
        XCTAssertEqual(
            TextFormatter.sanitize("<think>\nlet me reason\n</think>\n\nHello there."),
            "Hello there."
        )
        // Stray closing tag (the Qwen2.5 leak).
        XCTAssertEqual(
            TextFormatter.sanitize("Handle the error case. </think>"),
            "Handle the error case."
        )
    }

    func testSanitizeLeavesCleanTextUntouched() {
        let clean = "The quarterly report shows revenue grew twelve percent."
        XCTAssertEqual(TextFormatter.sanitize(clean), clean)
    }

    func testSanitizeDoesNotStripMidTextColon() {
        // A colon well into the text is not a preamble marker.
        let s = "Remember this: buy milk and eggs on the way home tonight."
        XCTAssertEqual(TextFormatter.sanitize(s), s)
    }

    // MARK: - Rule-based cleanup (fast path / fallback)

    func testRuleBasedCapitalizesAndTerminates() {
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("hello world"), "Hello world.")
    }

    func testRuleBasedPreservesExistingPunctuation() {
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("Hello world!"), "Hello world!")
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("Is it done?"), "Is it done?")
    }

    func testRuleBasedHandlesEmpty() {
        XCTAssertEqual(TextFormatter.ruleBasedCleanup(""), "")
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("   "), "")
    }
}
