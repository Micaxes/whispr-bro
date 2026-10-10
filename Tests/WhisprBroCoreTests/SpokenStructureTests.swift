import XCTest

@testable import WhisprBroCore

/// The layout he says out loud: "new paragraph", "bullet point",
/// "and I quote … unquote".
///
/// Two halves, tested separately and then together: lifting the markers out of
/// the transcript before the model sees them, and putting real structure back
/// after the model has re-punctuated and re-cased everything.
final class SpokenStructureTests: XCTestCase {

    /// The whole round trip, with `format` standing in for the LLM: it may
    /// re-case, re-punctuate and split sentences — exactly what the real one
    /// does — and the marks must still land in the right places.
    private func roundTrip(
        _ raw: String,
        policy: SpokenStructure.Policy = .prose,
        format: (String) -> String = { TextFormatter.ruleBasedCleanup($0) }
    ) -> String {
        let extraction = SpokenStructure.extract(from: raw, policy: policy)
        let formatted = format(extraction.text)
        return SpokenStructure.apply(extraction.marks, to: formatted, from: extraction.text, policy: policy)
    }

    // MARK: Extraction

    func testMarkersAreLiftedOutOfTheText() {
        let e = SpokenStructure.extract(from: "buy milk new line buy eggs new line buy bread")
        XCTAssertEqual(e.text, "buy milk. buy eggs. buy bread",
                       "markers gone, and each segment ends where the break was")
        XCTAssertEqual(e.marks, [
            .init(kind: .lineBreak, wordIndex: 2, terminatedWord: "milk"),
            .init(kind: .lineBreak, wordIndex: 4, terminatedWord: "eggs"),
        ], "each mark names the word it terminated, so a moved anchor strips nothing")
    }

    func testEveryMarkerPhrase() {
        func kind(_ raw: String) -> SpokenStructure.Kind? {
            SpokenStructure.extract(from: raw).marks.first?.kind
        }
        XCTAssertEqual(kind("ship it new line then rest"), .lineBreak)
        XCTAssertEqual(kind("ship it new paragraph then rest"), .paragraphBreak)
        XCTAssertEqual(kind("ship it bullet point then rest"), .bullet)
        XCTAssertEqual(kind("ship it next bullet then rest"), .bullet)
        XCTAssertEqual(kind("ship it next bullet point then rest"), .bullet)
        // Quotes need a pair to survive pruning.
        let quoted = SpokenStructure.extract(from: "he said and i quote ship it unquote today")
        XCTAssertEqual(quoted.marks.map(\.kind), [.quoteOpen, .quoteClose])
        let explicit = SpokenStructure.extract(from: "he said open quote ship it close quote today")
        XCTAssertEqual(explicit.marks.map(\.kind), [.quoteOpen, .quoteClose])
    }

    /// Case and punctuation in the transcript must not hide a marker.
    func testMatchingIgnoresCaseAndPunctuation() {
        let e = SpokenStructure.extract(from: "ship it, New Line. then rest")
        XCTAssertEqual(e.marks.map(\.kind), [.lineBreak])
        XCTAssertEqual(e.text, "ship it, then rest",
                       "his comma is his — the break is the separator, not a rewrite")
    }

    // MARK: The determiner guard — speech ABOUT layout stays literal

    func testAPhraseUsedAsANounIsNotACommand() {
        for raw in [
            "they offered me a new line of credit",
            "the bullet point I made was ignored",
            "every new paragraph needs a topic sentence",
            "that new line is wrong",
            "we talked about the new paragraph for an hour",
        ] {
            let e = SpokenStructure.extract(from: raw)
            XCTAssertTrue(e.isEmpty, "\"\(raw)\" is speech about layout, not an instruction")
            XCTAssertEqual(e.text, raw, "and its words must survive untouched")
        }
    }

    func testAFollowingOfOrAboutAlsoMakesItLiteral() {
        XCTAssertTrue(SpokenStructure.extract(from: "new line of credit please").isEmpty)
        XCTAssertTrue(SpokenStructure.extract(from: "bullet point about pricing").isEmpty)
    }

    // MARK: Pruning — a marker that structures nothing

