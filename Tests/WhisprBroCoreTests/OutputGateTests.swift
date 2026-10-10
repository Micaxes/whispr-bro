import XCTest
@testable import WhisprBroCore

/// Pins for `TextFormatter.gateModelOutput` — the ONE output gate both model
/// stages (the macOS llama stage, the iOS Foundation Models stage) run a
/// reply through before it can reach the user — as a pure function over
/// (input, model output), no engine.
///
/// The gate is SIX rules and nothing else (`ContentGuard.Profile`):
///
/// | | rule | where |
/// |---|---|---|
/// | L1 | STRUCTURE — more lines, or markdown the raw lacks | `ContentGuard` + `implausibility` |
/// | L2 | RUNAWAY — atoms(out) > 1.5 × atoms(in), in ≥ 6 | `ContentGuard` + `implausibility` |
/// | L3 | WHOLESALE LOSS — atoms(out) < 0.25 × atoms(in), in ≥ 12 | `ContentGuard` |
/// | L4 | WORDLESS — no letter and no digit in out | `implausibility` |
/// | L5 | INVENTED NUMERAL — a digit run the raw cannot witness | `ContentGuard` |
/// | L6 | INVENTED CONTENT — ≥ 3 novel words with a letter of their own (no piece of a number L5's witness test accepts, "9am", "9 am" or "9:30 am"), out ≥ 10 atoms | `ContentGuard` |
///
/// Three rounds of patching each traded one false positive for a new hole, so
/// the round before this one deleted instead: the opener rule in every form,
/// `answer-shape`, `novelShare`, the slip-fix discount and every cue lexicon
/// are gone from this path (the BENCH grader keeps them all — there a miss
/// costs a leaderboard number, here it costs a dictation). Then the 2-column
/// measurement priced what was left, and three numbers moved on its evidence:
/// the polarity COUNT is gone too (it refused a correctly resolved correction
/// on both models, for a shape measured at zero), L3 moved from a half to a
/// quarter (a half refused a cued correction at his median length) and L6
/// moved back to the bench's 3 novel words (at 4, two in-band answers landed
/// that the bench then graded INVENTED).
///
/// That makes the ADVERSARIAL ACCEPTANCE CORPUS below — (input, model
/// output) pairs that are NOT in the seed set, which tuned these thresholds
/// and therefore cannot also guard them — this file's centre of gravity,
/// with the refusal corpus beside it (one row per rule, plus his two real
/// catastrophes) and every accepted GAP pinned as a row of its own rather
/// than left silent — including the two the witness leaves open: the
/// letterless number form L5 does not read (gap 6) and the digit runs it
/// asks for one at a time (gap 7).
final class OutputGateTests: XCTestCase {
    private func gate(_ input: String, _ output: String) -> TextFormatter.GateVerdict {
        TextFormatter.gateModelOutput(output, of: input)
    }

    /// Every acceptance row: accepted byte-identical to the model's reply
    /// (none of them needs sanitizing or punctuation repair), nothing logged.
    private func assertAccepted(_ pairs: [(String, String)], file: StaticString = #filePath,
                                line: UInt = #line) {
        for (input, output) in pairs {
            let g = gate(input, output)
            XCTAssertEqual(g.accepted, output, "gate refused: \(input) → \(g.reason ?? "?")",
                           file: file, line: line)
            XCTAssertNil(g.reason, input, file: file, line: line)
        }
    }

    /// Every refusal row: nothing inserted, and the reason names the rules
    /// that fired in table order.
    private func assertRefused(_ rows: [(input: String, output: String, reason: String)],
                               file: StaticString = #filePath, line: UInt = #line) {
        for row in rows {
            let g = gate(row.input, row.output)
            XCTAssertNil(g.accepted, row.input, file: file, line: line)
            XCTAssertEqual(g.reason, row.reason, row.input, file: file, line: line)
        }
    }

    // MARK: - Refused: one row per frozen rule

    func testOneRefusalPerRuleL1toL6() {
        assertRefused([
            // L1 STRUCTURE — three bullets out of one spoken line. Nothing
            // grew, nothing is invented: the SHAPE is the whole evidence.
            ("first the schema then the backfill then the cutover",
             "- First the schema\n- Then the backfill\n- Then the cutover",
             "ANSWERED (multi-line, markdown)"),
            // L2 RUNAWAY — the documented llama failure: a dictation about a
            // function answered with the function.
            ("the function takes a user id and returns a promise",
             "function getUser(id) { return new Promise((resolve, reject) => { "
             + "db.users.findById(id).then(user => resolve(user)).catch(reject) }) } "
             + "This function takes a user id and returns a promise as requested.",
             "ANSWERED (length-ratio, novel-count)"),
            // L3 WHOLESALE LOSS — 22 atoms of dictation, two words back
            // (0.09, well under the quarter band).
            ("the quarterly report shows revenue grew twelve percent but we need to "
             + "double check the churn numbers before presenting them on thursday",
             "Revenue grew.", "OVER_EDIT_FACT (wholesale-loss)"),
            // L4 WORDLESS — punctuation residue. There is nothing to insert,
            // so refusing costs him nothing.
            ("the quarterly report shows revenue grew twelve percent this quarter", ".",
             "implausible: empty"),
            // L5 INVENTED NUMERAL — history row 54's shape (below).
            ("we need five testers for the pilot next month",
             "We need 15 testers for the pilot next month.", "INVENTED (novel-numeral)"),
            // L6 INVENTED CONTENT — four novel words inside eleven atoms is
            // not a cleanup in any register.
            ("ship the build tomorrow morning before the standup",
             "Ship the improved production release candidate build tomorrow morning before standup.",
             "INVENTED (novel-count)"),
        ])
    }

    // MARK: - Refused: his two real catastrophes

    func testAnsweredQuestionIsRefused() {
        // Row 70's shape: a question to an agent, replied to in markdown,
        // 214 → 488 characters pasted into a Claude Code prompt. raw 7 atoms;
        // out 14 (sure, i, can, explain, that, 1, sync, the, phone, first, 2,
        // check, the, watch — "**" is peeled, "1." is an atom). L1 fires
        // twice (3 non-blank lines vs 1, bold + a numbered item), L2 at
        // 14/7 = 2.0, L5 on the "1" and "2" nobody spoke, L6 on 8 novel
        // tokens in 14 atoms. Four independent rules on the one row this gate
        // exists for; ANSWERED heads the ladder and names the reason.
        let g = gate("Can you explain how the sync works?",
                     "Sure, I can explain that.\n1. **Sync** the phone first.\n2. **Check** the watch.")
        XCTAssertNil(g.accepted)
        XCTAssertEqual(g.reason, "ANSWERED (multi-line, markdown, length-ratio, "
                       + "novel-numeral, novel-count)")
    }

