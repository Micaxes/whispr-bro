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

    func testRuleBasedDoesNotOverCapitalizeAbbreviations() {
        // The abbreviation guard: "e.g." is not a sentence boundary.
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("see e.g. foo and bar"), "See e.g. foo and bar.")
    }

    // MARK: - Mid-utterance capitalization

    func testRuleBasedCapitalizesMidUtteranceSentences() {
        XCTAssertEqual(
            TextFormatter.ruleBasedCleanup("i sent the doc. please review it"),
            "I sent the doc. Please review it.")
        // ? and ! always end a sentence (abbreviations don't end in them).
        XCTAssertEqual(
            TextFormatter.ruleBasedCleanup("is it done? yes! ship it"),
            "Is it done? Yes! Ship it.")
    }

    func testRuleBasedAbbreviationGuards() {
        // Listed stems ("e.g", "etc", "p.m") — the follower stays lowercase.
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("we use e.g. npm for packages"),
                       "We use e.g. npm for packages.")
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("bring pens etc. also paper"),
                       "Bring pens etc. also paper.")
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("at 3 p.m. tomorrow works"),
                       "At 3 p.m. tomorrow works.")
        // Structural: a dotted initialism is exempt without listing…
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("the U.S. office is closed. bring your badge"),
                       "The U.S. office is closed. Bring your badge.")
        // …and "Ph.D." via its listed stem (its 2-letter part defeats the
        // single-letter structural pattern).
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("she has a Ph.D. in physics. impressive"),
                       "She has a Ph.D. in physics. Impressive.")
    }

    func testRuleBasedAmbiguousAbbreviationsAreDigitGated() {
        // The abbreviation reading ("no. 5", "est. 1999", "min. 3"): a digit
        // follower is never a sentence boundary, so the join stays lowercase.
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("no. 5 is ready"), "No. 5 is ready.")
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("founded est. 1999 downtown"),
                       "Founded est. 1999 downtown.")
        // The word reading: these stems end real sentences — the follower
        // capitalizes (the old unconditional exemption blocked this).
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("i told him no. he did not listen"),
                       "I told him no. He did not listen.")
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("wait a sec. then we go"),
                       "Wait a sec. Then we go.")
    }

    func testRuleBasedDictionaryTermAfterBoundaryStaysLowercase() {
        XCTAssertEqual(
            TextFormatter.ruleBasedCleanup("done. npm install next", preserveCasingFor: ["npm"]),
            "Done. npm install next.")
        // Internal uppercase survives without a dictionary entry.
        XCTAssertEqual(
            TextFormatter.ruleBasedCleanup("done. getUserData returns null"),
            "Done. getUserData returns null.")
    }

    func testRuleBasedSkipsCapitalizationAfterEllipsis() {
        // An ellipsis continues the sentence — no boundary.
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("i was thinking... maybe not"),
                       "I was thinking... maybe not.")
    }

    func testRuleBasedRepairsResidueBeforeCapitalizing() {
        XCTAssertEqual(TextFormatter.ruleBasedCleanup(", so anyway let's ship it"),
                       "So anyway let's ship it.")
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("that's the plan, ."), "That's the plan.")
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("is it done?. okay.. let's go"),
                       "Is it done? Okay. Let's go.")
        // A trailing comma folds away instead of becoming ",.".
        XCTAssertEqual(TextFormatter.ruleBasedCleanup("buy milk,"), "Buy milk.")
    }

    // MARK: - Punctuation repair

    func testRepairFoldsCommaRuns() {
        XCTAssertEqual(TextFormatter.repairPunctuation("eggs, , milk"), "eggs, milk")
        XCTAssertEqual(TextFormatter.repairPunctuation("eggs,, milk"), "eggs, milk")
        XCTAssertEqual(TextFormatter.repairPunctuation("eggs ,, milk"), "eggs, milk")
        XCTAssertEqual(TextFormatter.repairPunctuation("what;; now"), "what; now")
    }

    func testRepairStripsLeadingResidueButNotOpeners() {
        XCTAssertEqual(TextFormatter.repairPunctuation(", so anyway"), "so anyway")
        XCTAssertEqual(TextFormatter.repairPunctuation("; right"), "right")
        // Spanish openers, quotes, and parens are NOT residue.
        XCTAssertEqual(TextFormatter.repairPunctuation("¿qué hora es?"), "¿qué hora es?")
        XCTAssertEqual(TextFormatter.repairPunctuation("¡vamos!"), "¡vamos!")
        XCTAssertEqual(TextFormatter.repairPunctuation("\"quoted start\""), "\"quoted start\"")
        XCTAssertEqual(TextFormatter.repairPunctuation("(a note)"), "(a note)")
    }

    func testRepairDropsCommaBeforeTerminal() {
        XCTAssertEqual(TextFormatter.repairPunctuation("that's the plan, ."), "that's the plan.")
        XCTAssertEqual(TextFormatter.repairPunctuation("that's the plan,."), "that's the plan.")
        XCTAssertEqual(TextFormatter.repairPunctuation("wait, really, ?"), "wait, really?")
    }

    func testRepairDropsTrailingComma() {
        XCTAssertEqual(TextFormatter.repairPunctuation("buy milk,"), "buy milk")
        XCTAssertEqual(TextFormatter.repairPunctuation("buy milk,,"), "buy milk")
    }

    func testRepairFoldsDoubledAndMixedTerminals() {
        XCTAssertEqual(TextFormatter.repairPunctuation("okay.. next"), "okay. next")
        XCTAssertEqual(TextFormatter.repairPunctuation("is it done?."), "is it done?")
        XCTAssertEqual(TextFormatter.repairPunctuation("really.!"), "really!")
    }

    func testRepairPreservesEllipsisAndInterrobang() {
        // Runs of 3+ periods are a deliberate ellipsis.
        XCTAssertEqual(TextFormatter.repairPunctuation("wait... maybe"), "wait... maybe")
        // "?!" / "!?" carry no period — deliberate, untouched.
        XCTAssertEqual(TextFormatter.repairPunctuation("really?!"), "really?!")
        XCTAssertEqual(TextFormatter.repairPunctuation("no way!?"), "no way!?")
    }

    func testRepairIsIdempotentAndLeavesCleanTextAlone() {
        let cleans = [
            "Hello, world. It's fine.",
            "Is it done? Yes!",
            "e.g. npm — see the docs.",
            "¿Qué hora es? ¡Vamos!",
        ]
        for c in cleans { XCTAssertEqual(TextFormatter.repairPunctuation(c), c) }
        let dirty = [", so anyway", "eggs, , milk", "done?. okay..", "plan , .", "buy milk,,"]
        for d in dirty {
            let once = TextFormatter.repairPunctuation(d)
            XCTAssertEqual(TextFormatter.repairPunctuation(once), once, "not idempotent for: \(d)")
        }
    }

    // MARK: - Output validation (plausibleReformatting)

    func testPlausibleAcceptsFaithfulReformatting() {
        let input = "hey can you send me the updated design doc before standup tomorrow morning thanks"
        let output = "Hey, can you send me the updated design doc before standup tomorrow morning? Thanks."
        XCTAssertEqual(TextFormatter.plausibleReformatting(output, of: input), output)
    }

    func testPlausibleSanitizesAndRepairsBeforeJudging() {
        // Allowlisted preamble stripped, then residue folded — one line, in band.
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "Here is the cleaned text: That's the plan, .",
                of: "that's the plan"),
            "That's the plan.")
    }

    func testPlausibleRejectsEmpty() {
        XCTAssertNil(TextFormatter.plausibleReformatting("", of: "hello there my friend"))
        XCTAssertNil(TextFormatter.plausibleReformatting("  \n ", of: "hello there my friend"))
    }

    func testPlausibleRejectsMultiLineOutOfSingleLineInput() {
        // Commentary/answering — a dictation is one paragraph.
        XCTAssertNil(TextFormatter.plausibleReformatting(
            "Sure!\nHere are some thoughts on the design doc.",
            of: "send me the design doc before standup tomorrow"))
        // A multi-line INPUT may legitimately stay multi-line.
        let input = "first point\nsecond point about the plan"
        let output = "First point.\nSecond point about the plan."
        XCTAssertEqual(TextFormatter.plausibleReformatting(output, of: input), output)
    }

    func testPlausibleRejectsRunawayGeneration() {
        // The documented Llama-3.2 failure: "answered" a code dictation with a
        // generated function instead of cleaning the sentence.
        let input = "the function takes a user id and returns a promise"
        let runaway = "function getUser(id) { return new Promise((resolve, reject) => { "
            + "db.users.findById(id).then(user => resolve(user)).catch(reject) }) } "
            + "This function takes a user id and returns a promise as requested."
        XCTAssertNil(TextFormatter.plausibleReformatting(runaway, of: input))
    }

    func testPlausibleRejectsOverShrunkOutput() {
        let input = "so the quarterly report shows revenue grew twelve percent but we need "
            + "to double check the churn numbers before presenting them on thursday"
        XCTAssertNil(TextFormatter.plausibleReformatting("Revenue grew.", of: input))
    }

    func testPlausibleShortInputAbsoluteAllowance() {
        // 7 words → 3 words is 0.43× (under the ratio floor) but within the
        // ±4-word allowance that keeps the band meaningful on short inputs.
        // (Growth cases now die on the no-new-content-words check instead,
        // so the allowance matters for shrinkage — resolved corrections.)
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "Send it Tuesday.", of: "send it monday no wait tuesday please"),
            "Send it Tuesday.")
        // Beyond the allowance still fails.
        XCTAssertNil(TextFormatter.plausibleReformatting(
            "Send it.", of: "send it monday no wait tuesday please thanks"))
    }

    func testPlausibleRejectsIntroducedContentWords() {
        // The reproduced FM failure: the model ANSWERED the dictation —
        // single line and in-band, so every other check accepts it. "Yes" is
        // a new content word; the gate must reject.
        XCTAssertNil(TextFormatter.plausibleReformatting(
            "Yes, it is done. Okay, let's go.", of: "is it done?. okay.. let's go"))
        // One invented word rejects even when the rest is a faithful echo.
        XCTAssertNil(TextFormatter.plausibleReformatting(
            "Send the final report on Thursday.", of: "send the report on thursday"))
    }

    func testPlausibleAllowsNumericAndAllowlistedTimeTokens() {
        // Number denormalization survives: "2:30" has no alphabetic core, so
        // it never counts as an introduced content word.
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "Let's meet at 2:30 tomorrow afternoon.",
                of: "let's meet at two thirty tomorrow afternoon"),
            "Let's meet at 2:30 tomorrow afternoon.")
        // a.m./p.m. forms are the one allowlisted introduction (the dotted
        // variant compares equal after punctuation stripping).
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "Meet me at 3 p.m. tomorrow.",
                of: "meet me at three in the afternoon tomorrow"),
            "Meet me at 3 p.m. tomorrow.")
    }

    func testPlausibleAllowsSplitWordMerges() {
        // The prompt sanctions merging split words; a hyphen join strips to
        // the adjacent pair's concatenation, which is not "new" content
        // (measured live: the FM stage hyphenated "double check").
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "We need to double-check the churn numbers.",
                of: "we need to double check the churn numbers"),
            "We need to double-check the churn numbers.")
        // A non-adjacent mashup is still an invented word.
        XCTAssertNil(TextFormatter.plausibleReformatting(
            "We need to doublenumbers check the churn.",
            of: "we need to double check the churn numbers"))
    }

    func testPlausibleAcceptsEverySeedGold() {
        // The no-new-content-words rule must not catch legitimate transforms:
        // every seed fixture's hand-authored gold, judged against the same
        // stripped input the formatter sees, passes the gate.
        let stripper = FillerStripper()
        for c in EvalCase.seeds {
            let input = stripper.strip(c.raw)
            XCTAssertNotNil(TextFormatter.plausibleReformatting(c.gold, of: input),
                            "gate rejected the gold for seed '\(c.id)'")
        }
    }
}
