import Foundation

/// The platform-neutral post-capture text pipeline (spec §3): samples →
/// optional VAD trim → ASR → personal dictionary (ONCE) → Auto-Clean
/// (self-repair rules → filler strip) → spoken layout → platform formatter
/// stage, with per-stage timings. Extracted so the gating
/// rules can never drift between the macOS and iOS apps. Orchestration of OS
/// surfaces (hotkeys, HUD, insertion, session state) stays in each app; only
/// the shared samples → final-text path lives here.
///
/// The formatter stage is injected because it is the one platform-divergent
/// stage: macOS supplies the LLM `TextFormatter.format`; iOS (phase i4)
/// supplies `FoundationModelsFormatter.format`. Both degrade to the rule-based
/// result internally, so a dictation always lands. Each is handed a
/// `FormatterInput`: the text, and the word count its 150-word ceiling
/// applies to — the dictation's before the self-repair rules.
public struct DictationPipeline: Sendable {
    /// What downstream (insertion/pasteboard, history, UI) needs from one run.
    public struct Outcome: Sendable {
        /// The TRUE verbatim form (dictionary only) — what history stores as
        /// rawText and "undo AI edit → paste raw" re-pastes (task-014 §7c).
        public let verbatimText: String
        /// The final text: verbatim at level `.verbatim`, otherwise the
        /// formatter stage's output on the self-repaired, filler-stripped
        /// input.
        public let text: String
        /// Samples actually transcribed (post-trim), for duration/WPM stats.
        public let transcribedSampleCount: Int
        /// The caller's timings with `asrSeconds` and `formatSeconds` filled.
        public let timings: StageTimings
    }

    /// What the formatter stage receives for one dictation (`formatInput`).
    public struct FormatterInput: Sendable, Equatable {
        /// The cleaned text, spoken layout lifted out: what to format.
        public let text: String
        /// The words the model's length ceiling counts
        /// (`TextFormatter.Config.llmWordLimit`): those of the input this
        /// dictation would have given the formatter WITHOUT the self-repair
        /// rules, or `text`'s own when that is more. The rules only delete,
        /// so counting what they left would let them bring a long dictation
        /// under the ceiling and onto the model, which skipped it before —
        /// with the model damage and the latency that skip exists to avoid.
        /// Counted this way, whether the model runs on length is decided
        /// exactly as before the rules (`ceilingWords(...)`).
        public let ceilingWords: Int

        public init(text: String, ceilingWords: Int) {
            self.text = text
            self.ceilingWords = ceilingWords
        }
    }

    private let asr: AsrEngine

    public init(asr: AsrEngine) {
        self.asr = asr
    }