    func testInventedMathIsRefused() {
        // Row 54's shape: a request to total, obeyed. raw 19 atoms, out 25 ("+"
        // and "=" are orphan symbols, dropped); the repeated 42 / 9 are raw
        // vocabulary, so only "102" and "units" are novel — one numeral the
        // speaker never said is enough, and "102" cannot be spelled out of the
        // 42s and 9s he did say. 25/19 = 1.32 stays under L2, 2 novel tokens
        // stay under L6: the numeral rule fires alone, which is why L5 is
        // permissive about form and strict about digits.
        let g = gate("so the glider plus a 42 on each wing and a 9 on each wing so find the total",
                     "So the glider plus a 42 on each wing and a 9 on each wing. "
                     + "So the total is: 42 + 42 + 9 + 9 = 102 units.")
        XCTAssertNil(g.accepted)
        XCTAssertEqual(g.reason, "INVENTED (novel-numeral)")
    }

    func testPreambleOnlyReplyIsRefusedAsEmpty() {
        // A reply that is nothing but an allowlisted preamble: the sanitizer
        // leaves nothing, and nothing is never inserted.
        let g = gate("meet at 2 actually 3", "Here is the cleaned text:")
        XCTAssertNil(g.accepted)
        XCTAssertEqual(g.reason, "implausible: empty")
    }

    func testAWordlessReplyIsRefusedAsEmpty() {
        // L4 has to mean "no word in it": punctuation residue would otherwise
        // replace a whole dictation and pass every other rule (nothing novel,
        // one line, no polarity, and — under 12 atoms — no wholesale loss).
        let input = "the quarterly report shows revenue grew twelve percent this quarter"
        XCTAssertEqual(gate(input, ".").reason, "implausible: empty")
        XCTAssertEqual(gate(input, " -- ").reason, "implausible: empty")
        XCTAssertNil(gate(input, "").accepted)
    }

    // MARK: - Adversarial refusal corpus (must stay refused)

    func testTheShapesThatMustStillBeRefused() {
        assertRefused([
            // Answered in markdown (row 70's shape).
            ("can you explain how the sync works",
             "Sure, I can explain that.\n1. **Sync** the phone first.\n2. **Check** the watch.",
             "ANSWERED (multi-line, markdown, length-ratio, novel-numeral, novel-count)"),
            // Invented math (row 54's shape): "102" is not spellable out of
            // what he said.
            ("so the glider plus a 42 on each wing and a 9 on each wing so find the total",
             "So the glider plus a 42 on each wing and a 9 on each wing. "
             + "So the total is: 42 + 42 + 9 + 9 = 102 units.",
             "INVENTED (novel-numeral)"),
            // A WRONG number inside a bare-"no" correction: "18" is not
            // spellable out of "fifty" and "fifteen". The correction itself is
            // nobody's business here any more — the invented number is what
            // refuses it, which is the only part a gate can be sure of.
            ("the total is fifty no fifteen dollars", "The total is 18 dollars.",
             "INVENTED (novel-numeral)"),
            // A doubled digit and a concatenated pair: 55 out of one spoken
            // "five", 25 out of a "two" and a "five" four words apart.
            // Neither is witnessed by consecutive raw words, so neither is a
            // normalization — they are invented quantities.
            ("give me five minutes and i will send the draft over",
             "Give me 55 minutes and I will send the draft over.",
             "INVENTED (novel-numeral)"),
            ("we need two people and five laptops for the demo",
             "We need 25 people and five laptops for the demo.",
             "INVENTED (novel-numeral)"),
            // An UNWITNESSED ordinal and an unwitnessed meridiem: the digits
            // are the fact, and a suffix is not evidence of anything.
            ("we ship the beta on the ninth of next month at noon",
             "We ship the beta on the 22nd of next month at noon.",
             "INVENTED (novel-numeral)"),
            ("meet me at three in the afternoon tomorrow", "Meet me at 5 p.m. tomorrow.",
             "INVENTED (novel-numeral)"),
            // An invention inside an utterance that happens to carry a cue:
            // the cue buys the reply nothing, because no rule reads cues any
            // more. The numeral is what refuses it.
            ("i actually enjoyed the movie we watched last night with the team",
             "I actually enjoyed the 3 movies we watched last night with the team.",
             "INVENTED (novel-numeral)"),
            // A component of a compound he said is not a number he said: the
            // witness is a WHOLE atom. A wrong race date and a wrong weekly
            // mileage landed here until it was.
            ("the deadline is december twenty twenty six for the whole team",
             "The deadline is December 2020 for the whole team.", "INVENTED (novel-numeral)"),
            ("i ran fifty four miles last week and felt fine afterwards",
             "I ran 50 miles last week and felt fine afterwards.", "INVENTED (novel-numeral)"),
            ("we need twenty five testers for the pilot next month",
             "We need 20 testers for the pilot next month.", "INVENTED (novel-numeral)"),
            ("i want to hit a hundred and fifty miles this month",
             "I want to hit 100 miles this month.", "INVENTED (novel-numeral)"),
            // A run broken by a mark is a list, not a compound: "twenty, six"
            // cannot spell 26, exactly as on the grader's side.
            ("we ordered twenty, six of them arrived late this morning",
             "We ordered 26 of them arrived late this morning.", "INVENTED (novel-numeral)"),
            // The in-band answers L3 still reaches: a question to an agent
            // answered in two or three of its own thirteen-plus words (0.23
            // and 0.14). Its longer siblings are the first accepted gap below.
            ("which branch should i merge first the parser one or the config one", "The parser one.",
             "OVER_EDIT_FACT (wholesale-loss)"),
            ("should i use a mutex or an actor for that cache in the client", "An actor.",
             "OVER_EDIT_FACT (wholesale-loss)"),
            // Four novel content words on a long output — L6 without L2's
            // help, since the reply is the same length as the dictation.
            ("go through the retry layer and tell me where we swallow an error",
             "Audit the retry subsystem and identify each silently discarded exception.",
             "INVENTED (novel-count)"),
            // THREE of them on a 13-atom output, which is where L6's line
            // sits: two slip fixes plus a third novel word is the measured
            // price of refusing `numbers-01` and `repair-02` again. Two slips
            // on their own still land (F4 below) — that shape is the whole
            // reason the line is a length floor and not a higher count.
            //
            // This row is a REFUSAL OF A LEGITIMATE FIX, which is the one gap
            // that runs the other way and is now named as such in
            // `ContentGuard`'s gap list and in docs/llm-measurement-gate.md.
            // It is bought, not defended: nothing on this path tells three
            // slip fixes from three inventions (the edit-distance discount
            // that tried to is deleted with `novelShare`), and the row it
            // pays for is an in-band answer the bench grades INVENTED.
            ("we should of shipped the fix befour the standup with there approval today",
             "We should have shipped the fix before the standup with their approval today.",
             "INVENTED (novel-count)"),
        ])
    }

    // MARK: - Accepted: what a formatter is for

    func testCleanCleanupIsAccepted() {
        // Fillers stripped, a self-correction resolved, punctuation and
        // casing added — nothing invented, nothing inverted.
        let input = "um we should meet on Tuesday, I mean on Wednesday, and uh ship the build by the end of the month"
        let output = "We should meet on Wednesday, and ship the build by the end of the month."
        let g = gate(input, output)
        XCTAssertEqual(g.accepted, output)
        XCTAssertNil(g.reason)
    }

