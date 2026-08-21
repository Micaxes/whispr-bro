import Foundation

/// Reference-based scoring of one formatter output against a hand-authored
/// gold transcript (docs/llm-measurement-gate.md: quality claims need a
/// measured basis). Three INDEPENDENT axes so a formatter change reads
/// precisely:
///  - **WER** over normalized words (lowercased, punctuation stripped) —
///    punctuation/case-blind by construction, so it moves only when a stage
///    drops/adds/rewrites WORDS (e.g. resolves a self-correction);
///  - **punctuation P/R/F1** over marks keyed by the aligned gold word —
///    moves only on punctuation edits;
///  - **case accuracy** over aligned equal words — moves only on casing edits.
/// Pure string math, zero dependencies, deterministic. Lives in WhisprBroCore
/// (not whispr-bench) so the test target can pin it.
public struct TranscriptScore: Sendable {
    /// Word-level Levenshtein S+D+I over normalized tokens.
    public let wordErrors: Int
    public let goldWordCount: Int
    /// Marks (`. , ! ? ; : ¿ ¡`) attached to the RIGHT gold word (multiset).
    public let punctMatched: Int
    public let punctInHypothesis: Int
    public let punctInGold: Int
    /// Aligned equal-word pairs whose original casing matches exactly.
    public let caseMatched: Int
    public let caseComparable: Int

    /// (S+D+I) / gold words. An empty gold scores 0 only for an empty
    /// hypothesis (any insertion against nothing is a full miss).
    public var wer: Double {
        goldWordCount == 0
            ? (wordErrors == 0 ? 0 : 1)
            : Double(wordErrors) / Double(goldWordCount)
    }
    /// Vacuous sides score 1 (no marks emitted → no false positives; no marks
    /// expected → nothing missed) so the F1 degrades from the guilty side only.
    public var punctPrecision: Double {
        punctInHypothesis == 0 ? 1 : Double(punctMatched) / Double(punctInHypothesis)
    }
    public var punctRecall: Double {
        punctInGold == 0 ? 1 : Double(punctMatched) / Double(punctInGold)
    }
    public var punctF1: Double {
        let p = punctPrecision, r = punctRecall
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }
    public var caseAccuracy: Double {
        caseComparable == 0 ? 1 : Double(caseMatched) / Double(caseComparable)
    }

    /// Micro-average across fixtures: raw counts summed, ratios recomputed —
    /// so a long fixture weighs more than a three-word one, matching how the
    /// stage would feel in aggregate use.
    public static func aggregate(_ scores: [TranscriptScore]) -> TranscriptScore {
        TranscriptScore(
            wordErrors: scores.reduce(0) { $0 + $1.wordErrors },
            goldWordCount: scores.reduce(0) { $0 + $1.goldWordCount },
            punctMatched: scores.reduce(0) { $0 + $1.punctMatched },
            punctInHypothesis: scores.reduce(0) { $0 + $1.punctInHypothesis },
            punctInGold: scores.reduce(0) { $0 + $1.punctInGold },
            caseMatched: scores.reduce(0) { $0 + $1.caseMatched },
            caseComparable: scores.reduce(0) { $0 + $1.caseComparable })
    }

    // MARK: - Scoring

    public static func score(hypothesis: String, gold: String) -> TranscriptScore {
        let (goldTokens, goldOrphans) = tokenize(gold)
        let (hypTokens, hypOrphans) = tokenize(hypothesis)
        let (errors, pairs) = align(goldTokens, hypTokens)

        // Marks in gold/hypothesis, keyed by the (aligned) gold word index —
        // a multiset min per aligned pair counts a mark only when it sits on
        // the RIGHT word. Insertions/deletions and orphan marks (a chunk with
        // no word core, e.g. the middle of "eggs, , milk") can never match.
        var matched = 0
        var comparable = 0, caseHits = 0
        for (gi, hj) in pairs {
            matched += multisetOverlap(goldTokens[gi].marks, hypTokens[hj].marks)
            if goldTokens[gi].normalized == hypTokens[hj].normalized {
                comparable += 1
                if goldTokens[gi].cased == hypTokens[hj].cased { caseHits += 1 }
            }
        }
        return TranscriptScore(
            wordErrors: errors,
            goldWordCount: goldTokens.count,
            punctMatched: matched,
            punctInHypothesis: hypTokens.reduce(hypOrphans) { $0 + $1.marks.count },
            punctInGold: goldTokens.reduce(goldOrphans) { $0 + $1.marks.count },
            caseMatched: caseHits,
            caseComparable: comparable)
    }

