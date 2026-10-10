import Foundation
import os.log

/// Provenance of one formatter result, surfaced by the `formatDetailed`
/// variants for measurement callers (`whispr-bench eval`). The pipeline keeps
/// the plain-String `format` API — a dictation lands the same either way —
/// but the bench must know whether a row measured the MODEL or its rule-based
/// fallback: without the distinction, a Foundation Models daemon outage
/// produces an official-looking model row that is 100% rules output.
public enum FormatterSource: Sendable, Equatable {
    /// The model produced the output and it passed output validation.
    case model
    /// `TextFormatter.ruleBasedCleanup` produced the output.
    case fallback(FormatterFallbackReason)
}

/// Why a formatter result came from the rule-based path instead of the model.
public enum FormatterFallbackReason: String, Sendable {
    /// Short-utterance fast path: the model is skipped BY DESIGN (Parakeet
    /// already punctuates), identically on every machine — not a failure.
    case fastPath = "fast-path"
    /// Long-utterance ceiling: over `llmWordLimit` words the model is skipped
    /// BY DESIGN. Also not a failure — see `TextFormatter.Config.llmWordLimit`
    /// for the measurements behind the number.
    case tooLong = "too-long"
    /// Raw mode: the model stage is disabled for this dictation.
    case rawMode = "raw-mode"
    /// The engine is not loaded / the system model is unavailable right now.
    case unavailable
    /// The request threw (engine or session error).
    case requestFailed = "request-failed"
    /// The hard deadline elapsed before the model responded.
    case timedOut = "timed-out"
    /// The model responded but the output failed validation: refused by
    /// `TextFormatter.gateModelOutput` (a `ContentGuard` gate, or
    /// `implausibility` — wordless after sanitizing included).
    case implausible
}