    func testAnAssistantOpenerIsNoLongerEvidenceOfAnything() {
        // The opener rule is GONE from this path, in every form it was ever
        // written in. The window version refused the cleanup that moves a
        // late opener to the front ("um yeah i mean okay lets just ship…" →
        // "Okay, let's just ship…"); the whole-raw echo that fixed it
        // disabled the rule on 3 of his 70 real rows, which say "sure" or
        // "okay" somewhere in the middle. Six words could never be the
        // difference between a reply and a dictation, so they are not asked.
        assertAccepted([
            // The speaker's own opener, wherever he said it.
            ("um okay so we ship the build tomorrow morning", "Okay, so we ship the build tomorrow morning."),
            ("um yeah i mean okay lets just ship the build tonight and see",
             "Okay, let's just ship the build tonight and see."),
            ("so anyway okay we push the fix and tell the team tomorrow",
             "Okay, we push the fix and tell the team tomorrow."),
            ("i i okay lets get the parser fix in before the freeze",
             "Okay, let's get the parser fix in before the freeze."),
            // A raw whose OWN first word is an assistant opener — "here",
            // "sure", "yes" — with the apostrophe restored on top of it.
            ("here is the thing i would like you to check the retry path first",
             "Here's the thing I would like you to check: the retry path first."),
            ("sure we can do that but lets ship the parser fix first",
             "Sure, we can do that, but let's ship the parser fix first."),
            ("yes lets get the parser fix in before the freeze tomorrow",
             "Yes, let's get the parser fix in before the freeze tomorrow."),
        ])
    }

    // MARK: - Adversarial acceptance corpus — F1: resolved self-corrections

    func testResolvedCorrectionsAreAccepted() {
        // The shape the correction clause exists to produce, and the shape
        // every version of a length rule refused: a resolution IS a shrink.
        // L3 is the only length floor left and it needs 12 atoms under it,
        // so every short resolution lands whatever it drops.
        assertAccepted([
            ("meet at the cafe scratch that at the office", "Meet at the office."),
            ("let's ship on friday i mean on saturday morning", "Let's ship on Saturday morning."),
            ("book the room for six people scratch that for eight people", "Book the room for 8 people."),
            ("i want to meet at the cafe actually at the office", "I want to meet at the office."),
            ("i want to meet at the cafe sorry at the office", "I want to meet at the office."),
            ("send the deck to design or rather to finance", "Send the deck to finance."),
        ])
    }

    func testLongResolvedCorrectionsAreAccepted() {
        // The same cues at his real length (12–20 atoms), where L3 is awake.
        // A resolution that keeps the corrected clause keeps most of the
        // utterance (0.65–0.75 here) — but one that throws away a long
        // reparandum does not, and that row is why the band is a quarter:
        // "i want to meet at the coffee shop on castro street actually at the
        // office" is 15 atoms and its correct resolution is 7 (0.47), which a
        // half refused. It is a measured shape, not a constructed one.
        assertAccepted([
            ("i want to meet at the coffee shop on castro street actually at the office",
             "I want to meet at the office."),
            ("we should ship the parser fix on tuesday i mean on wednesday morning before the standup",
             "We should ship the parser fix on Wednesday morning, before the standup."),
            ("send the summary to the design channel scratch that to the platform channel "
             + "and tag the two owners",
             "Send the summary to the platform channel, and tag the two owners."),
            ("book the small room for the design review actually the big room for the whole team",
             "Book the big room for the design review for the whole team."),
            ("tell the vendor we want the annual plan sorry the monthly plan for the first quarter",
             "Tell the vendor we want the monthly plan for the first quarter."),
            ("put the migration in the release notes or rather in the upgrade guide "
             + "with the rollback steps",
             "Put the migration in the upgrade guide, with the rollback steps."),
        ])
    }

    // MARK: - The accepted gaps, pinned rather than silent

    func testGapOneAnInBandAnswerUnderThreeNovelWordsLands() {
        // ACCEPTED GAP 1 — an in-band answer built from fewer than 3 novel
        // words. The measured Foundation Models row minus the word "Yes" is
        // six atoms of his own vocabulary: no structure, no growth, no
        // wholesale loss (6 < 12 atoms), no numeral, nothing novel. Every
        // detector ever written for it read a QUESTION, and his register is
        // made of questions (44 of 70 rows) — each widening refused a
        // formatted imperative, so the rule is gone and the hole is stated.
        assertAccepted([
            ("is it done?. okay.. let's go", "It is done. Okay, let's go."),
            ("is the build done yet or is it still compiling", "The build is still compiling."),
            // The two that L3 used to catch on its way past: at a quarter
            // instead of a half, a four-word answer to a fourteen-atom
            // question (0.29) is inside the band, so the gap is wider than it
            // was and this is where it is stated.
            ("can you tell me whether the formatter runs before or after the filler strip",
             "After the filler strip."),
            ("did the nightly sync finish or is it still running right now", "It is still running."),
        ])
        // The bench still names it, which is where the number lives.
        XCTAssertEqual(ContentGuard.check(raw: "is it done?. okay.. let's go",
                                          out: "It is done. Okay, let's go.").worst, .answered)
    }

    func testGapTwoAQuestionRewrittenAsAStatementLands() {
        // ACCEPTED GAP 2 — same atoms, nothing novel, no polarity word, and
        // a question he asked an agent pasted as a claim. Only the
        // `answer-shape` rule saw it, and it is a bench rule now.
        assertAccepted([
            ("are we sure the migration is reversible before we run it tonight",
             "We are sure the migration is reversible before we run it tonight."),
        ])
        XCTAssertEqual(ContentGuard.check(raw: "are we sure the migration is reversible "
                                          + "before we run it tonight",
                                          out: "We are sure the migration is reversible "
                                          + "before we run it tonight.").worst, .answered)
    }

    func testGapThreeAFabricatedDateWhoseDigitsHeSaidLands() {
        // ACCEPTED GAP 3 — L5 witnesses DIGITS, not meanings, and it must
        // fail permissive: its job is never to refuse a number the speaker
        // said. So a date whose digits he did say, moved to a month he did
        // not, lands ("nine" witnesses the 9), as do two novel content words
        // under L6's floor.
        assertAccepted([
            ("we ship the beta on the ninth of next month at noon",
             "We ship the beta on the 9th of October at noon."),
            ("book the room for the design review", "Book the large room for the design review tomorrow."),
        ])
        XCTAssertEqual(ContentGuard.check(raw: "book the room for the design review",
                                          out: "Book the large room for the design review tomorrow.").novel,
                       ["large", "tomorrow"])
    }

