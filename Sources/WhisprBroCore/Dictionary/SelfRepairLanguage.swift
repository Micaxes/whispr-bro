import Foundation
import NaturalLanguage

/// The two NaturalLanguage reads `SelfRepair` makes, both on-device:
///
///  - the **language gate** — `NLLanguageRecognizer`'s top hypothesis for the
///    whole dictation. A text it calls non-English with p ≥ 0.9 is left as it
///    was (the word lists are English, and a repeat or a "no" means something
///    else in another language);
///  - the **lexical class** of each whitespace token — `NLTagger`
///    (`.lexicalClass`), read ONLY by R4: its slot test, so a cued swap
///    ("bigger, sorry, smaller") fires only between words of one class, and
///    [T21] whether the words around a mid-sentence "scratch that" hold a
///    verb and end in a noun.
///
/// Both are the exact calls of the reference's helper (same scheme, unit,
/// options, the same token mapping and the same p rounding), so the port's
/// tags and verdicts are the reference's. Neither runs unless a rule needs
/// it: the tagger only when a cued swap reaches the slot test or T21; the
/// recognizer only on a text of 4+ tokens, when a rule fired or before the
/// tagger runs (a text the gate would hand back is never tagged). The first
/// call of each loads a model (measured: ~15 ms recognizer, ~55 ms tagger,
/// M2 Pro), so the app pays it at launch, off the main thread
/// (`SelfRepair.prewarm`).
enum SelfRepairLanguage {
    /// The gate closes at this probability or above…
    static let gateProbability = 0.9
    /// …and only on a text of at least this many tokens (a short one says
    /// too little to be sure of).
    static let gateMinimumTokens = 4

    /// NLTagger is not thread-safe; one instance, reused under a lock, like
    /// the reference helper reusing one tagger for every line.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        let recognizer = NLLanguageRecognizer()
    }
    private static let shared = Shared()
    private static let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

    /// The top language hypothesis and its probability, rounded to three
    /// decimals as the reference helper reports it (so a 0.8996 reads 0.9 in
    /// both). `("", 0)` when the recognizer has no hypothesis.
    static func dominantLanguage(_ text: String) -> (code: String, probability: Double) {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        let recognizer = shared.recognizer
        recognizer.reset()
        recognizer.processString(text)
        let top = recognizer.languageHypotheses(withMaximum: 1).first
        recognizer.reset()   // hold no dictation text between calls
        guard let top else { return ("", 0) }
        return (top.key.rawValue, (top.value * 1000).rounded() / 1000)
    }

    /// Whether the gate leaves this text alone: `tokenCount` ≥ 4 and the
    /// recognizer is ≥ 90% sure it is a language other than English.
    static func gateCloses(_ text: String, tokenCount: Int) -> Bool {
        guard tokenCount >= gateMinimumTokens else { return false }
        let (code, probability) = dominantLanguage(text)
        return !code.isEmpty && code != "en" && probability >= gateProbability
    }

    /// One lexical-class tag per whitespace token ("" for a token with no
    /// word in it): the class of the FIRST word NLTagger finds inside the
    /// token ("Thursday," → Noun), and a word that spans several tokens
    /// (`.joinNames`) tags each of them. Tokens here are split on
    /// `Character.isWhitespace`, exactly as the reference helper splits them;
    /// the caller drops the tags when that count differs from its own.
    static func lexicalClasses(_ text: String) -> [String] {
        var ranges: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            if i >= text.endIndex { break }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            ranges.append(i..<j)
            i = j
        }
        var tags = [String](repeating: "", count: ranges.count)
        shared.lock.lock()
        defer { shared.lock.unlock() }
        let tagger = shared.tagger
        tagger.string = text
        var k = 0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lexicalClass, options: options) { tag, r in
            while k < ranges.count, ranges[k].upperBound <= r.lowerBound { k += 1 }
            if k < ranges.count, ranges[k].lowerBound <= r.lowerBound, r.lowerBound < ranges[k].upperBound,
               tags[k].isEmpty {
                tags[k] = tag?.rawValue ?? ""
            }
            var m = k + 1
            while m < ranges.count, ranges[m].lowerBound < r.upperBound {
                if tags[m].isEmpty { tags[m] = tag?.rawValue ?? "" }
                m += 1
            }
            return true
        }
        tagger.string = nil   // hold no dictation text between calls
        return tags
    }

    /// Load both models now, so the first dictation that needs one does not
    /// pay for it. Safe from any thread.
    static func prewarm() {
        _ = dominantLanguage("Move the review to Friday, no wait, Saturday morning.")
        _ = lexicalClasses("Move the review to Friday, no wait, Saturday morning.")
    }
}