    /// Run the shared samples → final-text path. Returns nil when ASR produced
    /// no text (callers reset their UI state). Throws only from ASR.
    ///
    /// Auto-Clean gating (task-014 §5a, §7a) — the rules this type exists to
    /// keep identical across platforms:
    ///  - level `.verbatim`: the WHOLE stage is a no-op — no self-repair, no
    ///    filler strip AND no formatter; the output is byte-identical to the
    ///    dictionary-corrected text (spec §7a / AC #6).
    ///  - `verbatimRegister` (ide/terminal/notes registers on macOS): skips
    ///    the self-repair rules and the filler strip; the formatter stage
    ///    still runs (with the platform's own verbatim-ish directive).
    ///  - self-repair (`SelfRepair`, deletion-only rules) runs where the strip
    ///    runs, BEFORE it, English only: repeats and fragments at every level
    ///    that strips, the cued corrections and restarts only at `standard`
    ///    — see `prePass`. `selfRepair: false` (`[cleanup] self_repair`)
    ///    switches the rules off alone: the pre-pass is then the strip, as
    ///    it was before the rules, at every level and register.
    ///  - all-filler fallback: a strip that leaves no letter or digit falls
    ///    back to the verbatim text so a dictation always lands (spec §3.2 #17).
    ///  - the dictionary is applied exactly ONCE, before the formatter (so the
    ///    LLM sees corrected terms); a second pass would duplicate words for
    ///    an expanding rule (target contains its source). Its targets protect
    ///    matching tokens from the filler strip (a case-insensitive collision).
    ///  - spoken LAYOUT ("new paragraph", "bullet point", "and I quote …
    ///    unquote") is lifted out before the formatter and applied after it
    ///    (`SpokenStructure`), so the model never sees a marker it could
    ///    mangle and the output gate never sees a line break it would refuse.
    ///    `register` decides which kinds are allowed — none in a terminal,
    ///    no bullets in an IDE.
    ///
    /// - Parameters:
    ///   - trim: leading/trailing-silence trim (`VadGate.trim`); nil when VAD
    ///     is unavailable or the mode doesn't trim. If the trimmed audio falls
    ///     under the ASR sample floor, the untrimmed samples are transcribed.
    ///   - dictionary/stripper/level/verbatimRegister: the caller's snapshots,
    ///     taken at one instant so a config reload mid-dictation can't make
    ///     the substitution, the LLM allowlist, and the filler pre-pass
    ///     disagree.
    ///   - language: the dictation language; the self-repair rules are
    ///     English and do not run on another.
    ///   - selfRepair: the rules on or off (`AppConfig.Cleanup.selfRepair`),
    ///     snapshotted with the rest.
    ///   - timings: stages the caller already measured (audio finalize).
    ///   - prepareFormatter: runs only when the formatter stage will run,
    ///     after the strip and OUTSIDE the measured format call — so a
    ///     platform can reload an idle-unloaded LLM (~1–2s) without inflating
    ///     `formatSeconds`.
    ///   - formatInput: cleaned input → final text, given with the word count
    ///     the model's length ceiling applies to (`FormatterInput`). Must not
    ///     throw — degrade internally (rule-based fallback) so a dictation
    ///     always lands.
    public func run(
        _ samples: [Float],
        trim: (([Float]) async -> [Float])? = nil,
        dictionary: DictionaryEngine,
        stripper: FillerStripper,
        level: AppConfig.Cleanup.Level,
        verbatimRegister: Bool = false,
        register: AppCategory = .unknown,
        language: DictationLanguage = .english,
        selfRepair: Bool = true,
        timings: StageTimings = StageTimings(),
        prepareFormatter: (() async -> Void)? = nil,
        formatInput: (FormatterInput) async -> String
    ) async throws -> Outcome? {
        var timings = timings
        let audioForAsr: [Float]
        if let trim {
            audioForAsr = await trim(samples)
        } else {
            audioForAsr = samples
        }
        let toTranscribe = audioForAsr.count >= asr.minimumSamples ? audioForAsr : samples
        let (result, asrSeconds) = try await measured { try await asr.transcribe(toTranscribe) }
        timings.asrSeconds = asrSeconds

        let verbatimText = dictionary.apply(
            result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !verbatimText.isEmpty else { return nil }

        let (text, formatSeconds) = await Self.finish(
            verbatimText, dictionary: dictionary, stripper: stripper, level: level,
            verbatimRegister: verbatimRegister, register: register, language: language,
            selfRepair: selfRepair, prepareFormatter: prepareFormatter, formatInput: formatInput)
        timings.formatSeconds = formatSeconds

        return Outcome(
            verbatimText: verbatimText, text: text,
            transcribedSampleCount: toTranscribe.count, timings: timings)
    }

    /// `run` with a formatter that takes the text alone — one that applies
    /// no length ceiling of its own, or counts the text it is given (tests,
    /// the rule-based stage). A formatter with the model's ceiling takes
    /// `formatInput` and its `ceilingWords`.
    public func run(
        _ samples: [Float],
        trim: (([Float]) async -> [Float])? = nil,
        dictionary: DictionaryEngine,
        stripper: FillerStripper,
        level: AppConfig.Cleanup.Level,
        verbatimRegister: Bool = false,
        register: AppCategory = .unknown,
        language: DictationLanguage = .english,
        selfRepair: Bool = true,
        timings: StageTimings = StageTimings(),
        prepareFormatter: (() async -> Void)? = nil,
        format: (String) async -> String
    ) async throws -> Outcome? {
        try await run(
            samples, trim: trim, dictionary: dictionary, stripper: stripper, level: level,
            verbatimRegister: verbatimRegister, register: register, language: language,
            selfRepair: selfRepair, timings: timings, prepareFormatter: prepareFormatter,
            formatInput: { await format($0.text) })
    }

    /// The text half of `run`: what a transcribed, dictionary-corrected
    /// dictation becomes — Auto-Clean (`prePass`), the spoken layout, the
    /// formatter stage and the finishing pass, under the same gating. Command
    /// Mode with nothing selected calls it too, so spoken words land exactly
    /// as a dictation's do (rules-only included). Returns the final text and
    /// the measured format seconds (0 at the verbatim level, where the text
    /// comes back byte-identical).
    public static func finish(
        _ verbatimText: String,
        dictionary: DictionaryEngine,
        stripper: FillerStripper,
        level: AppConfig.Cleanup.Level,
        verbatimRegister: Bool = false,
        register: AppCategory = .unknown,
        language: DictationLanguage = .english,
        selfRepair: Bool = true,
        prepareFormatter: (() async -> Void)? = nil,
        formatInput: (FormatterInput) async -> String
    ) async -> (text: String, formatSeconds: Double) {
        // Byte-identical to the dictionary-corrected text — proven no-op.
        guard level != .verbatim else { return (verbatimText, 0) }
        let stages = prePassStages(
            verbatimText, dictionary: dictionary, stripper: stripper,
            level: level, verbatimRegister: verbatimRegister, language: language,
            selfRepair: selfRepair)
        let cleanedInput = landing(stages.stripped, verbatimText: verbatimText)

        await prepareFormatter?()
        // Lift the spoken layout out, format the plain line, put the
        // layout back. With no markers this is byte-identical to handing
        // `cleanedInput` straight to the formatter.
        let policy = SpokenStructure.policy(for: register, verbatim: verbatimRegister)
        let structure = SpokenStructure.extract(from: cleanedInput, policy: policy)
        let input = FormatterInput(
            text: structure.text,
            ceilingWords: ceilingWords(
                for: structure.text, verbatimText: verbatimText, repaired: stages.repaired,
                dictionary: dictionary, stripper: stripper, policy: policy))
        let (formatted, seconds) = await measured { await formatInput(input) }
        let structured = SpokenStructure.apply(
            structure.marks, to: formatted, from: structure.text,
            policy: policy, preserveCasingFor: dictionary.lowercasedTargets)
        // Finish what the model left unfinished — an opening capital, a
        // closing full stop — wherever the register wants them. A shell and
        // an IDE get neither (`Policy.finishes`).
        let text = policy.finishes
            ? SpokenStructure.terminating(SpokenStructure.capitalizingFirstWord(
                structured, preserveCasingFor: dictionary.lowercasedTargets))
            : structured
        return (text, seconds)
    }

    /// `finish` with a formatter that takes the text alone (see `run`'s).
    public static func finish(
        _ verbatimText: String,
        dictionary: DictionaryEngine,
        stripper: FillerStripper,
        level: AppConfig.Cleanup.Level,
        verbatimRegister: Bool = false,
        register: AppCategory = .unknown,
        language: DictationLanguage = .english,
        selfRepair: Bool = true,
        prepareFormatter: (() async -> Void)? = nil,
        format: (String) async -> String
    ) async -> (text: String, formatSeconds: Double) {
        await finish(
            verbatimText, dictionary: dictionary, stripper: stripper, level: level,
            verbatimRegister: verbatimRegister, register: register, language: language,
            selfRepair: selfRepair, prepareFormatter: prepareFormatter,
            formatInput: { await format($0.text) })
    }

    /// What reaches the formatter of a pre-pass result: the result, unless
    /// it kept no letter or digit. Never emit empty: a punctuation-only
    /// residue ("um, uh." stripped to bare punctuation) falls back to the
    /// verbatim text.
    static func landing(_ stripped: String, verbatimText: String) -> String {
        stripped.contains { $0.isLetter || $0.isNumber } ? stripped : verbatimText
    }

    /// Words as the formatters count them (`TextFormatter.formatDetailed`).
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// `FormatterInput.ceilingWords`: the words of the formatter input this
    /// dictation would have produced without the self-repair rules — the
    /// strip alone, the same all-filler fallback, the same layout lifted out,
    /// what the formatter counted before the rules existed — or `text`'s own
    /// when that is more. `repaired` is the rules' output before the strip
    /// (`prePassStages`): when it is `verbatimText` they took nothing, `text`
    /// is what they would have produced, and nothing is computed twice.
    static func ceilingWords(
        for text: String, verbatimText: String, repaired: String,
        dictionary: DictionaryEngine, stripper: FillerStripper, policy: SpokenStructure.Policy
    ) -> Int {
        guard repaired != verbatimText else { return wordCount(text) }
        return ceilingWords(for: text, verbatimText: verbatimText, dictionary: dictionary,
                            stripper: stripper, policy: policy)
    }

    /// `FormatterInput.ceilingWords` for a caller that runs the stages
    /// itself — `whispr-bench format`, which swaps the layout policy or
    /// drops the layer — so its model is skipped on length exactly when the
    /// app's would be: the words of `text`, what it hands the formatter, or,
    /// when more, of the formatter input the strip alone would have made of
    /// `verbatimText`, with the layout lifted out under `policy` (`nil`: no
    /// layer, nothing lifted).
    public static func ceilingWords(
        for text: String, verbatimText: String,
        dictionary: DictionaryEngine, stripper: FillerStripper, policy: SpokenStructure.Policy?
    ) -> Int {
        let unrepaired = landing(
            stripper.strip(verbatimText, protecting: dictionary.lowercasedTargets),
            verbatimText: verbatimText)
        let before = policy.map { SpokenStructure.extract(from: unrepaired, policy: $0).text } ?? unrepaired
        return max(wordCount(text), wordCount(before))
    }

    /// Auto-Clean's deterministic pre-pass over the dictionary-corrected
    /// text: the self-repair rules, then the filler strip, both under the
    /// strip's gate — a level other than `.verbatim`, a register that is not
    /// verbatim — so wherever fillers survive, nothing else is touched
    /// either. Self-repair runs FIRST: the fillers are its evidence ("ten,
    /// uh, ten" is a repeat across a filled pause; it never deletes a filler
    /// on its own, and FillerStripper takes them out after). Which rules run
    /// is the level's (`SelfRepair.forDictation`: repeats and cut-off words
    /// at `fillers`, everything at `standard`), only on English, and the
    /// repetition rule only while `collapse_stutters` is on — the stripper's
    /// own switch for repeated words. Dictionary targets are protected from
    /// both, as before; spoken layout ("bullet point") is a boundary the
    /// rules never cross, so `SpokenStructure` after them sees every item.
    ///
    /// `selfRepair: false` (`[cleanup] self_repair = false`, Settings' "Fix
    /// self-corrections" off) runs no rule at all: the pre-pass is the
    /// strip alone, byte for byte what it was before the rules existed, at
    /// every level and register — pinned by test against outputs recorded
    /// from that build (`SelfRepairSwitchTests`).
    ///
    /// Static and engine-free so `whispr-bench` runs the exact stage the app
    /// ships (eval / cleanup / format) and the gating is pinned by test.
    public static func prePass(
        _ text: String, dictionary: DictionaryEngine, stripper: FillerStripper,
        level: AppConfig.Cleanup.Level, verbatimRegister: Bool, language: DictationLanguage,
        selfRepair: Bool = true
    ) -> String {
        prePassStages(text, dictionary: dictionary, stripper: stripper, level: level,
                      verbatimRegister: verbatimRegister, language: language, selfRepair: selfRepair).stripped
    }

    /// `prePass`, keeping the rules' output before the strip: `repaired` is
    /// `text` itself when the rules took nothing (or did not run).
    static func prePassStages(
        _ text: String, dictionary: DictionaryEngine, stripper: FillerStripper,
        level: AppConfig.Cleanup.Level, verbatimRegister: Bool, language: DictationLanguage,
        selfRepair: Bool
    ) -> (repaired: String, stripped: String) {
        guard level != .verbatim, !verbatimRegister else { return (text, text) }
        let terms = dictionary.lowercasedTargets
        let repair = selfRepair
            ? SelfRepair.forDictation(
                level: level, verbatimRegister: verbatimRegister, language: language, protecting: terms,
                collapseStutters: stripper.collapsesStutters)
            : nil
        let repaired = repair?.repair(text) ?? text
        return (repaired, stripper.strip(repaired, protecting: terms))
    }
}