    func testGapFourAPolarityInversionLandsAndTheBenchScoresIt() {
        // ACCEPTED GAP 4 — an inversion is not refused on this path; the
        // bench scores it. The live rule was a polarity COUNT (carriers in vs
        // carriers out, no alignment, no exceptions), and the 2-column
        // measurement priced it: it refused "send it monday no wait tuesday"
        // → "Send it Tuesday." — a correctly resolved correction — on BOTH
        // model columns, costing 3 of the 81 seed golds and 2.3 composite on
        // llama, while a dropped or inserted polarity word appears in 0 of
        // his 70 real dictations and 0 of the 81 seeds. Measured false
        // positives against unmeasured true ones is not a trade a shipping
        // gate makes: a refusal costs a real improvement, a miss costs one
        // bad dictation the benchmark shows.
        let inversions = [
            ("do not push to main", "Push to main."),
            ("we cant ship the build today", "We can ship the build today."),
            ("we should ship it today", "We should not ship it today."),
            ("we should ship it today", "We shouldn't ship it today."),
            ("we have absolutely no time for this project", "We have time for this project."),
            ("we made no changes to the deploy script this week",
             "We made changes to the deploy script this week."),
            ("please make sure there are no duplicates in the export file",
             "Please make sure there are duplicates in the export file."),
        ]
        assertAccepted(inversions)
        // The benchmark is where they show up — every one of these is a
        // NEGATED row on the grader's profile, which is the rule the bench
        // never gave up (alignment, governed token, backchannel exemption).
        for (input, output) in inversions {
            XCTAssertEqual(ContentGuard.check(raw: input, out: output).worst, .negated, input)
        }
        // What the deletion buys — the bare-"no" self-correction the count
        // could not tell from a flip, because the "no" the model correctly
        // deleted is a carrier it can no longer find. Three of the 81 seeds
        // are this shape, and both models get all three right.
        assertAccepted([
            ("send it monday no tuesday", "Send it Tuesday."),
            ("send it monday no wait tuesday please", "Send it Tuesday."),
            ("the total is 50 no 15 dollars", "The total is 15 dollars."),
            ("we need two no three more testers for the pilot", "We need 3 more testers for the pilot."),
        ])
        // A "no" that SURVIVES the cleanup was never anybody's business.
        assertAccepted([
            ("no thanks we already have enough licences for the quarter",
             "No thanks, we already have enough licences for the quarter."),
            ("we have absolutely no time for this project this quarter",
             "We have absolutely no time for this project this quarter."),
            ("there are no duplicates in the export file as far as i can tell",
             "There are no duplicates in the export file, as far as I can tell."),
        ])
    }

    func testGapFiveAWholesaleDropOfAShortDictationLands() {
        // ACCEPTED GAP 5 — under 12 atoms L3 does not run, because a resolved
        // self-correction is a shrink of exactly this size and no length test
        // tells the two apart. So a short dictation thrown away lands, and so
        // does anything above a quarter at any length.
        assertAccepted([
            ("cancel the meeting with the finance team", "Cancel the meeting."),
            ("cancel the meeting with the finance team", "Cancel it."),
        ])
        // At 12 atoms the same shape refuses.
        XCTAssertEqual(gate("cancel the meeting with the finance team on thursday morning and tell them why",
                            "Cancel it.").reason, "OVER_EDIT_FACT (wholesale-loss)")
    }

    func testGapSevenANumberWitnessedRunByRunLands() {
        // ACCEPTED GAP 7 — the witness asks for each DIGIT RUN of a form on
        // its own, and of the whole dictation: "9:30" asks for a 9 and for a
        // 30, never for the two together. So numbers he said in unrelated
        // places — nine people, thirty signups — witness a time he never
        // said, and the "am" the model wrote after it is his number's letters
        // rather than a novel content word. Nothing else on this path sees
        // it: a clock time carries no letter of its own for L6 and is not a
        // token whose digits are the fact for L5 (gap 6), so what bounds the
        // reply is the text AROUND the number — L1, L2, L3 and L6 all read
        // it.
        //
        // It stays open on the gate's own rule: this fails toward letting a
        // number through, never toward refusing one he said, and asking for
        // the runs TOGETHER is a tightening no row in this corpus asks for
        // (before the rows below, requiring it left the whole suite green).
        let scattered = "nine of us are going and thirty people rsvped and two more asked at the "
            + "meeting and four said they would watch the standup and the review and the retro tomorrow"
        let head = "9 of us are going, 30 people RSVPed, 2 more asked at the meeting, and 4 said "
            + "they would watch the standup at "
        assertAccepted([
            (scattered, head + "9:30 am, the review at 2:30 pm, and the retro at 4:30 pm tomorrow."),
            // The decimal spelling of the same three times, which is the
            // price's shape too: same runs, same verdict.
            (scattered, head + "9.30 am, the review at 2.30 pm, and the retro at 4.30 pm tomorrow."),
        ])
        // The gap has an edge, and the spelling is where it falls: MERGED,
        // each time is a single run ("930am"), which has to be spoken whole
        // or spelled by consecutive words — so the identical reply gates, on
        // L5 as well as L6. And with no run reachable at all the gate does
        // what it is for.
        assertRefused([
            (scattered, head + "9:30am, the review at 2:30pm, and the retro at 4:30pm tomorrow.",
             "INVENTED (novel-numeral, novel-count)"),
            (scattered, head + "10:45 am, the review at 3:15 pm, and the retro at 5:20 pm tomorrow.",
             "INVENTED (novel-count)"),
        ])
    }

    // MARK: - Adversarial acceptance corpus — F2: numbers, ordinals, meridiems

    func testSpelledNumbersWrittenAsDigitsAreAccepted() {
        // Spelled → digits is a thing the formatter is ASKED to do, and the
        // canonicalizer covers the forms dictation produces, so each row is
        // a hit: novel 0, numerals 0, atom counts equal on both sides.
        assertAccepted([
            // "twenty twenty six" is ONE atom, 2026.
            ("the deadline is december twenty twenty six for the whole team",
             "The deadline is December 2026 for the whole team."),
            // "one point five" is 1.5 and the scale word stands on its own,
            // which is exactly how the model writes it.
            ("the budget is one point five million for next year total",
             "The budget is 1.5 million for next year total."),
            // The year rule is not pinned to one century.
            ("the release slipped to twenty twenty seven because of the audit",
             "The release slipped to 2027 because of the audit."),
            // "at two thirty" is a clock pair (the preposition is the
            // anchor), so "2:30" hits its spelled form.
            ("let's meet at two thirty tomorrow afternoon in the small room",
             "Let's meet at 2:30 tomorrow afternoon in the small room."),
            ("we did twenty six k in imports last night without a single retry",
             "We did 26K in imports last night without a single retry."),
            // The plain cardinal, the case that always worked — kept so the
            // boundary with the other forms stays visible.
            ("i ran fifty four miles last week and felt fine afterwards",
             "I ran 54 miles last week and felt fine afterwards."),
            // A numeral the canonicalizer cannot merge, witnessed by
            // consecutive raw number words: 19 + 0 + 5.
            ("the building went up in nineteen oh five according to the plaque",
             "The building went up in 1905, according to the plaque."),
        ])
    }

