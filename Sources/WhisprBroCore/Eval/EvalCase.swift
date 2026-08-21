import Foundation

/// One fixture for `whispr-bench eval`: a raw transcript plus its hand-
/// authored ideal output. `raw` is the dictionary-corrected VERBATIM text —
/// exactly what `HistoryRecord.rawText` stores, so a History row converts to
/// a personal fixture by copy-paste (see docs/llm-measurement-gate.md).
/// `gold` is the POLISHED target (what the LLM stage should produce), so the
/// rule-based path is EXPECTED to score below 1.0 on correction fixtures —
/// the harness is comparative, not pass/fail.
public struct EvalCase: Codable, Sendable {
    public let id: String
    /// Dictionary-corrected verbatim transcript (a History row's rawText).
    public let raw: String
    /// Hand-authored ideal polished text.
    public let gold: String
    /// Free-form tag ("correction — needs standard level", …).
    public let note: String?
    /// Audio fixture path for a future ASR→format eval; the text path
    /// (the only one wired today) ignores it.
    public let audio: String?

    public init(id: String, raw: String, gold: String, note: String? = nil, audio: String? = nil) {
        self.id = id
        self.raw = raw
        self.gold = gold
        self.note = note
        self.audio = audio
    }
}

extension EvalCase {
    /// Built-in seed set, drawn from repo-measured examples (the task-014
    /// tables in docs/llm-measurement-gate.md, the whispr-bench LLM-gate
    /// transcripts) plus targeted deterministic-fix classes. Lexical forms are
    /// kept as dictated ("twelve percent" stays words) so WER measures
    /// formatting, not normalization.
    public static let seeds: [EvalCase] = [
        // docs/llm-measurement-gate.md task-014 table — self-corrections. The
        // last two were echoed unchanged by Qwen2.5; golds are the INTENDED
        // resolutions, so they chart future formatter progress.
        EvalCase(id: "correct-time",
                 raw: "let's meet at 2 actually 3",
                 gold: "Let's meet at 3.",
                 note: "correction — needs standard level"),
        EvalCase(id: "correct-day",
                 raw: "send it monday no wait tuesday",
                 gold: "Send it Tuesday.",
                 note: "correction — needs standard level"),
        EvalCase(id: "cue-is-content",
                 raw: "I actually enjoyed the movie",
                 gold: "I actually enjoyed the movie.",
                 note: "cue word is content — must be preserved"),
        EvalCase(id: "correct-long-span",
                 raw: "so I was thinking we should meet at 2 actually 3 pm",
                 gold: "So I was thinking we should meet at 3 pm.",
                 note: "correction — needs standard level"),
        EvalCase(id: "correct-number",
                 raw: "the total is 50 no sorry 15 dollars",
                 gold: "The total is 15 dollars.",
                 note: "correction — needs standard level"),
        // The premise-check sentence — Parakeet's ACTUAL output for the
        // say-synthesized filler fixture (fillers survive ASR verbatim).
        EvalCase(id: "premise-fillers",
                 raw: "Um, so I was uh thinking that we should uh meet at 2, uh, actually 3 p.m. Um, yeah.",
                 gold: "So I was thinking that we should meet at 3 p.m. Yeah.",
                 note: "fillers + correction — needs standard level"),
        // The four whispr-bench LLM-gate transcripts, with authored golds.
        EvalCase(id: "bench-standup",
                 raw: "hey can you um send me the the updated design doc before standup tomorrow morning thanks",
                 gold: "Hey, can you send me the updated design doc before standup tomorrow morning? Thanks."),
        EvalCase(id: "bench-quarterly",
                 raw: "so the quarterly report shows revenue grew twelve percent but we need to double check the churn numbers before presenting them to the board on thursday",
                 gold: "So the quarterly report shows revenue grew twelve percent, but we need to double check the churn numbers before presenting them to the board on Thursday."),
        EvalCase(id: "bench-meeting",
                 raw: "let's move the meeting to three pm and uh remind me to book the flight to berlin i think it's cheaper if we fly out on a tuesday",
                 gold: "Let's move the meeting to three pm and remind me to book the flight to Berlin. I think it's cheaper if we fly out on a Tuesday."),
        EvalCase(id: "bench-code",
                 raw: "the function takes a user id and returns a promise that resolves to the user object or null if not found make sure to handle the error case",
                 gold: "The function takes a user id and returns a promise that resolves to the user object or null if not found. Make sure to handle the error case."),
        // Deterministic-fix classes (TextFormatter.repairPunctuation + the
        // mid-utterance capitalizer) — regression pins for the rule-based path.
        EvalCase(id: "cap-mid",
                 raw: "i sent the doc. please review it",
                 gold: "I sent the doc. Please review it.",
                 note: "mid-utterance capitalization"),
        EvalCase(id: "abbrev-eg",
                 raw: "we use e.g. npm for packages",
                 gold: "We use e.g. npm for packages.",
                 note: "abbreviation guard — npm must stay lowercase"),
        EvalCase(id: "abbrev-us",
                 raw: "the U.S. office is closed. bring your badge",
                 gold: "The U.S. office is closed. Bring your badge.",
                 note: "dotted initialism guard + a real boundary after it"),
        EvalCase(id: "comma-leading",
                 raw: ", so anyway let's ship it",
                 gold: "So anyway, let's ship it.",
                 note: "leading comma residue"),
        EvalCase(id: "comma-double",
                 raw: "eggs, , milk and bread",
                 gold: "Eggs, milk and bread.",
                 note: "double-comma residue"),
        EvalCase(id: "comma-terminal",
                 raw: "that's the plan, .",
                 gold: "That's the plan.",
                 note: "comma before terminal"),
        EvalCase(id: "punct-double",
                 raw: "is it done?. okay.. let's go",
                 gold: "Is it done? Okay. Let's go.",
                 note: "doubled / mixed terminal punctuation"),
    ]
}
