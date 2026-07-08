import Foundation
import os.log

/// Deterministic filler-word remover (task-014 spec §5a, §5f). The Auto-Clean
/// stage's non-LLM half: strips semantically empty filled pauses (`um`, `uh`, …)
/// and — optionally — collapses stutter runs of function words (`I I I` → `I`).
///
/// Runs AFTER the dictionary and BEFORE the LLM (and on the raw/fast-path
/// routes, where the LLM never runs), so fillers are removed on every path.
/// Idempotent. A `Sendable` snapshot compiled once, like `DictionaryEngine`;
/// custom tokens are regex-escaped and the set is capped, and a compile failure
/// degrades to a no-op (never throws).
///
/// It deliberately does NOT resolve self-corrections — reparandum boundaries are
/// not a fixed pattern (that is the LLM clause's job, spec §5b).
public struct FillerStripper: Sendable {
    /// The narrow default set: unambiguous filled pauses only.
    public static let coreFillers = ["um", "uh", "er", "erm", "uhm"]
    /// Opt-in only (reachable solely by listing them in `extra`): interjections /
    /// discourse markers that carry meaning, so never in the default set.
    public static let extendedFillers = ["ah", "eh", "oh", "mm"]

    /// The narrow default filled-pause set per language. Kept deliberately small
    /// and unambiguous (no discourse markers that are also real words, e.g. no
    /// Spanish "este") so a filler strip never eats meaning; the LLM handles the
    /// ambiguous rest. It/Es are space-delimited like English, so the existing
    /// boundary regex works unchanged.
    public static func coreFillers(for language: DictationLanguage) -> [String] {
        switch language {
        case .english: return coreFillers
        case .italian: return ["ehm", "eh", "ehmm", "mmh"]
        // "este"/"esto" are common Spanish muletillas but also real demonstratives
        // ("este libro") — too risky to strip deterministically, so left to the LLM.
        case .spanish: return ["eh", "em", "ehm"]
        }
    }

    /// Function words safe to de-stutter. Content words (`very`, `no`, `black`)
    /// are excluded so emphasis/rhetorical repeats and lists survive (spec §2c),
    /// AND words that legitimately double are excluded: `is` ("what it is is a
    /// problem"), `so` ("so-so"), `that` ("the fact that that happened"), `this`,
    /// and the prepositions/conjunctions (`in`, `on`, `for`, `but`) that recur
    /// in normal speech. Only pronouns + articles + `and` remain — where a doubled
    /// token is almost always a stutter.
    private static let stutterCollapsible: Set<String> = [
        "i", "a", "an", "the", "we", "you", "he", "she", "they", "it", "and", "to",
    ]