/// Policy layer over `LlamaCppEngine` (spec §4 Formatter, §11.3). Decides when
/// to skip the LLM entirely and enforces safety rails:
///  - **raw mode** (per-call): LLM disabled — rule-based cleanup only.
///  - **short-utterance fast path**: under `fastPathWordLimit` words, skip the
///    LLM — Parakeet already punctuates, so the round-trip isn't worth it.
///  - **long-utterance ceiling**: over `llmWordLimit` words, skip it too — an
///    unmeasured band where the model paraphrases instead of editing.
///  - **generation cap**: `maxTokens ≈ 2×` the input so a model can't run away.
///  - **hard time budget**: the engine's abort callback aborts a decode that
///    exceeds `hangTimeout`, so a stuck GPU decode can't wedge the pipeline;
///    on abort/failure the dictation falls back to the rule-based result.
///  - **sanitizer**: conservatively strips known preambles / think blocks a
///    model may add despite instructions.
///  - **output gate** (`gateModelOutput`): `ContentGuard`'s gold-free gates
///    on the `.live` profile — the six rules L1-L6 — plus
///    `implausibility` for the wordless reply; a refused reply lands as the
///    rule-based result, never as the model's, and it is the same gate the
///    iOS stage runs. On this path a refusal costs the user a real
///    improvement, so the live profile refuses a catastrophe and nothing
///    else (`ContentGuard.Profile`); the bench grader keeps every rule.
public actor TextFormatter {
    public struct Config: Sendable {
        public var fastPathWordLimit: Int = 6
        /// Upper bound on what goes to the LLM, in words. Over it the stage is
        /// skipped and the rule-based cleanup ships. A dictation is counted
        /// as it was before the self-repair rules (`ceilingWords`,
        /// `DictationPipeline.FormatterInput`): their deletions never bring
        /// one under it.
        ///
        /// 150 because that is where the evidence stops: the longest fixture in
        /// the eval set is `latency-150`, and above ~200 words the measured
        /// behaviour turns bad in two ways — the model either **paraphrases**
        /// (a 450-word dictation came back as 121 words, a 0.27 ratio that the
        /// live gate's 0.25 floor lets through, so 329 words are lost at the
        /// cursor with no warning) or **echoes its input** after burning
        /// 2.4-3.1s, which `hangTimeout` then cuts anyway. A 2048-token context
        /// (`LlamaCppEngine.contextTokens`) minus the ~330-token prefix also
        /// can't hold a long transcript AND its rewrite, and an overflow
        /// mid-generation returns truncated output as a success.
        ///
        /// Raise it only with fixtures at the new length in the eval set.
        public var llmWordLimit: Int = 150
        public var hangTimeout: Duration = .seconds(3)
        public var maxTokensFloor: Int = 24
        /// Output-token budget as a multiple of the input word count.
        public var tokensPerWord: Double = 2.8
        public init() {}
    }

    // The LLM path exists only where the llama xcframework is linked (macOS).
    // Platforms without it (iOS phase i1) use the static rule-based helpers.
    #if canImport(llama)
    private let engine: LlamaCppEngine
    private let config: Config
    private let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "formatter")

    public init(engine: LlamaCppEngine, config: Config = Config()) {
        self.engine = engine
        self.config = config
    }

    public var isEngineLoaded: Bool {
        get async { await engine.isLoaded }
    }

    public func load() async throws {
        try await engine.load()
    }

    /// Free the model/context before process exit. Required: ggml-metal
    /// asserts at teardown if the Metal device is freed while the model still
    /// holds GPU buffers.
    public func shutdown() async {
        await engine.unload()
    }

    /// Format `raw` (already dictionary-corrected). Never throws: any engine
    /// failure, timeout, or raw/fast-path degrades to the rule-based result so
    /// a dictation always lands.
    /// - Parameters:
    ///   - resolveCorrections: when true, a short utterance that carries a
    ///     self-correction cue (spec §5c) is NOT shortcut to the fast path —
    ///     it goes to the LLM so the correction can be resolved. Only set by
    ///     the pipeline at `level = standard` on a non-verbatim register.
    ///   - ceilingWords: the word count the long-utterance ceiling applies
    ///     to when it is not `raw`'s own: the pipeline's count of the
    ///     dictation before the self-repair rules
    ///     (`DictationPipeline.FormatterInput.ceilingWords`), so the rules
    ///     never bring a long dictation onto the model. The larger of the two
    ///     counts decides.
    public func format(
        _ raw: String, rawMode: Bool, styleDirective: String = "",
        preserveCasingFor: Set<String> = [], resolveCorrections: Bool = false,
        language: DictationLanguage = .english, ceilingWords: Int? = nil
    ) async -> String {
        await formatDetailed(
            raw, rawMode: rawMode, styleDirective: styleDirective,
            preserveCasingFor: preserveCasingFor, resolveCorrections: resolveCorrections,
            language: language, ceilingWords: ceilingWords
        ).text
    }

    /// `format` plus provenance: whether the text came from the LLM or the
    /// rule-based fallback, and why (see `FormatterSource`). Measurement
    /// callers (`whispr-bench eval`) need the distinction so a fallback run
    /// can never masquerade as model evidence; the pipeline uses `format`.
    /// `rejected` is non-nil only on the `.implausible` path: the RAW model
    /// output the gate refused, so the bench can print WHAT the model did
    /// wrong (an answer, invented math, a polarity flip) instead of only
    /// that it fell back — the same shape as `FoundationModelsFormatter`'s.
    public func formatDetailed(
        _ raw: String, rawMode: Bool, styleDirective: String = "",
        preserveCasingFor: Set<String> = [], resolveCorrections: Bool = false,
        language: DictationLanguage = .english, ceilingWords: Int? = nil
    ) async -> (text: String, source: FormatterSource, rejected: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (trimmed, .fallback(.fastPath), nil) }

        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        // A short utterance skips the LLM — unless it likely holds a correction
        // to resolve (cue + plausible replacement), which the fast path can't do.
        let cueBypass = resolveCorrections
            && CorrectionCues.plausibleCorrection(in: trimmed, language: language)
        if rawMode || (wordCount < config.fastPathWordLimit && !cueBypass) {
            return (Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor),
                    .fallback(rawMode ? .rawMode : .fastPath), nil)
        }
        // Over the ceiling the model is skipped, not timed out into: a long
        // hands-free dictation must reach the cursor whole (see `llmWordLimit`).
        // Counted before the self-repair rules when the pipeline says so.
        let counted = max(wordCount, ceilingWords ?? 0)
        if counted > config.llmWordLimit {
            log.info("LLM skipped: \(counted) words over the \(self.config.llmWordLimit)-word ceiling")
            return (Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor),
                    .fallback(.tooLong), nil)
        }
        guard await engine.isLoaded else {
            return (Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor),
                    .fallback(.unavailable), nil)
        }

        let cap = max(config.maxTokensFloor, Int(Double(wordCount) * config.tokensPerWord))
        do {
            let formatted = try await engine.format(
                trimmed, styleDirective: styleDirective,
                maxTokens: cap, timeout: config.hangTimeout)
            // The gate sanitizes, repairs punctuation, then validates.
            // Punctuation repair runs POST-LLM only: pre-LLM it is redundant
            // (FillerStripper's gap repair already normalized strip sites, and
            // the LLM tolerates residue), but post-LLM it is load-bearing —
            // the measurement gate documents that Qwen2.5 conservatively
            // ECHOES its input on hard cases, so residue in means residue out.
            // `repairPunctuation` is idempotent and a no-op on clean output.
            // Full `ruleBasedCleanup` would be wrong here: it appends periods
            // to deliberately unterminated per-app-style output.
            let gate = Self.gateModelOutput(formatted, of: trimmed, language: language)
            guard let accepted = gate.accepted else {
                // Both catastrophic history classes (a question answered in
                // markdown, invented math) land here: the RULE names the
                // gate and is public; the head of the refused reply is
                // dictated text and stays private.
                log.error("""
                    format output rejected — \(gate.reason ?? "?", privacy: .public): \
                    \(Self.logHead(formatted)); using raw
                    """)
                return (Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor),
                        .fallback(.implausible), formatted)
            }
            return (accepted, .model, nil)
        } catch WhisprError.formattingTimedOut {
            log.error("format aborted (>\(self.config.hangTimeout.description)); re-priming, using raw")
            await engine.recover()
            return (Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor),
                    .fallback(.timedOut), nil)
        } catch {
            log.error("format failed: \(error.localizedDescription); using raw")
            return (Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor),
                    .fallback(.requestFailed), nil)
        }
    }
    #endif

    // MARK: - Command Mode

    #if canImport(llama)
    /// Voice-edit `selection` per the spoken `instruction`. Returns the edited
    /// text, or nil on empty/failed/timed-out generation — so the caller leaves
    /// the user's selection untouched rather than replacing it with garbage.
    public func command(
        instruction: String, selection: String, language: DictationLanguage = .english
    ) async -> String? {
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sel.isEmpty, !instr.isEmpty else { return nil }
        guard await engine.isLoaded else { return nil }

        let words = sel.split(whereSeparator: \.isWhitespace).count
            + instr.split(whereSeparator: \.isWhitespace).count
        // Edits can expand; generous floor. Off the latency-critical path, so an
        // 8s ceiling (vs 3s for dictation) is acceptable.
        let maxTokens = max(96, Int(Double(words) * 3.0))
        let userText = PromptBuilder.commandUserContent(instruction: instr, selection: sel)
        do {
            let raw = try await engine.command(
                systemPrompt: PromptBuilder.commandSystemPrompt,
                userText: userText, maxTokens: maxTokens, timeout: .seconds(8))
            let cleaned = Self.sanitize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            await engine.recover()   // restore a clean formatting prefix
            return nil
        }
    }
    #endif

    // MARK: - Rule-based fallback

    /// Deterministic cleanup for the fast path / fallback (and the ONLY
    /// formatter on platforms without an LLM, iOS phase i1): punctuation-
    /// residue repair, first-letter + guarded per-sentence capitalization,
    /// terminal punctuation. Parakeet already emits most punctuation, so this
    /// is intentionally conservative. `preserveCasingFor` = lowercased
    /// dictionary targets whose casing must survive (so a leading "npm" isn't
    /// up-cased to "Npm" — at the start OR after a sentence boundary).
    public static func ruleBasedCleanup(_ text: String, preserveCasingFor: Set<String> = []) -> String {
        var s = repairPunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = s.first else { return s }
        // Capitalize the first letter — UNLESS the leading token already carries
        // deliberate mixed casing (a dictionary identifier like "getUserData")
        // or is itself a dictionary target (like "npm").
        let leading = String(s.prefix { !$0.isWhitespace })
        let isDictionaryTerm = preserveCasingFor.contains(leading.lowercased())
        if first.isLowercase, !isDictionaryTerm, !leadingTokenHasInternalUppercase(s) {
            s.replaceSubrange(s.startIndex...s.startIndex, with: String(first).uppercased())
        }
        s = capitalizeSentenceStarts(s, preserveCasingFor: preserveCasingFor)
        if let last = s.last, !".!?".contains(last) {
            s.append(".")
        }
        return s
    }

    private static func leadingTokenHasInternalUppercase(_ s: String) -> Bool {
        let token = s.prefix { !$0.isWhitespace }
        return token.dropFirst().contains { $0.isUppercase }
    }

    // MARK: - Punctuation repair

    /// Deterministic punctuation-residue repair, shared by BOTH formatter
    /// paths (`ruleBasedCleanup` and the post-LLM sanitize step). The residue
    /// classes come from Parakeet's native output and conservative LLM echoes
    /// — FillerStripper's gap repair already handles strip sites. Every fold
    /// is a no-op on human-clean text and the whole pass is idempotent:
    ///  - whitespace squeezed out before closing punctuation (the same fold as
    ///    `FillerStripper.normalizeWhitespace`, for input that never passed
    ///    through the stripper — verbatim register, LLM output);
    ///  - comma/semicolon runs folded to one (`eggs, , milk` → `eggs, milk`);
    ///  - a leading comma/semicolon dropped (`, so anyway` → `so anyway`) —
    ///    the class is exactly `[,;]`, so Spanish openers (¿ ¡), quotes, and
    ///    parens survive;
    ///  - a trailing comma/semicolon dropped (the terminal-period append
    ///    would otherwise manufacture `,.`);
    ///  - a comma absorbed into a following terminal (`plan, .` → `plan.`);
    ///  - exactly-two periods folded to one; runs of 3+ are an ellipsis, kept;
    ///  - `?.` / `.!` mixes folded to the stronger mark; deliberate `?!` / `!?`
    ///    carry no period and are untouched.
    public static func repairPunctuation(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",(?:[ \t]*,)+[ \t]*"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #";(?:[ \t]*;)+"#, with: ";", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[,;\s]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]*[,;]+[ \t]*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*([.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\.)\.\.(?!\.)"#, with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([!?])\.(?!\.)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\.)\.([!?])"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sentence-start capitalization

    /// Tokens whose trailing `.` does NOT end a sentence, so the capitalizer
    /// must leave the following word alone ("e.g. foo", "3 p.m. tomorrow").
    /// Stored lowercased WITHOUT the trailing period; "e.g"/"a.m"/"ph.d" keep
    /// their internal dots. Single-letter dotted initialisms ("U.S.", "U.K.",
    /// a bare initial "J.") are exempted structurally in
    /// `isAbbreviationExempt`, so only multi-letter stems need listing.
    ///
    /// Ambiguous stems ("no", "min", "max", "est", "sec", "co") are
    /// deliberately ABSENT: they are common English words at least as often
    /// as abbreviations, and an unconditional exemption over-blocks — "i told
    /// him no. he did not listen" must capitalize "He". Their abbreviation
    /// reading ("no. 5", "est. 1999", "min. 3") is followed by a DIGIT, which
    /// `sentenceStartRegex` (lowercase-LETTER follower) never treats as a
    /// boundary — so the digit pattern stays lowercase-joined with no listing,
    /// and the exemption is effectively context-gated on the follower.
    static let capitalizationExemptAbbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "cf", "al", "mr", "mrs", "ms", "dr", "prof",
        "sr", "jr", "st", "mt", "dept", "approx", "misc", "inc", "ltd", "corp",
        "fig", "a.m", "p.m", "ph.d",
    ]

    /// A sentence boundary: terminal mark + whitespace + a lowercase letter.
    /// The `(?<!\.)` keeps an ellipsis ("wait... maybe") reading as a
    /// continuation, not a boundary.
    private static let sentenceStartRegex = try? NSRegularExpression(
        pattern: #"(?<!\.)([.!?])\s+(\p{Ll})"#)

    /// Uppercase the first letter of every sentence after the first, with the
    /// guards that used to justify skipping this entirely:
    ///  - a `.` ending an abbreviation-exempt token ("e.g.", "U.S.", "etc.")
    ///    is not a boundary;
    ///  - a follower that is a dictionary target ("npm") or carries internal
    ///    uppercase ("getUserData") keeps its casing;
    ///  - `?` and `!` always end a sentence (abbreviations don't end in them).
    private static func capitalizeSentenceStarts(
        _ text: String, preserveCasingFor: Set<String>
    ) -> String {
        guard let regex = sentenceStartRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {   // back-to-front so offsets stay valid
            let markRange = match.range(at: 1)
            let letterRange = match.range(at: 2)
            guard markRange.location != NSNotFound, letterRange.location != NSNotFound else { continue }
            if ns.substring(with: markRange) == "." {
                let token = tokenEnding(at: markRange.location + markRange.length, in: ns)
                if isAbbreviationExempt(token) { continue }
            }
            let follower = tokenStarting(at: letterRange.location, in: ns)
            let core = follower.prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" || $0 == "_" }
            if preserveCasingFor.contains(core.lowercased()) { continue }    // dictionary term
            if core.dropFirst().contains(where: \.isUppercase) { continue }  // deliberate casing
            guard let r = Range(letterRange, in: out) else { continue }
            out.replaceSubrange(r, with: out[r].uppercased())
        }
        return out
    }

    /// Is `token` (which ends in the `.` under inspection) an abbreviation
    /// whose period does not end the sentence?
    private static func isAbbreviationExempt(_ token: String) -> Bool {
        // Trim leading quotes/brackets so `("etc.` still matches its stem.
        let t = String(token.drop { !$0.isLetter && !$0.isNumber })
        guard t.hasSuffix(".") else { return false }
        if capitalizationExemptAbbreviations.contains(String(t.dropLast()).lowercased()) { return true }
        // Structural: a dotted initialism ("U.S.", "U.K.", a bare "J.") is
        // exempt without listing.
        return t.range(of: #"^(\p{L}\.)+\p{L}?$"#, options: .regularExpression) != nil
    }

    /// The whitespace-delimited token ending exactly at UTF-16 offset `end`
    /// (exclusive) — "U.S." for the mark inside "the U.S. office".
    private static func tokenEnding(at end: Int, in ns: NSString) -> String {
        var start = end
        while start > 0, !isTokenBreak(ns.character(at: start - 1)) { start -= 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// The whitespace-delimited token starting at UTF-16 offset `start`.
    private static func tokenStarting(at start: Int, in ns: NSString) -> String {
        var end = start
        while end < ns.length, !isTokenBreak(ns.character(at: end)) { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func isTokenBreak(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    // MARK: - Output sanitizer

    /// Known preamble phrases a model may prepend despite "output only the
    /// cleaned text". Matched only as an exact case-insensitive line PREFIX
    /// ending in a colon, so legitimately dictated sentences (even ones that
    /// start with "Here is …") are not eaten unless they exactly match one of
    /// these meta phrases.
    private static let preambles = [
        "here is the cleaned text",
        "here's the cleaned text",
        "here is the corrected text",
        "here's the corrected text",
        "here is the cleaned-up text",
        "cleaned text",
        "corrected text",
    ]

    static func sanitize(_ output: String) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove a reasoning block. If unterminated (cap truncated it), drop
        // everything from <think> to the end so no reasoning leaks.
        if let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        s = s.replacingOccurrences(of: "</think>", with: "")
             .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a known preamble phrase only when it is an exact prefix ending
        // at a colon.
        if let colon = s.firstIndex(of: ":") {
            let head = s[s.startIndex..<colon].lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'*"))
            if Self.preambles.contains(head) {
                s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip surrounding code fences (a clear model artifact). Do NOT strip
        // ordinary wrapping quotes — a dictation may legitimately be a quote.
        if s.hasPrefix("```"), s.hasSuffix("```"), s.count >= 6 {
            s = String(s.dropFirst(3).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    // MARK: - Output gate

    /// The ONE gate a formatter model's reply must pass before it can reach
    /// the user, shared by the macOS llama stage and the iOS Foundation
    /// Models stage: `sanitize` + `repairPunctuation`, then `ContentGuard`
    /// in gold-free mode — raw = the input the model saw, out = the cleaned
    /// reply, no gold, no alternates, disfluencies derived from the
    /// stripper's own lexicon — refusing on any gate the LIVE profile runs,
    /// then `implausibility` for a wordless reply. Returns the cleaned text
    /// to insert, or nil with the reason to log: the guard's worst gate with
    /// every trigger that fired, or the plausibility rule. The caller falls
    /// back to `ruleBasedCleanup` — a refused reply never reaches the user,
    /// and the model's raw text is surfaced only to the bench
    /// (`formatDetailed`'s `rejected`).
    ///
    /// The gate's job is to catch a CATASTROPHE, not to referee edit
    /// quality: on this path a refusal costs the user a real improvement (he
    /// gets the rules output, i.e. the unresolved raw), while edit quality is
    /// what the benchmark scores and what the register wording and the
    /// prompt delimiters fix. It is SIX rules — L1 structure, L2 runaway,
    /// L3 wholesale loss, L4 wordless, L5 invented numeral, L6 invented
    /// content — and `ContentGuard.Profile` states each one, the evidence for
    /// it, and the seven shapes the gate knowingly does not catch. Over-editing
    /// inside the length band, a resolved correction that shrinks a short
    /// utterance, two introduced words and a polarity inversion all land. The
    /// BENCH grader keeps its own, stricter profile, so row 54's invented
    /// total still gates there and so does every flip.
    ///
    /// The two halves cannot disagree: `implausibility` is L1, L2 and L4
    /// read off the same tokens and the same constants, so the only verdict
    /// it can reach that the guard cannot is the wordless one.
    ///
    /// Static and engine-free so the decision is pinned over (input, model
    /// output) pairs — the history rows that motivated it — without a model.
    public static func gateModelOutput(
        _ output: String, of input: String, language: DictationLanguage = .english
    ) -> GateVerdict {
        let cleaned = repairPunctuation(sanitize(output))
        let guarded = ContentGuard.check(raw: input, out: cleaned, language: language, profile: .live)
        if let worst = guarded.worst {
            let triggers = guarded.triggers.map(\.rawValue).joined(separator: ", ")
            return GateVerdict(accepted: nil, reason: "\(worst.rawValue) (\(triggers))")
        }
        if let rule = implausibility(of: cleaned, input: input) {
            return GateVerdict(accepted: nil, reason: "implausible: \(rule)")
        }
        return GateVerdict(accepted: cleaned, reason: nil)
    }

    /// What the gate decided. `reason` is the rule that fired — a gate with
    /// its triggers, or the plausibility rule — and never carries dictated
    /// text, so a log may print it in clear. (It once carried a second,
    /// private field for the content token the introduced-word rule named;
    /// that rule is gone, and with it the only reason this struct had to
    /// hold anything the user said.) Nil reason ⇔ non-nil `accepted`.
    public struct GateVerdict: Sendable, Equatable {
        public let accepted: String?
        public let reason: String?
    }

    /// The first ~80 characters of a refused reply on one line, for the
    /// rejection log — enough to see an answer or an invented number without
    /// dumping the whole reply.
    static func logHead(_ text: String, limit: Int = 80) -> String {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ⏎ ")
        return head.count > limit ? String(head.prefix(limit)) + "…" : head
    }

    // MARK: - Output validation

    /// Engine-agnostic guardrail over a formatter model's output: `sanitize` +
    /// `repairPunctuation`, then nil when the result cannot plausibly be a
    /// REFORMATTING of `input` — the caller falls back to its rule-based
    /// result. Encodes the measured small-model failure modes
    /// (docs/llm-measurement-gate.md) without engine knowledge; it is the
    /// second half of `gateModelOutput`, after `ContentGuard`, so the macOS
    /// llama stage and the iOS Foundation Models stage share ONE gate:
    ///  - **L4 WORDLESS** — an output with no letter and no digit in it:
    ///    empty, or punctuation residue like "." left by the sanitizer.
    ///    There is nothing to insert, so refusing costs nothing; reading
    ///    "empty" as "no characters" alone would let a lone period replace a
    ///    whole dictation (the fast path handles genuinely one-word
    ///    utterances, so a wordless reply is never the right answer here).
    ///    This is the one rule of the six that needs no alignment,
    ///    which is why it lives here and not in `ContentGuard`;
    ///  - **L1 STRUCTURE** — multiple non-empty lines out of a single-line
    ///    dictation (a preamble the sanitizer's allowlist missed, commentary,
    ///    or an "answer" — a dictation is one paragraph);
    ///  - **L2 RUNAWAY** — more than `EvalThresholds.answeredLengthRatio`
    ///    times the input's ATOMS, on an input of at least
    ///    `minWordsForRatio` of them: formatting adds punctuation, not words,
    ///    and Llama-3.2's documented 771-character generated-JavaScript
    ///    "answer" dies here.
    ///
    /// L1 and L2 are read with `ContentGuard`'s own tokens and constants, so
    /// this rule cannot hold a second, DISAGREEING opinion about length or
    /// structure — one length band, one place. (It once had its own `1.6×`
    /// over whitespace-split words, which made the shipping gate stricter
    /// than the grader on a band nobody could point at.)
    ///
    /// What this rule no longer does is as deliberate as what it does. The
    /// lower bound of the old `[0.5, 1.6]×` band is gone from HERE: a
    /// wholesale loss is L3, in `ContentGuard`, where the raw atoms are
    /// already counted. The introduced-content-word rule is gone outright: it
    /// refused the homophone and split-word fixes the system prompt
    /// COMMISSIONS, and every list written to exempt them (homophone classes,
    /// ordinal and meridiem suffixes) sanctioned the corruption direction
    /// too. `ContentGuard`'s L6 is the rule that survived.
    public static func plausibleReformatting(_ output: String, of input: String) -> String? {
        let cleaned = repairPunctuation(sanitize(output))
        return implausibility(of: cleaned, input: input) == nil ? cleaned : nil
    }

    /// `plausibleReformatting`'s verdict over an ALREADY sanitized and
    /// repaired output — the rule that fired; nil when plausible. No rule
    /// here names a content token any more, so the verdict is public text.
    static func implausibility(of cleaned: String, input: String) -> String? {
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return "empty" }
        if nonEmptyLineCount(cleaned) > 1, nonEmptyLineCount(input) <= 1 { return "multi-line" }
        let inAtoms = Align.canonicalTokens(input).count
        let outAtoms = Align.canonicalTokens(cleaned).count
        guard inAtoms < EvalThresholds.minWordsForRatio
                || Double(outAtoms) <= EvalThresholds.answeredLengthRatio * Double(inAtoms) else {
            return "\(outAtoms) atoms out of \(inAtoms)"
        }
        return nil
    }

    private static func nonEmptyLineCount(_ s: String) -> Int {
        s.split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .count
    }
}