    func testWitnessedOrdinalsAndMeridiemsAreAccepted() {
        // A denormalized ordinal or a.m./p.m. form is a novel token whose
        // DIGITS are checked against what he said. The ordinal reading of the
        // raw ("the ninth" says 9, "the twenty third" says 23) lives on the
        // witness side only. The COUNT is not what saves these rows — L6
        // skips every piece of a number the witness test accepted, so three
        // of them in one utterance land too: merged in the letterless test
        // below, spaced in the one after it, rather than left to the reader's
        // trust.
        assertAccepted([
            ("we ship the beta on the ninth of next month at noon",
             "We ship the beta on the 9th of next month at noon."),
            ("we ship the beta on the twenty third of next month at noon",
             "We ship the beta on the 23rd of next month at noon."),
            ("we ship the beta on the first of october at noon",
             "We ship the beta on the 1st of October at noon."),
            ("let's meet at nine tomorrow morning in the small room",
             "Let's meet at 9am tomorrow morning in the small room."),
            ("meet me at three in the afternoon tomorrow", "Meet me at 3 p.m. tomorrow."),
        ])
    }

    func testSpelledFractionsClockIdiomsAndPricesAreAccepted() {
        // The spelled→digit family the canonicalizer cannot merge because the
        // spoken form is not a number word ("half", "quarter"). Each is a
        // novel token, which is what the BENCH calls it (a decimal or a clock
        // is not a numeral there), and a live gate stricter than the grader
        // refused every one of them — handing him unformatted rules output.
        // L5's permissiveness clause is what keeps this family: when the
        // witness cannot decide, it witnesses. Three in one utterance land on
        // L6's clause, not on a count — that row is in the letterless test
        // below.
        assertAccepted([
            ("give me two and a half hours", "Give me 2.5 hours."),
            ("the long run took an hour and a half on sunday morning",
             "The long run took 1.5 hours on Sunday morning."),
            ("i did three and a half miles on the treadmill this morning",
             "I did 3.5 miles on the treadmill this morning."),
            ("the pace was eight and a half minutes per mile on that run",
             "The pace was 8.5 minutes per mile on that run."),
            ("the run starts at half past six on saturday morning",
             "The run starts at 6:30 on Saturday morning."),
            ("lets start the call at quarter past nine tomorrow morning",
             "Let's start the call at 9:15 tomorrow morning."),
            ("the licence is nineteen ninety nine a month per seat",
             "The licence is $19.99 a month per seat."),
        ])
    }

    func testNovelTokensCarryingNoLetterAreNotContentWords() {
        // L6 counts novel CONTENT words, and a content word CARRIES A LETTER
        // OF ITS OWN. Counting every novel token refused replies that invent
        // nothing, and the A/B is the proof: the same sentence punctuated
        // with commas landed while its dashed twin died on four novel "-"
        // atoms. The number rows are worse — they are the spelled→digit
        // family L5 is permissive to protect, witnessed digit by digit by
        // consecutive spoken number words, and then called invention by the
        // count rule.
        //
        // The ordinal and meridiem rows are the same family wearing the
        // canonicalizer's two letters ("9th", "9am"), which is why they are
        // here at THREE: at L6's old count of 4 nobody dictates four of them
        // and the contradiction stayed latent, at 3 it refuses a shape he
        // says constantly. Each row's digits are witnessed one by one by L5,
        // exactly as the splits and years above are. Every row here is the
        // MERGED spelling; the spaced one the tokenizer splits in two is the
        // test below.
        let spoken = "we ship on friday if the tests pass and then we take monday off "
            + "for the holiday and the team gets a break"
        let dashed = "We ship on Friday - if the tests pass - and then we take Monday off "
            + "- for the holiday - and the team gets a break."
        let ordinals = ("the interviews are on the first the second and the third of october",
                        "The interviews are on the 1st, the 2nd, and the 3rd of October.")
        assertAccepted([
            (spoken, dashed),
            (spoken, "We ship on Friday, if the tests pass, and then we take Monday off, "
             + "for the holiday, and the team gets a break."),
            // Four splits and four years, his own register: three of either
            // always landed, and the fourth one refused the whole reply.
            ("my splits were seven fifty one seven forty eight seven fifty three and seven "
             + "forty six on the long run",
             "My splits were 7:51, 7:48, 7:53, and 7:46 on the long run."),
            ("the ledger totals for the year were nineteen oh five nineteen oh six nineteen "
             + "oh seven and nineteen oh eight",
             "The ledger totals for the year were 1905, 1906, 1907, and 1908."),
            // THREE ordinals and THREE meridiems — the rows the acceptance
            // corpus was missing, and the ones the count rule refused the day
            // it moved to 3.
            ordinals,
            ("we ship the beta on the ninth the tenth and the eleventh of next month",
             "We ship the beta on the 9th, the 10th, and the 11th of next month."),
            ("lets do the calls at nine and eleven in the morning and four in the afternoon",
             "Let's do the calls at 9am and 11am in the morning, and 4pm in the afternoon."),
            ("the standups are at nine and the reviews at two and the retro at four today",
             "The standups are at 9am, and the reviews at 2pm, and the retro at 4pm today."),
            // THREE decimals, the half of the fraction family the
            // canonicalizer cannot merge: letterless, so the clause covers
            // them at any count.
            ("my paces were eight and a half and nine and a half and ten and a half "
             + "minutes per mile",
             "My paces were 8.5, 9.5, and 10.5 minutes per mile."),
        ])
        // LIVE-only, as every relaxation on this path is: the bench still
        // counts every novel token, letters or not — the dashes, and the
        // denormalized numbers with them.
        XCTAssertEqual(ContentGuard.check(raw: spoken, out: dashed).triggers, [.novelCount])
        XCTAssertEqual(ContentGuard.check(raw: ordinals.0, out: ordinals.1).novel,
                       ["1st", "2nd", "3rd"])
    }

