import XCTest
@testable import WhisprBroCore

/// Schema v2 pins (plan §3.1): a v1 file decodes unchanged, unknown keys are
/// ignored, every derived default is hand-counted, and the fixture-set hash
/// is pinned byte-for-byte — a drift in the canonical encoding would silently
/// break leaderboard comparability, so the shape is asserted, not just
/// "hashes twice the same".
final class EvalCaseTests: XCTestCase {
    private func decode(_ json: String) throws -> [EvalCase] {
        try JSONDecoder().decode([EvalCase].self, from: Data(json.utf8))
    }

    private func one(_ json: String) throws -> EvalCase {
        try XCTUnwrap(decode("[\(json)]").first)
    }

    private func canonical(_ cases: [EvalCase]) throws -> String {
        String(decoding: try EvalCase.canonicalJSON(cases), as: UTF8.self)
    }

    /// The §3.1 example, shape for shape.
    private let planExample = #"""
    {
      "id": "agent-hedge-03",
      "raw": "I don't know, um, try some broad benchmarking on the the gravlin tabs and a and sixty two other things.",
      "gold": "I don't know, try some broad benchmarking on the gravlin tabs and 62 other things.",
      "golds": ["I don't know, try some broad benchmarking on the gravlin tabs and sixty-two other things."],
      "note": "hedge must survive; non-identical stutter; spelled number",
      "audio": null,

      "tags": ["agent-prompt", "hedge", "stutter", "numbers"],
      "register": "unknown",
      "level": "standard",
      "language": "en",
      "control": false,

      "fillers": null,
      "stutters": [{"span": "and a and", "keep": "and"}],
      "repairs": [{"reparandum": "on Tuesday, I mean", "repair": "on Wednesday", "resolve_at": "standard"}],
      "must_keep": [{"span": "I don't know,", "weight": 2}, {"span": "sixty two other things", "weight": 5}],
      "alternates": [{"from": "walk up", "to": ["walk-up"]}],

      "max_ms": 700,
      "source": "synthetic",
      "gold_source": "seed",
      "annotations_status": "confirmed",

      "observed": null,
      "observed_ms": null
    }
    """#

    // MARK: - v1 compatibility and unknown keys

    func testV1JSONDecodesUnchangedWithDerivedDefaults() throws {
        let c = try one(#"{"id": "mine-1", "raw": "hey um can you", "gold": "Hey, can you?"}"#)
        XCTAssertEqual(c.id, "mine-1")
        XCTAssertEqual(c.raw, "hey um can you")
        XCTAssertEqual(c.gold, "Hey, can you?")
        XCTAssertNil(c.note)
        XCTAssertNil(c.audio)
        XCTAssertEqual(c.golds, [])
        XCTAssertEqual(c.tags, [])
        XCTAssertEqual(c.register, .unknown)
        XCTAssertEqual(c.level, .standard)
        XCTAssertEqual(c.language, .english)
        XCTAssertNil(c.control)
        XCTAssertNil(c.fillers)
        XCTAssertNil(c.stutters)
        XCTAssertEqual(c.repairs, [])
        XCTAssertEqual(c.mustKeep, [])
        XCTAssertEqual(c.alternates, [])
        XCTAssertNil(c.maxMs)
        XCTAssertEqual(c.source, "synthetic")
        XCTAssertEqual(c.goldSource, "seed")
        XCTAssertEqual(c.annotationsStatus, .confirmed)
        XCTAssertNil(c.observed)
        XCTAssertNil(c.observedMs)
        // The Swift v1 initializer and the v1 JSON are the same fixture.
        XCTAssertEqual(c, EvalCase(id: "mine-1", raw: "hey um can you", gold: "Hey, can you?"))
        // …and the derived view: not a control, "um" expected gone, short budget.
        XCTAssertFalse(c.isControl)
        XCTAssertEqual(c.expectedFillers, [EvalCase.Filler(span: "um")])
        XCTAssertEqual(c.expectedStutters, [])
        XCTAssertEqual(c.latencyBudgetMs, 300)
        XCTAssertFalse(c.isGoldFree)
        XCTAssertFalse(c.isDraft)
        XCTAssertEqual(c.acceptableGolds, ["Hey, can you?"])
    }

    func testV1NoteAndAudioStillDecode() throws {
        let c = try one(#"{"id": "x", "raw": "a", "gold": "A.", "note": "n", "audio": "x.wav"}"#)
        XCTAssertEqual(c.note, "n")
        XCTAssertEqual(c.audio, "x.wav")
    }

    func testUnknownKeysAreIgnored() throws {
        // The deliberately-absent fields (§3.1) and arbitrary junk decode
        // silently — a future key never breaks an older binary.
        let c = try one(#"""
        {"id": "x", "raw": "do the math", "gold": "Do the math.",
         "entities": ["math"], "numbers": [], "no_new_content": true, "must_not_answer": true,
         "terminal": ".", "nested": {"k": [1, 2, {"deep": null}]}, "version": 3}
        """#)
        XCTAssertEqual(c.id, "x")
        XCTAssertTrue(c.isControl)
    }

    func testExplicitNullReadsAsDerive() throws {
        let c = try one(#"{"id": "x", "raw": "um hi", "gold": "Hi.", "control": null, "fillers": null, "stutters": null, "max_ms": null}"#)
        XCTAssertNil(c.control)
        XCTAssertNil(c.fillers)
        XCTAssertNil(c.stutters)
        XCTAssertNil(c.maxMs)
        XCTAssertEqual(c.expectedFillers, [EvalCase.Filler(span: "um")])
    }

    // MARK: - The plan's example, field by field

    func testPlanExampleDecodes() throws {
        let c = try one(planExample)
        XCTAssertEqual(c.id, "agent-hedge-03")
        XCTAssertEqual(c.golds, ["I don't know, try some broad benchmarking on the gravlin tabs and sixty-two other things."])
        XCTAssertEqual(c.acceptableGolds.count, 2)
        XCTAssertEqual(c.note, "hedge must survive; non-identical stutter; spelled number")
        XCTAssertNil(c.audio)
        XCTAssertEqual(c.tags, ["agent-prompt", "hedge", "stutter", "numbers"])
        XCTAssertEqual(c.register, .unknown)
        XCTAssertEqual(c.level, .standard)
        XCTAssertEqual(c.language, .english)
        XCTAssertEqual(c.control, false)
        XCTAssertFalse(c.isControl)
        XCTAssertNil(c.fillers)
        XCTAssertEqual(c.stutters, [EvalCase.Stutter(span: "and a and", keep: "and")])
        XCTAssertEqual(c.repairs, [EvalCase.Repair(reparandum: "on Tuesday, I mean", repair: "on Wednesday", resolveAt: .standard)])
        XCTAssertEqual(c.mustKeep, [EvalCase.MustKeep(span: "I don't know,", weight: 2),
                                    EvalCase.MustKeep(span: "sixty two other things", weight: 5)])
        XCTAssertEqual(c.alternates, [EvalCase.Alternate(from: "walk up", to: ["walk-up"])])
        XCTAssertEqual(c.maxMs, 700)
        XCTAssertEqual(c.latencyBudgetMs, 700)
        XCTAssertEqual(c.source, "synthetic")
        XCTAssertEqual(c.goldSource, "seed")
        XCTAssertEqual(c.annotationsStatus, .confirmed)
        XCTAssertNil(c.observed)
        XCTAssertNil(c.observedMs)
        // "fillers": null → derived: the one "um" the gold drops.
        XCTAssertEqual(c.expectedFillers, [EvalCase.Filler(span: "um", occurrence: 1)])
        // An explicit stutter list OVERRIDES derivation — "the the" is not
        // added behind the author's back.
        XCTAssertEqual(c.expectedStutters, [EvalCase.Stutter(span: "and a and", keep: "and")])
        XCTAssertEqual(c.wordCount, 20)   // "sixty two" is two spoken words
    }

    func testMustKeepDecodesStringsAndObjects() throws {
        // A bare string is weight 2 (hedge); an object without weight too;
        // a mixed array decodes element-wise.
        let c = try one(#"""
        {"id": "x", "raw": "r", "gold": "g",
         "must_keep": ["I don't know,", {"span": "fifty four", "weight": 5}, {"span": "yeah"}]}
        """#)
        XCTAssertEqual(c.mustKeep, [EvalCase.MustKeep(span: "I don't know,", weight: 2),
                                    EvalCase.MustKeep(span: "fifty four", weight: 5),
                                    EvalCase.MustKeep(span: "yeah", weight: 2)])
        XCTAssertEqual(EvalCase.MustKeep.hedgeWeight, 2)
        XCTAssertEqual(EvalCase.MustKeep.factWeight, 5)
        XCTAssertEqual(EvalCase.MustKeep(span: "s").weight, 2)
        // Both spellings encode as the object, so they are the same fixture.
        let asString = try one(#"{"id": "x", "raw": "r", "gold": "g", "must_keep": ["hedge"]}"#)
        let asObject = try one(#"{"id": "x", "raw": "r", "gold": "g", "must_keep": [{"span": "hedge", "weight": 2}]}"#)
        XCTAssertEqual(asString, asObject)
        XCTAssertEqual(try EvalCase.fixtureSetHash([asString]), try EvalCase.fixtureSetHash([asObject]))
    }

    func testStutterAndFillerDefaults() throws {
        let c = try one(#"""
        {"id": "x", "raw": "r", "gold": "g",
         "stutters": [{"span": "then then then"}, {"span": "my l phone", "keep": "my phone", "occurrence": 2}],
         "fillers": [{"span": "uh"}, {"span": "uh", "occurrence": 3}]}
        """#)
        // `keep` defaults to the run's first word (the identical-run contract).
        XCTAssertEqual(c.stutters, [EvalCase.Stutter(span: "then then then", keep: "then", occurrence: 1),
                                    EvalCase.Stutter(span: "my l phone", keep: "my phone", occurrence: 2)])
        XCTAssertEqual(EvalCase.Stutter(span: "the the").keep, "the")
        XCTAssertEqual(c.fillers, [EvalCase.Filler(span: "uh", occurrence: 1), EvalCase.Filler(span: "uh", occurrence: 3)])
        XCTAssertEqual(c.expectedFillers, c.fillers)   // explicit list wins
        XCTAssertEqual(c.expectedStutters, c.stutters)
    }

    func testRepairResolveAtDefaultsToStandard() throws {
        let c = try one(#"""
        {"id": "x", "raw": "r", "gold": "g",
         "repairs": [{"reparandum": "at 2 actually", "repair": "at 3"},
                     {"reparandum": "monday no wait", "repair": "tuesday", "resolve_at": "fillers"}]}
        """#)
        XCTAssertEqual(c.repairs.map(\.resolveAt), [.standard, .fillers])
    }

    func testDraftGoldsDecode() throws {
        // Dispatcher decision D1: an agent-drafted gold is a scorable fixture
        // with its provenance and status kept as written.
        let c = try one(#"{"id": "h58", "raw": "r", "gold": "g", "gold_source": "draft:claude", "annotations_status": "draft", "source": "history:58", "observed": "G", "observed_ms": 412}"#)
        XCTAssertEqual(c.goldSource, "draft:claude")
        XCTAssertTrue(c.isDraft)
        XCTAssertEqual(c.source, "history:58")
        XCTAssertEqual(c.observed, "G")
        XCTAssertEqual(c.observedMs, 412)
    }

    // MARK: - Enum values are validated loudly

    func testRegisterLevelLanguageStatusDecode() throws {
        let c = try one(#"{"id": "x", "raw": "r", "gold": "g", "register": "notes", "level": "fillers", "language": "it", "annotations_status": "draft"}"#)
        XCTAssertEqual(c.register, .notes)
        XCTAssertEqual(c.level, .fillers)
        XCTAssertEqual(c.language, .italian)
        XCTAssertEqual(c.annotationsStatus, .draft)
        // The enum's own raw value is accepted for language as well as the ISO code.
        XCTAssertEqual(try one(#"{"id": "x", "raw": "r", "gold": "g", "language": "spanish"}"#).language, .spanish)
        XCTAssertEqual(try one(#"{"id": "x", "raw": "r", "gold": "g", "language": "es"}"#).language, .spanish)
    }

    func testUnknownEnumValuesThrow() {
        // A typo must not silently run a fixture under `.unknown` / English.
        let bad = [
            #"{"id": "x", "raw": "r", "gold": "g", "register": "browsr"}"#,
            #"{"id": "x", "raw": "r", "gold": "g", "level": "verbatim"}"#,   // a register property, not a level
            #"{"id": "x", "raw": "r", "gold": "g", "level": "loose"}"#,
            #"{"id": "x", "raw": "r", "gold": "g", "language": "fr"}"#,
            #"{"id": "x", "raw": "r", "gold": "g", "annotations_status": "maybe"}"#,
            #"{"id": "x", "raw": "r", "gold": "g", "repairs": [{"reparandum": "a", "repair": "b", "resolve_at": "verbatim"}]}"#,
        ]
        for json in bad {
            XCTAssertThrowsError(try decode("[\(json)]"), json)
        }
    }

    func testMissingRequiredKeysThrow() {
        XCTAssertThrowsError(try decode(#"[{"raw": "r", "gold": "g"}]"#))
        XCTAssertThrowsError(try decode(#"[{"id": "x", "gold": "g"}]"#))
        XCTAssertThrowsError(try decode(#"[{"id": "x", "raw": "r"}]"#))
    }

    // MARK: - Derivation: control

    func testControlDerivesFromWordsModuloMarksAndCase() {
        XCTAssertTrue(EvalCase(id: "c", raw: "okay we ship it", gold: "Okay, we ship it.").isControl)
        XCTAssertTrue(EvalCase(id: "c", raw: "it’s fine", gold: "It's fine.").isControl)   // curly apostrophe
        XCTAssertTrue(EvalCase(id: "c", raw: ", so anyway let's ship it", gold: "So anyway, let's ship it.").isControl)
        XCTAssertFalse(EvalCase(id: "c", raw: "the the whisper bro", gold: "The Whisper Bro.").isControl)
        // Number form is a WORD edit here (as on the continuity WER axis).
        XCTAssertFalse(EvalCase(id: "c", raw: "fifty four", gold: "54").isControl)
        XCTAssertFalse(EvalCase(id: "c", raw: "Uh", gold: "").isControl)
        XCTAssertFalse(EvalCase(id: "c", raw: "um so", gold: "So.").isControl)
    }

    func testExplicitControlWins() {
        // Explicit beats derived both ways — `lint`, not the decoder, flags
        // a `control: true` whose gold edits words.
        XCTAssertFalse(EvalCase(id: "c", raw: "okay we ship it", gold: "Okay, we ship it.", control: false).isControl)
        XCTAssertTrue(EvalCase(id: "c", raw: "um okay", gold: "Okay.", control: true).isControl)
    }

    // MARK: - Derivation: fillers

    func testFillersDeriveFromDeletedCoreFillers() {
        XCTAssertEqual(EvalCase(id: "f", raw: "um I also signed into Zephyrnet", gold: "I also signed into Zephyrnet.").expectedFillers,
                       [EvalCase.Filler(span: "um", occurrence: 1)])
        // A filler the gold KEEPS is not expected gone.
        XCTAssertEqual(EvalCase(id: "f", raw: "um so", gold: "Um, so.").expectedFillers, [])
        // All-filler raw with an empty gold: E = every token (§4.3).
        XCTAssertEqual(EvalCase(id: "f", raw: "Uh", gold: "").expectedFillers, [EvalCase.Filler(span: "Uh")])
        XCTAssertEqual(EvalCase(id: "f", raw: "um, uh.", gold: "").expectedFillers,
                       [EvalCase.Filler(span: "um"), EvalCase.Filler(span: "uh")])
        // A deleted word outside the lexicon is an over-edit, never a filler.
        XCTAssertEqual(EvalCase(id: "f", raw: "I don't know, try some benchmarking", gold: "Try some benchmarking.").expectedFillers, [])
    }

    func testFillerOccurrencesAreCountedPerWord() throws {
        // premise-fillers: Um(1) … uh(1) … uh(2) … uh(3) … Um(2); every
        // occurrence lands on the deleted token via Align.locate.
        let c = try XCTUnwrap(EvalCase.seeds.first { $0.id == "premise-fillers" })
        let fillers = c.expectedFillers
        XCTAssertEqual(fillers.map(\.span), ["Um", "uh", "uh", "uh", "Um"])
        XCTAssertEqual(fillers.map(\.occurrence), [1, 1, 2, 3, 2])
        let tokens = Align.canonicalTokens(c.raw)
        XCTAssertEqual(fillers.map { Align.locate($0.span, in: tokens, occurrence: $0.occurrence)?.lowerBound },
                       [0, 4, 9, 13, 17])
    }

    func testFillerLexiconFollowsTheLanguage() {
        XCTAssertEqual(EvalCase(id: "f", raw: "ehm vado a casa", gold: "Vado a casa.", language: .italian).expectedFillers,
                       [EvalCase.Filler(span: "ehm")])
        // Same text under English: "ehm" is deleted but not in that lexicon.
        XCTAssertEqual(EvalCase(id: "f", raw: "ehm vado a casa", gold: "Vado a casa.", language: .english).expectedFillers, [])
        XCTAssertEqual(EvalCase(id: "f", raw: "um vado", gold: "Vado.", language: .italian).expectedFillers, [])
    }

    func testEmptyFillersDisablesDerivation() throws {
        let c = try one(#"{"id": "x", "raw": "um hi", "gold": "Hi.", "fillers": []}"#)
        XCTAssertEqual(c.fillers, [])
        XCTAssertEqual(c.expectedFillers, [])
        XCTAssertEqual(EvalCase(id: "x", raw: "um hi", gold: "Hi.", fillers: []).expectedFillers, [])
    }

    // MARK: - Derivation: stutters

    func testStuttersDeriveFromCollapsibleRunsNotSurvivingInGold() {
        XCTAssertEqual(EvalCase(id: "s", raw: "the the whisper bro", gold: "The Whisper Bro.").expectedStutters,
                       [EvalCase.Stutter(span: "the the", keep: "the", occurrence: 1)])
        // Content words never derive — emphasis, even when the gold drops one.
        XCTAssertEqual(EvalCase(id: "s", raw: "very, very flat", gold: "Very, very flat.").expectedStutters, [])
        XCTAssertEqual(EvalCase(id: "s", raw: "very very flat", gold: "Very flat.").expectedStutters, [])
        // A run the gold keeps intact is not expected collapsed.
        XCTAssertEqual(EvalCase(id: "s", raw: "the the whisper bro", gold: "the the whisper bro").expectedStutters, [])
        // A scored mark breaks the run, exactly as the stripper's regex does
        // — "I, I think" needs an explicit annotation.
        XCTAssertEqual(EvalCase(id: "s", raw: "I, I think", gold: "I think.").expectedStutters, [])
        // Maximal: one run of three, not two overlapping pairs.
        XCTAssertEqual(EvalCase(id: "s", raw: "and and and fifty", gold: "and 50.").expectedStutters,
                       [EvalCase.Stutter(span: "and and and", keep: "and", occurrence: 1)])
        // Non-identical restarts are out of the stripper's contract → explicit only.
        XCTAssertEqual(EvalCase(id: "s", raw: "and a and sixty two", gold: "and 62").expectedStutters, [])
        // Casing of the first token is kept; Fi matches keep form-blind.
        XCTAssertEqual(EvalCase(id: "s", raw: "The the plan", gold: "The plan.").expectedStutters,
                       [EvalCase.Stutter(span: "The the", keep: "The")])
        // Gold-free: every run is expected collapsed.
        XCTAssertEqual(EvalCase(id: "s", raw: "the the the", gold: "").expectedStutters,
                       [EvalCase.Stutter(span: "the the the", keep: "the")])
    }

    func testRepeatedRunsGetDistinctOccurrences() {
        let c = EvalCase(id: "s", raw: "I I said I I did", gold: "I said I did.")
        XCTAssertEqual(c.expectedStutters, [EvalCase.Stutter(span: "I I", keep: "I", occurrence: 1),
                                            EvalCase.Stutter(span: "I I", keep: "I", occurrence: 2)])
        let tokens = Align.canonicalTokens(c.raw)
        XCTAssertEqual(c.expectedStutters.map { Align.locate($0.span, in: tokens, occurrence: $0.occurrence) },
                       [0..<2, 3..<5])
    }

    func testEmptyStuttersDisablesDerivationAndExplicitOverrides() throws {
        let off = try one(#"{"id": "x", "raw": "the the plan", "gold": "The plan.", "stutters": []}"#)
        XCTAssertEqual(off.expectedStutters, [])
        let explicit = try one(#"{"id": "x", "raw": "the the plan and a and more", "gold": "The plan and more.", "stutters": [{"span": "and a and", "keep": "and"}]}"#)
        XCTAssertEqual(explicit.expectedStutters, [EvalCase.Stutter(span: "and a and", keep: "and")])
    }

    func testSeedsDeriveAsExpected() {
        // Hand-counted over the 81 seeds: 49 controls (word-identical
        // golds — the ten originals, the ten long prompts, the clean
        // questions / traps / hedges / numbers, both cue controls, the two
        // mark-free fragments, the three punct seeds, the three registers,
        // the first continuation and the ladder), fillers only where the
        // gold drops um/uh, eight stutter runs over six seeds.
        let controls = Set(EvalCase.seeds.filter(\.isControl).map(\.id))
        XCTAssertEqual(controls, [
            "cue-is-content", "bench-quarterly", "bench-code", "cap-mid", "abbrev-eg",
            "abbrev-us", "comma-leading", "comma-double", "comma-terminal", "punct-double",
            "long-01", "long-02", "long-03", "long-04", "long-05", "long-06", "long-07", "long-08", "long-09", "long-10",
            "question-01", "question-04", "question-05", "trap-01", "trap-02", "trap-04", "trap-05",
            "hedge-01", "hedge-02", "hedge-04", "numbers-02", "numbers-03", "numbers-04",
            "cue-control-01", "cue-control-02", "fragment-02", "fragment-04", "punct-01", "punct-02", "punct-03",
            "register-messaging", "register-notes", "register-browser", "continuation-01",
            "latency-010", "latency-030", "latency-060", "latency-100", "latency-150",
        ])
        XCTAssertEqual(controls.count, 49)
        let fillerCounts = Dictionary(uniqueKeysWithValues: EvalCase.seeds.map { ($0.id, $0.expectedFillers.count) })
        XCTAssertEqual(fillerCounts.filter { $0.value > 0 }, [
            "premise-fillers": 5, "bench-standup": 1, "bench-meeting": 1,
            "medium-01": 2, "medium-02": 1, "medium-03": 2, "medium-04": 2, "medium-05": 2, "medium-06": 2,
            "question-02": 1, "question-03": 1, "trap-03": 1, "hedge-03": 1, "hedge-05": 1,
            "stutter-03": 1, "repair-03": 1, "asr-slip-03": 1, "fragment-01": 1, "fragment-03": 1,
            "continuation-02": 1,
        ])
        let stutters = EvalCase.seeds.flatMap { c in c.expectedStutters.map { "\(c.id): \($0.span) → \($0.keep)" } }
        XCTAssertEqual(stutters, [
            "bench-standup: the the → the",          // derived
            "numbers-01: and a and → and",           // explicit, non-identical
            "stutter-01: I I → I", "stutter-01: the like the → the",
            "stutter-02: then then then → then",
            "stutter-03: and a and → and",
            "stutter-04: my l laptop → my laptop", "stutter-04: I I → I",
        ])
        // No seed has an identical collapsible run it did not annotate.
        for c in EvalCase.seeds where c.stutters != nil {
            let derived = EvalCase.deriveStutters(raw: c.raw, gold: c.gold)
            for run in derived {
                XCTAssertTrue(c.stutters!.contains { $0.span.lowercased() == run.span.lowercased() }, "\(c.id) \(run)")
            }
        }
        // Every derived span locates in its raw at the stated occurrence.
        for c in EvalCase.seeds {
            let tokens = Align.canonicalTokens(c.raw)
            for f in c.expectedFillers {
                XCTAssertNotNil(Align.locate(f.span, in: tokens, occurrence: f.occurrence), "\(c.id) \(f)")
            }
            for s in c.expectedStutters {
                XCTAssertNotNil(Align.locate(s.span, in: tokens, occurrence: s.occurrence), "\(c.id) \(s)")
            }
            XCTAssertFalse(c.isGoldFree, c.id)
            XCTAssertFalse(c.isDraft, c.id)
        }
    }

    // MARK: - Gold-free is a provenance, not an empty string

    func testGoldFreeIsKeyedOffTheHistoryProvenance() {
        // Dispatcher decision a: only a history export row (empty gold
        // under `gold_source: "history-unrated"`) is gold-free. An empty
        // gold under any other provenance — a seed, a draft, an edit — is
        // a rated gold that says "paste nothing".
        XCTAssertEqual(EvalCase.historyUnratedGoldSource, "history-unrated")
        XCTAssertTrue(EvalCase(id: "h", raw: "Uh", gold: "", goldSource: "history-unrated").isGoldFree)
        XCTAssertFalse(EvalCase(id: "s", raw: "Uh", gold: "").isGoldFree)
        XCTAssertFalse(EvalCase(id: "d", raw: "Uh", gold: "", goldSource: "draft:claude", annotationsStatus: .draft).isGoldFree)
        XCTAssertFalse(EvalCase(id: "e", raw: "Uh", gold: "", goldSource: "edit").isGoldFree)
        // A gold under the export's provenance is still a gold.
        XCTAssertFalse(EvalCase(id: "h", raw: "um hi", gold: "Hi.", goldSource: "history-unrated").isGoldFree)
        // A v1 file's empty gold is a rated empty gold (the export always
        // writes its provenance; a hand-authored file that wants
        // "unrated" spells it).
        XCTAssertFalse(try one(#"{"id": "x", "raw": "Uh", "gold": ""}"#).isGoldFree)
        XCTAssertTrue(try one(#"{"id": "x", "raw": "Uh", "gold": "", "gold_source": "history-unrated"}"#).isGoldFree)
        // The seed set's all-filler fragment is rated.
        XCTAssertFalse(try XCTUnwrap(EvalCase.seeds.first { $0.id == "fragment-01" }).isGoldFree)
    }

    // MARK: - Derivation: latency budget

    func testMaxMsDefaultsByLength() {
        func words(_ n: Int) -> String { Array(repeating: "word", count: n).joined(separator: " ") }
        XCTAssertEqual(EvalCase(id: "l", raw: words(15), gold: "").latencyBudgetMs, 300)
        XCTAssertEqual(EvalCase(id: "l", raw: words(16), gold: "").latencyBudgetMs, 700)
        XCTAssertEqual(EvalCase(id: "l", raw: words(60), gold: "").latencyBudgetMs, 700)
        XCTAssertEqual(EvalCase(id: "l", raw: words(61), gold: "").latencyBudgetMs, 1500)
        XCTAssertEqual(EvalCase(id: "l", raw: "", gold: "").latencyBudgetMs, 300)
        XCTAssertEqual(EvalCase(id: "l", raw: words(100), gold: "", maxMs: 250).latencyBudgetMs, 250)
        // Spoken words, not canonical atoms: "fifty four" is two.
        XCTAssertEqual(EvalCase(id: "l", raw: "fifty four", gold: "54").wordCount, 2)
        XCTAssertEqual(EvalCase(id: "l", raw: "Um, so… yeah.", gold: "").wordCount, 3)
        XCTAssertEqual(EvalCase(id: "l", raw: "", gold: "").wordCount, 0)
    }

    // MARK: - Fixture-set hash

    func testCanonicalJSONShapeIsPinned() throws {
        // Sorted keys, no whitespace, defaults spelled out, nils omitted.
        // Any change to this string is a leaderboard-comparability break
        // and must be deliberate.
        let cases = [EvalCase(id: "a", raw: "um hi", gold: "Hi.")]
        XCTAssertEqual(try canonical(cases),
                       #"[{"alternates":[],"annotations_status":"confirmed","gold":"Hi.","gold_source":"seed","golds":[],"id":"a","language":"en","level":"standard","must_keep":[],"raw":"um hi","register":"unknown","repairs":[],"source":"synthetic","tags":[]}]"#)
        // sha256 of exactly those bytes (shasum -a 256 over the literal above).
        XCTAssertEqual(try EvalCase.fixtureSetHash(cases),
                       "df1d65d12f692ffcba712de70855c99fe96054336433ac4bbdbfb7c47b40e539")
    }

    func testHashIsStableAndNormalizes() throws {
        let v1 = try decode(#"[{"id": "a", "raw": "um hi", "gold": "Hi."}]"#)
        XCTAssertEqual(try EvalCase.fixtureSetHash(v1), try EvalCase.fixtureSetHash(v1))
        XCTAssertEqual(try EvalCase.fixtureSetHash(v1), try EvalCase.fixtureSetHash([EvalCase(id: "a", raw: "um hi", gold: "Hi.")]))
        // The same fixture spelled with every v2 default explicit, keys in
        // any order, `null` for the derived fields: same bytes, same hash.
        let v2 = try decode(#"""
        [{"tags": [], "source": "synthetic", "raw": "um hi", "annotations_status": "confirmed", "golds": [],
          "repairs": [], "id": "a", "language": "en", "must_keep": [], "register": "unknown",
          "gold_source": "seed", "alternates": [], "level": "standard", "gold": "Hi.",
          "fillers": null, "stutters": null, "control": null, "max_ms": null, "observed": null, "observed_ms": null}]
        """#)
        XCTAssertEqual(try canonical(v1), try canonical(v2))
        XCTAssertEqual(try EvalCase.fixtureSetHash(v1), try EvalCase.fixtureSetHash(v2))
        // Hex sha256: 64 lowercase hex chars.
        let hash = try EvalCase.fixtureSetHash(v1)
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testHashIsSensitive() throws {
        let base = [EvalCase(id: "a", raw: "um hi", gold: "Hi."), EvalCase(id: "b", raw: "okay so", gold: "Okay, so.")]
        let baseHash = try EvalCase.fixtureSetHash(base)
        XCTAssertNotEqual(baseHash, try EvalCase.fixtureSetHash([EvalCase(id: "a", raw: "um hi", gold: "Hi!"), base[1]]))
        XCTAssertNotEqual(baseHash, try EvalCase.fixtureSetHash([EvalCase(id: "a", raw: "um hi", gold: "Hi.", tags: ["x"]), base[1]]))
        // An explicit annotation is part of the identity even when it equals
        // the derived value…
        XCTAssertNotEqual(baseHash, try EvalCase.fixtureSetHash([base[0], EvalCase(id: "b", raw: "okay so", gold: "Okay, so.", control: true)]))
        XCTAssertNotEqual(baseHash, try EvalCase.fixtureSetHash([EvalCase(id: "a", raw: "um hi", gold: "Hi.", fillers: []), base[1]]))
        // …but fixture ORDER is not (the bench re-sorts by register/level
        // and the export merges by id; a reordered file is the same set).
        XCTAssertEqual(baseHash, try EvalCase.fixtureSetHash([base[1], base[0]]))
        XCTAssertNotEqual(baseHash, try EvalCase.fixtureSetHash([base[0]]))
        XCTAssertNotEqual(baseHash, try EvalCase.fixtureSetHash([base[0], EvalCase(id: "b", raw: "okay so", gold: "Okay, so.", annotationsStatus: .draft)]))
    }

    func testHashIsOrderInvariant() throws {
        // The canonical bytes sort by id, so any permutation of the seeds
        // encodes identically — and the sort is a plain scalar compare, so
        // "a-10" < "a-2" (no locale, no numeric collation) on every machine.
        let seeds = EvalCase.seeds
        XCTAssertEqual(try canonical(seeds.reversed()), try canonical(seeds))
        XCTAssertEqual(try EvalCase.fixtureSetHash(seeds.shuffled()), try EvalCase.fixtureSetHash(seeds))
        let a10 = EvalCase(id: "a-10", raw: "um hi", gold: "Hi.")
        let a2 = EvalCase(id: "a-2", raw: "um hi", gold: "Hi.")
        let text = try canonical([a2, a10])
        XCTAssertEqual(text, try canonical([a10, a2]))
        XCTAssertLessThan(text.range(of: #""id":"a-10""#)!.lowerBound, text.range(of: #""id":"a-2""#)!.lowerBound)
    }

    func testCanonicalJSONOmitsNilsAndKeepsExplicitFields() throws {
        let plain = try canonical([EvalCase(id: "a", raw: "um hi", gold: "Hi.")])
        for absent in ["note", "audio", "control", "fillers", "stutters", "max_ms", "observed", "observed_ms"] {
            XCTAssertFalse(plain.contains("\"\(absent)\""), absent)
        }
        let full = try canonical([EvalCase(id: "a", raw: "um hi", gold: "Hi.", note: "n", control: false,
                                           fillers: [], stutters: [], maxMs: 250, observed: "Hi", observedMs: 12)])
        XCTAssertTrue(full.contains(#""control":false"#))
        XCTAssertTrue(full.contains(#""fillers":[]"#))
        XCTAssertTrue(full.contains(#""stutters":[]"#))
        XCTAssertTrue(full.contains(#""max_ms":250"#))
        XCTAssertTrue(full.contains(#""observed":"Hi""#))
        XCTAssertTrue(full.contains(#""observed_ms":12"#))
        XCTAssertTrue(full.contains(#""note":"n""#))
        XCTAssertFalse(full.contains("\n"))
        XCTAssertFalse(full.contains(": "))
    }

    func testRoundTripIsLossless() throws {
        let example = try one(planExample)
        let again = try decode(try canonical([example]))
        XCTAssertEqual(again, [example])
        // The seeds survive the trip too (in canonical id order), and hash
        // the same on both sides.
        let seeds = try decode(try canonical(EvalCase.seeds))
        XCTAssertEqual(seeds, EvalCase.seeds.sorted { $0.id < $1.id })
        XCTAssertEqual(seeds.map(\.id).sorted(), EvalCase.seeds.map(\.id).sorted())
        XCTAssertEqual(try EvalCase.fixtureSetHash(seeds), try EvalCase.fixtureSetHash(EvalCase.seeds))
        // Nested types encode in their canonical shapes.
        let text = try canonical([example])
        XCTAssertTrue(text.contains(#""must_keep":[{"span":"I don't know,","weight":2},{"span":"sixty two other things","weight":5}]"#))
        XCTAssertTrue(text.contains(#""stutters":[{"keep":"and","occurrence":1,"span":"and a and"}]"#))
        XCTAssertTrue(text.contains(#""repairs":[{"repair":"on Wednesday","reparandum":"on Tuesday, I mean","resolve_at":"standard"}]"#))
        XCTAssertTrue(text.contains(#""alternates":[{"from":"walk up","to":["walk-up"]}]"#))
        XCTAssertTrue(text.contains(#""language":"en""#))
    }

    // MARK: - The stripper's set is the derivation's set

    func testStutterCollapsibleIsTheStrippersSet() {
        XCTAssertEqual(FillerStripper.stutterCollapsible,
                       ["i", "a", "an", "the", "we", "you", "he", "she", "they", "it", "and", "to"])
        // The stripper and the derivation agree on the same input.
        let raw = "the the whisper bro and very very flat"
        XCTAssertEqual(FillerStripper().strip(raw), "the whisper bro and very very flat")
        XCTAssertEqual(EvalCase(id: "s", raw: raw, gold: "The whisper bro and very very flat.").expectedStutters,
                       [EvalCase.Stutter(span: "the the", keep: "the")])
    }
}
