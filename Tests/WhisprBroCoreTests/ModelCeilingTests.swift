import XCTest
@testable import WhisprBroCore

/// The model's 150-word ceiling counts a dictation as it was before the
/// self-repair rules (`DictationPipeline.FormatterInput.ceilingWords`): the
/// rules only delete, so counting what they left would let them bring a long
/// dictation under the ceiling and onto the model, which skipped it before.
/// Counted this way the decision is the one made before the rules: fillers
/// and layout words still do not count, deletions by the rules never help.
final class ModelCeilingTests: XCTestCase {
    private let limit = TextFormatter.Config().llmWordLimit
    private let noDict = DictionaryEngine(rules: [])

    /// `count` invented words no rule touches: word1 word2 …
    private func plain(_ count: Int) -> String {
        (1...count).map { "word\($0)" }.joined(separator: " ") + "."
    }

    /// Four invented sentences, each with one content word said twice — a
    /// repeat the rules take at every level that strips ("hose hose"), and
    /// the filler strip does not (it collapses function words only).
    private let doubled = [
        "the garden hose hose is leaking near the shed.",
        "we painted the fence fence on a bright morning.",
        "please water the tomato tomato plants before noon.",
        "the orange kite kite drifted over the quiet harbor.",
    ]

    private func words(_ text: String) -> Int { DictationPipeline.wordCount(text) }

    /// What `finish` hands the formatter.
    private func formatterInput(
        _ text: String, level: AppConfig.Cleanup.Level = .fillers, selfRepair: Bool = true,
        register: AppCategory = .unknown, verbatimRegister: Bool = false
    ) async throws -> DictationPipeline.FormatterInput {
        var seen: DictationPipeline.FormatterInput?
        _ = await DictationPipeline.finish(
            text, dictionary: noDict, stripper: FillerStripper(), level: level,
            verbatimRegister: verbatimRegister, register: register, selfRepair: selfRepair,
            formatInput: { seen = $0; return $0.text })
        return try XCTUnwrap(seen, "the formatter stage ran")
    }

    /// A formatter with no model loaded: `.unavailable` is the model path
    /// (the ceiling let it through), `.tooLong` the ceiling's skip.
    private func route(_ input: DictationPipeline.FormatterInput, passingTheCount: Bool = true) async -> FormatterSource {
        let formatter = TextFormatter(engine: LlamaCppEngine(
            modelPath: URL(fileURLWithPath: "/nonexistent.gguf"),
            promptBuilder: PromptBuilder(family: .qwen, systemPrompt: "")))
        return await formatter.formatDetailed(input.text, rawMode: false,
                                              ceilingWords: passingTheCount ? input.ceilingWords : nil).source
    }

    // MARK: - The formatters

    func testTheFormatterAppliesTheCeilingToTheCountItIsGiven() async {
        let formatter = TextFormatter(engine: LlamaCppEngine(
            modelPath: URL(fileURLWithPath: "/nonexistent.gguf"),
            promptBuilder: PromptBuilder(family: .qwen, systemPrompt: "")))
        let hundred = (1...100).map { "word\($0)" }.joined(separator: " ")
        let over = await formatter.formatDetailed(hundred, rawMode: false, ceilingWords: limit + 1)
        XCTAssertEqual(over.source, .fallback(.tooLong))
        XCTAssertEqual(words(over.text), 100, "the rules path keeps every word")
        let at = await formatter.formatDetailed(hundred, rawMode: false, ceilingWords: limit)
        XCTAssertEqual(at.source, .fallback(.unavailable), "at the ceiling the model path is taken")
        let unset = await formatter.formatDetailed(hundred, rawMode: false)
        XCTAssertEqual(unset.source, .fallback(.unavailable), "no count given: the text's own")
        // The larger count decides: a smaller one never lets a long text through.
        let long = (1...(limit + 20)).map { "word\($0)" }.joined(separator: " ")
        let small = await formatter.formatDetailed(long, rawMode: false, ceilingWords: 10)
        XCTAssertEqual(small.source, .fallback(.tooLong))
    }