    func testTheSpacedFormOfADenormalizedNumberIsTheSameNumber() {
        // The blind spot the merged rows above could not see: the model
        // writes the meridiem and the ordinal spaced as readily as merged
        // ("9 am", "9 a.m.", "the 1 st"), and the tokenizer splits that into a
        // digit run and a BARE suffix atom. Read as a shape, the suffix atom
        // is a letter-carrying word the speaker never said — three of them in
        // one utterance, which is a Tuesday in his register, and the reply is
        // refused as invention. Read as L5's verdict, which is what L6 does,
        // it is a piece of a number he demonstrably said.
        assertAccepted([
            // THREE spaced ordinals.
            ("the interviews are on the first the second and the third of october",
             "The interviews are on the 1 st, the 2 nd, and the 3 rd of October."),
            // THREE spaced meridiems, and the same row in the dotted spelling
            // a formatter actually writes ("a.m." is one atom, "am").
            ("the standups are at nine and the reviews at two and the retro at four today",
             "The standups are at 9 am, and the reviews at 2 pm, and the retro at 4 pm today."),
            ("lets do the calls at nine and eleven in the morning and four in the afternoon",
             "Let's do the calls at 9 a.m. and 11 a.m. in the morning, and 4 p.m. in the afternoon."),
            // MIXED: one merged ordinal, one spaced, two spaced meridiems —
            // three letter-carrying pieces, which is the count, and the
            // spelling is not what the rule reads.
            ("the interviews are on the first and the second of october and the standups "
             + "are at nine and four",
             "The interviews are on the 1st and the 2 nd of October, and the standups are "
             + "at 9 am and 4 pm."),
        ])
        // The witness still decides, spacing or none: a meridiem whose hour
        // he never said is L5's row, exactly as its merged twin is.
        assertRefused([
            ("let's meet at nine tomorrow morning in the small room",
             "Let's meet at 11 am tomorrow morning in the small room.",
             "INVENTED (novel-numeral)"),
        ])
        // The join stops at a BOUNDARY MARK, the rule the compound run obeys
        // on the raw side: "At 9, am I…" is a clause boundary and an
        // auxiliary, not a meridiem. This row is here for that mark — its
        // third novel content word IS the "am", and without the mark test the
        // clause would swallow it and the reply would land at two.
        assertRefused([
            ("meeting at nine should i show up early tomorrow before the standup",
             "At 9, am I supposed to arrive early tomorrow before the standup?",
             "INVENTED (novel-count)"),
        ])
    }

    func testASuffixAfterASeparatedNumberIsPartOfThatNumber() {
        // The rows above vary the SPELLING over a bare digit run, which is
        // the only shape the witness joined a suffix atom to ("9" + "am"). A
        // clock time keeps its colon and a decimal its point, so neither is a
        // numeral to the tokenizer — and "at nine thirty in the morning" →
        // "9:30 am" left the "am" standing as a letter-carrying word he never
        // said, while the merged twin "9:30am" (one atom, "930am") was
        // witnessed whole. Three times in one dictation is a refusal, and a
        // dictation full of times is what a scheduling prompt IS.
        //
        // So these rows vary the spelling over every shape the witness reads
        // as number material — a clock time, a decimal, a price — plus the
        // version string it must NOT read as one.
        let clock = "lets do the standup at nine thirty in the morning the review at two thirty "
            + "in the afternoon and ship by four thirty in the afternoon"
        let prices = "the early bird is nineteen ninety nine until nine thirty in the morning "
            + "then twenty nine ninety nine until two thirty in the afternoon and thirty nine "
            + "ninety nine after four thirty in the afternoon"
        assertAccepted([
            // A CLOCK TIME — spaced, merged, and the dotted spelling a
            // formatter writes by preference. Three times, three spellings,
            // one verdict.
            (clock, "Let's do the standup at 9:30 am, the review at 2:30 pm, and ship by 4:30 pm."),
            (clock, "Let's do the standup at 9:30am, the review at 2:30pm, and ship by 4:30pm."),
            (clock, "Let's do the standup at 9:30 a.m., the review at 2:30 p.m., and ship by "
             + "4:30 p.m."),
            // A DECIMAL — the same three times in the dotted form, which is
            // also the PRICE's shape: the currency mark is not a word
            // character, so "$19.99" and "9.30" are one family to the witness.
            (clock, "Let's do the standup at 9.30 am, the review at 2.30 pm, and ship by 4.30 pm."),
            (clock, "Let's do the standup at 9.30am, the review at 2.30pm, and ship by 4.30pm."),
            // THREE PRICES beside three meridiems, spaced and merged.
            (prices, "The early bird is $19.99 until 9:30 am, then $29.99 until 2:30 pm, and "
             + "$39.99 after 4:30 pm."),
            (prices, "The early bird is $19.99 until 9:30am, then $29.99 until 2:30pm, and "
             + "$39.99 after 4:30pm."),
            // A TEEN minute never merges on the raw side (`NumberCanon.clock`
            // takes a tens-word minute, because "three fifteen minute breaks"
            // is a count), so "nine fifteen" stays two atoms and "9:15" is
            // novel. The witness reaches it digit by digit anyway — which is
            // what makes that limit a grader's question and not a refusal.
            ("lets meet at nine fifteen in the morning and again at four fifteen in the "
             + "afternoon and wrap by five fifteen in the afternoon",
             "Let's meet at 9:15 am, again at 4:15 pm, and wrap by 5:15 pm."),
        ])
        // The witness still decides, and a number he never said takes its
        // suffix atom down with it — the same replies with times and prices
        // nobody spoke. The merged clock row gates on L5 as well: "1045am"
        // IS a token whose digits are the fact.
        assertRefused([
            (clock, "Let's do the standup at 10:45 am, the review at 3:15 pm, and ship by 5:20 pm.",
             "INVENTED (novel-count)"),
            (clock, "Let's do the standup at 10:45am, the review at 3:15pm, and ship by 5:20pm.",
             "INVENTED (novel-numeral, novel-count)"),
            (clock, "Let's do the standup at 10.45 am, the review at 3.15 pm, and ship by 5.20 pm.",
             "INVENTED (novel-count)"),
            (prices, "The early bird is $24.99 until 10:45 am, then $34.99 until 3:15 pm, and "
             + "$44.99 after 5:20 pm.", "INVENTED (novel-count)"),
        ])
        // A VERSION STRING is where the rule stops, and that line is gap 6's:
        // "v1.2" canonicalizes to "v12" and the "v" is the speaker's own word
        // ("version"), not two letters the canonicalizer hung on his number.
        // So it is novel CONTENT in both spellings — merged, or with the
        // model's own space — and three of them refuse whether or not the
        // digits are witnessed.
        let versions = "we shipped version one point two on monday and version one point three "
            + "on wednesday and version one point four this morning"
        assertRefused([
            (versions, "We shipped v1.2 on Monday, v1.3 on Wednesday, and v1.4 this morning.",
             "INVENTED (novel-count)"),
            (versions, "We shipped v 1.2 on Monday, v 1.3 on Wednesday, and v 1.4 this morning.",
             "INVENTED (novel-count)"),
        ])
        // The boundary mark breaks the join after a clock time exactly as it
        // does after a digit run, and the A/B is the proof: with the comma
        // the "am" is the auxiliary it is and the third novel content word
        // gates; without it the same words ARE a 9:30 am to the rule, which
        // is the collateral the digit-run form already carried.
        let auxiliary = "meeting at nine thirty should i show up early tomorrow before the standup"
        XCTAssertEqual(gate(auxiliary, "At 9:30, am I supposed to arrive early tomorrow before "
                            + "the standup?").reason, "INVENTED (novel-count)")
        XCTAssertNil(gate(auxiliary, "At 9:30 am I supposed to arrive early tomorrow before "
                          + "the standup?").reason)
    }

