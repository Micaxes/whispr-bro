import Foundation

/// Per-app output-register directives (spec §4 StyleRules). Each is a short
/// line appended to the LLM system prompt so the same spoken sentence comes out
/// casual in Slack, formal in Mail, code-literal in an IDE, etc.
///
/// Every directive anchors register to punctuation/capitalization and repeats
/// the words-preserving rule — a 1.5B model told merely to be "formal" will
/// paraphrase, so the anti-rewrite clause is load-bearing.
///
/// Structured as an overridable map so task-011's config mirror can let the
/// user tweak per-category (or per-bundle-id) rules.
public struct StyleRules: Sendable {
    private var directives: [AppCategory: String]

    public init(directives: [AppCategory: String] = StyleRules.defaults) {
        self.directives = directives
    }

    public func directive(for category: AppCategory) -> String {
        directives[category] ?? directives[.unknown] ?? StyleRules.defaults[.unknown]!
    }

    public mutating func setDirective(_ directive: String, for category: AppCategory) {
        directives[category] = directive
    }

    public static let defaults: [AppCategory: String] = [
        .unknown: "Register: standard written text — sentence case and normal "
            + "punctuation. Keep the exact words.",
        .messaging: "Register: casual instant message — relaxed, light "
            + "punctuation; keep contractions and any emoji, and a lowercase "
            + "start is fine. Do not formalize or reword — the words stay "
            + "exactly as spoken.",
        .mail: "Register: formal written prose — proper sentence "
            + "capitalization and complete terminal punctuation, no emoji or "
            + "slang. Keep the exact words: do not expand contractions or swap "
            + "in fancier vocabulary.",
        .browser: "Register: standard written text — sentence case and normal "
            + "punctuation. Keep the exact words.",
        .ide: "Register: code editor. Preserve identifiers, camelCase/"
            + "snake_case, casing, operators, brackets, paths and symbols "
            + "EXACTLY. Keep every word in the same order — do not shorten, "
            + "reorder, or reword anything; only fix punctuation in plain "
            + "English parts.",
        .terminal: "Register: shell command — output verbatim except an "
            + "obvious speech-to-text word error. Do not capitalize, do not add "
            + "periods or punctuation, and preserve flags, dashes, paths and "
            + "casing exactly as spoken.",
        .notes: "Register: concise notes — sentence case and basic "
            + "punctuation. Keep every word in the same order — do not shorten, "
            + "summarize, drop, or reword anything.",
    ]
}
