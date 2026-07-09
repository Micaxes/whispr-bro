import Foundation
import os.log

/// Policy layer over `LlamaCppEngine` (spec §4 Formatter, §11.3). Decides when
/// to skip the LLM entirely and enforces safety rails:
///  - **raw mode** (per-call): LLM disabled — rule-based cleanup only.
///  - **short-utterance fast path**: under `fastPathWordLimit` words, skip the
///    LLM — Parakeet already punctuates, so the round-trip isn't worth it.
///  - **generation cap**: `maxTokens ≈ 2×` the input so a model can't run away.
///  - **hard time budget**: the engine's abort callback aborts a decode that
///    exceeds `hangTimeout`, so a stuck GPU decode can't wedge the pipeline;
///    on abort/failure the dictation falls back to the rule-based result.
///  - **sanitizer**: conservatively strips known preambles / think blocks a
///    model may add despite instructions.
public actor TextFormatter {
    public struct Config: Sendable {
        public var fastPathWordLimit: Int = 6
        public var hangTimeout: Duration = .seconds(3)
        public var maxTokensFloor: Int = 24
        /// Output-token budget as a multiple of the input word count.
        public var tokensPerWord: Double = 2.8
        public init() {}
    }

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
    /// - Parameter resolveCorrections: when true, a short utterance that carries
    ///   a self-correction cue (spec §5c) is NOT shortcut to the fast path — it
    ///   goes to the LLM so the correction can be resolved. Only set by the
    ///   pipeline at `level = standard` on a non-verbatim register.
    public func format(
        _ raw: String, rawMode: Bool, styleDirective: String = "",
        preserveCasingFor: Set<String> = [], resolveCorrections: Bool = false,
        language: DictationLanguage = .english
    ) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        // A short utterance skips the LLM — unless it likely holds a correction
        // to resolve (cue + plausible replacement), which the fast path can't do.
        let cueBypass = resolveCorrections
            && CorrectionCues.plausibleCorrection(in: trimmed, language: language)
        if rawMode || (wordCount < config.fastPathWordLimit && !cueBypass) {
            return Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor)
        }
        guard await engine.isLoaded else {
            return Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor)
        }

        let cap = max(config.maxTokensFloor, Int(Double(wordCount) * config.tokensPerWord))
        do {
            let formatted = try await engine.format(
                trimmed, styleDirective: styleDirective,
                maxTokens: cap, timeout: config.hangTimeout)
            let cleaned = Self.sanitize(formatted)
            return cleaned.isEmpty ? Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor) : cleaned
        } catch WhisprError.formattingTimedOut {
            log.error("format aborted (>\(self.config.hangTimeout.description)); re-priming, using raw")
            await engine.recover()
            return Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor)
        } catch {
            log.error("format failed: \(error.localizedDescription); using raw")
            return Self.ruleBasedCleanup(trimmed, preserveCasingFor: preserveCasingFor)
        }
    }

    // MARK: - Rule-based fallback

    /// Minimal deterministic cleanup for the fast path / fallback: capitalize
    /// the first letter and ensure terminal punctuation. Parakeet already
    /// emits most punctuation, so this is intentionally conservative.
    /// `preserveCasingFor` = lowercased dictionary targets whose casing must
    /// survive (so a leading "npm" isn't up-cased to "Npm").
    // MARK: - Command Mode

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

    static func ruleBasedCleanup(_ text: String, preserveCasingFor: Set<String> = []) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = s.first else { return s }
        // Capitalize the first letter — UNLESS the leading token already carries
        // deliberate mixed casing (a dictionary identifier like "getUserData")
        // or is itself a dictionary target (like "npm").
        let leading = String(s.prefix { !$0.isWhitespace })
        let isDictionaryTerm = preserveCasingFor.contains(leading.lowercased())
        if first.isLowercase, !isDictionaryTerm, !leadingTokenHasInternalUppercase(s) {
            s.replaceSubrange(s.startIndex...s.startIndex, with: String(first).uppercased())
        }
        // NB: this deliberately capitalizes only the FIRST sentence. Capitalizing
        // after every ". " would over-capitalize abbreviations ("e.g. foo",
        // "U.S. government"); a lowercase word after a mid-utterance period on the
        // no-LLM fast path is an accepted minor artifact (the LLM path fixes it).
        if let last = s.last, !".!?".contains(last) {
            s.append(".")
        }
        return s
    }

    private static func leadingTokenHasInternalUppercase(_ s: String) -> Bool {
        let token = s.prefix { !$0.isWhitespace }
        return token.dropFirst().contains { $0.isUppercase }
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
}