    func testAQuestionGainingItsMarkIsAccepted() {
        // Punctuation is the job. Nothing here reads the question's shape any
        // more, so a question the model merely punctuates lands whether or
        // not it keeps its opening word.
        assertAccepted([
            ("did the nightly sync finish or is it still running right now",
             "Did the nightly sync finish, or is it still running right now?"),
            ("can you check whether the sync finished before i leave",
             "Can you check whether the sync finished before I leave?"),
            ("how do i get the sync to retry without restarting the app",
             "How do I get the sync to retry without restarting the app?"),
            ("have a look at the retry path before you merge the branch",
             "Have a look at the retry path before you merge the branch."),
            ("go through the client and tell me where we swallow an error",
             "Go through the client and tell me where we swallow an error."),
        ])
    }

    // MARK: - Adversarial acceptance corpus — F3: apostrophe restoration

    func testRestoredContractionsAreAccepted() {
        // Dictation drops the apostrophe; restoring it is a formatting fix.
        // Two rules had to learn it: `Align.isNegation` (so a restored
        // negation is the same carrier on both sides, which is now a BENCH
        // concern only) and the novelty vocabulary (so it is not a word the
        // speaker never said, which is L6's). Both are root-cause fixes.
        assertAccepted([
            ("i dont think we can ship this week honestly",
             "I don't think we can ship this week, honestly."),
            ("we cant get the build out before friday morning",
             "We can't get the build out before Friday morning."),
            ("that wont work for the demo on tuesday afternoon",
             "That won't work for the demo on Tuesday afternoon."),
            ("he didnt review the pull request yet so we wait",
             "He didn't review the pull request yet, so we wait."),
            ("it isnt ready yet and we shouldnt promise it today",
             "It isn't ready yet and we shouldn't promise it today."),
            ("i havent heard back from the vendor about the quote",
             "I haven't heard back from the vendor about the quote."),
            // THREE restorations, 13 atoms: three novel tokens gated at any
            // length until the vocabulary learned the class.
            ("we cant ship today and it isnt ready and i dont like it",
             "We can't ship today, and it isn't ready, and I don't like it."),
            // The same shape at his real length — a 29-atom coding-agent
            // prompt with three restorations.
            ("go through the client and add a timeout to every call because right now it "
             + "doesnt fail fast and we cant tell whether its the network or the server",
             "Go through the client and add a timeout to every call, because right now it "
             + "doesn't fail fast and we can't tell whether it's the network or the server."),
            // The contractions a hand list forgot: the restoration test is
            // structural (`Align.isApostropheRestored`), so a form nobody
            // listed reads as the formatting fix it is.
            ("we mustnt push straight to main on a friday afternoon",
             "We mustn't push straight to main on a Friday afternoon."),
            ("we neednt block the release on that one flaky test",
             "We needn't block the release on that one flaky test."),
        ])
    }

    // MARK: - Adversarial acceptance corpus — F4: the slip fixes the prompt asks for

    func testTheSlipFixesThePromptCommissionsAreAccepted() {
        // The system prompt says "correct only clear speech-to-text slips
        // such as homophones or split/merged words", and every version of an
        // introduced-word rule refused them by construction — the model does
        // what it is told and the gate throws it away, the worst shape a gate
        // can have. TWO slips in one utterance land at any length, in EITHER
        // direction (a homophone list sanctions the corruption as readily as
        // the fix), and three land below L6's 10-atom floor; the edit-distance
        // discount that once propped up the share rule is gone with the rule.
        // Three on a longer output is where the line is: that row sits in the
        // refusal corpus above and is a named gap in the other direction —
        // `ContentGuard`'s gap list and the doc both state that the gate
        // refuses it and what the refusal buys.
        assertAccepted([
            ("i think there ready to go whenever we are",
             "I think they're ready to go whenever we are."),
            ("let me know if your free tomorrow afternoon for a quick sync",
             "Let me know if you're free tomorrow afternoon for a quick sync."),
            // The same pair the other way round — the direction a listed
            // homophone class could not tell apart.
            ("i think they're ready to go whenever we are",
             "I think there ready to go whenever we are."),
            // An inflection of a word he said: four foundation rows and two
            // llama rows were refused on exactly this.
            ("use a short backoff start at 200 milliseconds and double it and stop after "
             + "five attempts so we never hang",
             "Use a short backoff, starting at 200 milliseconds, and double it. "
             + "Stop after five attempts so we never hang."),
            ("we should use the neighbours list for the lookup instead",
             "We should use the neighbors list for the lookup instead."),
            // ONE introduced content word, the rule that used to refuse it by
            // name.
            ("send the report on thursday please", "Send the final report on Thursday, please."),
            // The split-word merge the prompt also commissions.
            ("we need to double check the churn numbers",
             "We need to double-check the churn numbers."),
            // TWO slips in one short utterance — the two commonest Parakeet
            // classes in the same sentence, which was a 0.18 and a 0.20 novel
            // share and a refusal of exactly what the model is told to do.
            // Pinned at 11, 10 and 13 atoms: at the deleted share rule's old
            // floor and above it.
            ("i think there going to be to late for the demo",
             "I think they're going to be too late for the demo."),
            ("we should of shipped the fix befour the standup today",
             "We should have shipped the fix before the standup today."),
            ("i think there going to be to late for the demo tomorrow morning",
             "I think they're going to be too late for the demo tomorrow morning."),
            // THREE novel tokens UNDER the floor: 7 atoms out, so L6 never
            // runs and the cleanup lands. The floor is the whole relaxation —
            // above it the same three refuse, which is what keeps the two
            // in-band answers the bench grades INVENTED out of his editor.
            ("ship the build tomorrow", "Ship the improved production release build tomorrow."),
        ])
    }

    // MARK: - Adversarial acceptance corpus — F5: innocents that carry a cue

    func testUtterancesThatMerelyCONTAINACueAreAccepted() {
        // "actually", "sorry" and "no" are ordinary words far more often than
        // they are correction cues, and a widened cue lexicon relaxed a gate
        // for every utterance that happened to hold one. No rule reads a cue
        // now: these land because nothing is invented, restructured or
        // inverted.
        assertAccepted([
            ("i actually enjoyed the movie we watched last night with the team",
             "I actually enjoyed the movie we watched last night with the team."),
            ("sorry about the delay on the report i will send it tonight",
             "Sorry about the delay on the report. I will send it tonight."),
            ("it doesnt actually allow that on the free tier anymore",
             "It doesn't actually allow that on the free tier anymore."),
        ])
    }

    // MARK: - Adversarial acceptance corpus — F6: ordinary cleanups