    /// Word char for boundary asserts — INCLUDES the hyphen so a filler never
    /// fires inside a hyphenated word, which structurally protects backchannels
    /// (`uh-huh`, `mm-hmm`) and interjections (`uh-oh`) without an explicit list.
    private static let wordChar = #"[\p{L}\p{N}_-]"#
    private static let maxTokens = 200
    private static let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "filler")

    /// Group 1 captures the filler token itself (for the dictionary-protect check).
    private let regex: NSRegularExpression?
    private let stutterRegex: NSRegularExpression?
    private let collapseStutters: Bool

    public var isEmpty: Bool { regex == nil }

    /// - Parameters:
    ///   - core: the base filled-pause set (defaults to the English set; pass a
    ///     per-language set via `FillerStripper.coreFillers(for:)`).
    ///   - extra: tokens appended to the core set (e.g. the opt-in extended set).
    ///   - disabled: tokens removed from the core set (a name/brand collision).
    ///   - collapseStutters: collapse function-word runs (`I I I` → `I`). Only
    ///     English function words collapse (the set is English), so this is a safe
    ///     no-op for other languages until per-language sets are added.
    public init(
        core: [String] = FillerStripper.coreFillers,
        extra: [String] = [], disabled: [String] = [], collapseStutters: Bool = true
    ) {
        self.collapseStutters = collapseStutters

        let disabledSet = Set(disabled.map { $0.lowercased() })
        var tokens: [String] = []
        var seen = Set<String>()
        for t in (core + extra) {
            let norm = t.trimmingCharacters(in: .whitespaces).lowercased()
            guard !norm.isEmpty, !disabledSet.contains(norm), !seen.contains(norm) else { continue }
            seen.insert(norm); tokens.append(norm)
        }
        if tokens.count > Self.maxTokens {
            Self.log.warning("filler set capped at \(Self.maxTokens) tokens")
            tokens = Array(tokens.prefix(Self.maxTokens))
        }

        // Longest-first so a multi-char token wins at a shared anchor (ICU
        // alternation is leftmost-first). Each token regex-escaped (§5f).
        let alts = tokens.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let wc = Self.wordChar
        // Match ONLY the boundary-anchored filler token — never the surrounding
        // whitespace or commas. Absorbing a comma would delete a list-separator
        // ("eggs, uh, milk" → "eggs milk"); instead we remove just the token and
        // let normalizeWhitespace fold the leftover doubled comma ("eggs, , milk"
        // → "eggs, milk") and doubled space. Bias-to-keep: a stray comma beats
        // lost list delimiters.
        let pattern = tokens.isEmpty ? nil
            : #"(?<!"# + wc + #")("# + alts + #")(?!"# + wc + #")"#
        self.regex = Self.compile(pattern, caseInsensitive: true)

        // Adjacent identical function-word run: `\b(word)( +\1\b)+`. Membership
        // in `stutterCollapsible` is checked per match so only function words
        // collapse (emphasis/list repeats of content words are preserved).
        self.stutterRegex = collapseStutters
            ? Self.compile(#"(?<!\S)([\p{L}']+)((?:[ \t]+\1)+)(?!\S)"#, caseInsensitive: true)
            : nil
    }

    private static func compile(_ pattern: String?, caseInsensitive: Bool) -> NSRegularExpression? {
        guard let pattern else { return nil }
        do { return try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) }
        catch {
            log.error("filler regex failed to compile; stage disabled: \(error.localizedDescription)")
            return nil
        }
    }

    /// Remove fillers (and, if enabled, collapse function-word stutters).
    /// `protecting` = lowercased tokens that must never be stripped even if they
    /// collide with a filler (e.g. a dictionary acronym `UM`). Idempotent.
    /// A Private-Use sentinel that marks a removed-filler gap, so comma/space
    /// repair touches ONLY removal sites — never a legitimate comma elsewhere
    /// (a dictation with no fillers is left byte-for-byte alone except whitespace).
    private static let gap: Character = "\u{E000}"

    public func strip(_ text: String, protecting: Set<String> = []) -> String {
        var out = text
        var removedAny = false
        if let regex, !out.isEmpty {
            let ns = out as NSString
            let quoted = Self.quotedRanges(in: ns)
            let matches = regex.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            // Back-to-front so earlier offsets stay valid.
            for match in matches.reversed() {
                let range = match.range(at: 1)
                guard range.location != NSNotFound else { continue }
                let token = ns.substring(with: range)
                let lower = token.lowercased()
                if protecting.contains(lower) { continue }               // dictionary term
                // An ALL-CAPS multi-letter token is almost always an initialism
                // (ER, UM), not a filled pause — keep it (spec §8 edge case).
                if token == token.uppercased() && token != lower { continue }
                // Never touch a filler inside a quoted span (dictated quote).
                if Self.inQuote(range.location, quoted) { continue }
                guard let r = Range(range, in: out) else { continue }
                out.replaceSubrange(r, with: String(Self.gap))   // mark the gap
                removedAny = true
            }
        }
        if removedAny { out = Self.repairGaps(out) }
        out = Self.normalizeWhitespace(out)
        if let stutterRegex { out = Self.collapseRuns(out, stutterRegex) }
        return out
    }

    /// Fold each removed-filler gap (and only those) into clean text: a filler
    /// bracketed by commas collapses to a single comma ("eggs, ⎵, milk" →
    /// "eggs, milk"); any other gap (plus at most one directly-adjacent comma)
    /// becomes a single space; leftover gaps are dropped.
    private static func repairGaps(_ text: String) -> String {
        let g = String(gap)
        var s = text
        // filler set off by commas on BOTH sides → keep one comma (list-safe).
        s = s.replacingOccurrences(
            of: #"[ \t]*,[ \t]*"# + g + #"[ \t]*,[ \t]*"#, with: ", ", options: .regularExpression)
        // any other gap, absorbing at most one adjacent comma → a single space.
        s = s.replacingOccurrences(
            of: #"[ \t]*,?[ \t]*"# + g + #"[ \t]*,?[ \t]*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: g, with: "")   // safety: any stray sentinel
        return s
    }

    /// Does `range` (start) fall inside any quoted span of `ns`?
    private static func inQuote(_ location: Int, _ quoted: [NSRange]) -> Bool {
        quoted.contains { NSLocationInRange(location, $0) }
    }

    /// Ranges of double-quoted spans (paired `"`), so fillers inside a dictated
    /// quote are preserved. Unbalanced trailing quote is ignored.
    private static func quotedRanges(in ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start: Int?
        for i in 0..<ns.length where ns.character(at: i) == 0x22 { // ASCII "
            if let s = start { ranges.append(NSRange(location: s, length: i - s + 1)); start = nil }
            else { start = i }
        }
        return ranges
    }

    /// Whitespace-only normalization — SAFE to run on any input (it never
    /// deletes a comma; comma repair is localized to gaps in `repairGaps`).
    private static func normalizeWhitespace(_ text: String) -> String {
        var s = text
        // space(s)/tab(s) before closing punctuation → none
        s = s.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        // runs of spaces/tabs → one (newlines preserved)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        // trailing spaces/tabs at the end of any line (a removed line-final filler)
        s = s.replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
        // leading spaces at the start of the string or any line
        s = s.replacingOccurrences(of: #"(?m)^[ \t]+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseRuns(_ text: String, _ regex: NSRegularExpression) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let quoted = quotedRanges(in: ns)   // honor dictated quotes, same as filler removal
        var out = text
        for match in matches.reversed() {
            let firstRange = match.range(at: 1)
            guard firstRange.location != NSNotFound else { continue }
            if inQuote(match.range.location, quoted) { continue }   // don't touch a quoted stutter
            let word = ns.substring(with: firstRange)
            guard stutterCollapsible.contains(word.lowercased()) else { continue } // content word → keep
            guard let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: word) // keep one occurrence, verbatim casing of the first
        }
        return out
    }
}
