import XCTest
@testable import WhisprBroCore

/// The extracted samples → final-text pipeline with a stub ASR — proves the
/// Auto-Clean gating rules (task-014 §5a, §7a) that `DictationPipeline` exists
/// to keep identical across platforms.
final class DictationPipelineTests: XCTestCase {
    /// Canned-transcript ASR: the pipeline under test never touches audio.
    /// Records the samples it received (for the trim-floor fallback test).
    private actor StubAsr: AsrEngine {
        nonisolated let minimumSamples: Int
        private let canned: String
        private(set) var transcribed: [Float] = []

        init(text: String, minimumSamples: Int = 0) {
            self.canned = text
            self.minimumSamples = minimumSamples
        }

        var isLoaded: Bool { true }
        func load() async throws {}
        func transcribe(_ samples: [Float]) async throws -> AsrResult {
            transcribed = samples
            // A measurable (but tiny) duration so `asrSeconds > 0` is never flaky.
            try? await Task.sleep(for: .milliseconds(2))
            return AsrResult(text: canned)
        }
    }

    private let noDict = DictionaryEngine(rules: [])
    private let stripper = FillerStripper()

    // MARK: - Auto-Clean gating

    func testVerbatimLevelSkipsStripAndFormatter() async throws {
        // Level "Off (verbatim)": the WHOLE stage is a no-op — fillers survive,
        // neither prepareFormatter nor format runs, formatSeconds stays 0.
        let pipeline = DictationPipeline(asr: StubAsr(text: " um hello there "))
        var formatterRan = false
        let outcome = try await pipeline.run(
            [0.1], dictionary: noDict, stripper: stripper, level: .verbatim,
            prepareFormatter: { formatterRan = true },
            format: { _ in formatterRan = true; return "MUST NOT RUN" })
        let out = try XCTUnwrap(outcome)
        XCTAssertFalse(formatterRan)
        XCTAssertEqual(out.verbatimText, "um hello there")   // whitespace-trimmed only
        XCTAssertEqual(out.text, "um hello there")           // byte-identical to verbatim
        XCTAssertEqual(out.timings.formatSeconds, 0)
    }

    func testVerbatimRegisterSkipsStripButRunsFormatter() async throws {
        // A verbatim register (ide/terminal/notes) skips only the filler strip;
        // the formatter stage still runs — prepare first, then format.
        let pipeline = DictationPipeline(asr: StubAsr(text: "um hello"))
        var prepared = false
        var sawInput: String?
        let outcome = try await pipeline.run(
            [0.1], dictionary: noDict, stripper: stripper,
            level: .fillers, verbatimRegister: true,
            prepareFormatter: { prepared = true },
            format: { input in
                XCTAssertTrue(prepared)   // prepare runs before the format stage
                sawInput = input
                return "formatted"
            })
        XCTAssertEqual(sawInput, "um hello")   // strip skipped — filler intact
        // A VERBATIM register means Auto-Clean is off for that app, so the
        // finishing pass is off too: no forced capital, no invented full stop.
        // (A prose register gets both — see testCodeAndShellRegistersAreNotFinished.)
        XCTAssertEqual(outcome?.text, "formatted")
        XCTAssertEqual(outcome?.verbatimText, "um hello")
    }

    func testAllFillerUtteranceFallsBackToVerbatim() async throws {
        // "um, uh." strips to bare punctuation (no letter or digit) — the
        // formatter must receive the verbatim text so a dictation always lands.
        let pipeline = DictationPipeline(asr: StubAsr(text: "um, uh."))
        var sawInput: String?
        let outcome = try await pipeline.run(
            [0.1], dictionary: noDict, stripper: stripper, level: .fillers,
            format: { input in sawInput = input; return input })
        XCTAssertEqual(sawInput, "um, uh.")
        XCTAssertEqual(outcome?.verbatimText, "um, uh.")
    }

    // MARK: - Dictionary

