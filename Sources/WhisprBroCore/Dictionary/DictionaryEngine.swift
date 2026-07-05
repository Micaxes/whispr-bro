import Foundation
import os.log

/// Case-aware personal-dictionary substitution (spec §4 DictionaryEngine).
/// Runs AFTER ASR (Parakeet, already punctuated) and BEFORE the LLM cleanup —
/// and on the raw-mode path — so a custom term survives either way. Whole-word/
/// phrase, case-insensitive, longest-source-first, tolerant of the whitespace/
/// comma/case an ASR sprinkles between the words of a multi-word source. The
/// canonical target is emitted VERBATIM (identifiers/proper nouns have fixed
/// casing), even at sentence start.
///
/// Compiled ONCE in init; a dictionary change builds a fresh value (cheap
/// Sendable snapshot, swapped behind the pipeline). Idempotent, so it is safe
/// to call both before and after the LLM.
public struct DictionaryEngine: Sendable {
    public struct Rule: Sendable, Equatable {
        public let from: String   // spoken source, e.g. "get user data"
        public let to: String     // canonical target, e.g. "getUserData"
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    /// Chars an ASR may insert BETWEEN the words of a multi-word source. One-or-
    /// more, so a real boundary is always required (never collapses "get user").
    /// `\s` matches Unicode whitespace; the span normalizer (`tokenize`) uses
    /// `Character.isWhitespace`, which is a superset, so a matched span always
    /// re-normalizes to a known key.
    private static let separator = #"[\s,;:\-–—]+"#
    /// Word char for boundary asserts: Unicode letters, digits, _ (so accented
    /// letters count and a term never fires mid-word).
    private static let wordChar = #"[\p{L}\p{N}_]"#
    /// Punctuation separators (kept in lockstep with `separator`).
    private static let separatorPunctuation: Set<Character> = [",", ";", ":", "-", "–", "—"]
    /// Cap on rules so a pathological hand-edited dictionary can't build a
    /// giant/slow regex.
    private static let maxRules = 1000

    private static let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "dictionary")

    private let regex: NSRegularExpression?
    private let targets: [String: String]   // normalizedSource -> canonical

    public var isEmpty: Bool { regex == nil }

    public init(rules ruleList: [Rule]) {
        let rules = ruleList.count > DictionaryEngine.maxRules
            ? Array(ruleList.prefix(DictionaryEngine.maxRules))
            : ruleList
        if rules.count < ruleList.count {
            DictionaryEngine.log.warning("dictionary capped at \(DictionaryEngine.maxRules) rules")
        }
        var map: [String: String] = [:]
        var prepared: [(tokens: [String], normalized: String)] = []
        for rule in rules {
            let tokens = DictionaryEngine.tokenize(rule.from)
            guard !tokens.isEmpty, !rule.to.isEmpty else { continue }
            let key = tokens.joined(separator: " ")
            if map[key] == nil { prepared.append((tokens, key)) } // dedupe, last target wins
            map[key] = rule.to
        }
        self.targets = map
        guard !prepared.isEmpty else { self.regex = nil; return }

        // Longest-source-first: ICU alternation is leftmost-FIRST, so at a given
        // anchor the earlier alternative wins — list the longer phrase first.
        prepared.sort {
            $0.tokens.count != $1.tokens.count
                ? $0.tokens.count > $1.tokens.count
                : $0.normalized.count > $1.normalized.count
        }
        let sep = DictionaryEngine.separator
        let alts = prepared.map { entry in
            entry.tokens.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: sep)
        }
        let wc = DictionaryEngine.wordChar
        let pattern = "(?<!\(wc))(?:\(alts.joined(separator: "|")))(?!\(wc))"
        do {
            self.regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            // Don't let one bad term silently disable the whole dictionary
            // without a trace — surface it.
            DictionaryEngine.log.error("dictionary regex failed to compile; substitution disabled: \(error.localizedDescription)")
            self.regex = nil
        }
    }

    /// The single definition of "the words of a source", shared by pattern build
    /// and the match-span normalizer so they can never drift.
    private static func tokenize(_ s: String) -> [String] {
        // isWhitespace covers all Unicode whitespace that the regex `\s` matches
        // (and more), so the two stay aligned and a matched span (even one an
        // ASR joined with an NBSP) always re-normalizes to a known key.
        s.lowercased()
            .split { $0.isWhitespace || separatorPunctuation.contains($0) }
            .map(String.init)
    }

    /// Substitute every dictionary term in `text`. Idempotent.
    public func apply(_ text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        // Replace back-to-front so earlier NSRange offsets stay valid.
        var result = text
        for match in matches.reversed() {
            let range = match.range
            let key = DictionaryEngine.tokenize(ns.substring(with: range)).joined(separator: " ")
            guard let target = targets[key], let r = Range(range, in: result) else { continue }
            result.replaceSubrange(r, with: target)
        }
        return result
    }

    /// The canonical targets, for the LLM "preserve these spellings" allowlist.
    public var canonicalTargets: [String] {
        Array(Set(targets.values)).sorted()
    }

    /// Lowercased canonical targets — so the rule-based cleanup can avoid
    /// up-casing a leading dictionary term (e.g. "npm" → "Npm").
    public var lowercasedTargets: Set<String> {
        Set(targets.values.map { $0.lowercased() })
    }
}
