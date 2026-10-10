import XCTest
@testable import WhisprBroCore

final class TextFormatterTests: XCTestCase {
    // MARK: - Long-utterance ceiling

    /// A hands-free dictation can now run for minutes, and the LLM stage is
    /// only measured up to 150 words. Over the ceiling it must be SKIPPED — not
    /// attempted and timed out into, which is how a paraphrase reaches the
    /// cursor: a 450-word dictation came back as 121 words, a 0.27 shrink that
    /// the live gate's 0.25 floor lets through.
    func testOverTheCeilingSkipsTheModelAndKeepsEveryWord() async {
        let limit = TextFormatter.Config().llmWordLimit
        let words = (1...(limit + 50)).map { "word\($0)" }
        let raw = words.joined(separator: " ")

        let formatter = TextFormatter(engine: LlamaCppEngine(
            modelPath: URL(fileURLWithPath: "/nonexistent.gguf"),
            promptBuilder: PromptBuilder(family: .qwen, systemPrompt: "")))
        let result = await formatter.formatDetailed(raw, rawMode: false)

        XCTAssertEqual(result.source, .fallback(.tooLong))
        XCTAssertNil(result.rejected)
        // Rule-based cleanup only: every spoken word survives, in order.
        XCTAssertEqual(
            result.text.split(whereSeparator: \.isWhitespace).count, words.count,
            "the rules path may never change the word count")
        XCTAssertTrue(result.text.lowercased().hasPrefix("word1 word2"))
        XCTAssertTrue(result.text.contains("word\(words.count)"))
    }

    /// The boundary: exactly at the ceiling still goes to the model, so the
    /// eval set's longest fixture (latency-150) keeps measuring the model path.
    func testAtTheCeilingStillTakesTheModelPath() async {
        let limit = TextFormatter.Config().llmWordLimit
        let raw = (1...limit).map { "word\($0)" }.joined(separator: " ")
        let formatter = TextFormatter(engine: LlamaCppEngine(
            modelPath: URL(fileURLWithPath: "/nonexistent.gguf"),
            promptBuilder: PromptBuilder(family: .qwen, systemPrompt: "")))
        let result = await formatter.formatDetailed(raw, rawMode: false)
        // No model is loaded here, so it lands on `.unavailable` — the point is
        // that it is NOT `.tooLong`: the ceiling did not claim this one.
        XCTAssertEqual(result.source, .fallback(.unavailable))
    }

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

    func testPlausibleNoLongerJudgesSHRINKAGE() {
        // The band's lower bound is gone: a resolved self-correction IS a
        // shrink, and no length test tells it from an over-edit. Over-editing
        // is what the benchmark scores (`ContentGuard` keeps the collapse
        // rule on `.bench`) and what the register wording fixes; refusing it
        // here handed the user the unresolved raw.
        let input = "so the quarterly report shows revenue grew twelve percent but we need "
            + "to double check the churn numbers before presenting them on thursday"
        XCTAssertEqual(TextFormatter.plausibleReformatting("Revenue grew.", of: input), "Revenue grew.")
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "Send it Tuesday.", of: "send it monday no wait tuesday please"),
            "Send it Tuesday.")
    }

    func testPlausibleNoLongerJudgesINTRODUCEDWords() {
        // The no-new-content-words rule is gone: the prompt commissions
        // homophone and split-word fixes, every exemption list written for
        // them sanctioned the corruption direction too, and `ContentGuard`'s
        // L6 (4 novel tokens on a ≥ 10-atom output) is the rule that
        // survived. One new word lands.
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "Send the final report on Thursday.", of: "send the report on thursday"),
            "Send the final report on Thursday.")
        // Four of them on a long enough output do not — and the verdict comes
        // from the gate that owns content, never from this length rule.
        XCTAssertEqual(
            TextFormatter.gateModelOutput(
                "Ship the improved production release candidate build tomorrow morning before standup.",
                of: "ship the build tomorrow morning before the standup").reason,
            "INVENTED (novel-count)")
    }

    func testPlausibleReadsTheSameLengthBandAsTheGuard() {
        // The UPPER bound is `ContentGuard`'s, read off the same atoms: this
        // rule may not hold a second, disagreeing opinion about length (it
        // once had its own 1.6× over whitespace words, which made the
        // shipping gate stricter than the grader on a band nobody could point
        // at). 9 atoms in, 15 out — a repetition loop, refused:
        let loop = "Ship the parser fix Friday. Ship the parser fix Friday. Ship the parser fix Friday."
        XCTAssertNil(TextFormatter.plausibleReformatting(
            loop, of: "ship the parser fix on friday before the freeze"))
        XCTAssertEqual(
            TextFormatter.implausibility(of: loop, input: "ship the parser fix on friday before the freeze"),
            "15 atoms out of 9")
        // …and L2's floor is real: under 6 atoms no length rule runs on
        // either side of the gate. It costs nothing on-device, where an
        // utterance that short never reaches the model (`fastPathWordLimit`).
        XCTAssertEqual(TextFormatter.plausibleReformatting(
            "Ship it Friday. Ship it Friday. Ship it Friday.", of: "ship it friday"),
            "Ship it Friday. Ship it Friday. Ship it Friday.")
    }

    func testPlausibleAllowsNumberAndTimeDenormalization() {
        // Number denormalization survives — nothing here reads word forms
        // any more, so "2:30" and "3 p.m." are simply not this rule's
        // business (`ContentGuard` checks their DIGITS against what he said).
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "Let's meet at 2:30 tomorrow afternoon.",
                of: "let's meet at two thirty tomorrow afternoon"),
            "Let's meet at 2:30 tomorrow afternoon.")
        XCTAssertEqual(
            TextFormatter.plausibleReformatting(
                "Meet me at 3 p.m. tomorrow.",
                of: "meet me at three in the afternoon tomorrow"),
            "Meet me at 3 p.m. tomorrow.")
    }

    func testPlausibleAcceptsEverySeedGold() {
        // Every seed fixture's hand-authored gold, judged against the same
        // stripped input the formatter sees, passes this half of the gate —
        // except the `all-filler` fragment, whose gold is empty and whose
        // refusal costs nothing (on-device the one-word fast path never
        // consults the gate). The `asr-slip` golds used to fail here, on the
        // introduced-word rule that is now deleted.
        let stripper = FillerStripper()
        var rejected: [String] = []
        for c in EvalCase.seeds {
            let input = stripper.strip(c.raw)
            if TextFormatter.plausibleReformatting(c.gold, of: input) == nil { rejected.append(c.id) }
        }
        XCTAssertEqual(rejected, ["fragment-01"])
    }
}