    func testDictionaryAppliedExactlyOnce() async throws {
        // An expanding rule (target contains its source) is exactly the case a
        // second apply would corrupt ("whispr-bro" → "whispr-bro-bro").
        let dict = DictionaryEngine(rules: [.init(from: "whispr", to: "whispr-bro")])
        let pipeline = DictationPipeline(asr: StubAsr(text: "ship whispr today"))
        let outcome = try await pipeline.run(
            [0.1], dictionary: dict, stripper: stripper, level: .fillers,
            format: { $0 })   // identity: expose exactly what reached the formatter
        XCTAssertEqual(outcome?.verbatimText, "ship whispr-bro today")
        XCTAssertEqual(outcome?.text, "Ship whispr-bro today.",
                       "identity formatter, so this is the finishing pass alone")
    }

    func testCodeAndShellRegistersAreNotFinished() async throws {
        // A capital or an invented period in code is a syntax error, and in a
        // shell it is a different command.
        for register in [AppCategory.ide, .terminal] {
            let pipeline = DictationPipeline(asr: StubAsr(text: "let x = 1"))
            let outcome = try await pipeline.run(
                [0.1], dictionary: noDict, stripper: stripper, level: .fillers,
                register: register, format: { $0 })
            XCTAssertEqual(outcome?.text, "let x = 1", "\(register) must pass through untouched")
        }
    }

    func testSpokenLayoutIsAppliedAroundTheFormatter() async throws {
        // The formatter never sees the marker words, and the layout lands on
        // its output (DictationPipeline's contract with SpokenStructure).
        let pipeline = DictationPipeline(asr: StubAsr(text: "buy milk new line buy eggs"))
        var sawInput: String?
        let outcome = try await pipeline.run(
            [0.1], dictionary: noDict, stripper: stripper, level: .fillers,
            format: { input in sawInput = input; return input })
        XCTAssertEqual(sawInput, "buy milk. buy eggs", "markers lifted out, boundary left behind")
        XCTAssertEqual(outcome?.text, "Buy milk\nBuy eggs.")
        XCTAssertEqual(outcome?.verbatimText, "buy milk new line buy eggs",
                       "history keeps what he actually said")
    }

    func testDictionaryTargetProtectedFromFillerStrip() async throws {
        // A dictionary target that collides case-insensitively with a filler
        // ("uhm" is in the core set) must survive the strip.
        let dict = DictionaryEngine(rules: [.init(from: "uhm", to: "uhm")])
        let pipeline = DictationPipeline(asr: StubAsr(text: "the uhm library"))
        var sawInput: String?
        _ = try await pipeline.run(
            [0.1], dictionary: dict, stripper: stripper, level: .fillers,
            format: { input in sawInput = input; return input })
        XCTAssertEqual(sawInput, "the uhm library")
    }

    // MARK: - Self-repair (before the strip, under its gate)

    /// What reached the formatter (identity formatter) and the outcome.
    private func run(
        _ raw: String, level: AppConfig.Cleanup.Level = .standard, verbatimRegister: Bool = false,
        language: DictationLanguage = .english, dictionary: DictionaryEngine? = nil,
        format: @escaping (String) -> String = { $0 }
    ) async throws -> (input: String?, outcome: DictationPipeline.Outcome?) {
        var sawInput: String?
        let outcome = try await DictationPipeline(asr: StubAsr(text: raw)).run(
            [0.1], dictionary: dictionary ?? noDict,
            stripper: FillerStripper(core: FillerStripper.coreFillers(for: language)),
            level: level, verbatimRegister: verbatimRegister, language: language,
            format: { input in sawInput = input; return format(input) })
        return (sawInput, outcome)
    }

    func testSelfRepairRunsBeforeTheFillerStrip() async throws {
        // The filled pause is R1's evidence that "ten, uh, ten" is a repeat.
        // Stripped first, "ten, ten" reads as a list and nothing could fire.
        let raw = "look at the last ten, uh, ten runs"
        XCTAssertEqual(stripper.strip(raw), "look at the last ten, ten runs")
        XCTAssertEqual(SelfRepair().apply(stripper.strip(raw)).fires, [])
        let (input, outcome) = try await run(raw)
        XCTAssertEqual(input, "look at the last ten runs")
        XCTAssertEqual(outcome?.verbatimText, raw, "history keeps what he said")
    }

