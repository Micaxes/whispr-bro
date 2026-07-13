import Foundation

/// The platform-neutral post-capture text pipeline (spec §3): samples →
/// optional VAD trim → ASR → personal dictionary (ONCE) → Auto-Clean gating →
/// platform formatter stage, with per-stage timings. Extracted so the gating
/// rules can never drift between the macOS and iOS apps. Orchestration of OS
/// surfaces (hotkeys, HUD, insertion, session state) stays in each app; only
/// the shared samples → final-text path lives here.
///
/// The formatter stage is injected because it is the one platform-divergent
/// stage: macOS supplies the LLM `TextFormatter.format` (which degrades to the
/// rule-based result internally); iOS phase i1 supplies
/// `TextFormatter.ruleBasedCleanup` until Apple Foundation Models formatting
/// lands (phase i4).
public struct DictationPipeline: Sendable {
    /// What downstream (insertion/pasteboard, history, UI) needs from one run.
    public struct Outcome: Sendable {
        /// The TRUE verbatim form (dictionary only) — what history stores as
        /// rawText and "undo AI edit → paste raw" re-pastes (task-014 §7c).
        public let verbatimText: String
        /// The final text: verbatim at level `.verbatim`, otherwise the
        /// formatter stage's output on the filler-stripped input.
        public let text: String
        /// Samples actually transcribed (post-trim), for duration/WPM stats.
        public let transcribedSampleCount: Int
        /// The caller's timings with `asrSeconds` and `formatSeconds` filled.
        public let timings: StageTimings
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
    ///  - level `.verbatim`: the WHOLE stage is a no-op — no filler strip AND
    ///    no formatter; the output is byte-identical to the dictionary-
    ///    corrected text (spec §7a / AC #6).
    ///  - `verbatimRegister` (ide/terminal/notes registers on macOS): skips
    ///    only the filler strip; the formatter stage still runs (with the
    ///    platform's own verbatim-ish directive).
    ///  - all-filler fallback: a strip that leaves no letter or digit falls
    ///    back to the verbatim text so a dictation always lands (spec §3.2 #17).
    ///  - the dictionary is applied exactly ONCE, before the formatter (so the
    ///    LLM sees corrected terms); a second pass would duplicate words for
    ///    an expanding rule (target contains its source). Its targets protect
    ///    matching tokens from the filler strip (a case-insensitive collision).
    ///
    /// - Parameters:
    ///   - trim: leading/trailing-silence trim (`VadGate.trim`); nil when VAD
    ///     is unavailable or the mode doesn't trim. If the trimmed audio falls
    ///     under the ASR sample floor, the untrimmed samples are transcribed.
    ///   - dictionary/stripper/level/verbatimRegister: the caller's snapshots,
    ///     taken at one instant so a config reload mid-dictation can't make
    ///     the substitution, the LLM allowlist, and the filler pre-pass
    ///     disagree.
    ///   - timings: stages the caller already measured (audio finalize).
    ///   - prepareFormatter: runs only when the formatter stage will run,
    ///     after the strip and OUTSIDE the measured format call — so a
    ///     platform can reload an idle-unloaded LLM (~1–2s) without inflating
    ///     `formatSeconds`.
    ///   - format: cleaned input → final text. Must not throw — degrade
    ///     internally (rule-based fallback) so a dictation always lands.
    public func run(
        _ samples: [Float],
        trim: (([Float]) async -> [Float])? = nil,
        dictionary: DictionaryEngine,
        stripper: FillerStripper,
        level: AppConfig.Cleanup.Level,
        verbatimRegister: Bool = false,
        timings: StageTimings = StageTimings(),
        prepareFormatter: (() async -> Void)? = nil,
        format: (String) async -> String
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

        let stageOff = level == .verbatim
        let stripFillers = !stageOff && !verbatimRegister
        let stripped = stripFillers
            ? stripper.strip(verbatimText, protecting: dictionary.lowercasedTargets)
            : verbatimText
        // Never emit empty: "meaningful" = has a letter or digit, so a
        // punctuation-only residue (e.g. "um, uh." stripped to bare
        // punctuation) also triggers the fallback to the verbatim text.
        let hasContent = stripped.contains { $0.isLetter || $0.isNumber }
        let cleanedInput = hasContent ? stripped : verbatimText

        let text: String
        let formatSeconds: Double
        if stageOff {
            // Byte-identical to the dictionary-corrected text — proven no-op.
            text = verbatimText
            formatSeconds = 0
        } else {
            await prepareFormatter?()
            (text, formatSeconds) = await measured { await format(cleanedInput) }
        }
        timings.formatSeconds = formatSeconds

        return Outcome(
            verbatimText: verbatimText, text: text,
            transcribedSampleCount: toTranscribe.count, timings: timings)
    }
}