    /// A break with nothing on one side structures nothing, so no mark is
    /// produced — and its WORDS stay exactly as spoken. Dropping them was a
    /// silent deletion that happened before the output gate, where nothing
    /// downstream could ever see it.
    func testABreakThatStructuresNothingKeepsItsWords() {
        let trailing = SpokenStructure.extract(from: "ship the build new paragraph")
        XCTAssertTrue(trailing.isEmpty)
        XCTAssertEqual(trailing.text, "ship the build new paragraph")

        let leading = SpokenStructure.extract(from: "new line ship the build")
        XCTAssertTrue(leading.isEmpty)
        XCTAssertEqual(leading.text, "new line ship the build")
    }

    /// …but a leading BULLET is real: it makes the first line a list item.
    func testALeadingBulletSurvives() {
        let e = SpokenStructure.extract(from: "bullet point finish the deck")
        XCTAssertEqual(e.marks, [.init(kind: .bullet, wordIndex: 0)],
                       "nothing precedes it, so no terminator was inserted")
        XCTAssertEqual(e.text, "finish the deck")
    }

    func testUnpairedQuoteMarkersStayLiteral() {
        let open = SpokenStructure.extract(from: "he said and i quote we are shipping")
        XCTAssertTrue(open.isEmpty)
        XCTAssertEqual(open.text, "he said and i quote we are shipping")

        let close = SpokenStructure.extract(from: "we are shipping unquote")
        XCTAssertTrue(close.isEmpty)
        XCTAssertEqual(close.text, "we are shipping unquote")
    }

    func testAnEmptyQuoteIsNotAQuote() {
        let e = SpokenStructure.extract(from: "he said open quote close quote and left")
        XCTAssertTrue(e.isEmpty, "nothing between the markers")
    }

    // MARK: Registers