    func testDictionaryRunsFirstAndItsTargetsAreProtected() async throws {
        // "zq" between two words is a fragment to R3 — unless the dictionary
        // put it there.
        let (bare, _) = try await run("run the zq tool now")
        XCTAssertEqual(bare, "run the tool now")
        let dict = DictionaryEngine(rules: [.init(from: "zed queue", to: "zq")])
        let (input, outcome) = try await run("run the zed queue tool now", dictionary: dict)
        XCTAssertEqual(input, "run the zq tool now")
        XCTAssertEqual(outcome?.verbatimText, "run the zq tool now")
    }

    func testCorrectionsResolveOnlyAtStandard() async throws {
        let raw = "ship the the build build Thursday, no wait, Friday"
        let (fillers, _) = try await run(raw, level: .fillers)
        XCTAssertEqual(fillers, "ship the build Thursday, no wait, Friday", "repeats only")
        let (standard, _) = try await run(raw, level: .standard)
        XCTAssertEqual(standard, "ship the build Friday")
        let (_, verbatim) = try await run(raw, level: .verbatim)
        XCTAssertEqual(verbatim?.text, raw, "verbatim: byte-identical, nothing removed")
    }

    func testVerbatimRegistersAreUntouched() async throws {
        let raw = "um the dog dog park opens Thursday, no wait, Friday"
        let (input, _) = try await run(raw, verbatimRegister: true)
        XCTAssertEqual(input, raw)
    }

    func testSelfRepairIsEnglishOnly() async throws {
        // Another dictation language: the stage does not run at all.
        let (italian, _) = try await run("the dog dog park is open", language: .italian)
        XCTAssertEqual(italian, "the dog dog park is open")
        // English selected, but the recognizer is sure the text is not.
        let text = "Il burro burro e la farina sono sul tavolo della cucina."
        let (gated, _) = try await run(text)
        XCTAssertEqual(gated, text)
        let (english, _) = try await run("the dog dog park is open")
        XCTAssertEqual(english, "the dog park is open")
    }

    func testSpokenLayoutSurvivesTheRepairs() async throws {
        let (_, repeat_) = try await run("we went over over the numbers new paragraph thanks again")
        XCTAssertEqual(repeat_?.text, "We went over the numbers.\n\nThanks again.")
        // A doubled marker is SpokenStructure's (it drops the redundant one):
        // the rules leave both copies for it.
        XCTAssertEqual(SelfRepair().apply("buy milk new line new line buy eggs").fires, [])
        let (_, doubled) = try await run("buy milk new line new line buy eggs")
        XCTAssertEqual(doubled?.text, "Buy milk\nBuy eggs.")
        let (_, bullets) = try await run("three things bullet point the the cache cache keys bullet point the lo logs")
        XCTAssertEqual(bullets?.text, "Three things:\n- The cache keys\n- The logs")
    }

    func testTwoEqualListItemsAreTwoItems() async throws {
        // A spoken layout marker is a boundary the rules never cross: two
        // equal items in a row are not a repeat, at either level that runs
        // the rules (the tally of a vote must not change).
        for level in [AppConfig.Cleanup.Level.fillers, .standard] {
            let (_, survey) = try await run("survey answers bullet point yes bullet point yes bullet point no",
                                            level: level)
            XCTAssertEqual(survey?.text, "Survey answers:\n- Yes\n- Yes\n- No", "\(level)")
            let (_, votes) = try await run(
                "votes bullet point approve bullet point approve bullet point reject bullet point approve",
                level: level)
            XCTAssertEqual(votes?.text, "Votes:\n- Approve\n- Approve\n- Reject\n- Approve", "\(level)")
            let (_, lines) = try await run("hi team new line okay new line okay new line thanks", level: level)
            XCTAssertEqual(lines?.text, "Hi team\nOkay\nOkay\nThanks.", "\(level)")
            let (_, roll) = try await run("roll call next line present next line present next line absent",
                                          level: level)
            XCTAssertEqual(roll?.text, "Roll call\nPresent\nPresent\nAbsent.", "\(level)")
        }
        // A repair inside an item still goes; a retraction never takes a
        // marker with it.
        let (_, item) = try await run("todo bullet point book book the vet bullet point buy milk")
        XCTAssertEqual(item?.text, "Todo:\n- Book the vet\n- Buy milk")
        let retracted = "Buy milk. Scratch that, new line buy eggs and bread."
        let (input, _) = try await run(retracted)
        XCTAssertEqual(input, retracted, "both kept: the rules never delete a marker")
    }