    // MARK: - Tokenization

    /// One whitespace-delimited word with its boundary punctuation pulled off.
    private struct Token {
        var normalized: String   // lowercased word core (see `wordChar` note)
        var cased: String        // word core with original casing
        var marks: [Character]   // leading + trailing marks from `scoredMarks`
    }

    private static let scoredMarks: Set<Character> = [".", ",", "!", "?", ";", ":", "¿", "¡"]

    /// In-word characters kept in the normalized form — letters/digits plus
    /// apostrophe/hyphen/underscore, consistent with FillerStripper's
    /// `wordChar` (so "it's" ≠ "its" and "top-notch" stays one token).
    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "-" || c == "_"
    }

    /// Split on whitespace; peel boundary marks off each chunk. Non-scored
    /// boundary symbols (quotes, brackets, dashes, …) are TRANSPARENT to the
    /// peel — dropped, but the peel continues past them — so a mark next to
    /// one still counts: «plan."» carries its period. A chunk with
    /// no word core (a stray "," between words) attaches its marks to the
    /// previous word — or is returned in the orphan count when there is none —
    /// so residue punctuation still counts against precision/recall.
    private static func tokenize(_ text: String) -> (tokens: [Token], orphanMarks: Int) {
        var tokens: [Token] = []
        var orphans = 0
        for chunk in text.split(whereSeparator: \.isWhitespace) {
            var chars = Array(chunk).map { $0 == "’" ? Character("'") : $0 }
            var marks: [Character] = []
            while let f = chars.first, !isWordChar(f) {
                if scoredMarks.contains(f) { marks.append(f) }
                chars.removeFirst()
            }
            while let l = chars.last, !isWordChar(l) {
                if scoredMarks.contains(l) { marks.append(l) }
                chars.removeLast()
            }
            let cased = String(chars.filter { isWordChar($0) })
            if cased.isEmpty {
                if tokens.isEmpty { orphans += marks.count }
                else { tokens[tokens.count - 1].marks += marks }
                continue
            }
            tokens.append(Token(normalized: cased.lowercased(), cased: cased, marks: marks))
        }
        return (tokens, orphans)
    }

    /// Elements of `a` also present in `b`, as multisets (min of the counts).
    private static func multisetOverlap(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for m in a { counts[m, default: 0] += 1 }
        var overlap = 0
        for m in b where (counts[m] ?? 0) > 0 {
            counts[m]! -= 1
            overlap += 1
        }
        return overlap
    }

    // MARK: - Alignment

    /// Word-level Levenshtein with backtrace (fixtures are sentence-sized, so
    /// the O(n·m) table is trivial). Returns the edit count and the aligned
    /// (gold, hypothesis) index pairs (matches AND substitutions).
    private static func align(_ gold: [Token], _ hyp: [Token]) -> (errors: Int, pairs: [(Int, Int)]) {
        var dp = Array(repeating: Array(repeating: 0, count: hyp.count + 1), count: gold.count + 1)
        for i in 0...gold.count { dp[i][0] = i }
        for j in 0...hyp.count { dp[0][j] = j }
        if !gold.isEmpty && !hyp.isEmpty {
            for i in 1...gold.count {
                for j in 1...hyp.count {
                    let sub = gold[i - 1].normalized == hyp[j - 1].normalized ? 0 : 1
                    dp[i][j] = min(dp[i - 1][j - 1] + sub, dp[i - 1][j] + 1, dp[i][j - 1] + 1)
                }
            }
        }
        // Backtrace, preferring the diagonal so a substitution beats a
        // delete+insert pair of the same cost (keeps punctuation keyed).
        var pairs: [(Int, Int)] = []
        var i = gold.count, j = hyp.count
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               dp[i][j] == dp[i - 1][j - 1] + (gold[i - 1].normalized == hyp[j - 1].normalized ? 0 : 1) {
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                i -= 1   // deletion (gold word the hypothesis dropped)
            } else {
                j -= 1   // insertion (hypothesis word gold doesn't have)
            }
        }
        return (dp[gold.count][hyp.count], pairs)
    }
}
