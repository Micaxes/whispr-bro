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
        XCTAssertEqual(outcome?.text, "ship whispr-bro today")
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