    func testRepetitionsStayWhenStutterCollapseIsOff() {
        // `collapse_stutters = false`: the stripper keeps "I I", and the
        // rules keep their repeats too; the other rules still run.
        let keeping = FillerStripper(collapseStutters: false)
        let raw = "I I think we went over over the lo logs"
        XCTAssertEqual(DictationPipeline.prePass(raw, dictionary: noDict, stripper: keeping, level: .standard,
                                                 verbatimRegister: false, language: .english),
                       "I I think we went over over the logs")
        XCTAssertEqual(DictationPipeline.prePass(raw, dictionary: noDict, stripper: stripper, level: .standard,
                                                 verbatimRegister: false, language: .english),
                       "I think we went over the logs")
    }

    func testTheDefaultLevelKeepsALoneShortWord() {
        // R3a's non-words are Standard's: at Fillers a lower-case abbreviation
        // is never taken for a stray letter.
        func prePass(_ text: String, _ level: AppConfig.Cleanup.Level) -> String {
            DictationPipeline.prePass(text, dictionary: noDict, stripper: stripper, level: level,
                                      verbatimRegister: false, language: .english)
        }
        XCTAssertEqual(prePass("the pr is ready for review", .fillers), "the pr is ready for review")
        XCTAssertEqual(prePass("ask my pt about the knee", .fillers), "ask my pt about the knee")
        XCTAssertEqual(prePass("the desk and the b chair are new", .standard), "the desk and the chair are new")
    }

    func testDoublesThatAreContentReachTheFormatter() async throws {
        // Another language's doubles, a sign-off, a phrasal verb's particle
        // before the same preposition, English grammar: kept at both levels
        // that run the rules, and the filler strip leaves them too.
        for level in [AppConfig.Cleanup.Level.fillers, .standard] {
            for raw in ["Ti mando tanti tanti baci, see you soon.", "Baci baci", "Forza forza!",
                        "Quasi quasi I'll stay another week.", "Book the lomi lomi massage for Sunday.",
                        "Can you swing by by noon tomorrow?", "Cool cool, see you then.",
                        "By then she had had enough of the noise."] {
                let (input, _) = try await run(raw, level: level)
                XCTAssertEqual(input, raw, "\(level)")
            }
            // The same shapes as a stutter still go.
            let (stutter, _) = try await run("We went over over these numbers yesterday.", level: level)
            XCTAssertEqual(stutter, "We went over these numbers yesterday.", "\(level)")
            let (wiki, _) = try await run("Check the wiki wiki page for the address.", level: level)
            XCTAssertEqual(wiki, "Check the wiki page for the address.", "\(level)")
        }
    }

    func testRoundZeroFindingsThroughThePipeline() async throws {
        // [T20] A short Italian or English word between words is a word, not a
        // cut-off one, at Standard too — the strip leaves it as well.
        for raw in ["Running late, ti chiamo after lunch.", "Ciao, ti scrivo after the meeting, see you at Christmas.",
                    "Running late, fa freddo here so grab a jacket.", "I learned kung fu as a kid."] {
            let (input, _) = try await run(raw, level: .standard)
            XCTAssertEqual(input, raw)
        }
        // [T21] A bare noun phrase after a mid-sentence "scratch that" takes
        // its slot, not the clause; no slot that fits keeps both.
        let (slot, _) = try await run("Book a window seat, scratch that, an aisle seat.")
        XCTAssertEqual(slot, "Book an aisle seat.")
        let (leads, _) = try await run("Invite every engineer, scratch that, only leads.")
        XCTAssertEqual(leads, "Invite only leads.")
        let (both, _) = try await run("Sam fixed it, scratch that, Priya.")
        XCTAssertEqual(both, "Sam fixed it, scratch that, Priya.")
        let (clause, _) = try await run("I'll take the train, scratch that, I'll drive.")
        XCTAssertEqual(clause, "I'll drive.")
        // [T19] [T22] A double right after a wh-word is a stutter, at both
        // levels; with a subject between, grammar.
        for level in [AppConfig.Cleanup.Level.fillers, .standard] {
            let (stutter, _) = try await run("What are are you doing tonight?", level: level)
            XCTAssertEqual(stutter, "What are you doing tonight?", "\(level)")
            let (name, _) = try await run("What is is your name?", level: level)
            XCTAssertEqual(name, "What is your name?", "\(level)")
            for raw in ["What the options are are listed below.", "What it is is a timing bug."] {
                let (input, _) = try await run(raw, level: level)
                XCTAssertEqual(input, raw, "\(level)")
            }
        }
    }

