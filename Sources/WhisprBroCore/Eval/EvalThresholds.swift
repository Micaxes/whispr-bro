import Foundation

/// Every constant the content gates compare against (plan §4.5) and every
/// weight the quality scorer blends with (§4.2, §4.4, §5), in ONE place and
/// pinned literal-by-literal by a test — so a "small" tuning move is a
/// visible diff, never a drift, and `EvalRun.scoringVersion` can be bumped
/// deliberately (a change here re-grades every stored run). The gate values
/// are read off the real history rows each gate reproduces (id 70 answered
/// at ratio 2.35; id 54 invented ONE numeral; the over-edit rows dropped
/// 3–6 of 12–40 words); the composite weights follow the damage in that
/// history (7/25 harmful LLM edits vs 0/11 stripper errors — meaning is
/// where the product breaks) and are refit only by the calibration report.
///
/// The live gate is a SUBSET of these rules, and the split lives in
/// `ContentGuard` as WHICH rules run rather than in a second table of
/// numbers: all but three of the values below are read by both profiles. The
/// three exceptions are named in the six-rule gate itself (L3's 12-atom floor
/// and its 0.25 band, L6's 3 novel tokens) and are marked LIVE where they
/// sit. They are not a re-tuning by taste: each is a number the measured
/// 2-column seed run moved, and the run that moved it is in
/// docs/llm-measurement-gate.md.
public enum EvalThresholds {
    // MARK: ANSWERED

    /// Output words per raw word above which a dictation was replied to,
    /// not formatted. Formatting adds punctuation, not words; a reply
    /// restates the question and then answers it.
    public static let answeredLengthRatio = 1.5
    /// Assistant openers. An output whose FIRST token is one of these, when
    /// the raw does not carry it ANYWHERE, is a reply ("Sure, I can
    /// explain…"). Read against the whole raw rather than against a window
    /// of its first two tokens: the cleanup itself moves a late opener to the
    /// front ("um yeah i mean okay lets just ship the build" → "Okay, let's
    /// just ship the build."), and the window called that an assistant.
    public static let answerOpeners: Set<String> = ["sure", "certainly", "here's", "here", "yes", "okay"]
    /// The words that make an utterance a QUESTION to an agent when it opens
    /// with one — wh-words and auxiliaries. An output that keeps neither the
    /// opener nor a question mark, and invents nothing, answered him instead
    /// of formatting him (`ContentGuard.Trigger.answerShape`); 44 of his 70
    /// history rows are prompts or questions to an agent (plan §2), and six
    /// opener words were the only thing standing between one of those answers
    /// and his editor. The auxiliaries that also head an imperative ("do",
    /// "have") are safe here: a formatted imperative keeps its opening word.
    public static let interrogativeOpeners: Set<String> = [
        "what", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
        "should", "would", "will", "shall", "have", "has", "had", "may", "might", "must",
    ]

    // MARK: NEGATED

    /// Words a backchannel "no" may follow and still open the utterance
    /// ("yeah no that's fine", "so no we ship it"): such a "no" is stance,
    /// not polarity, and its loss is an over-edit, never a NEGATED gate.
    public static let discourseOpeners: Set<String> = [
        "yeah", "yes", "okay", "ok", "oh", "well", "so", "and", "but", "right",
    ]
    // MARK: INVENTED

    /// One numeric atom the speaker never said is a fact the model made up
    /// (id 54's invented total). Cardinals, years, decimals and clock times are
    /// canonicalized first, so "26K" for "twenty six K" and "2026" for
    /// "twenty twenty six" are not novel — the clock pair being an anchored
    /// hour plus a TENS-word minute, so "at nine fifteen" stays two atoms
    /// (`NumberCanon.clock`). LIVE relaxes only the RESIDUE of
    /// that canonicalizer: a numeral every digit run of which is witnessed
    /// by number words the speaker actually said ("nineteen oh five" → 1905)
    /// is a normalization, not an invention (`ContentGuard.isReachable`).
    /// The bench keeps the strict rule — it is what pins row 54's invented
    /// total, whose digits nobody spoke.
    public static let inventedNovelNumerals = 1
    /// Novel content tokens (∉ raw ∪ gold ∪ alternates ∪ STOP) that gate on
    /// their own. Below it an ASR-slip fix ("Norbose" → "Norbase", one
    /// token) or a grammar rewording passes the gate and lands at REWORDED.
    public static let inventedNovelTokens = 3
    /// LIVE (L6). Novel content tokens that gate a dictation, on an output of
    /// at least `inventedMinOutWords` atoms. A novel CONTENT token carries a
    /// letter OF ITS OWN: a dash the model punctuated with, or any piece of a
    /// number L5's witness test accepts — a clock time, a year, and equally
    /// "the 9th", "9am", "9:30am" or their spaced twins "the 9 th", "9 am",
    /// "9:30 am", whose suffix atom is the canonicalizer's letters and not
    /// the speaker's (`ContentGuard.witnessedNumbers`) — invents no content.
    /// The bench's number with a length floor under it — the floor is the
    /// relaxation, not the count. At 4 the measured run let `numbers-01` and
    /// `repair-02` through as in-band answers the bench then graded INVENTED,
    /// which is the exact class this rule exists to catch; at 3 they refuse
    /// again, while the two-slip fix that was the reason for leaving 3 still
    /// lands, because the rule that actually refused slip fixes was
    /// `novelShare` and that one is off the live path for good.
    public static let liveInventedNovelTokens = 3
    /// LIVE. The share of an output that has to be novel content for L6 to
    /// gate BELOW `inventedMinOutWords`. A short output with this much
    /// invention in it is not a formatted dictation with slip fixes; it is a
    /// different sentence. Read off the case that motivated it: a five-atom
    /// reply with three novel content words (0.60) that the floor waved
    /// through — the model reciting a few-shot example from its own prompt.
    public static let liveInventedDominantShare = 0.5
    /// Novel share of the output that gates on a long enough output.
    public static let inventedNovelShare = 0.15
    /// Edit distance at which a novel token is the SLIP FIX the system prompt
    /// commissions rather than invention: "there" → "they're" and "to" →
    /// "too" are one edit, "befour" → "before" two. Read off the raw word the
    /// aligner says it replaced, and capped again at half the longer word, so
    /// the licence never covers a short word outright. It discounts the SHARE
    /// rule only — a slip fix still counts toward the three novel tokens that
    /// gate at any length — because two slips in one short utterance (the two
    /// commonest Parakeet classes, one sentence) were a 0.20 share and a
    /// refusal of exactly what the model was told to do.
    public static let inventedSlipDistance = 2
    /// The share rule needs this many output words — on a short output one
    /// token is already 15%.
    public static let inventedMinOutWords = 10

