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
        let (goldTokens, goldOrphans) = Align.tokenize(gold)
        let (hypTokens, hypOrphans) = Align.tokenize(hypothesis)
        // Keyed on the normalized word, NOT the canonical one: an ITN rewrite
        // ("fifty-four" → "54") is still a word edit on this continuity axis;
        // forgiving it is the quality scorer's job.
        let alignment = Align.align(goldTokens, hypTokens, by: \.normalized)

        // Marks in gold/hypothesis, keyed by the (aligned) gold word index —
        // a multiset min per aligned pair counts a mark only when it sits on
        // the RIGHT word. Insertions/deletions and orphan marks (a chunk with
        // no word core, e.g. the middle of "eggs, , milk") can never match.
        var matched = 0
        var comparable = 0, caseHits = 0
        for (gi, hj) in alignment.pairs {
            matched += multisetOverlap(goldTokens[gi].marks, hypTokens[hj].marks)
            if goldTokens[gi].normalized == hypTokens[hj].normalized {
                comparable += 1
                if goldTokens[gi].cased == hypTokens[hj].cased { caseHits += 1 }
            }
        }
        return TranscriptScore(
            wordErrors: alignment.errors,
            goldWordCount: goldTokens.count,
            punctMatched: matched,
            punctInHypothesis: hypTokens.reduce(hypOrphans.count) { $0 + $1.marks.count },
            punctInGold: goldTokens.reduce(goldOrphans.count) { $0 + $1.marks.count },
            caseMatched: caseHits,
            caseComparable: comparable)
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
}