    func testDescribingARepairKeepsIt() async throws {
        let raw = "add a fixture where the input is ship it Thursday, no wait, Friday and nothing else"
        let (input, _) = try await run(raw)
        XCTAssertEqual(input, raw)
        let (made, _) = try await run("ship it Thursday, no wait, Friday and nothing else")
        XCTAssertEqual(made, "ship it Friday and nothing else")
    }

    // MARK: - The text half (Command Mode with nothing selected)

    func testFinishIsTheDictationTextPath() async throws {
        // Command Mode with nothing selected hands its words to `finish`: the
        // same self-repair, strip, layout and finishing as a dictation.
        let raw = "um so the the build build ships Thursday, no wait, Friday new line thanks"
        var prepared = 0
        let (text, seconds) = await DictationPipeline.finish(
            raw, dictionary: noDict, stripper: stripper, level: .standard,
            prepareFormatter: { prepared += 1 }, format: { TextFormatter.ruleBasedCleanup($0) })
        XCTAssertEqual(text, "So the build ships Friday\nThanks.")
        XCTAssertEqual(prepared, 1)
        XCTAssertGreaterThanOrEqual(seconds, 0)
        let (_, outcome) = try await run(raw, format: { TextFormatter.ruleBasedCleanup($0) })
        XCTAssertEqual(outcome?.text, text, "byte-identical to a dictation of the same words")
        // Verbatim: untouched, and neither the preparation nor the formatter runs.
        var formatted = false
        let (verbatim, none) = await DictationPipeline.finish(
            raw, dictionary: noDict, stripper: stripper, level: .verbatim,
            prepareFormatter: { prepared += 1 }, format: { formatted = true; return $0 })
        XCTAssertEqual(verbatim, raw)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(prepared, 1)
        XCTAssertFalse(formatted)
    }

    func testQuotationsSurvive() async throws {
        for raw in ["he typed \"the the dog dog\" twice", "call it 'fix fix' for now"] {
            let (input, _) = try await run(raw)
            XCTAssertEqual(input, raw)
        }
    }

    func testRulesOnlyIsTheDeterministicPathEndToEnd() async throws {
        // Rules only — no AI rewrite: the formatter is the rule-based cleanup.
        let (_, outcome) = try await run("um so the the build build ships Thursday, no wait, Friday",
                                         format: { TextFormatter.ruleBasedCleanup($0) })
        XCTAssertEqual(outcome?.text, "So the build ships Friday.")
    }

    func testALineBreakFromTheDictionarySurvivesARepair() async throws {
        // A dictionary target may carry a line break; the repair keeps it.
        let dict = DictionaryEngine(rules: [.init(from: "sign off", to: "Best,\nSam")])
        let (input, _) = try await run("thanks for the dog dog park sign off", dictionary: dict)
        XCTAssertEqual(input, "thanks for the dog park Best,\nSam")
    }