    // MARK: OVER_EDIT_FACT

    /// Output shorter than this share of its reference length is a wholesale
    /// drop (an empty output, a clause thrown away). The BENCH reads it
    /// against `ContentGuard.expectedWords`; live has its own band below.
    public static let overEditLengthRatio = 0.5
    /// LIVE (L3). The same shape, read against the raw atoms the model was
    /// actually given, and at a quarter rather than a half. Half was measured
    /// refusing a legitimate long cued correction at his MEDIAN dictation
    /// length — "i want to meet at the coffee shop on castro street actually
    /// at the office" (15 atoms) → "I want to meet at the office." (7) is
    /// 0.47 — while the catastrophe the rule exists for (22 atoms back as
    /// "Revenue grew.", 0.09) is nowhere near a quarter. A resolved
    /// correction throws away the reparandum, so on this path the band has to
    /// sit under the shortest resolution, not over the longest one.
    public static let liveWholesaleLossRatio = 0.25
    /// LIVE (L3). Raw atoms under which a shrink is never refused. A resolved
    /// self-correction IS a shrink, and the shorter the utterance the likelier
    /// the shrink is that resolution rather than a drop ("meet at the cafe
    /// scratch that at the office" → "Meet at the office." is 4 of 9). Above
    /// it, half an utterance gone is a wholesale loss whatever produced it.
    /// The named cost is a wholesale drop of an 11-atom-or-shorter dictation,
    /// pinned as an accepted row in `OutputGateTests`.
    public static let liveWholesaleLossMinWords = 12
    /// Gold-scored: deleted gold words as a share of gold at which an
    /// over-edit stops being a hedge drop and gates. Read by the quality
    /// scorer, which owns the gold↔out alignment.
    public static let overEditDeletedShare = 0.15
    /// Every ratio trigger needs this many words on its reference side (raw
    /// for the length ratios, gold for the deletion share): below it one
    /// word swings any ratio past its threshold.
    public static let minWordsForRatio = 6

    // MARK: F — auto-formatting (§4.2)

    /// Punctuation (per-class macro-F1), casing (non-initial accuracy) and
    /// terminal-mark weights; renormalized over the components a fixture
    /// can define (a fragment with no non-initial word has no casing term).
    public static let formatPunctuationWeight = 0.5
    public static let formatCasingWeight = 0.3
    public static let formatTerminalWeight = 0.2

    // MARK: M — meaning (§4.4)

    /// Score lost per deleted gold word, as a share of gold: two deletions
    /// in a ten-word gold cost 40 points.
    public static let meaningDeletionCost = 2.0
    /// Score lost per novel token, as a share of gold — invention is worse
    /// than omission (a wrong fact beats a missing one every time).
    public static let meaningNoveltyCost = 3.0
    /// Flat stance penalty per missed `must_keep` span, times its weight
    /// (hedge 2 → 8 points, on top of the deletion share). Deliberate, not
    /// double counting: an annotated span is one he said matters.
    public static let meaningMustKeepPenalty = 4.0
    /// When repairs are scored, M_text keeps this share and the resolved
    /// fraction of the repairs earns the rest (`meaningRepairPoints`).
    public static let meaningTextShare = 0.75
    public static let meaningRepairPoints = 25.0

    // MARK: Composite (§5)

    /// C = 0.30·F + 0.20·Fi + 0.50·M; with Fi undefined the two remaining
    /// weights renormalize (0.375 / 0.625).
    public static let compositeFormatWeight = 0.30
    public static let compositeFillerWeight = 0.20
    public static let compositeMeaningWeight = 0.50

    // MARK: Run status (§5)

    /// OVER_EDIT_FACT verdicts above this share of the scored fixtures fail
    /// the run (one answered / invented / negated row already does).
    public static let failOverEditFactShare = 0.05
    /// Controls (pass-through fixtures) left word-for-word unchanged below
    /// this percentage fail the run.
    public static let failControlsUnchangedPct = 95.0
    /// The latency WARN gate reads p99 over LLM-path fixtures up to this
    /// many words — a 150-word prompt at 1.4 s is not the failure a 12-word
    /// one at 900 ms is.
    public static let warnLatencyMaxWords = 60
    /// Default `--budget-ms` for the WARN gate (docs/llm-measurement-gate.md).
    public static let defaultBudgetMs = 700
    /// The on-device hang timeout; a row over it is flagged
    /// `would_timeout_3s` when the bench measured with a longer one.
    public static let defaultTimeoutMs = 3000

    // MARK: Rating queue (§4.5, §7.1)

    /// `dropped_content` at which an ungated row is still FLAGGED for the
    /// rating queue (`--only flagged` = gated ∨ this): R1 measured that
    /// three dropped content words alone pick out both over-edit history
    /// rows.
    public static let flaggedDroppedContent = 3
}
