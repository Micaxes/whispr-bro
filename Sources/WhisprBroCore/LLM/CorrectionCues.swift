import Foundation

/// The self-correction cue lexicon (task-014 spec §5c, §6.2). Single source of
/// truth so the LLM prompt clause and the fast-path bypass detector can never
/// drift (spec AC #14). Kept here rather than duplicated as string literals in
/// PromptBuilder and TextFormatter.
public enum CorrectionCues {
    /// Cue phrases the prompt clause names as introducing a self-correction.
    /// Human-readable form (as they appear in the instruction).
    public static let promptPhrases = [
        "actually", "no wait", "I mean", "scratch that", "or rather", "sorry",
    ]

    /// The stricter subset the deterministic fast-path bypass keys on — STRONG,
    /// unambiguous mid-utterance correction cues. A subset of `promptPhrases`
    /// (asserted by a test). Ambiguous single-word cues that are common in
    /// innocent short utterances are deliberately EXCLUDED — "actually" (an
    /// adverb: "I actually enjoyed it"), "sorry", and bare "rather" — so a short
    /// non-correction is not routed to the 1.5B (latency + over-edit risk). The
    /// cost is that a short "actually"-cued correction stays on the fast path
    /// unresolved, which the spec (§5c) names as the acceptable safe failure.
    public static let bypassPhrases = [
        "scratch that", "no wait", "i mean", "or rather",
    ]

    /// Fast-path bypass heuristic (spec §5c): true only when a bypass cue phrase
    /// appears **not** at the very start of the utterance **and** is followed by
    /// at least one more word — a cue *plus a plausible replacement*, not a lone
    /// cue or a sentence-opener. Every occurrence is checked (a leading opener
    /// must not mask a later real correction). Conservative: a false negative
    /// just leaves a short correction on the fast path, the safe failure.
    public static func plausibleCorrection(in text: String) -> Bool {
        // Commas → spaces, then collapse runs, so a comma-split cue ("no, wait")
        // still matches the single-space-bounded phrase.
        var lower = " " + text.lowercased().replacingOccurrences(of: ",", with: " ") + " "
        lower = lower.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        for phrase in bypassPhrases {
            let needle = " " + phrase + " "
            var searchStart = lower.startIndex
            while let r = lower.range(of: needle, range: searchStart..<lower.endIndex) {
                let before = lower[lower.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let after = lower[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !before.isEmpty && !after.isEmpty { return true }
                searchStart = lower.index(after: r.lowerBound)
            }
        }
        return false
    }
}