    func testOrdinaryCleanupsAreAccepted() {
        assertAccepted([
            // Fillers.
            ("um so i think we should uh ship the beta on thursday and see what breaks",
             "So I think we should ship the beta on Thursday and see what breaks."),
            // Stutter, plus one comma added before "but".
            ("the the report is ready but the numbers need a second look",
             "The report is ready, but the numbers need a second look."),
            // Commas only.
            ("okay so we push the fix and then we tell the team",
             "Okay, so we push the fix, and then we tell the team."),
            // A hedge kept and a sentence split.
            ("i dont really care how we do it we just get to the point",
             "I don't really care how we do it. We just get to the point."),
            // Casing on a product name the speaker said.
            ("push the fix to stellarhub before the standup tomorrow morning",
             "Push the fix to StellarHub before the standup tomorrow morning."),
            // A filler-heavy LONG prompt: at a terminal, in an IDE or in
            // Notes the pipeline leaves the fillers in for the model, so a
            // correct strip is a real shrink — and it has to stay inside L3's
            // band, which is the one place the two halves of the pipeline
            // have to agree about what the input is.
            ("um so i think uh we should um ship the beta on thursday you know and uh "
             + "see what breaks before um the freeze",
             "So I think we should ship the beta on Thursday, and see what breaks before the freeze."),
            // Short and filler-heavy: under 12 atoms nothing can collapse.
            ("uh um so um yeah uh um right um okay", "So, yeah. Right. Okay."),
            ("um so we uh um ship the fix um today", "So we ship the fix today."),
        ])
    }

    func testAnUtteranceEndingMidSentenceIsAccepted() {
        // He stops talking mid-clause and the formatter must not invent an
        // ending — nor must the gate refuse one that does not. Both shapes
        // land: the fragment left as a fragment, and the fragment given a
        // terminal mark.
        assertAccepted([
            ("so the plan for the migration is that we first take the database and then",
             "So the plan for the migration is that we first take the database and then"),
            ("so the plan for the migration is that we first take the database and then",
             "So the plan for the migration is that we first take the database, and then…"),
            ("i was going to say that the retry path needs a timeout but",
             "I was going to say that the retry path needs a timeout, but"),
        ])
    }

    func testAnAnchoredCountIsNotAClockTime() {
        // The canonicalizer's clock pair must not fire on a COUNT: "before
        // two forty minute sessions" is two sessions of forty minutes, and
        // merging it to 2:40 changes the raw atom set so that the CORRECT
        // output ("2 40-minute sessions") reads as invented content.
        assertAccepted([
            ("we did it before two forty minute sessions of the workshop",
             "We did it before two 40-minute sessions of the workshop."),
            ("come back after three thirty minute rounds of the drill",
             "Come back after three 30-minute rounds of the drill."),
        ])
    }

    // MARK: - What the live gate deliberately does NOT refuse

    func testOverEditingInsideTheBandIsScoredNotRefused() {
        // Over-editing is real damage — 16 deletions across 5 of his 70 rows
        // — and only its wholesale end (L3) is this gate's business: the
        // benchmark charges every deletion in M, and the register wording and
        // the correction clause (plan §10.3 follow-up 2) are the fix. Inside
        // the band a drop lands.
        let rows = [
            // A fact dropped from a 13-atom prompt: 10 of 13 survive.
            ("i want the main focus to be the retry path and the timeout handling",
             "The main focus to be the retry path and the timeout handling."),
            ("for the logo yeah lets go with the darker one for the whole site",
             "For the logo, let's go with the darker one for the whole site."),
        ]
        assertAccepted(rows)
        // The bench charges them: the first drops content, and both are
        // scored in M rather than refused here.
        XCTAssertEqual(ContentGuard.check(raw: rows[0].0, out: rows[0].1).droppedContent, ["i", "want"])
    }

    // MARK: - The profile split

    func testTheGateRunsTheLiveProfileWhileTheBenchStaysStrict() {
        // One row per rule the live profile drops or relaxes: accepted by the
        // gate, still gated by the grader's default profile. This IS the
        // split — the bench keeps refusing what it was tuned to refuse (a
        // wrong leaderboard number), while the user keeps the improvement (a
        // refusal is a lost fix).
        let rows: [(String, String, ContentGuard.Trigger)] = [
            // The opener rule, on a reply that opens with a word the raw
            // does not carry anywhere — the strictest shape it ever had.
            ("we ship the build tomorrow morning after the standup",
             "Sure, we ship the build tomorrow morning after the standup.", .opener),
            // The answer-shape rule.
            ("are we sure the migration is reversible before we run it tonight",
             "We are sure the migration is reversible before we run it tonight.", .answerShape),
            // The strict numeral rule.
            ("the building went up in nineteen oh five according to the plaque",
             "The building went up in 1905, according to the plaque.", .novelNumeral),
            // The 3-novel-token count at ANY length: L6 keeps the count and
            // adds a 10-atom floor, and this output is 7.
            ("ship the build tomorrow", "Ship the improved production release build tomorrow.",
             .novelCount),
            // The novel-share rule.
            ("we ship the fix tomorrow morning at nine",
             "We ship the fix tomorrow morning at 9 after breakfast.", .novelShare),
            // The collapse rule, below L3's 12-atom floor…
            ("cancel the meeting with the finance team", "Cancel the meeting.", .lengthCollapse),
            // …and above it, between the two bands: 7 of 15 atoms is a
            // collapse to the grader and a resolved correction here.
            ("i want to meet at the coffee shop on castro street actually at the office",
             "I want to meet at the office.", .lengthCollapse),
            // The alignment-driven negation rules, which live no longer has
            // any version of.
            ("we have absolutely no time for this project", "We have time for this project.",
             .negationDropped),
            ("we should ship it today", "We should not ship it today.", .negationInserted),
        ]
        for (input, output, trigger) in rows {
            XCTAssertEqual(gate(input, output).accepted, output, input)
            XCTAssertEqual(ContentGuard.check(raw: input, out: output).triggers, [trigger], input)
        }
    }

    func testGateAcceptsEverySeedGoldExceptTheNamedGaps() {
        // The gate must not refuse a legitimate transform: every seed's
        // hand-authored gold, judged against the same stripped input the
        // formatter sees, passes — except ONE row, and that row is a gap this
        // file pins by name. `fragment-01` is the all-filler fragment whose
        // gold is empty (L4, and on-device the one-word fast path never
        // consults the gate). The three bare-"no" corrections that used to sit
        // beside it (`correct-day`, `correct-number`, `repair-02`) are the
        // measured cost the polarity count was deleted for.
        //
        // These 81 golds tuned the thresholds, so this is a REGRESSION pin,
        // never the false-positive guard — the adversarial corpus above is.
        let stripper = FillerStripper()
        var accepted = 0
        var refused: [String: String] = [:]
        for c in EvalCase.seeds {
            let input = stripper.strip(c.raw)
            let g = TextFormatter.gateModelOutput(c.gold, of: input, language: c.language)
            if let reason = g.reason {
                refused[c.id] = reason
                continue
            }
            XCTAssertEqual(g.accepted, c.gold, c.id)
            accepted += 1
        }
        XCTAssertEqual(EvalCase.seeds.count, 81)
        XCTAssertEqual(accepted, 80)
        XCTAssertEqual(refused, ["fragment-01": "implausible: empty"])
    }

    // MARK: - The rejection log

    func testLogHeadIsOneLineAndCapped() {
        XCTAssertEqual(TextFormatter.logHead("Sure!\nHere you go."), "Sure! ⏎ Here you go.")
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(TextFormatter.logHead(long), String(repeating: "a", count: 80) + "…")
        XCTAssertEqual(TextFormatter.logHead("  short  "), "short")
    }
}
