import XCTest
@testable import WhisprBroCore

/// Hand-counted pins for the §4.5 gates. Every trigger is asserted by name
/// (never "isGated == true"), the three real-history failure shapes (rows
/// 70 / 54 / 58) are replicated with invented content, and the boundaries
/// of each threshold are pinned from both sides — a gate that fires one
/// word early zeroes a composite, so the exact edge is the contract.
final class ContentGuardTests: XCTestCase {
    private func check(_ raw: String, _ out: String, gold: String? = nil,
                       alternates: [EvalCase.Alternate] = [],
                       fillers: [EvalCase.Filler]? = nil,
                       stutters: [EvalCase.Stutter]? = nil) -> ContentGuard {
        ContentGuard.check(raw: raw, out: out, gold: gold, alternates: alternates,
                           fillers: fillers, stutters: stutters)
    }

    // MARK: - Thresholds (§4.5 literals)

    func testThresholdLiteralsMatchThePlan() {
        XCTAssertEqual(EvalThresholds.answeredLengthRatio, 1.5)
        XCTAssertEqual(EvalThresholds.answerOpeners, ["sure", "certainly", "here's", "here", "yes", "okay"])
        // The opener echo reads the WHOLE raw, so there is no window constant
        // left to pin: a raw whose own "okay" sits at index 3 was refused for
        // opening with it (task-023 fix round).
        XCTAssertEqual(EvalThresholds.interrogativeOpeners.count, 29)
        for word in ["what", "which", "who", "whom", "whose", "when", "where", "why", "how",
                     "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
                     "should", "would", "will", "shall", "have", "has", "had", "may", "might", "must"] {
            XCTAssertTrue(EvalThresholds.interrogativeOpeners.contains(word), word)
        }
        XCTAssertEqual(EvalThresholds.inventedNovelNumerals, 1)
        XCTAssertEqual(EvalThresholds.inventedNovelTokens, 3)
        XCTAssertEqual(EvalThresholds.inventedNovelShare, 0.15)
        XCTAssertEqual(EvalThresholds.inventedMinOutWords, 10)
        XCTAssertEqual(EvalThresholds.inventedSlipDistance, 2)
        XCTAssertEqual(EvalThresholds.overEditLengthRatio, 0.5)
        XCTAssertEqual(EvalThresholds.overEditDeletedShare, 0.15)
        XCTAssertEqual(EvalThresholds.minWordsForRatio, 6)
        // The three LIVE constants, and the only three: L6's novel-token
        // count, L3's atom floor and L3's own band, each named in the six-rule
        // gate itself. None of the three is a taste — the measured 2-column
        // seed run moved two of them: at 0.5 L3 refused a long cued correction
        // at his median dictation length, and at 4 novel tokens L6 let two
        // in-band answers land that the bench then graded INVENTED.
        XCTAssertEqual(EvalThresholds.liveInventedNovelTokens, 3)
        XCTAssertEqual(EvalThresholds.liveWholesaleLossMinWords, 12)
        XCTAssertEqual(EvalThresholds.liveWholesaleLossRatio, 0.25)
    }

    func testGateLadderAndTriggerMapMatchThePlan() {
        // Worst-first: the §4.6 ladder's gated head, and the JSON strings
        // the run rows will carry.
        XCTAssertEqual(ContentGuard.Gate.allCases, [.answered, .invented, .negated, .overEditFact])
        XCTAssertEqual(ContentGuard.Gate.allCases.map(\.rawValue),
                       ["ANSWERED", "INVENTED", "NEGATED", "OVER_EDIT_FACT"])
        let expected: [ContentGuard.Trigger: ContentGuard.Gate] = [
            .multiLine: .answered, .markdown: .answered, .opener: .answered, .lengthRatio: .answered,
            .answerShape: .answered,
            .novelNumeral: .invented, .novelCount: .invented, .novelShare: .invented,
            .negationDropped: .negated, .negationInserted: .negated,
            .lengthCollapse: .overEditFact, .wholesaleLoss: .overEditFact,
        ]
        XCTAssertEqual(ContentGuard.Trigger.allCases.count, expected.count)
        for trigger in ContentGuard.Trigger.allCases {
            XCTAssertEqual(trigger.gate, expected[trigger], trigger.rawValue)
        }
    }

    // MARK: - Replica shapes of history rows 70 / 54 / 58

    func testAnsweredReplicaOfRow70TripsAllFourTriggers() {
        // The shape of id 70 (cmux, 2026-09-07) with an invented product:
        // a question, answered in markdown. raw 18 atoms; out 5 + 9 + 10 + 8
        // = 32 atoms ("1." / "2." / "3." are atoms, "**" is peeled),
        // 4 non-blank lines vs 1, ratio 32/18 = 1.78 > 1.5, first token
        // "sure" ∉ {can, you}.
        let g = check("Can you explain in full detail how the running playlist sync works between the phone and the watch",
                      "Sure, I can detail that.\n\n1. **Pick tracks** for the playlist on the phone.\n"
                      + "2. **Sync** the watch over the bridge before a run.\n3. **Check** the watch shows the new songs.")
        XCTAssertEqual(g.rawWords, 18)
        XCTAssertEqual(g.outWords, 32)
        XCTAssertEqual(g.ratio, 32.0 / 18.0, accuracy: 1e-9)
        for trigger in [ContentGuard.Trigger.multiLine, .markdown, .opener, .lengthRatio] {
            XCTAssertTrue(g.triggers.contains(trigger), trigger.rawValue)
        }
        // A real answer also invents everything: sure, i, 1, pick, tracks, 2,
        // over, bridge, before, run, 3, check, shows, new, songs = 15 novel,
        // three of them list numerals. ANSWERED still heads the ladder.
        XCTAssertEqual(g.novel.count, 15)
        XCTAssertEqual(g.novelNumerals, 3)
        XCTAssertEqual(g.gates, [.answered, .invented])
        XCTAssertEqual(g.worst, .answered)
        XCTAssertTrue(g.isGated)
    }

    func testInventedReplicaOfRow54IsTheNumeralAlone() {
        // The shape of id 54 (Notes, 2026-08-21): a request to total, obeyed.
        // raw: "forty two" / "twenty eight" canonicalize to 42 / 28 → 19
        // atoms; out 25 atoms ("+", "=" are orphan symbols, dropped). The
        // repeated 42 / 28 are covered by raw; only 140 and "units" are
        // novel — one numeral is enough. Ratio 25/19 = 1.32 stays under
        // the ANSWERED line. "find" (of "so find the total") is the one
        // dropped content atom.
        let g = check("so the glider plus a forty two on each wing and a twenty eight on each wing so find the total",
                      "So the glider plus a 42 on each wing and a 28 on each wing. So the total is: 42 + 42 + 28 + 28 = 140 units.")
        XCTAssertEqual(g.rawWords, 19)
        XCTAssertEqual(g.outWords, 25)
        XCTAssertEqual(g.novel, ["140", "units"])
        XCTAssertEqual(g.novelNumerals, 1)
        XCTAssertEqual(g.triggers, [.novelNumeral])
        XCTAssertEqual(g.gates, [.invented])
        XCTAssertEqual(g.deleted, 1)
        XCTAssertEqual(g.droppedContent, ["find"])
    }

    func testOverEditReplicaOfRow58IsNotGatedByTheGuardAlone() {
        // The shape of id 58: the hedge clause dropped, the rest verbatim.
        // raw 16 atoms → out 13 (ratio 0.81, nowhere near 0.5); "don't" is
        // deleted but so is the "know" it governed, so it is NOT a flip.
        // Only the diagnostic sees it: dropped_content 3 — the rating
        // queue's "flagged" line — and the gold-scored M charges the D.
        let g = check("I don't know, try some broad benchmarking on the gravlin tabs and see what comes up",
                      "Try some broad benchmarking on the gravlin tabs and see what comes up.")
        XCTAssertEqual(g.rawWords, 16)
        XCTAssertEqual(g.outWords, 13)
        XCTAssertEqual(g.triggers, [])
        XCTAssertEqual(g.gates, [])
        XCTAssertNil(g.worst)
        XCTAssertFalse(g.isGated)
        XCTAssertEqual(g.deleted, 3)
        XCTAssertEqual(g.droppedContent, ["I", "don't", "know"])
        XCTAssertEqual(g.novel, [])
    }

    // MARK: - §4.5 "Tests:" paragraph

    func testDroppedNegationWithSurvivingContentIsNegated() {
        // "not" deleted, the "push" it governed survives → polarity flip.
        // 5 raw atoms: the length gates cannot fire, so NEGATED is alone.
        let g = check("do not push to main", "push to main")
        XCTAssertEqual(g.triggers, [.negationDropped])
        XCTAssertEqual(g.gates, [.negated])
        XCTAssertEqual(g.droppedContent, ["do", "not"])
    }