    func testTheSystemModelStageCountsTheSame() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        let hundred = (1...100).map { "word\($0)" }.joined(separator: " ")
        let result = await FoundationModelsFormatter(language: .english)
            .formatDetailed(hundred, ceilingWords: limit + 1)
        XCTAssertEqual(result.source, .fallback(.tooLong), "skipped before the model is even asked")
        #else
        throw XCTSkip("FoundationModels not in this SDK")
        #endif
    }

    // MARK: - The pipeline

    func testTheRulesNeverBringALongDictationOntoTheModel() async throws {
        // 152 words; the rules take 4 repeats, leaving 148.
        let text = plain(limit - 33) + " " + doubled.joined(separator: " ")
        XCTAssertEqual(words(text), limit + 2)
        let input = try await formatterInput(text)
        XCTAssertEqual(words(input.text), limit - 2, "the rules ran")
        XCTAssertEqual(input.ceilingWords, limit + 2, "counted as it was before them")
        let skipped = await route(input)
        XCTAssertEqual(skipped, .fallback(.tooLong))
        // What happened before this fix: the rules' 148 words reached the model.
        let reached = await route(input, passingTheCount: false)
        XCTAssertEqual(reached, .fallback(.unavailable))
    }

    func testACorrectionTakenAtStandardIsCountedToo() async throws {
        // 153 words; at Standard the cued correction goes ("Thursday, no
        // wait,"), leaving exactly 150 — the model would have run.
        let text = plain(limit - 3) + " ship it Thursday, no wait, Friday."
        XCTAssertEqual(words(text), limit + 3)
        let input = try await formatterInput(text, level: .standard)
        XCTAssertEqual(words(input.text), limit)
        XCTAssertEqual(input.ceilingWords, limit + 3)
        let routed = await route(input)
        XCTAssertEqual(routed, .fallback(.tooLong))
    }

    func testWhatTheFormatterNeverSawStillDoesNotCount() async throws {
        // Fillers: stripped before the count, as before the rules — a 152-word
        // dictation with 6 "um"s is 146 words to the formatter, and it runs.
        var tokens = plain(limit - 4).split(separator: " ").map(String.init)
        for i in stride(from: 140, through: 15, by: -25) { tokens.insert("um,", at: i) }
        let fillers = tokens.joined(separator: " ")
        XCTAssertEqual(words(fillers), limit + 2)
        let stripped = try await formatterInput(fillers)
        XCTAssertEqual(stripped.ceilingWords, limit - 4)
        let ran = await route(stripped)
        XCTAssertEqual(ran, .fallback(.unavailable))

        // Spoken layout: "new line" is lifted out before the formatter, and
        // not counted. 150 words of content, 2 of them repeats the rules
        // take, plus one marker: 152 said, 148 formatted, 150 counted.
        let layout = plain(limit - 18) + " " + doubled[0] + " new line " + doubled[1]
        XCTAssertEqual(words(layout), limit + 2)
        let lifted = try await formatterInput(layout)
        XCTAssertEqual(words(lifted.text), limit - 2)
        XCTAssertEqual(lifted.ceilingWords, limit)
        let reached = await route(lifted)
        XCTAssertEqual(reached, .fallback(.unavailable), "at the ceiling, as before the rules")
    }

    func testWithoutTheRulesTheCountIsTheTextsOwn() async throws {
        let text = plain(limit - 33) + " " + doubled.joined(separator: " ")
        for (selfRepair, register, verbatimRegister) in [(false, AppCategory.unknown, false),
                                                         (true, .ide, true), (true, .notes, true)] {
            let input = try await formatterInput(text, selfRepair: selfRepair, register: register,
                                                           verbatimRegister: verbatimRegister)
            XCTAssertEqual(input.ceilingWords, words(input.text), "\(selfRepair) \(register)")
            XCTAssertEqual(input.ceilingWords, limit + 2)
        }
        // And a short dictation the rules changed: its own count, rules or not.
        let short = try await formatterInput(doubled[0])
        XCTAssertEqual(short.ceilingWords, 9)
        XCTAssertEqual(words(short.text), 8)
    }

    func testRunHandsTheCountThrough() async throws {
        final class FixedAsr: AsrEngine, @unchecked Sendable {
            let text: String
            init(_ text: String) { self.text = text }
            let minimumSamples = 0
            var isLoaded: Bool { get async { true } }
            func load() async throws {}
            func transcribe(_ samples: [Float]) async throws -> AsrResult { AsrResult(text: text) }
        }
        let text = plain(limit - 33) + " " + doubled.joined(separator: " ")
        var seen: DictationPipeline.FormatterInput?
        _ = try await DictationPipeline(asr: FixedAsr(text)).run(
            [0.1], dictionary: noDict, stripper: FillerStripper(), level: .fillers,
            formatInput: { seen = $0; return $0.text })
        XCTAssertEqual(seen?.ceilingWords, limit + 2)
        XCTAssertEqual(seen.map { words($0.text) }, limit - 2)
    }

    // MARK: - The bench commands

    func testTheBenchCountsAsTheAppDoes() async throws {
        // `whispr-bench format` runs the stages itself (it swaps the layout
        // policy, or drops the layer) and asks `ceilingWords(for:verbatimText:…)`;
        // `cleanup` runs `finish`. Both must count what the app's `finish`
        // counts, or a long dictation the rules shorten reaches their model.
        var fillers = plain(limit - 4).split(separator: " ").map(String.init)
        for i in stride(from: 140, through: 15, by: -25) { fillers.insert("um,", at: i) }
        let texts = [
            plain(limit - 33) + " " + doubled.joined(separator: " "),             // 152 → 148 by the rules
            plain(limit - 3) + " ship it Thursday, no wait, Friday.",             // 153 → 150 at Standard
            plain(limit - 18) + " " + doubled[0] + " new line " + doubled[1],     // layout lifted out
            fillers.joined(separator: " "),                                       // fillers never count
            doubled[0],                                                           // short: its own count
            "um, uh.",                                                            // nothing left: verbatim lands
        ]
        let stripper = FillerStripper()
        for text in texts {
            for level in [AppConfig.Cleanup.Level.fillers, .standard] {
                for register in [AppCategory.unknown, .notes, .messaging] {
                    let app = try await formatterInput(text, level: level, register: register)
                    let stripped = DictationPipeline.prePass(
                        text, dictionary: noDict, stripper: stripper, level: level,
                        verbatimRegister: false, language: .english)
                    let policy = SpokenStructure.policy(for: register)
                    let lifted = SpokenStructure.extract(
                        from: DictationPipeline.landing(stripped, verbatimText: text), policy: policy).text
                    XCTAssertEqual(lifted, app.text, "\(level) \(register): the same formatter input")
                    let counted = DictationPipeline.ceilingWords(
                        for: lifted, verbatimText: text, dictionary: noDict, stripper: stripper, policy: policy)
                    XCTAssertEqual(counted, app.ceilingWords, "\(level) \(register) \(words(text)) words")
                }
            }
        }
        // The 152-word dictation through the bench's own stages: counted 152,
        // so the model is skipped, as in the app — with the layer, with the
        // `inferring` policy, and without the layer (`format --no-structure`).
        let long = texts[0]
        let stripped = DictationPipeline.prePass(long, dictionary: noDict, stripper: stripper, level: .standard,
                                                 verbatimRegister: false, language: .english)
        XCTAssertEqual(words(stripped), limit - 2, "the rules ran")
        for policy in [SpokenStructure.policy(for: .unknown), .inferring, nil] {
            let text = policy.map { SpokenStructure.extract(from: stripped, policy: $0).text } ?? stripped
            let counted = DictationPipeline.ceilingWords(
                for: text, verbatimText: long, dictionary: noDict, stripper: stripper, policy: policy)
            XCTAssertEqual(counted, limit + 2)
            let routed = await route(DictationPipeline.FormatterInput(text: text, ceilingWords: counted))
            XCTAssertEqual(routed, .fallback(.tooLong))
        }
    }

    // MARK: - The bench's provenance

    func testHistoryProvenanceUsesTheSameCount() throws {
        // A long history row the rules bring under the ceiling: the strip
        // alone and the rules now agree it skipped the model.
        let text = plain(limit - 33) + " " + doubled.joined(separator: " ")
        let fixture = try XCTUnwrap(EvalCase.seeds.first)
        let item = try XCTUnwrap(EvalPlan(cases: [fixture], levelOverride: .fillers).items.first)
        let repaired = DictationPipeline.prePass(text, dictionary: noDict, stripper: FillerStripper(),
                                                 level: .fillers, verbatimRegister: false, language: .english)
        XCTAssertEqual(words(repaired), limit - 2)
        XCTAssertEqual(EvalPlan.shippedSource(candidates: [text, repaired], item: item), .fallback(.tooLong))
        XCTAssertEqual(EvalPlan.shippedSource(stripped: repaired, item: item), .model, "its own count alone")
        XCTAssertEqual(EvalPlan.shippedSource(stripped: repaired, item: item, ceilingWords: limit + 2),
                       .fallback(.tooLong))
    }
}