    func testPrePassGating() {
        let raw = "the dog dog park opens Thursday, no wait, Friday, um, okay"
        func prePass(_ level: AppConfig.Cleanup.Level, verbatimRegister: Bool = false,
                     language: DictationLanguage = .english) -> String {
            DictationPipeline.prePass(raw, dictionary: noDict, stripper: stripper, level: level,
                                      verbatimRegister: verbatimRegister, language: language)
        }
        XCTAssertEqual(prePass(.verbatim), raw)
        XCTAssertEqual(prePass(.standard, verbatimRegister: true), raw)
        XCTAssertEqual(prePass(.fillers), "the dog park opens Thursday, no wait, Friday, okay")
        XCTAssertEqual(prePass(.standard), "the dog park opens Friday, okay")
        XCTAssertEqual(prePass(.standard, language: .spanish), stripper.strip(raw))
    }

    // MARK: - Formatter stage

    func testFormatterFailureFallsBackToCleanedText() async throws {
        // The format closure must not throw — on engine failure the platform
        // degrades to the rule-based result (TextFormatter.format's contract),
        // and the pipeline lands that fallback, computed from the STRIPPED text.
        let pipeline = DictationPipeline(asr: StubAsr(text: "um so the build is green"))
        let outcome = try await pipeline.run(
            [0.1], dictionary: noDict, stripper: stripper, level: .fillers,
            format: { TextFormatter.ruleBasedCleanup($0) })   // the engine-failed path
        XCTAssertEqual(outcome?.text, "So the build is green.")
        XCTAssertEqual(outcome?.verbatimText, "um so the build is green")
    }

    func testEmptyTranscriptReturnsNil() async throws {
        let pipeline = DictationPipeline(asr: StubAsr(text: "   "))
        let outcome = try await pipeline.run(
            [0.1], dictionary: noDict, stripper: stripper, level: .fillers,
            format: { input in XCTFail("formatter must not run"); return input })
        XCTAssertNil(outcome)
    }

    // MARK: - Trim + timings

    func testTrimUnderAsrFloorFallsBackToUntrimmed() async throws {
        // Over-aggressive trim (below the engine's sample floor) must not eat
        // the utterance — the untrimmed samples are transcribed instead.
        let asr = StubAsr(text: "hi", minimumSamples: 4)
        let samples: [Float] = [1, 2, 3, 4, 5]
        let outcome = try await DictationPipeline(asr: asr).run(
            samples, trim: { _ in [1, 2] },
            dictionary: noDict, stripper: stripper, level: .fillers,
            format: { $0 })
        let transcribed = await asr.transcribed
        XCTAssertEqual(transcribed.count, 5)
        XCTAssertEqual(outcome?.transcribedSampleCount, 5)

        // A trim above the floor IS used (and reported for duration stats).
        let asr2 = StubAsr(text: "hi", minimumSamples: 4)
        let outcome2 = try await DictationPipeline(asr: asr2).run(
            samples, trim: { Array($0.prefix(4)) },
            dictionary: noDict, stripper: stripper, level: .fillers,
            format: { $0 })
        let transcribed2 = await asr2.transcribed
        XCTAssertEqual(transcribed2.count, 4)
        XCTAssertEqual(outcome2?.transcribedSampleCount, 4)
    }

    func testTimingsPopulated() async throws {
        // The caller's already-measured stage survives; the pipeline fills in
        // asr + format; insert stays 0 (it happens downstream).
        var timings = StageTimings()
        timings.audioFinalizeSeconds = 0.25
        let pipeline = DictationPipeline(asr: StubAsr(text: "hello world"))
        let outcome = try await pipeline.run(
            [0.1], dictionary: noDict, stripper: stripper, level: .fillers,
            timings: timings,
            format: { input in
                try? await Task.sleep(for: .milliseconds(2))
                return input
            })
        let out = try XCTUnwrap(outcome)
        XCTAssertEqual(out.timings.audioFinalizeSeconds, 0.25)
        XCTAssertGreaterThan(out.timings.asrSeconds, 0)
        XCTAssertGreaterThan(out.timings.formatSeconds, 0)
        XCTAssertEqual(out.timings.insertSeconds, 0)
        XCTAssertEqual(
            out.timings.totalSeconds,
            0.25 + out.timings.asrSeconds + out.timings.formatSeconds,
            accuracy: 1e-9)
    }
}