    func testWholeClauseDropIsNotNegatedAndSitsOnTheCollapseBoundary() {
        // "I don't know, try some benchmarking" → "Try some benchmarking.": D = 3,
        // "know" went with the "don't" → not a flip. 3/6 = 0.5 exactly is
        // NOT below the 0.5 collapse line — the strict inequality is the
        // contract, so a half-length output is an over-edit for M, not a
        // gate.
        let g = check("I don't know, try some benchmarking", "Try some benchmarking.")
        XCTAssertEqual(g.deleted, 3)
        XCTAssertEqual(g.ratio, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.triggers, [])
        XCTAssertEqual(g.gates, [])
        XCTAssertEqual(g.droppedContent, ["I", "don't", "know"])
    }

    func testOpenerAlreadyInRawIsNotAnswered() {
        let g = check("Okay, so we ship", "Okay, so we ship.")
        XCTAssertEqual(g.triggers, [])
        XCTAssertEqual(g.gates, [])
        XCTAssertEqual(g.ratio, 1)
    }

    func testEmptyOutputOnTwelveWordsIsOverEditFact() {
        // 12 raw atoms → 0: ratio 0 < 0.5. Every deletion counts in
        // `deleted`; dropped_content keeps the 8 that are not STOP words
        // (the, to, the, for).
        let g = check("I want the main focus to be the festival plan for December", "")
        XCTAssertEqual(g.rawWords, 12)
        XCTAssertEqual(g.outWords, 0)
        XCTAssertEqual(g.ratio, 0)
        XCTAssertEqual(g.triggers, [.lengthCollapse])
        XCTAssertEqual(g.gates, [.overEditFact])
        XCTAssertEqual(g.deleted, 12)
        XCTAssertEqual(g.droppedContent, ["I", "want", "main", "focus", "be", "festival", "plan", "December"])
    }

    func testGoldFreeSpelledNumberRewriteIsNotNovel() {
        // "twenty six K" and "26K" are the same atom (26000), so the
        // shipped column — no gold — never reads an ITN rewrite as an
        // invented numeral. Atoms, not words: 5 on both sides, not 7 vs 5.
        let g = check("we did twenty six K last week", "We did 26K last week.")
        XCTAssertEqual(g.rawWords, 5)
        XCTAssertEqual(g.outWords, 5)
        XCTAssertEqual(g.novel, [])
        XCTAssertEqual(g.novelNumerals, 0)
        XCTAssertEqual(g.gates, [])
    }

    func testAsrSlipFixIsOneNovelTokenBelowInvented() {
        // A clear STT slip fixed: one novel token on a 6-word output is
        // under every INVENTED line (count < 3, no numeral, N_out < 10).
        let g = check("I also signed into Norbose today", "I also signed into Norbase today.")
        XCTAssertEqual(g.novel, ["norbase"])
        XCTAssertEqual(g.novelNumerals, 0)
        XCTAssertEqual(g.gates, [])
        // In gold-scored mode the gold's vocabulary covers the fix.
        XCTAssertEqual(check("I also signed into Norbose today", "I also signed into Norbase today.",
                             gold: "I also signed into Norbase today.").novel, [])
    }

    // MARK: - ANSWERED edges

    func testLengthRatioNeedsSixRawWords() {
        // Doubling a 5-word raw (ratio 2.0) is under the floor; the same on
        // 6 words gates. No novelty either way — the output repeats raw.
        let five = check("ship the fix to prod", "Ship the fix to prod. Ship the fix to prod.")
        XCTAssertEqual(five.ratio, 2)
        XCTAssertEqual(five.triggers, [])
        let six = check("ship the fix to prod now", "Ship the fix to prod now. Ship the fix to prod now.")
        XCTAssertEqual(six.rawWords, 6)
        XCTAssertEqual(six.outWords, 12)
        XCTAssertEqual(six.triggers, [.lengthRatio])
        XCTAssertEqual(six.gates, [.answered])
    }

    func testOpenerIsReadAgainstTheWholeRaw() {
        // A reply opener the speaker never said.
        XCTAssertEqual(check("the plan is fine", "Yes, the plan is fine.").triggers, [.opener])
        // The speaker said it — after a filler, which the strip removes
        // before the model ever sees the text.
        let echoed = check("um yes we can do that", "Yes, we can do that.")
        XCTAssertEqual(echoed.triggers, [])
        XCTAssertEqual(echoed.deleted, 1)
        XCTAssertEqual(echoed.droppedContent, [])
        // Second raw token still counts as "said it".
        XCTAssertEqual(check("so here is the plan", "Here is the plan.").triggers, [])
        // …and so does a LATER one. The two-token window called four
        // legitimate cleanups an assistant opener, because the cleanup itself
        // is what moves the speaker's own "okay" to the front (an abandoned
        // lead-in deleted, a stutter collapsed, a discourse run trimmed —
        // all of them commissioned by the prompt).
        for (raw, out) in [("um yeah i mean okay lets just ship the build tonight and see",
                            "Okay, let's just ship the build tonight and see."),
                           ("so anyway okay we push the fix and tell the team tomorrow",
                            "Okay, we push the fix and tell the team tomorrow."),
                           ("i i okay lets get the parser fix in before the freeze",
                            "Okay, let's get the parser fix in before the freeze.")] {
            XCTAssertEqual(check(raw, out).triggers, [], raw)
            XCTAssertEqual(live(raw, out).triggers, [], raw)
        }
        // The apostrophe the formatter restores is not evidence of an
        // assistant either: "here is" and "here's" are one opener.
        XCTAssertEqual(check("here is the thing i would like you to check the retry path first",
                             "Here's the thing I would like you to check: the retry path first.").triggers, [])
    }