    func testTerminalTakesNoStructureAtAll() {
        // A newline in a shell is Return: it would run the half-typed command.
        XCTAssertEqual(SpokenStructure.policy(for: .terminal).features, [])
        let e = SpokenStructure.extract(from: "git commit new line git push",
                                        policy: SpokenStructure.policy(for: .terminal))
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.text, "git commit new line git push")
    }

    func testIdeTakesBreaksButNotBulletsAndNeverInventsPunctuation() {
        let policy = SpokenStructure.policy(for: .ide)
        XCTAssertTrue(policy.features.contains(.lineBreak))
        XCTAssertFalse(policy.features.contains(.bullet), "\"- \" in source code is a syntax error")
        XCTAssertFalse(policy.features.contains(.numbered), "nor a numbered list")
        XCTAssertFalse(policy.sentenceBoundaries, "a period added to code is a syntax error")
        XCTAssertFalse(policy.capitalizeLines, "`Let y = 2` does not compile")

        let e = SpokenStructure.extract(from: "let x = 1 new line bullet point let y = 2", policy: policy)
        XCTAssertEqual(e.marks.map(\.kind), [.lineBreak])
        XCTAssertEqual(e.text, "let x = 1 bullet point let y = 2",
                       "a rejected marker keeps its words, and no period is invented")
        XCTAssertEqual(
            SpokenStructure.apply(e.marks, to: e.text, from: e.text, policy: policy),
            "let x = 1\nbullet point let y = 2")
    }

    func testEveryOtherRegisterTakesEveryLayoutFeature() {
        for category in [AppCategory.unknown, .messaging, .mail, .browser, .notes] {
            XCTAssertEqual(SpokenStructure.policy(for: category).features,
                           Set(SpokenStructure.Feature.allCases).subtracting([.numbered]),
                           "\(category) — every stated layout, no inference")
        }
        // Messaging differs only in who owns the opening capital and the full
        // stop — see testRegisterDecidesWhoOwnsTheOpeningWordAndTheFullStop.
        for category in [AppCategory.unknown, .mail, .browser, .notes] {
            XCTAssertEqual(SpokenStructure.policy(for: category), .prose, "\(category)")
        }
    }

    // MARK: Applying structure through a rewrite

    func testBreaksSurviveRecasingAndRepunctuation() {
        XCTAssertEqual(roundTrip("buy milk new line buy eggs new line buy bread"),
                       "Buy milk\nBuy eggs\nBuy bread.")
    }

    func testParagraphBreakMakesABlankLine() {
        let out = roundTrip("the plan is simple new paragraph we start with the pilot")
        XCTAssertEqual(out, "The plan is simple.\n\nWe start with the pilot.",
                       "a paragraph is prose: it keeps its period")
    }

    func testBulletsBecomeAList() {
        XCTAssertEqual(
            roundTrip("bullet point finish the deck next bullet call marco next bullet book the flights"),
            "- Finish the deck\n- Call marco\n- Book the flights",
            "a list: every item capitalized, no terminators — including the last")
    }

    /// The anchor is a WORD, not an offset — the formatter may insert
    /// punctuation and change casing before it and the break must not drift.
    func testAnchorsSurviveAnAggressiveRewrite() {
        let out = roundTrip("first point new line second point") { text in
            // Stand-in for a formatter that re-cases and repunctuates.
            "First point, " + text.split(separator: " ").dropFirst(2).joined(separator: " ") + "!"
        }
        XCTAssertEqual(out, "First point\nSecond point!")
    }

    func testAMarkWhoseAnchorWasDeletedIsSkipped() {
        // The formatter dropped everything after the break: no anchor, so no
        // stray line break at the end.
        let out = roundTrip("keep this new line drop that") { _ in "Keep this." }
        XCTAssertEqual(out, "Keep this.")
    }

    // MARK: Quotations

    func testQuotationMarksWrapTheSpokenSpan() {
        XCTAssertEqual(
            roundTrip("he said and i quote we are not shipping unquote today"),
            "He said \"we are not shipping\" today.")
    }

    func testTheClosingQuoteGoesInsideTrailingPunctuation() {
        // The formatter terminates the sentence; the quote closes inside it.
        let out = roundTrip("she said open quote ship it close quote")
        XCTAssertEqual(out, "She said \"ship it.\"")
    }

    func testQuotesAndBreaksTogether() {
        let out = roundTrip("he said and i quote ship it unquote new line then he left")
        XCTAssertEqual(out, "He said \"ship it.\"\nThen he left.",
                       "the line break keeps the final sentence's period")
    }

    // MARK: Inferred lists — the thing nobody asks for by name

    /// **Inference is off in every shipping register.** It is kept, tested and
    /// opt-in because the measurement is worth keeping — and because the
    /// reason it is off is the test below it.
    func testInferenceIsNotReachableFromAnyRegister() {
        for category in [AppCategory.unknown, .messaging, .mail, .browser, .notes, .ide, .terminal] {
            XCTAssertFalse(SpokenStructure.policy(for: category).features.contains(.numbered),
                           "\(category) must not infer lists")
            XCTAssertFalse(SpokenStructure.policy(for: category, verbatim: true).features.contains(.numbered))
        }
        XCTAssertTrue(SpokenStructure.Policy.inferring.features.contains(.numbered))
    }

    func testAnAscendingEnumerationBecomesANumberedListWhenOptedIn() {
        XCTAssertEqual(
            roundTrip("i need to do three things today first finish the deck second call marco and third book the flights",
                      policy: .inferring),
            "I need to do three things today:\n1. Finish the deck\n2. Call marco\n3. Book the flights",
            "the lead-in ends in a colon and each item is a line")
        XCTAssertEqual(
            roundTrip("the steps are one clone the repo two run the install script three open the app",
                      policy: .inferring),
            "The steps are:\n1. Clone the repo\n2. Run the install script\n3. Open the app")
    }

    /// Why inference is off: these are ordinary sentences a founder says, and
    /// every one of them became a numbered list — with "one", "two" and "and"
    /// deleted from his text. The rules that separate a list from a count are
    /// semantic; the guard here is a word count, and this is what it misses.
    func testTheInferenceFailuresThatKeepItTurnedOff() {
        for raw in [
            "we need one more week for qa two more engineers for the port and three days of buffer",
            "we lost one deal last quarter two people quit and three customers churned",
            "there is one bug in checkout two bugs in search and three bugs in the admin panel",
            "it took one hour to write two hours to review and three days to ship it",
            "i have one call at nine two calls at eleven and three meetings after lunch",
        ] {
            XCTAssertTrue(SpokenStructure.extract(from: raw).isEmpty,
                          "no shipping register may restructure \"\(raw)\"")
            XCTAssertFalse(SpokenStructure.extract(from: raw, policy: .inferring).isEmpty,
                           "…and this is the case the opt-in policy still gets wrong")
        }
    }

    /// Everything the detector must leave alone. Each of these counts
    /// something in ordinary speech, and turning any of them into a list would
    /// be worse than doing nothing.
    func testProseThatMerelyCountsStaysProse() {
        // (Run against the opt-in policy: under any shipping register none of
        // these can restructure, because inference is off entirely.)
        for raw in [
            // Two items: below the floor, and extremely common.
            "first we ship it then we tell the team",
            // Quantities, not markers — one word per "item".
            "i have one dog two cats and three birds at home",
            // Determiners: describing, not counting.
            "the first thing you notice is the noise and the second you walk in it hits you and the third time it is normal",
            // Partitives.
            "one of the things i noticed is that two of the tests are flaky and three people mentioned it",
            // A count word that never enumerates.
            "we need three things a laptop a charger and a dongle",
            // Starts at "second": a run must begin at the first item.
            "second thoughts aside we should third party this and fourth quarter is fine",
        ] {
            XCTAssertTrue(SpokenStructure.extract(from: raw, policy: .inferring).isEmpty,
                          "\"\(raw)\" is prose that counts, not a list")
        }
    }

    func testEnumerationNeedsThreeItems() {
        XCTAssertEqual(SpokenStructure.minimumListItems, 3)
        let two = "first finish the deck second call marco"
        XCTAssertTrue(SpokenStructure.extract(from: two, policy: .inferring).isEmpty)
        let three = "first finish the deck second call marco third book the flights"
        XCTAssertEqual(SpokenStructure.extract(from: three, policy: .inferring).marks.count, 3)
    }

    func testAnExplicitMarkerWinsOverInference() {
        // He said "bullet point": he is not also being counted at.
        let e = SpokenStructure.extract(
            from: "bullet point first task bullet point second task bullet point third task")
        XCTAssertEqual(e.marks.map(\.kind), [.bullet, .bullet, .bullet])
    }

    func testCodeAndShellsAreNeverEnumerated() {
        for policy in [SpokenStructure.Policy.code, .none, .prose] {
            let e = SpokenStructure.extract(
                from: "the steps are one clone the repo two run the install script three open the app",
                policy: policy)
            XCTAssertTrue(e.isEmpty, "\(policy.features) must not invent a list")
        }
    }

    // MARK: Finishing the text

    func testProseGetsATerminatorTheModelForgot() {
        XCTAssertEqual(SpokenStructure.terminating("he said we are shipping"), "he said we are shipping.")
        XCTAssertEqual(SpokenStructure.terminating("already done."), "already done.")
        XCTAssertEqual(SpokenStructure.terminating("really?"), "really?")
        XCTAssertEqual(SpokenStructure.terminating("wait!"), "wait!")
        // Inside the quotation it ends, not after it.
        XCTAssertEqual(SpokenStructure.terminating("He said \"ship it\""), "He said \"ship it.\"")
        // A list item is not a sentence.
        XCTAssertEqual(SpokenStructure.terminating("- Finish the deck\n- Call Marco"),
                       "- Finish the deck\n- Call Marco")
        XCTAssertEqual(SpokenStructure.terminating("1. Clone the repo\n2. Run it"),
                       "1. Clone the repo\n2. Run it")
        XCTAssertEqual(SpokenStructure.terminating("   "), "   ")
    }

    func testTheFirstWordIsCapitalizedWhenTheModelLeftIt() {
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("he said it was fine"), "He said it was fine")
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("Already capital"), "Already capital")
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("npm test", preserveCasingFor: ["npm"]),
                       "npm test", "a dictionary term keeps its casing")
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("getUserData returns nil"),
                       "getUserData returns nil", "an identifier keeps its casing")
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord(""), "")
    }

    func testTheRegistersThatFinishAndTheOnesThatDoNot() {
        for category in [AppCategory.unknown, .mail, .browser, .notes] {
            XCTAssertTrue(SpokenStructure.policy(for: category).finishes, "\(category)")
        }
        // An instant message keeps its own casing and ending — StyleRules
        // tells the model "a lowercase start is fine" there.
        XCTAssertFalse(SpokenStructure.policy(for: .messaging).finishes)
        // …and so does any app where Auto-Clean is off.
        XCTAssertFalse(SpokenStructure.policy(for: .notes, verbatim: true).finishes)
        XCTAssertFalse(SpokenStructure.Policy.code.finishes)
        XCTAssertFalse(SpokenStructure.Policy.none.finishes)
        // Layout still applies in every one of them.
        for category in [AppCategory.unknown, .messaging, .mail, .browser, .notes] {
            XCTAssertTrue(SpokenStructure.policy(for: category).features.contains(.bullet), "\(category)")
        }
    }

    // MARK: Regressions the verifier panel found

    /// Two identical markers: the first one's words were silently deleted and
    /// the second left literal, because the rebuild re-matched phrases and
    /// correlated them by kind.
    func testRepeatedMarkersAllSurvive() {
        let three = SpokenStructure.extract(from: "alpha new line beta new line gamma")
        XCTAssertEqual(three.marks.map(\.kind), [.lineBreak, .lineBreak])
        XCTAssertEqual(three.text, "alpha. beta. gamma")
        XCTAssertEqual(roundTrip("alpha new line beta new line gamma"), "Alpha\nBeta\nGamma.")
    }

    func testMixedMarkersDoNotLeak() {
        let e = SpokenStructure.extract(
            from: "bullet point call the bank next bullet renew the insurance")
        XCTAssertFalse(e.text.lowercased().contains("bullet point"), "got: \(e.text)")
        XCTAssertEqual(e.marks.map(\.kind), [.bullet, .bullet])
    }

    /// `terminating` dropped the closing quote and appended `."` without
    /// checking for a terminator already inside it: `done."` → `done.."`.
    func testAQuotationThatIsAlreadyFinishedIsLeftAlone() {
        XCTAssertEqual(SpokenStructure.terminating("He said \"we are done.\""), "He said \"we are done.\"")
        XCTAssertEqual(SpokenStructure.terminating("He said \"really?\""), "He said \"really?\"")
        XCTAssertEqual(SpokenStructure.terminating("He said \"ship it\""), "He said \"ship it.\"")
    }

    /// Talking ABOUT the layout — a subject or a modal in front of the marker.
    /// Removing these to fix "call me new line then text me" took the whole
    /// class with it, and everything here started being taken as a command.
    func testTalkingAboutTheLayoutIsNotACommand() {
        for raw in [
            "i will start a new paragraph when the section changes",
            "you should start a new line after the greeting",
            "could you skip a line between the paragraphs",
            "we should skip a line before the signature block",
            "should i start a new paragraph here or keep it as one block",
            "do you want a new line there or not",
        ] {
            XCTAssertTrue(SpokenStructure.extract(from: raw).isEmpty, "\"\(raw)\"")
        }
    }

    /// …while the object pronouns, which only frame a bullet, must not block
    /// a break. This is the case the subject frames were removed for.
    func testAnObjectPronounDoesNotBlockABreak() {
        XCTAssertEqual(SpokenStructure.extract(from: "call me new line then text me").marks.map(\.kind),
                       [.lineBreak])
        XCTAssertEqual(
            SpokenStructure.extract(from: "that works for me new paragraph lets do it").marks.map(\.kind),
            [.paragraphBreak])
        // …but it still frames a bullet, which is also a verb.
        XCTAssertTrue(SpokenStructure.extract(from: "can you bullet point that for me").isEmpty)
    }

    /// The closing period of a LIST is stripped only when the formatter added
    /// it. "meet at 5 p.m." ends in his abbreviation, not our boundary.
    func testAListDoesNotEatHisClosingPeriod() {
        let his = SpokenStructure.extract(from: "bullet point call the dentist bullet point meet at 5 p.m.")
        XCTAssertTrue(
            SpokenStructure.apply(his.marks, to: his.text, from: his.text).hasSuffix("5 p.m."),
            "got: \(SpokenStructure.apply(his.marks, to: his.text, from: his.text))")
        // …and an unterminated list still closes without one.
        let ours = SpokenStructure.extract(from: "bullet point finish the deck bullet point call marco")
        XCTAssertEqual(SpokenStructure.apply(ours.marks, to: ours.text + ".", from: ours.text),
                       "- Finish the deck\n- Call marco")
    }

    /// An opening quotation whose close the formatter dropped would leave a
    /// lone `"` in his text.
    func testAnUnclosedQuotationIsDropped() {
        let e = SpokenStructure.extract(from: "he said and i quote ship it unquote and then he left")
        XCTAssertEqual(e.marks.map(\.kind), [.quoteOpen, .quoteClose])
        // The formatter kept only the opening half of the span.
        let out = SpokenStructure.apply(e.marks, to: "He said ship it.", from: e.text)
        XCTAssertFalse(out.contains("\""), "a quotation opens and closes, or not at all — got: \(out)")
    }

    /// The terminator is stripped only from the word it was added to: when the
    /// formatter drops that word, the anchor moves onto punctuation that is his.
    func testAMovedAnchorStripsNothing() {
        let e = SpokenStructure.extract(from: "the meeting is at 5 p.m. tomorrow new line bring the deck")
        // The formatter dropped "tomorrow", so the line now ends at "p.m.".
        let out = SpokenStructure.apply(e.marks, to: "The meeting is at 5 p.m. bring the deck", from: e.text)
        XCTAssertTrue(out.contains("5 p.m.\n"), "the abbreviation keeps its period — got: \(out)")
    }

    func testShellCommandsKeepTheirCaseAtALineStart() {
        for command in ["ls", "cd", "rm", "vim", "npm", "git", "python3"] {
            XCTAssertEqual(SpokenStructure.capitalizingFirstWord("\(command) something"),
                           "\(command) something", command)
        }
        // …but an ordinary English word that happens to be a command is not
        // held back.
        for word in ["make", "cat", "swift", "node", "python", "open", "touch"] {
            XCTAssertEqual(SpokenStructure.capitalizingFirstWord("\(word) something").first, "\(word)".first?.uppercased().first,
                           word)
        }
    }

    /// The phrasings that ARE supported, after the ambiguous ones were cut.
    func testTheSupportedCommandPhrasings() {
        func kind(_ raw: String) -> SpokenStructure.Kind? {
            SpokenStructure.extract(from: raw).marks.first?.kind
        }
        XCTAssertEqual(kind("buy milk next line buy eggs"), .lineBreak)
        XCTAssertEqual(kind("buy milk line break buy eggs"), .lineBreak)
        XCTAssertEqual(kind("ship it new paragraph then rest"), .paragraphBreak)
        XCTAssertEqual(kind("ship it next bullet point then rest"), .bullet)
        XCTAssertEqual(SpokenStructure.extract(from: "he said open quote ship it close quote today")
                        .marks.map(\.kind), [.quoteOpen, .quoteClose])
        // Bare "quote" is an ordinary verb and is not a marker.
        XCTAssertTrue(SpokenStructure.extract(from: "he said quote ship it unquote today").isEmpty)
        XCTAssertTrue(SpokenStructure.extract(from: "the quote was higher than we expected").isEmpty)
    }

    /// A connective before a break is KEPT — deleting "or" from "ship it
    /// friday OR new line we could wait" changes what he said. It just does
    /// not get a full stop stapled to it.
    func testAConnectiveBeforeABreakIsKeptAndNotTerminated() {
        XCTAssertEqual(roundTrip("thanks for the update and new paragraph i will review it tonight"),
                       "Thanks for the update and\n\nI will review it tonight.")
        let alternative = SpokenStructure.extract(
            from: "we could ship it friday or new line we could wait until monday")
        XCTAssertTrue(alternative.text.contains("friday or"), "got: \(alternative.text)")
    }

    /// A break boundary is always a period — the question guess that used to
    /// live here made "do it this week new line then tell me" a question, and
    /// unlike `terminating` the model never sees it again to correct it.
    func testABreakBoundaryIsAlwaysAPeriod() {
        let e = SpokenStructure.extract(from: "can you look at the pr when you get a sec new line no rush")
        XCTAssertTrue(e.text.contains("sec."), "got: \(e.text)")
        let imperative = SpokenStructure.extract(from: "do it this week new line then tell me")
        XCTAssertTrue(imperative.text.contains("week."), "got: \(imperative.text)")
    }

    func testCommandsAndAddressesAreNotCapitalized() {
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("npm install keeps failing"),
                       "npm install keeps failing", "a command word is lower case by nature")
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("git push failed again"), "git push failed again")
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("sonjiunn@ymail.com is the address"),
                       "sonjiunn@ymail.com is the address")
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("/usr/local/bin is on the path"),
                       "/usr/local/bin is on the path")
        XCTAssertEqual(SpokenStructure.capitalizingFirstWord("hello there"), "Hello there")
    }

    /// Code and shells are never "finished": an invented capital or period
    /// there is a syntax error.
    func testCodeAndShellsAreNeverFinished() {
        XCTAssertFalse(SpokenStructure.Policy.code.finishes)
        XCTAssertFalse(SpokenStructure.Policy.none.finishes)
        XCTAssertTrue(SpokenStructure.Policy.prose.finishes)
        XCTAssertTrue(SpokenStructure.policy(for: .notes).finishes)
    }

    // MARK: The frame guard, and why it is shaped this way

    /// The guard that survived six review rounds: ONE determiner check, plus
    /// verb frames for `bullet` alone. The phrases that needed more than this
    /// were removed rather than guarded — "PLEASE start a new paragraph here
    /// is the plan" and "I WILL start a new paragraph when the section
    /// changes" are the same sentence shape, and no word list separates them.
    func testTheGuardIsOneDeterminerCheckPlusBulletVerbs() {
        // Determiner: every kind.
        XCTAssertTrue(SpokenStructure.extract(from: "they offered me a new line of credit").isEmpty)
        // Verb frame: bullets only…
        XCTAssertTrue(SpokenStructure.extract(from: "can you bullet point that for me").isEmpty)
        XCTAssertTrue(SpokenStructure.extract(from: "just bullet point it and send it over").isEmpty)
        // …and a break after the same word is still a command.
        XCTAssertEqual(SpokenStructure.extract(from: "thank you new paragraph best regards").marks.map(\.kind),
                       [.paragraphBreak])
        XCTAssertEqual(SpokenStructure.extract(from: "call me new line then text me").marks.map(\.kind),
                       [.lineBreak])
    }

    /// The phrases deliberately NOT supported, and why. Each carries its own
    /// determiner (blinding the guard) or is an ordinary verb.
    func testDeliberatelyUnsupportedPhrases() {
        for raw in [
            "okay so the plan is simple start a new paragraph we begin in march",
            "you should start a new line after the greeting",
            "could you skip a line between the paragraphs",
            "please quote the new price and then unquote the old one",
            "i will quote the terms in the email and then end quote",
        ] {
            XCTAssertTrue(SpokenStructure.extract(from: raw).isEmpty,
                          "\"\(raw)\" must be left exactly as spoken")
        }
    }

    /// Everyday email phrasings that a wider guard silently declined — the
    /// marker words then went to the model, which printed or deleted them.
    func testABreakAfterAPronounIsStillACommand() {
        for raw in [
            "thank you new paragraph best regards michelangelo",
            "if that works for you new paragraph thanks again",
            "let me know as soon as you can new paragraph thanks",
            "that part is up to you new line let me know what you think",
            "i will call you new line then we ship",
            "email me bullet point finish the deck bullet point call marco",
        ] {
            XCTAssertFalse(SpokenStructure.extract(from: raw).isEmpty,
                           "\"\(raw)\" is a command he gave")
        }
    }

    // MARK: Which mark ends a sentence

    /// A period, always — never a guessed question mark. Every attempt to
    /// infer one traded a wrong "?" on "can do" for a wrong "." on "is the
    /// migration reversible". The model marks its own questions.
    func testTerminatingAlwaysUsesAPeriod() {
        for statement in [
            "can do", "will do it tomorrow", "may as well ship it",
            "do the dishes tonight", "have marco review the deck",
            "should be fine either way", "had a good run this morning",
            "was great seeing you", "am heading out now", "ship it on friday",
        ] {
            XCTAssertEqual(SpokenStructure.terminating(statement), statement + ".", statement)
        }
        // …including the ones a reader would mark "?" — the model already
        // marks those itself, and guessing cost more than it bought.
        for question in [
            "what time does the pharmacy close", "can you review the deck",
            "are we still on for monday",
        ] {
            XCTAssertEqual(SpokenStructure.terminating(question), question + ".", question)
        }
        // A mark the model DID add is never second-guessed.
        XCTAssertEqual(SpokenStructure.terminating("are we still on?"), "are we still on?")
    }

    func testALineItemIsNeverTerminated() {
        XCTAssertEqual(SpokenStructure.terminating("- Finish the deck\n- Call Marco"),
                       "- Finish the deck\n- Call Marco")
        XCTAssertEqual(SpokenStructure.terminating("1. Clone the repo\n2. Run it"),
                       "1. Clone the repo\n2. Run it")
    }

    // MARK: Nothing may be lost

    /// The invariant that matters most: this layer MOVES text, it never
    /// rewrites it. Every letter and digit that goes in comes out, in order.
    ///
    /// Written after the first implementation rebuilt the output from parsed
    /// tokens and silently ate the `=` in `let x = 1` — a token carries a word
    /// and its punctuation, and anything that is neither simply vanished.
    func testNoLetterOrDigitIsEverLost() {
        let cases = [
            "let x = 1 new line let y = x + 2",
            "run npm install new line then npm test -- --watch",
            "he said and i quote 42 % is not enough unquote so we moved on",
            "bullet point alpha & omega next bullet a -> b next bullet c/d",
            "email me at marco@example.com new paragraph or call 555 1234",
            "buy milk new line buy eggs new line buy bread",
        ]
        func core(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        for raw in cases {
            for policy in [SpokenStructure.Policy.prose, .code] {
                let e = SpokenStructure.extract(from: raw, policy: policy)
                let formatted = e.text            // a formatter that changed nothing
                let out = SpokenStructure.apply(e.marks, to: formatted, from: e.text, policy: policy)
                XCTAssertEqual(core(out), core(e.text), "content changed for \"\(raw)\"")
            }
        }
    }

    func testSymbolsSurviveAStructuredRewrite() {
        let e = SpokenStructure.extract(from: "let x = 1 new line let y = 2",
                                        policy: .code)
        XCTAssertEqual(SpokenStructure.apply(e.marks, to: e.text, from: e.text, policy: .code),
                       "let x = 1\nlet y = 2")
    }

    func testDictionaryCasingIsNotClobberedAtALineStart() {
        let e = SpokenStructure.extract(from: "install it new line npm test")
        let out = SpokenStructure.apply(e.marks, to: e.text, from: e.text,
                                        preserveCasingFor: ["npm"])
        XCTAssertEqual(out, "install it\nnpm test", "a dictionary term keeps its casing")
        // "npm" is in the built-in floor too, so it survives without one.
        XCTAssertEqual(SpokenStructure.apply(e.marks, to: e.text, from: e.text), "install it\nnpm test")
        // A word with no such claim IS capitalized at a line start.
        let plain = SpokenStructure.extract(from: "install it new line then restart")
        XCTAssertEqual(SpokenStructure.apply(plain.marks, to: plain.text, from: plain.text),
                       "install it\nThen restart")
        // The FIRST word is never touched — that line belongs to the formatter.
        let first = SpokenStructure.extract(from: "npm test new line npm run build")
        XCTAssertEqual(SpokenStructure.apply(first.marks, to: first.text, from: first.text),
                       "npm test\nnpm run build")
    }

    // MARK: Nothing to do

    func testTextWithoutMarkersIsUntouched() {
        let raw = "so there are two options we could either ship it friday or wait until monday"
        let e = SpokenStructure.extract(from: raw)
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.text, raw)
        XCTAssertEqual(SpokenStructure.apply([], to: "anything", from: raw), "anything",
                       "no marks, no rewriting")
    }

    func testEmptyInput() {
        let e = SpokenStructure.extract(from: "")
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.text, "")
        XCTAssertEqual(SpokenStructure.apply([.init(kind: .lineBreak, wordIndex: 1)], to: "", from: ""), "")
    }
}
