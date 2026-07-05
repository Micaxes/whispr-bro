import XCTest
@testable import WhisprBroCore

final class DictionaryEngineTests: XCTestCase {
    private func engine(_ pairs: [(String, String)]) -> DictionaryEngine {
        DictionaryEngine(rules: pairs.map { .init(from: $0.0, to: $0.1) })
    }

    func testSingleWordCanonicalCasing() {
        let e = engine([("github", "GitHub")])
        XCTAssertEqual(e.apply("i pushed to github today"), "i pushed to GitHub today")
        // Case-insensitive match, verbatim target — even at sentence start.
        XCTAssertEqual(e.apply("Github is down"), "GitHub is down")
        XCTAssertEqual(e.apply("github"), "GitHub")
    }

    func testMultiWordToIdentifier() {
        let e = engine([("get user data", "getUserData")])
        XCTAssertEqual(e.apply("call get user data first"), "call getUserData first")
    }

    func testMultiWordToleratesSeparatorNoise() {
        let e = engine([("get user data", "getUserData")])
        // Commas/extra spaces/casing the ASR sprinkles in.
        XCTAssertEqual(e.apply("Get, User  Data"), "getUserData")
    }

    func testWholeWordBoundaryNotMidWord() {
        let e = engine([("github", "GitHub")])
        XCTAssertEqual(e.apply("githubbing around"), "githubbing around") // not matched
        XCTAssertEqual(e.apply("github-actions"), "GitHub-actions")       // hyphen is a boundary
    }

    func testLongestSourceFirst() {
        let e = engine([("get user data", "getUserData"), ("get user data details", "getUserDataDetails")])
        XCTAssertEqual(e.apply("get user data details please"), "getUserDataDetails please")
    }

    func testIdempotentOnAlreadyCorrected() {
        let e = engine([("acme corp", "AcmeCorp")])
        XCTAssertEqual(e.apply("AcmeCorp"), "AcmeCorp") // single token, no internal separator
    }

    func testReAppliesAfterModelUncorrects() {
        // The LLM re-introduces a separator; the post-pass fixes it.
        let e = engine([("acme corp", "AcmeCorp")])
        XCTAssertEqual(e.apply("welcome to Acme Corp"), "welcome to AcmeCorp")
    }

    func testEmptyDictionaryIsPassthrough() {
        let e = engine([])
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.apply("nothing changes here"), "nothing changes here")
    }

    func testRegexMetacharactersInSourceAreEscaped() {
        let e = engine([("c plus plus", "C++")])
        XCTAssertEqual(e.apply("i write c plus plus"), "i write C++")
    }

    func testCanonicalTargetsForAllowlist() {
        let e = engine([("github", "GitHub"), ("get user data", "getUserData")])
        XCTAssertEqual(e.canonicalTargets, ["GitHub", "getUserData"])
    }

    func testMatchesAcrossNonBreakingSpace() {
        // ASR/LLM joins the words with a non-breaking space (U+00A0). The regex
        // \s matches it; tokenize (isWhitespace) must too, or the substitution
        // is silently dropped.
        let e = engine([("get user data", "getUserData")])
        XCTAssertEqual(e.apply("call get\u{00A0}user\u{00A0}data now"), "call getUserData now")
    }

    func testLowercasedTargets() {
        let e = engine([("node package manager", "npm"), ("github", "GitHub")])
        XCTAssertEqual(e.lowercasedTargets, ["npm", "github"])
    }
}

final class RuleBasedCleanupTests: XCTestCase {
    func testCapitalizesNormalSentence() {
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("hello world"), "Hello world.")
    }

    func testLeavesInternalUppercaseIdentifier() {
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("getUserData returns null"),
                       "getUserData returns null.")
    }

    func testPreservesLowercaseDictionaryTargetAtStart() {
        // "npm" has no internal uppercase, so only the preserve-set saves it.
        XCTAssertEqual(
            TextFormatter.ruleBasedCleanup("npm install failed", preserveCasingFor: ["npm"]),
            "npm install failed.")
        // Without the preserve-set it would be capitalized.
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("npm install failed"),
                       "Npm install failed.")
    }
}