    func testAQuestionAnsweredInBandIsAnswered() {
        // The measured Foundation Models failure without its one giveaway
        // word: six openers were the whole in-band detector, so dropping
        // "Yes" left an ANSWER that carries no markdown, no growth, no novel
        // token and the same six atoms. The question's SHAPE is the evidence
        // — the raw opens with an auxiliary or a wh-word, the output keeps
        // neither that opener nor a question mark.
        for (raw, out) in [("is it done?. okay.. let's go", "It is done. Okay, let's go."),
                           ("is the build done yet or is it still compiling",
                            "The build is still compiling."),
                           ("which branch should i merge first the parser one or the config one",
                            "The parser one."),
                           ("should i use a mutex or an actor for that cache in the client",
                            "An actor."),
                           ("did the nightly sync finish or is it still running right now",
                            "It is still running."),
                           ("can you tell me whether the formatter runs before or after the filler strip",
                            "After the filler strip."),
                           // A question rewritten as an assertion: same atom
                           // count, nothing novel, no polarity word — the
                           // judge rubric's "question → statement" loss, which
                           // no gate on either profile used to see.
                           ("are we sure the migration is reversible before we run it tonight",
                            "We are sure the migration is reversible before we run it tonight.")] {
            XCTAssertEqual(check(raw, out).triggers.first, .answerShape, raw)
            XCTAssertEqual(check(raw, out).worst, .answered, raw)
        }
        // LIVE runs none of it. The answer-shape rule went the way of the
        // opener rule it was written to extend: it reads a QUESTION, his
        // register is made of them (44 of 70 rows), and each widening of it
        // refused a formatted imperative. What LIVE still catches of these
        // seven is what any rule can see without a cue — L3, and only where
        // the answer throws away three quarters of a 12-atom question:
        for (raw, out) in [// 13 atoms → 3 (0.23).
                           ("which branch should i merge first the parser one or the config one",
                            "The parser one."),
                           // 14 → 2 (0.14).
                           ("should i use a mutex or an actor for that cache in the client",
                            "An actor.")] {
            XCTAssertEqual(live(raw, out).triggers, [.wholesaleLoss], raw)
        }
        // ACCEPTED GAP — an in-band answer built from fewer than 3 novel
        // words, inside the length band: the measured Foundation Models row
        // minus the word "Yes", the question flattened into a claim, and —
        // since L3 moved to a quarter — the two longer answers that used to
        // fall over the old half band (0.33 and 0.29). The live gate lands
        // them knowingly; the bench names them ANSWERED, which is where the
        // number that moves the decision lives.
        for (raw, out) in [("is it done?. okay.. let's go", "It is done. Okay, let's go."),
                           ("is the build done yet or is it still compiling",
                            "The build is still compiling."),
                           ("did the nightly sync finish or is it still running right now",
                            "It is still running."),
                           ("can you tell me whether the formatter runs before or after the filler strip",
                            "After the filler strip."),
                           ("are we sure the migration is reversible before we run it tonight",
                            "We are sure the migration is reversible before we run it tonight.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
            XCTAssertEqual(check(raw, out).worst, .answered, raw)
        }
    }

    func testAQuestionTheModelMerelyFormatsIsNotAnAnswer() {
        // The exemptions, each of which is the evidence the rule asks for: a
        // question mark survives, or the opener still opens the output, or
        // the utterance never opened with one.
        for (raw, out) in [("can you check whether the sync finished before i leave",
                            "Can you check whether the sync finished before I leave?"),
                           ("did the nightly sync finish or is it still running right now",
                            "Did the nightly sync finish, or is it still running right now?"),
                           // An imperative that happens to open with an
                           // auxiliary keeps its opening word when it is
                           // formatted, which is what clears it.
                           ("have a look at the retry path before you merge the branch",
                            "Have a look at the retry path before you merge the branch."),
                           ("go through the client and tell me where we swallow an error",
                            "Go through the client and tell me where we swallow an error.")] {
            XCTAssertEqual(check(raw, out).triggers, [], raw)
            XCTAssertEqual(live(raw, out).triggers, [], raw)
        }
        // The hedge drop, which neither profile charges any more: the bench
        // reads it as an over-edit (the "know" the "dont" governed went with
        // it) and live reads nothing at all, where the deleted polarity count
        // refused it for the "dont" alone.
        XCTAssertEqual(check("i dont know try some broad benchmarking on the vendor before we commit",
                             "Try some broad benchmarking on the vendor before we commit.").triggers, [])
        XCTAssertEqual(live("i dont know try some broad benchmarking on the vendor before we commit",
                            "Try some broad benchmarking on the vendor before we commit.").triggers, [])
        // "do not push" is an ORDER, not a question: an opener followed by a
        // negation is excluded, so a polarity flip keeps naming itself
        // NEGATED instead of climbing to the ANSWERED rung.
        XCTAssertEqual(check("do not push the fix to main today", "Push the fix to main today.").triggers,
                       [.negationDropped])
    }

    func testMarkdownAndLinesAreChargedOnlyWhenRawLacksThem() {
        // Same bullets and line count on both sides: nothing to charge.
        let list = check("the checklist is\n- sync the watch\n- test the build",
                         "The checklist is:\n- Sync the watch.\n- Test the build.")
        XCTAssertEqual(list.triggers, [])
        // Bold the speaker never dictated.
        XCTAssertEqual(check("add songs to the playlist", "Add **songs** to the playlist.").triggers, [.markdown])
        // A one-line dictation split over two lines.
        let split = check("first sync the watch then test the build", "First sync the watch.\nThen test the build.")
        XCTAssertEqual(split.triggers, [.multiLine])
        XCTAssertEqual(split.gates, [.answered])
    }

    // MARK: - INVENTED edges

    func testTwoSlipFixesAreNotADensityOfInvention() {
        // The system prompt commissions homophone and split/merged-word
        // fixes; two of them in one short utterance — the two commonest
        // Parakeet classes in the same sentence — were 0.18 and 0.20 of the
        // output and the share rule threw the model's correct reply away.
        // A novel token substituted for a NEAR NEIGHBOUR of itself is that
        // slip fix, read off the word the aligner says it replaced. Pinned at
        // 10, 11 and 13 atoms, i.e. AT the rule's floor and above it.
        let eleven = check("i think there going to be to late for the demo",
                           "I think they're going to be too late for the demo.")
        XCTAssertEqual(eleven.outWords, 11)
        XCTAssertEqual(eleven.novel, ["they're", "too"])   // still novel, still counted
        XCTAssertEqual(eleven.triggers, [])
        let ten = check("we should of shipped the fix befour the standup today",
                        "We should have shipped the fix before the standup today.")
        XCTAssertEqual(ten.outWords, 10)
        XCTAssertEqual(ten.novel, ["have", "before"])
        XCTAssertEqual(ten.triggers, [])
        let thirteen = check("i think there going to be to late for the demo tomorrow morning",
                             "I think they're going to be too late for the demo tomorrow morning.")
        XCTAssertEqual(thirteen.outWords, 13)
        XCTAssertEqual(thirteen.triggers, [])
        // Below the floor, unchanged — two novel tokens on 9 atoms never ran
        // the rule.
        XCTAssertEqual(check("the parser need to handle the trailing comma to",
                             "The parser needs to handle the trailing comma too.").triggers, [])
        // What the exemption is NOT: added words. Two novel tokens the
        // aligner reports as insertions (or as substitutions for a word they
        // are nothing like) still make the share, and three still make the
        // count at any length.
        XCTAssertEqual(check("we ship the fix tomorrow morning at nine",
                             "We ship the fix tomorrow morning at 9 after breakfast.").triggers,
                       [.novelShare])
        XCTAssertEqual(check("ship the build tomorrow", "Ship the improved production release build tomorrow.")
                        .triggers, [.novelCount])
    }

    func testOnlyATokenWhoseDigitsAreTheFactIsReadAsANumeral() {
        // The live numeral rule read the digits inside ANY token, which made
        // it STRICTER than the grader on every mixed form: the bench counts
        // pure numerals (`EvalToken.isNumeral` is false for "2.5" and
        // "6:30"), so a correct ITN of a fraction, a clock idiom or a price
        // was one novel token on the bench and a REFUSAL on the path that
        // guards his dictation — the class plan §10.3 rank 1 named as wrongly
        // refused. A mixed token is novel content on both profiles now; the
        // count and share rules see it, the numeral rule does not.
        for (raw, out) in [("give me two and a half hours", "Give me 2.5 hours."),
                           ("the long run took an hour and a half on sunday morning",
                            "The long run took 1.5 hours on Sunday morning."),
                           ("the pace was eight and a half minutes per mile on that run",
                            "The pace was 8.5 minutes per mile on that run."),
                           ("the run starts at half past six on saturday morning",
                            "The run starts at 6:30 on Saturday morning."),
                           ("lets start the call at quarter past nine tomorrow morning",
                            "Let's start the call at 9:15 tomorrow morning."),
                           ("the licence is nineteen ninety nine a month per seat",
                            "The licence is $19.99 a month per seat.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
            XCTAssertEqual(check(raw, out).triggers, [], raw)   // live is a SUBSET of the bench
        }
        // The forms whose digits ARE the fact still answer for them: a bare
        // numeral, an ordinal, a meridiem.
        XCTAssertEqual(live("we need two people and five laptops for the demo",
                            "We need 25 people and five laptops for the demo.").triggers, [.novelNumeral])
        XCTAssertEqual(live("we ship the beta on the ninth of next month at noon",
                            "We ship the beta on the 22nd of next month at noon.").triggers, [.novelNumeral])
        XCTAssertEqual(live("let's meet at nine tomorrow morning in the small room",
                            "Let's meet at 11am tomorrow morning in the small room.").triggers, [.novelNumeral])
    }

    func testNovelCountAndShareRules() {
        // raw 8 atoms ("nine" → 9). Three novel tokens on an 11-atom output:
        // the count rule and the share rule (3/11 = 0.27) both fire; the
        // ratio 11/8 = 1.375 does not.
        let three = check("we ship the fix tomorrow morning at nine",
                          "We ship the fix tomorrow morning at 9 after early breakfast.")
        XCTAssertEqual(three.rawWords, 8)
        XCTAssertEqual(three.outWords, 11)
        XCTAssertEqual(three.novel, ["after", "early", "breakfast"])
        XCTAssertEqual(three.triggers, [.novelCount, .novelShare])
        XCTAssertEqual(three.gates, [.invented])
        // Two novel on exactly 10 atoms: 0.2 > 0.15 — the share rule alone.
        let share = check("we ship the fix tomorrow morning at nine",
                          "We ship the fix tomorrow morning at 9 after breakfast.")
        XCTAssertEqual(share.outWords, 10)
        XCTAssertEqual(share.triggers, [.novelShare])
        // Two novel on 9 atoms: the share rule needs 10, the count rule 3.
        let under = check("we ship the fix tomorrow morning early",
                          "We ship the fix tomorrow morning early, after breakfast.")
        XCTAssertEqual(under.outWords, 9)
        XCTAssertEqual(under.novel, ["after", "breakfast"])
        XCTAssertEqual(under.triggers, [])
    }

    func testAnAnchoredClockPairIsOneAtomAndAnnotationStillCoversIt() {
        // "at eleven thirty" canonicalizes to 11:30 (task-023), so the ITN a
        // formatter is asked for is a HIT, not a reword: the fixture needs
        // no `alternates` — and carrying them anyway changes nothing.
        let bare = check("let's meet at eleven thirty", "Let's meet at 11:30.")
        XCTAssertEqual(bare.novel, [])
        XCTAssertEqual(bare.novelNumerals, 0)
        XCTAssertEqual(bare.triggers, [])
        let covered = check("let's meet at eleven thirty", "Let's meet at 11:30.",
                            alternates: [EvalCase.Alternate(from: "eleven thirty", to: ["11:30"])])
        XCTAssertEqual(covered.novel, [])
        XCTAssertEqual(covered.triggers, [])
        // Unanchored, the pair stays two atoms and the time is ONE novel
        // token that is not a numeral — below every INVENTED threshold, a
        // reword M charges, exactly as before the clock rule existed.
        let unanchored = check("the standup slot is eleven thirty", "The standup slot is 11:30.")
        XCTAssertEqual(unanchored.novel, ["11:30"])
        XCTAssertEqual(unanchored.triggers, [])
    }

    func testSpelledYearIsOneAtom() {
        // "twenty twenty six" canonicalizes to 2026 (task-023), so the digit
        // year a formatter writes is covered by raw — no `alternates` and no
        // INVENTED, on either profile. Before this, spelled-to-digit
        // normalization of a year was an invented numeral.
        let bare = check("the festival is in twenty twenty six", "The festival is in 2026.")
        XCTAssertEqual(bare.novel, [])
        XCTAssertEqual(bare.triggers, [])
        XCTAssertEqual(check("the deadline is december twenty twenty six for the whole team",
                             "The deadline is December 2026 for the whole team.").triggers, [])
        XCTAssertEqual(check("we shipped it in nineteen ninety five believe it or not",
                             "We shipped it in 1995, believe it or not.").triggers, [])
        // A year the speaker did NOT say is still invented.
        XCTAssertEqual(check("the festival is in twenty twenty six", "The festival is in 2027.").triggers,
                       [.novelNumeral])
    }

    func testGoldFreeSpelledNumberWithAndIsNotNovel() {
        // §3.3's history rows have no gold and no alternates: "a hundred
        // and fifty" is ONE atom (150), so the shipped column's "150" is
        // covered by raw. 9 raw atoms (it took a 150 milliseconds to run
        // the sync) vs 8 out; the dropped "a" is STOP.
        let g = check("it took a hundred and fifty milliseconds to run the sync",
                      "It took 150 milliseconds to run the sync.")
        XCTAssertEqual(g.rawWords, 9)
        XCTAssertEqual(g.outWords, 8)
        XCTAssertEqual(g.novel, [])
        XCTAssertEqual(g.novelNumerals, 0)
        XCTAssertEqual(g.gates, [])
        XCTAssertEqual(g.droppedContent, [])
        XCTAssertEqual(check("two thousand and twenty six", "2026").novel, [])
        XCTAssertEqual(check("two hundred and fifty dollars", "$250").novel, [])
    }

    func testDecimalIsNeverItsDigitRunAndATimeIsNotACardinal() {
        // A factor-of-ten corruption of a quantity stays visible: "1.5"
        // is one novel token (a reword M charges), never a silent hit on
        // "15"; and the converse — a correct ITN of a fraction or a time —
        // is the same one novel token, never an invented number.
        let corrupted = check("put a 15 on each wing of the glider", "Put a 1.5 on each wing of the glider.")
        XCTAssertEqual(corrupted.novel, ["1.5"])
        XCTAssertEqual(corrupted.novelNumerals, 0)
        XCTAssertEqual(corrupted.triggers, [])
        let fraction = check("give me two and a half hours", "Give me 2.5 hours.")
        XCTAssertEqual(fraction.novel, ["2.5"])
        XCTAssertEqual(fraction.triggers, [])
        // A SPOKEN decimal ("one point five") is the atom the output writes,
        // so that half of the class is now a hit; "two and a half" still is
        // not (no "point"), which is why the row above still reads novel.
        let spoken = check("the budget is one point five million for next year total",
                           "The budget is 1.5 million for next year total.")
        XCTAssertEqual(spoken.novel, [])
        XCTAssertEqual(spoken.triggers, [])
        let time = check("the standup is at eleven thirty every day", "The standup is at 11:30 every day.")
        XCTAssertEqual(time.novel, [])
        XCTAssertEqual(time.triggers, [])
    }

    // MARK: - NEGATED edges

    func testDroppedNegationSkipsStopWordsToFindTheGovernedToken() {
        // "not" → next content atom is "plan" (past "in", "the"); it
        // survives → flip.
        let g = check("it's not in the plan", "It's in the plan.")
        XCTAssertEqual(g.triggers, [.negationDropped])
        XCTAssertEqual(g.droppedContent, ["not"])
    }

    func testDroppedNegationWithNothingAfterItDoesNotFire() {
        // The rule needs a surviving governed token; a trailing "no" has
        // none, so its loss is a dropped_content diagnostic, not a gate.
        let g = check("I said no", "I said.")
        XCTAssertEqual(g.triggers, [])
        XCTAssertEqual(g.droppedContent, ["no"])
    }

    func testResolvedReparandumWithAnInsertedWordIsNotAFlip() {
        // Seed `correct-day` with one added preposition. The backtrace
        // prefers the diagonal on equal cost, so the dropped "wait" is
        // paired with the inserted "on" as a substitution — `.sub`, yet
        // gone. Survival is read off the paired out tokens ("on" is not
        // "wait"), so the rule stays silent; §4.5 as literally written
        // ("`.hit`/`.sub`") fired here and zeroed a correct row.
        let g = check("send it monday no wait tuesday", "Send it on Tuesday.")
        XCTAssertEqual(g.alignment.ops, [.hit(0, 0), .hit(1, 1), .del(2), .del(3), .sub(4, 2), .hit(5, 3)])
        XCTAssertEqual(g.triggers, [])
        XCTAssertEqual(check("send it monday no wait tuesday", "Send it Tuesday please.").triggers, [])
        XCTAssertEqual(check("send it monday no wait tuesday", "Send it Tuesday morning.").triggers, [])
        // The mirror case the `.hit`-only reading would miss: the governed
        // word moved INTO the negation's slot (not→push, push→it) — "push"
        // is among the paired out tokens, so the flip fires.
        let moved = check("do not push to main", "Push it to main.")
        XCTAssertEqual(moved.alignment.ops, [.del(0), .sub(1, 0), .sub(2, 1), .hit(3, 2), .hit(4, 3)])
        XCTAssertEqual(moved.triggers, [.negationDropped])
    }

    func testDiscourseNoIsNotAPolarityGate() {
        // A backchannel / stance "no" opens the utterance (past fillers,
        // openers and repeats) or carries its own mark; dropping it is an
        // over-edit for M (or a PASS against a gold that drops it too),
        // never a flip of the clause after it — 19 of his 70 rows are
        // backchannels.
        XCTAssertEqual(check("no I think we should ship it", "I think we should ship it.").triggers, [])
        XCTAssertEqual(check("yeah no that's fine", "That's fine.").triggers, [])
        XCTAssertEqual(check("no no no let's not do that", "Let's not do that.").triggers, [])
        XCTAssertEqual(check("um so no we ship today", "We ship today.").triggers, [])
        XCTAssertEqual(check("the answer is no, we ship today", "The answer is we ship today.").triggers, [])
        // The dropped "no" is still a diagnostic for the rating queue.
        XCTAssertEqual(check("no I think we should ship it", "I think we should ship it.").droppedContent, ["no"])
        // A "no" inside the utterance without its own mark is polarity.
        XCTAssertEqual(check("there are no changes to the plan", "There are changes to the plan.").triggers,
                       [.negationDropped])
        // The measured cost of the opener rule, pinned so it stays a
        // decision and not a surprise: a DETERMINER "no" that heads the
        // utterance ("no pushing to main") reads as discourse too, and its
        // loss is a diagnostic for the rating queue, never a gate.
        // Narrowing it needs a part-of-speech call the guard does not make;
        // calibration §7.4 check 3 measures this gate's recall on his tags.
        let determiner = check("no pushing to main today please", "Pushing to main today, please.")
        XCTAssertEqual(determiner.triggers, [])
        XCTAssertFalse(determiner.isGated)
        XCTAssertEqual(determiner.droppedContent, ["no"])
        XCTAssertEqual(QualityScore.score(EvalCase(id: "h", raw: "no pushing to main today please", gold: "",
                                                   goldSource: EvalCase.historyUnratedGoldSource),
                                          out: "Pushing to main today, please.").verdict, .unrated)
        // The other negation words never get the discourse reading.
        XCTAssertEqual(check("never push to main", "Push to main.").triggers, [.negationDropped])
        XCTAssertEqual(check("not the plan I wanted", "The plan I wanted.").triggers, [.negationDropped])
        XCTAssertEqual(EvalThresholds.discourseOpeners,
                       ["yeah", "yes", "okay", "ok", "oh", "well", "so", "and", "but", "right"])
    }

    func testNoToKnowSlipFixIsNotAFlipButCantToCanIs() {
        // "no" rewritten to a word the speaker never said is the homophone
        // slip fix — one novel token, §3.2 class 9, no gate.
        let slip = check("I no what you mean about the tabs", "I know what you mean about the tabs.")
        XCTAssertEqual(slip.triggers, [])
        XCTAssertEqual(slip.novel, ["know"])
        // Every other negation rewritten to a non-negation is a flip,
        // novel replacement or not.
        XCTAssertEqual(check("we can't ship it today", "We can ship it today.").triggers, [.negationDropped])
        XCTAssertEqual(check("we should not ship it", "We should now ship it.").triggers, [.negationDropped])
        // A deleted "no" mid-utterance is still a flip (the slip rule is
        // about substitution only).
        XCTAssertEqual(check("there is no fix for it yet", "There is fix for it yet.").triggers, [.negationDropped])
    }

    func testNegationRewrittenToANegationIsNotAFlip() {
        // "do not" → "Never": the alignment subs not→never (both NEG) and
        // deletes "do". Polarity kept.
        let g = check("do not push to main", "Never push to main.")
        XCTAssertEqual(g.triggers, [])
        XCTAssertEqual(g.novel, ["never"])
    }

    func testInsertedNegation() {
        // Between two aligned neighbours: a flip the speaker never said.
        let between = check("we should ship it today", "We should not ship it today.")
        XCTAssertEqual(between.triggers, [.negationInserted])
        XCTAssertEqual(between.gates, [.negated])
        XCTAssertEqual(between.novel, ["not"])
        // Heading the output, nothing aligned before it: the plan's rule
        // is "between two surviving raw tokens", so this does not fire —
        // pinned so a widening is a deliberate change.
        XCTAssertEqual(check("ship it today", "Never ship it today.").triggers, [])
        // The mirror of the drop rule's sub-to-non-NEG: a raw non-negation
        // rewritten AS a negation.
        let sub = check("I do want the hedge kept", "I don't want the hedge kept.")
        XCTAssertEqual(sub.triggers, [.negationInserted])
        XCTAssertEqual(sub.novel, ["don't"])
    }

    // MARK: - dropped_content diagnostics

    func testDroppedContentIgnoresDerivedFillersStuttersAndStopWords() {
        // Deleted: um (filler), the first I (stutter run), the first the
        // (stutter run AND stop word) → 3 deletions, 0 content.
        let derived = check("um I I think the the plan is good", "I think the plan is good.")
        XCTAssertEqual(derived.deleted, 3)
        XCTAssertEqual(derived.droppedContent, [])
        // Explicit empty lists disable the derivation: "um" and "I" now
        // count; "the" is still a stop word.
        let explicit = check("um I I think the the plan is good", "I think the plan is good.",
                             fillers: [], stutters: [])
        XCTAssertEqual(explicit.droppedContent, ["um", "I"])
    }

    func testExplicitStutterCoversAContentWordDouble() {
        // "then" is not `stutterCollapsible`, so the derivation charges the
        // two collapsed copies; the fixture's annotation clears them.
        let raw = "and then then then we go"
        XCTAssertEqual(check(raw, "And then we go.").droppedContent, ["then", "then"])
        XCTAssertEqual(check(raw, "And then we go.",
                             stutters: [EvalCase.Stutter(span: "then then then", keep: "then")]).droppedContent, [])
    }

    // MARK: - Expected length (the collapse gate's denominator)

    func testCollapseReadsTheExpectedLengthNotRaw() {
        // The plan's own repair row: raw 7 atoms, out 3. Against raw the
        // ratio is 0.43 — a "collapse" for a CORRECT resolution. With the
        // scored reparandum (4 atoms) subtracted, 3 of 3 expected words
        // survive and nothing fires. Same for the wrong-side output.
        let raw = "meet on Tuesday, I mean on Wednesday"
        let bare = check(raw, "Meet on Wednesday.")
        XCTAssertEqual(bare.expectedWords, 7)
        XCTAssertEqual(bare.triggers, [.lengthCollapse])
        let scored = ContentGuard.check(raw: raw, out: "Meet on Wednesday.", reparanda: ["on Tuesday, I mean"])
        XCTAssertEqual(scored.expectedWords, 3)
        XCTAssertEqual(scored.ratio, 3.0 / 7.0, accuracy: 1e-9)   // N_out / N_raw is still reported
        XCTAssertEqual(scored.triggers, [])
        XCTAssertEqual(ContentGuard.check(raw: raw, out: "Meet on Tuesday.", reparanda: ["on Tuesday, I mean"]).triggers, [])
        // An unlocatable reparandum subtracts nothing.
        XCTAssertEqual(ContentGuard.check(raw: raw, out: "Meet on Wednesday.", reparanda: ["on Monday"]).expectedWords, 7)
    }

    func testExpectedLengthSubtractsFillersAndStutterExtras() {
        // "um um so uh yeah um" (6 atoms, 4 derived fillers) → 2 expected;
        // a clean strip to "So, yeah." is 2 of 2, not 2 of 6.
        let stripped = check("um um so uh yeah um", "So, yeah.")
        XCTAssertEqual(stripped.expectedWords, 2)
        XCTAssertEqual(stripped.triggers, [])
        // Explicit `fillers: []` disables the derivation: 2 of 6 → collapse.
        let literal = check("um um so uh yeah um", "So, yeah.", fillers: [])
        XCTAssertEqual(literal.expectedWords, 6)
        XCTAssertEqual(literal.triggers, [.lengthCollapse])
        // Stutter runs count their extras only: "I I I" → 2, "the the" → 1
        // on 9 atoms → 6 expected. "I think" (2) is 0.33 → collapse; "I
        // think the plan." (4) is 0.67 → not.
        let runs = "I I I think the the plan is good"
        XCTAssertEqual(check(runs, "I think.").expectedWords, 6)
        XCTAssertEqual(check(runs, "I think.").triggers, [.lengthCollapse])
        XCTAssertEqual(check(runs, "I think the plan.").triggers, [])
        // An explicit multi-word keep: "my l phone" → "my phone" is one extra.
        XCTAssertEqual(check("call me on my l phone tonight please", "Call me on my phone tonight, please.",
                             stutters: [EvalCase.Stutter(span: "my l phone", keep: "my phone")]).expectedWords, 7)
        // A filler inside a reparandum is subtracted once.
        XCTAssertEqual(ContentGuard.check(raw: "meet at 2, uh, actually 3 tomorrow", out: "Meet at 3 tomorrow.",
                                          reparanda: ["2, uh, actually"]).expectedWords, 4)
        // Nothing expected to survive (an all-filler raw ≥ 6 words) cannot
        // collapse, whatever the output.
        let allFiller = check("um um um um um um", "")
        XCTAssertEqual(allFiller.expectedWords, 0)
        XCTAssertEqual(allFiller.triggers, [])
        // The floor stays on N_raw: 5 raw atoms never collapse.
        XCTAssertEqual(check("um so yeah okay fine", "").triggers, [])
    }

    // MARK: - Ladder

    func testGatesAreOrderedWorstFirst() {
        // 8 raw atoms → 3 (ratio 0.375): a collapse, and the "not" whose
        // "push" survived: NEGATED outranks OVER_EDIT_FACT.
        let g = check("do not push the fix to main today", "Push to main.")
        XCTAssertEqual(g.triggers, [.negationDropped, .lengthCollapse])
        XCTAssertEqual(g.gates, [.negated, .overEditFact])
        XCTAssertEqual(g.worst, .negated)
        XCTAssertEqual(g.droppedContent, ["do", "not", "fix", "today"])
    }

    // MARK: - Profiles (bench grades, live guards)

    func testProfileDefaultsToBenchAndListsBothSides() {
        XCTAssertEqual(ContentGuard.Profile.allCases, [.bench, .live])
        XCTAssertEqual(ContentGuard.Profile.allCases.map(\.rawValue), ["bench", "live"])
        // The default is the grader's, so every scorer / lint / test call
        // site keeps its behaviour: this row gates on both, unchanged.
        let raw = "do not push the fix to main today"
        XCTAssertEqual(check(raw, "Push to main.").triggers,
                       ContentGuard.check(raw: raw, out: "Push to main.", profile: .bench).triggers)
    }

    func testLiveReadsTheWholesaleLossBandAgainstTheRawItself() {
        // L3. The bench collapse rule reads N_out against the EXPECTED length
        // (raw minus fillers, stutter extras and scored reparanda); live reads
        // it against the raw the model was actually given, needs 12 atoms
        // under it, and sits at a QUARTER where the bench sits at a half.
        //
        // Under 12 atoms nothing collapses — a resolved self-correction IS a
        // shrink, and at his median length (13 words) the shrink is the
        // resolution far more often than a drop:
        for (raw, out) in [// 7 raw atoms → 3 (0.43); the bench calls it a collapse.
                           ("cancel the meeting with the finance team", "Cancel the meeting."),
                           // A cued correction past the short shapes: 9 → 4.
                           ("meet at the cafe scratch that at the office", "Meet at the office.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
            XCTAssertEqual(check(raw, out).triggers, [.lengthCollapse], raw)
        }
        // ACCEPTED GAP — a wholesale drop of an 11-atom-or-shorter dictation
        // lands, because no length rule can tell it from the resolution above.
        XCTAssertEqual(live("cancel the meeting with the finance team", "Cancel it.").triggers, [])
        // And the row the band moved FOR: the same cued correction at his
        // median dictation length, 15 atoms → 7 = 0.47. A half refused it,
        // which is a refusal of exactly what the correction clause asks the
        // model to do; a quarter lands it.
        let median = "i want to meet at the coffee shop on castro street actually at the office"
        XCTAssertEqual(live(median, "I want to meet at the office.").rawWords, 15)
        XCTAssertEqual(live(median, "I want to meet at the office.").outWords, 7)
        XCTAssertEqual(live(median, "I want to meet at the office.").triggers, [])
        XCTAssertEqual(check(median, "I want to meet at the office.").triggers, [.lengthCollapse])
        // At 12 atoms and eleven-twelfths of the words gone, it refuses:
        let long = "the quarterly report shows revenue grew twelve percent but we need to "
            + "double check the churn numbers before presenting them on thursday"
        XCTAssertEqual(live(long, "Revenue grew.").ratio, 2.0 / 22.0, accuracy: 1e-9)
        XCTAssertEqual(live(long, "Revenue grew.").triggers, [.wholesaleLoss])
        XCTAssertEqual(check(long, "Revenue grew.").triggers, [.lengthCollapse])
        // The boundary from both sides, hand-counted: 12 raw atoms, 3 out is
        // exactly 0.25 and lands, 2 is under it and refuses. (11 raw atoms
        // never fire whatever the output.)
        let twelve = "we should ship the parser fix before the code freeze on friday"
        XCTAssertEqual(ContentGuard.check(raw: twelve, out: "", profile: .live).rawWords, 12)
        XCTAssertEqual(live(twelve, "We ship Friday.").outWords, 3)
        XCTAssertEqual(live(twelve, "We ship Friday.").triggers, [])
        XCTAssertEqual(live(twelve, "Ship Friday.").outWords, 2)
        XCTAssertEqual(live(twelve, "Ship Friday.").triggers, [.wholesaleLoss])
        // Half an utterance gone is the bench's business now, not this gate's:
        // at 5 of 12 the collapse rule fires and live lands it.
        XCTAssertEqual(live(twelve, "We ship the fix Friday.").triggers, [])
        XCTAssertEqual(check(twelve, "We ship the fix Friday.").triggers, [.lengthCollapse])
        let eleven = "we should ship the parser fix before the freeze on friday"
        XCTAssertEqual(ContentGuard.check(raw: eleven, out: "", profile: .live).rawWords, 11)
        XCTAssertEqual(live(eleven, "Ship it.").triggers, [])
        // Fillers do NOT lower the reference length live: on the live path the
        // text has already been through the stripper (and where a register
        // leaves them in, a strip that halves a 12-atom utterance is the one
        // measured cost of having one band instead of two).
        XCTAssertEqual(live("um so uh we uh ship it", "So we ship it.").triggers, [])
        XCTAssertEqual(live("um um um um um um", "").triggers, [])
        // The diagnostics are unchanged — the report still prints what left.
        XCTAssertEqual(live("cancel the meeting with the finance team", "Cancel the meeting.")
                        .droppedContent, ["with", "finance", "team"])
    }

    func testLivePassesAPolarityInversionAndTheBenchScoresIt() {
        // The ex-L7. Live ran a polarity COUNT — raw carriers against out
        // carriers, no alignment — until the 2-column measurement priced it:
        // it refused "send it monday no wait tuesday" → "Send it Tuesday.",
        // a correctly resolved correction, on BOTH model columns, and with it
        // 3 of the 81 seed golds and 2.3 composite on llama. The shapes it
        // guards — a dropped or an inserted polarity word — are measured at 0
        // of his 70 real dictations and 0 of the 81 seeds. Measured false
        // positives against unmeasured true ones is not a trade a shipping
        // gate makes, so the rule is gone from live and nothing replaced it.
        //
        // ACCEPTED GAP — this is what it costs. An inversion lands:
        for (raw, out) in [("we have absolutely no time for this project",
                            "We have time for this project."),
                           ("we made no changes to the deploy script this week",
                            "We made changes to the deploy script this week."),
                           ("please make sure there are no duplicates in the export file",
                            "Please make sure there are duplicates in the export file."),
                           ("there are no changes to the plan", "There are changes to the plan.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
            // …and the BENCH names every one of them, which is where the
            // number that would show it to him lives.
            XCTAssertEqual(check(raw, out).triggers, [.negationDropped], raw)
        }
        // What it buys, and what the measurement was about: the bare-"no"
        // self-correction the count could not tell from a flip, because the
        // "no" the model correctly deleted is a carrier it can no longer
        // find. Three of the 81 seeds are this shape (`correct-day`,
        // `correct-number`, `repair-02`) and the models get all three right.
        for (raw, out) in [("the total is 50 no 15 dollars", "The total is 15 dollars."),
                           ("send it monday no tuesday", "Send it Tuesday."),
                           ("send it monday no wait tuesday please", "Send it Tuesday.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
        }
        // Every other carrier, in both directions: live lands them all, and
        // the bench charges each one to a NEGATED row.
        for (raw, out, bench) in [("do not push to main", "Push to main.", [ContentGuard.Trigger.negationDropped]),
                                  ("never push to main", "Push to main.", [.negationDropped]),
                                  ("we cant ship it today", "We can ship it today.", [.negationDropped]),
                                  ("we made none of the changes we planned",
                                   "We made the changes we planned.", [.negationDropped]),
                                  ("we should ship it today", "We should not ship it today.",
                                   [.negationInserted]),
                                  ("we should ship it today", "We shouldn't ship it today.",
                                   [.negationInserted])] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
            XCTAssertEqual(check(raw, out).triggers, bench, raw)
        }
        // The classes the count got right for free stay right for free: a
        // restored apostrophe, a carrier rewritten to another carrier, and a
        // discourse "no" that survives are all ordinary cleanups here.
        XCTAssertEqual(live("we cant ship today and it isnt ready and i dont like it",
                            "We can't ship today, and it isn't ready, and I don't like it.").triggers, [])
        XCTAssertEqual(live("we can not ship the build this week",
                            "We cannot ship the build this week.").triggers, [])
        XCTAssertEqual(live("no thanks we already have enough licences for the quarter",
                            "No thanks, we already have enough licences for the quarter.").triggers, [])
    }

    func testLiveExemptsANumeralWhoseDigitsTheSpeakerSaid() {
        // The residue the canonicalizer still cannot read: "nineteen oh
        // five" is [19, oh, 5], so "1905" is a novel numeral on the BENCH.
        // On live every digit run of it is reachable from what was said
        // (19 + 0 + 5), so it is a normalization, not an invention.
        let raw = "the building went up in nineteen oh five according to the plaque"
        let out = "The building went up in 1905, according to the plaque."
        XCTAssertEqual(live(raw, out).triggers, [])
        XCTAssertEqual(check(raw, out).triggers, [.novelNumeral])
        // Row 54's shape is NOT reachable — nobody said "a hundred and two" —
        // so the live gate refuses invented math exactly as the bench does.
        let math = "so the glider plus a 42 on each wing and a 9 on each wing so find the total"
        let sum = "So the glider plus a 42 on each wing and a 9 on each wing. "
            + "So the total is: 42 + 42 + 9 + 9 = 102 units."
        XCTAssertEqual(live(math, sum).triggers, [.novelNumeral])
        XCTAssertEqual(check(math, sum).triggers, [.novelNumeral])
        // The reported diagnostic is the measured count on both profiles.
        XCTAssertEqual(live(raw, out).novelNumerals, 1)
        // The exemption is WITNESSED by the raw, never assembled from a set
        // of spoken digits: a lone "five" does not spell 55, and a "two"
        // with a "five" four words later does not spell 25. Both are
        // invented quantities, and a set-membership reading accepted them.
        for (spoken, invented) in [("give me five minutes and i will send the draft over",
                                    "Give me 55 minutes and I will send the draft over."),
                                   ("we need two people and five laptops for the demo",
                                    "We need 25 people and five laptops for the demo.")] {
            XCTAssertEqual(live(spoken, invented).triggers, [.novelNumeral], spoken)
            XCTAssertEqual(check(spoken, invented).triggers, [.novelNumeral], spoken)
        }
        // Consecutive and in order is what makes a multi-part numeral a
        // normalization: the same digits said the other way round are not.
        XCTAssertEqual(live("the code is five two seven for the door",
                            "The code is 527 for the door.").triggers, [])
        XCTAssertEqual(live("the code is five two seven for the door",
                            "The code is 752 for the door.").triggers, [.novelNumeral])
    }

    func testTheWitnessIsAWholeAtomNeverAWordInsideOne() {
        // The witness set used to hold the digits of every WORD inside a
        // merged atom, and every prefix a compound run parsed. So any
        // component of a number the speaker said licensed a DIFFERENT number
        // in the output: the live gate accepted a wrong race date and a wrong
        // weekly mileage that the bench gated as INVENTED — history row 54's
        // class, on the path that guards his dictation.
        for (raw, out) in [("the deadline is december twenty twenty six for the whole team",
                            "The deadline is December 2020 for the whole team."),
                           ("i ran fifty four miles last week and felt fine afterwards",
                            "I ran 50 miles last week and felt fine afterwards."),
                           ("we need twenty five testers for the pilot next month",
                            "We need 20 testers for the pilot next month."),
                           ("i want to hit a hundred and fifty miles this month",
                            "I want to hit 100 miles this month.")] {
            XCTAssertEqual(live(raw, out).triggers, [.novelNumeral], raw)
            XCTAssertEqual(check(raw, out).triggers, [.novelNumeral], raw)
        }
        // The whole atom still passes, on every spelled form the
        // canonicalizer merges and on the one it cannot ("nineteen oh five"
        // is three atoms spelled consecutively).
        for (raw, out) in [("i ran fifty four miles last week and felt fine afterwards",
                            "I ran 54 miles last week and felt fine afterwards."),
                           ("the deadline is december twenty twenty six for the whole team",
                            "The deadline is December 2026 for the whole team."),
                           ("i want to hit a hundred and fifty miles this month",
                            "I want to hit 150 miles this month."),
                           ("the building went up in nineteen oh five according to the plaque",
                            "The building went up in 1905, according to the plaque."),
                           ("we ship the beta on the twenty third of next month at noon",
                            "We ship the beta on the 23rd of next month at noon.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
        }
    }

    func testACompoundRunBreaksAtABoundaryMark() {
        // `Align.numberRun` stops a run at a mark — "twenty, six" is a list,
        // not 26 — and the witness side has to obey the same rule, or the
        // live gate fuses number words the shared canon refuses to fuse and
        // invents a quantity (or a year) out of a two-number list.
        for (raw, out) in [("we ordered twenty, six of them arrived late this morning",
                            "We ordered 26 of them arrived late this morning."),
                           ("we shipped twenty, thirty units last quarter",
                            "We shipped 2030 units last quarter."),
                           ("section twenty. six covers the refund policy",
                            "Section 26 covers the refund policy.")] {
            XCTAssertEqual(live(raw, out).triggers, [.novelNumeral], raw)
            XCTAssertEqual(check(raw, out).triggers, [.novelNumeral], raw)
        }
        // Unbroken, the same words still witness the compound.
        XCTAssertEqual(live("we ordered twenty six of them last week",
                            "We ordered 26 of them last week.").triggers, [])
    }

    func testLiveReadsTheDigitsInsideAnOrdinalOrAMeridiemToken() {
        // The witness test runs over the digit run inside ANY novel token,
        // not only a bare numeral: an ordinal or an a.m./p.m. form is a
        // number the speaker either said or did not. Exempting the SUFFIX
        // instead (an `{st, nd, rd, th}` list) let "the ninth" become "the
        // 22nd" — a wrong date, waved through because it ended in "nd".
        // Witnessed, so accepted — and not because the count is 1: L6 asks
        // the witness test, not the token's shape, so every piece of a number
        // it accepted is out of the count and three of them in one utterance
        // land too, merged or spaced (both below):
        for (raw, out) in [("we ship the beta on the ninth of next month at noon",
                            "We ship the beta on the 9th of next month at noon."),
                           ("we ship the beta on the twenty third of next month at noon",
                            "We ship the beta on the 23rd of next month at noon."),
                           ("we ship the beta on the first of october at noon",
                            "We ship the beta on the 1st of October at noon."),
                           ("let's meet at nine tomorrow morning in the small room",
                            "Let's meet at 9am tomorrow morning in the small room."),
                           ("meet me at three in the afternoon tomorrow",
                            "Meet me at 3 p.m. tomorrow.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
        }
        // Unwitnessed, so refused — the digits are the fact, the suffix is
        // not evidence of anything:
        for (raw, out) in [("we ship the beta on the ninth of next month at noon",
                            "We ship the beta on the 22nd of next month at noon."),
                           ("we ship the beta on the twenty third of next month at noon",
                            "We ship the beta on the 31st of next month at noon."),
                           ("let's meet at nine tomorrow morning in the small room",
                            "Let's meet at 11am tomorrow morning in the small room."),
                           ("meet me at three in the afternoon tomorrow",
                            "Meet me at 5 p.m. tomorrow.")] {
            XCTAssertEqual(live(raw, out).triggers, [.novelNumeral], raw)
        }
        // THREE witnessed ones in an utterance: a denormalized number is not
        // a novel CONTENT word whatever suffix it keeps, so the count rule
        // does not see them either. The bench does — that is the split, and
        // it is the whole difference between the two profiles here.
        for (raw, out) in [("the interviews are on the first the second and the third of october",
                            "The interviews are on the 1st, the 2nd, and the 3rd of October."),
                           ("the standups are at nine and the reviews at two and the retro at four today",
                            "The standups are at 9am, and the reviews at 2pm, and the retro at 4pm today.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
            XCTAssertEqual(check(raw, out).triggers, [.novelCount, .novelShare], raw)
        }
    }

    func testTheWitnessCoversTheSpacedFormOfADenormalizedNumber() {
        // The same number, spaced: the tokenizer splits "9 am" and "the 1 st"
        // into a digit run and a BARE suffix atom, and that atom carries the
        // canonicalizer's two letters and nothing else. Reading the token's
        // SHAPE (`digitsAreTheFact` on its own) only ever covered the merged
        // spelling, so three spaced ones in an utterance — the register's own
        // scheduling prompt — read as three invented words. L6 reads L5's
        // verdict instead, so both pieces of a witnessed number are out of
        // the count.
        for (raw, out) in [("the standups are at nine and the reviews at two and the retro at four today",
                            "The standups are at 9 am, and the reviews at 2 pm, and the retro at 4 pm today."),
                           ("lets do the calls at nine and eleven in the morning and four in the afternoon",
                            "Let's do the calls at 9 a.m. and 11 a.m. in the morning, and 4 p.m. in the afternoon.")] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
            XCTAssertEqual(check(raw, out).triggers, [.novelCount, .novelShare], raw)
        }
        // The spaced ORDINAL, where the digit run is novel on its own too
        // ("first" is not canonicalized to 1 — the ordinal reading lives on
        // the witness side alone), so the bench adds its strict numeral rule
        // to the same row and live still lands.
        let ordinals = ("the interviews are on the first the second and the third of october",
                        "The interviews are on the 1 st, the 2 nd, and the 3 rd of October.")
        XCTAssertEqual(live(ordinals.0, ordinals.1).triggers, [])
        XCTAssertEqual(check(ordinals.0, ordinals.1).triggers,
                       [.novelNumeral, .novelCount, .novelShare])
        XCTAssertEqual(check(ordinals.0, ordinals.1).novel, ["1", "st", "2", "nd", "3", "rd"])
        // Merged and spaced in one reply: the clause reads a number, not a
        // spelling.
        XCTAssertEqual(live("the interviews are on the first and the second of october and the "
                            + "standups are at nine and four",
                            "The interviews are on the 1st and the 2 nd of October, and the "
                            + "standups are at 9 am and 4 pm.").triggers, [])
        // Unwitnessed, spaced: L5 fires on the digit run exactly as it does
        // on the merged form, and the suffix atom buys nothing.
        XCTAssertEqual(live("let's meet at nine tomorrow morning in the small room",
                            "Let's meet at 11 am tomorrow morning in the small room.").triggers,
                       [.novelNumeral])
        // The join stops at a boundary mark: "At 9, am I…" is an auxiliary,
        // so the "am" is a novel content word like any other and the third
        // one gates.
        XCTAssertEqual(live("meeting at nine should i show up early tomorrow before the standup",
                            "At 9, am I supposed to arrive early tomorrow before the standup?").triggers,
                       [.novelCount])
    }

    func testTheWitnessReadsASeparatedNumberAsNumberMaterial() {
        // The spaced rows above are all bare DIGIT RUNS, and the witness
        // joined a suffix atom only to one of those (`EvalToken.isNumeral`).
        // A clock time keeps its colon and a decimal its point, so "at nine
        // thirty in the morning" → "9:30 am" left the "am" counted as
        // invented content while the merged "9:30am" — one atom, "930am" —
        // was witnessed whole. The suffix now hangs off any NUMBER MATERIAL:
        // separators and all, clock times, decimals and prices included.
        let clock = "lets do the standup at nine thirty in the morning the review at two thirty "
            + "in the afternoon and ship by four thirty in the afternoon"
        let prices = "the early bird is nineteen ninety nine until nine thirty in the morning "
            + "then twenty nine ninety nine until two thirty in the afternoon and thirty nine "
            + "ninety nine after four thirty in the afternoon"
        for (raw, out) in [
            (clock, "Let's do the standup at 9:30 am, the review at 2:30 pm, and ship by 4:30 pm."),
            (clock, "Let's do the standup at 9:30am, the review at 2:30pm, and ship by 4:30pm."),
            (clock, "Let's do the standup at 9.30 am, the review at 2.30 pm, and ship by 4.30 pm."),
            (prices, "The early bird is $19.99 until 9:30 am, then $29.99 until 2:30 pm, and "
             + "$39.99 after 4:30 pm."),
            // A teen minute is two atoms on the raw side and the witness
            // reads it digit by digit — 9 and 15, both spoken whole.
            ("lets meet at nine fifteen in the morning and again at four fifteen in the "
             + "afternoon and wrap by five fifteen in the afternoon",
             "Let's meet at 9:15 am, again at 4:15 pm, and wrap by 5:15 pm."),
        ] {
            XCTAssertEqual(live(raw, out).triggers, [], raw)
            // LIVE-only, as every relaxation on this path is.
            XCTAssertEqual(check(raw, out).triggers, [.novelCount, .novelShare], raw)
        }
        // Unwitnessed, and the suffix atom buys nothing: spaced, the times
        // are three novel content words; merged, "1045am" is also a token
        // whose digits are the fact, so L5 fires on it too.
        XCTAssertEqual(live(clock, "Let's do the standup at 10:45 am, the review at 3:15 pm, "
                            + "and ship by 5:20 pm.").triggers, [.novelCount])
        XCTAssertEqual(live(clock, "Let's do the standup at 10:45am, the review at 3:15pm, "
                            + "and ship by 5:20pm.").triggers, [.novelNumeral, .novelCount])
        // A VERSION STRING is not number material: "v1.2" canonicalizes to
        // "v12" and the "v" is the speaker's word, not the canonicalizer's
        // suffix — so it counts as content in both spellings, witnessed
        // digits or not. That is the line gap 6 draws.
        let versions = "we shipped version one point two on monday and version one point three "
            + "on wednesday and version one point four this morning"
        let merged = live(versions, "We shipped v1.2 on Monday, v1.3 on Wednesday, and v1.4 this morning.")
        XCTAssertEqual(merged.triggers, [.novelCount])
        XCTAssertEqual(merged.novel, ["v12", "v13", "v14"])
        let spaced = live(versions, "We shipped v 1.2 on Monday, v 1.3 on Wednesday, and v 1.4 this morning.")
        XCTAssertEqual(spaced.triggers, [.novelCount])
        XCTAssertEqual(spaced.novel, ["v", "v", "v"])
        // The join stops at a boundary mark after a clock time exactly as it
        // does after a digit run: "At 9:30, am I…" is an auxiliary.
        XCTAssertEqual(live("meeting at nine thirty should i show up early tomorrow before the standup",
                            "At 9:30, am I supposed to arrive early tomorrow before the standup?").triggers,
                       [.novelCount])
    }

    func testTheWitnessAsksForEachDigitRunSeparately() {
        // THE RUN-BY-RUN GAP, pinned rather than argued. Every row above
        // spells its times out of CONSECUTIVE number words, so each digit run
        // and the whole digit string are both reachable and the corpus cannot
        // tell the two readings apart. The witness asks per RUN, of the whole
        // dictation: "9:30" asks for a 9 and for a 30 and never for the two
        // together, so counts said in unrelated places witness a time nobody
        // spoke — and the "am" after it is then his number's letters, not a
        // novel content word. It stays: the gap lets a number THROUGH, which
        // is the only direction this gate is allowed to fail in.
        let scattered = "nine of us are going and thirty people rsvped and two more asked at the "
            + "meeting and four said they would watch the standup and the review and the retro tomorrow"
        let head = "9 of us are going, 30 people RSVPed, 2 more asked at the meeting, and 4 said "
            + "they would watch the standup at "
        let witnessed = head + "9:30 am, the review at 2:30 pm, and the retro at 4:30 pm tomorrow."
        XCTAssertEqual(live(scattered, witnessed).triggers, [])
        XCTAssertEqual(live(scattered, witnessed).novel, ["9:30", "am", "2:30", "pm", "4:30", "pm"])
        // LIVE-only: the bench counts every novel token, witnessed or not.
        XCTAssertEqual(check(scattered, witnessed).triggers, [.novelCount, .novelShare])
        // The SAME three times merged are one run each, and a run has to be
        // spoken whole or spelled by consecutive words — "930" is neither. So
        // the spelling decides the verdict on identical content, which is the
        // same gap read from its other side: here "930am" is also a token
        // whose digits are the fact, so L5 fires beside the count.
        XCTAssertEqual(live(scattered,
                            head + "9:30am, the review at 2:30pm, and the retro at 4:30pm tomorrow.")
                       .triggers, [.novelNumeral, .novelCount])
        // The sibling with NO run reachable at all — no 10, no 45, no 3, no
        // 15, no 5, no 20 — where the gate does what it is for: the witness
        // refuses each form and the three suffix atoms are three novel
        // content words.
        XCTAssertEqual(live(scattered,
                            head + "10:45 am, the review at 3:15 pm, and the retro at 5:20 pm tomorrow.")
                       .triggers, [.novelCount])
    }

    func testLiveAndBenchBothForgiveARestoredApostrophe() {
        // The novelty half of the apostrophe class (the negation half is
        // `Align.isApostropheRestored`): a restored contraction is the
        // speaker's own word, so it is not novel on EITHER profile. Three in
        // one utterance is the shape that gated — the count rule fires at 3
        // regardless of length, the share rule at 2 on a 10-atom output.
        let raw = "go through the client and add a timeout because right now it doesnt fail fast "
            + "and we cant tell whether its the network or the server"
        let out = "Go through the client and add a timeout, because right now it doesn't fail fast "
            + "and we can't tell whether it's the network or the server."
        XCTAssertEqual(live(raw, out).novel, [])
        XCTAssertEqual(check(raw, out).novel, [])
        XCTAssertEqual(live(raw, out).triggers, [])
        // Two restorations on a 10-atom output — the share rule's floor.
        let short = check("it isnt ready yet and we shouldnt promise it today",
                          "It isn't ready yet and we shouldn't promise it today.")
        XCTAssertEqual(short.novel, [])
        XCTAssertEqual(short.outWords, 10)
        XCTAssertEqual(short.triggers, [])
        // A contraction the speaker never said is still novel content.
        XCTAssertEqual(check("we ship the build on friday", "We won't ship the build on Friday.").novel,
                       ["won't"])
    }

    func testLiveRunsSixRulesAndTheBenchRunsItsOwn() {
        // The whole split in one table. Column 1 is what the BENCH sees,
        // column 2 what LIVE sees, and the difference is never a tuned
        // constant — it is which rules ran.
        let cases: [(raw: String, out: String, bench: [ContentGuard.Trigger],
                     live: [ContentGuard.Trigger])] = [
            // L1 + L2 + L5 + L6 all at once: history row 70's shape. The
            // opener and the share rule fire on the bench only.
            ("can you explain how the sync works",
             "Sure, I can explain that.\n1. **Sync** the phone first.\n2. **Check** the watch.",
             [.multiLine, .markdown, .opener, .lengthRatio, .novelNumeral, .novelCount, .novelShare],
             [.multiLine, .markdown, .lengthRatio, .novelNumeral, .novelCount]),
            // L6's floor: 3 novel tokens gate the bench at any length, live
            // wants the same 3 AND 10 output atoms — the floor is the split.
            ("ship the build tomorrow", "Ship the improved production release build tomorrow.",
             [.novelCount], []),
            ("ship the build tomorrow morning before the standup",
             "Ship the improved production release candidate build tomorrow morning before standup.",
             [.novelCount, .novelShare], [.novelCount]),
            // L6's LETTER clause: a novel token with no letter of its own in
            // it — a dash the model punctuated with, a denormalized clock
            // time, year, ordinal or meridiem — is not a content word, so
            // live does not count it. The bench counts every novel token,
            // which is the split.
            ("we ship on friday if the tests pass and then we take monday off for the holiday "
             + "and the team gets a break",
             "We ship on Friday - if the tests pass - and then we take Monday off - for the "
             + "holiday - and the team gets a break.",
             [.novelCount], []),
            ("my splits were seven fifty one seven forty eight seven fifty three and seven "
             + "forty six on the long run",
             "My splits were 7:51, 7:48, 7:53, and 7:46 on the long run.",
             [.novelCount, .novelShare], []),
            // The suffixed half of the same family: the "st"/"nd"/"rd" and
            // the "am"/"pm" are the canonicalizer's letters, not the
            // speaker's, and at L6's count of 3 they were three refusals of
            // the ITN the prompt commissions.
            ("the interviews are on the first the second and the third of october",
             "The interviews are on the 1st, the 2nd, and the 3rd of October.",
             [.novelCount, .novelShare], []),
            ("the standups are at nine and the reviews at two and the retro at four today",
             "The standups are at 9am, and the reviews at 2pm, and the retro at 4pm today.",
             [.novelCount, .novelShare], []),
            // The novel SHARE rule is gone from live outright.
            ("we ship the fix tomorrow morning at nine",
             "We ship the fix tomorrow morning at 9 after breakfast.", [.novelShare], []),
            // An inserted negation: a bench rule and nothing else now.
            ("we should ship it today", "We should not ship it today.",
             [.negationInserted], []),
        ]
        for c in cases {
            XCTAssertEqual(check(c.raw, c.out).triggers, c.bench, c.raw)
            XCTAssertEqual(live(c.raw, c.out).triggers, c.live, c.raw)
        }
    }

    private func live(_ raw: String, _ out: String) -> ContentGuard {
        ContentGuard.check(raw: raw, out: out, profile: .live)
    }
}
