import Foundation

/// Deterministic, deletion-only removal of the self-repairs a speaker makes
/// mid-dictation — "the the", "sen sentences", "on Thursday, no wait,
/// Friday", "Let's use Redis. Scratch that, let's use Postgres." — with no
/// model, in well under a millisecond.
///
/// **Why rules and not the LLM.** Measured on the maintainer's own labelled
/// dictations (docs/self-repair.md §5): the shipping path, 1.5B formatter
/// and all, fixed at most 8 of 33 repairs and damaged words in 3 dictations;
/// these rules fix 23 of 33 with zero damage and zero violations of 112
/// protected look-alike spans ("the fact that that happened", "C plus
/// plus", "Will will review it"). The formatter run after them fixed none
/// of the other ten.
///
/// **The contract.** The output is the input with whole tokens deleted, the
/// kept ones joined by single spaces, byte-identical except for two case
/// fixes (`render`). Nothing quoted is ever deleted or matched; a dictionary
/// term is never taken for a fragment; a deletion never leaves a bracket or
/// quotation mark without its partner. Numbers: R2's and R2B's restarts,
/// R3's fragments and R4's word swap never take one; a number goes as a
/// repeat only across a filler (R1) and as a cued numeric correction (R5);
/// what is taken back whole goes with its numbers — R4's "scratch that"
/// clause and its restart from the onset, the noun phrase a bare one
/// replaces after a mid-sentence "scratch that" (T21: "we need 5 servers,
/// scratch that, a cluster"), R4S's sentence; and an inflected restart
/// (R1B) can take a number word ("two hundred hundreds"). A spoken
/// layout marker ("bullet point", "new line") is a boundary no rule reads,
/// deletes or spans (T16). A repair inside words he presents as words —
/// reported ("the bug report says it costs 30, sorry, 40"), quoted,
/// exemplified, specified ("the input is Friday, no wait, Saturday") or
/// labelled — is kept (T17), as far as a frame around the words shows it:
/// that is a heuristic over the words, and a description no frame matches
/// is still repaired (docs/self-repair.md §3, §7). On every eval set and the
/// written-English corpus its output is a fixed point (docs/self-repair.md
/// §4 has where that can fail).
///
/// **The rules**, applied in passes (up to 4, until one fires nothing), each
/// pass running R4S, R5, R4, R2, R2B, R3, R1, R1B in that order:
///
///  - R1 repetition — "we went over over these", "ten, uh, ten runs";
///  - R1B inflected restart — "two more server servers";
///  - R2 restart — "I told them to I told you to stop";
///  - R2B pronoun restart — "I we should leave";
///  - R3 fragment — "check the lo logs", "the sto, the stock room";
///  - R4 cued swap — "Thursday, no wait, Friday";
///  - R4S sentence retraction — "… Scratch that, …";
///  - R5 cued numeric restart — "about 3, sorry, 4 seconds".
///
/// Each carries guards against the look-alikes that are content (`Guard`,
/// T1–T26, no T12). This is a port of the reference implementation
/// (`rules.py` v11, kept with the private eval); `whispr-bench repairs
/// --compare` checks it row for row (docs/self-repair.md has the numbers and
/// the known gaps).
///
/// English only: the word lists are English, and a closed `SelfRepairLanguage`
/// gate leaves a dictation the recognizer is sure is another language alone.
public struct SelfRepair: Sendable {

    public enum Rule: String, CaseIterable, Sendable {
        case r1 = "R1", r1b = "R1B", r2 = "R2", r2b = "R2B", r3 = "R3", r4 = "R4", r4s = "R4S", r5 = "R5"
    }

    /// The guards against content that looks like a repair, named as in the
    /// reference. All are on in the product; switching one off exists only to
    /// measure what it holds back (`whispr-bench repairs --drop-guards`).
    public enum Guard: String, CaseIterable, Sendable {
        /// R1: "Does the fix fix the crash?" — noun, then the bare verb.
        case t1 = "T1"
        /// R1: "whether Will will" — a name, then the word it spells.
        case t2a = "T2a"
        /// R1: "Drew drew it", "Will will send" opening a sentence.
        case t2b = "T2b"
        /// R1: fixed doubles ("win win", "cous cous", "same same but different"),
        /// other languages' ("tanti tanti", "lomi lomi"), and any double of a
        /// word that is not ASCII ("già già").
        case t3 = "T3"
        /// R1: spoken symbols and layout ("dash dash verbose", "new line new line").
        case t4 = "T4"
        /// Single-quoted spans are quotations ('the the' is what he typed).
        case t5 = "T5"
        /// A deletion never orphans a bracket or a quotation mark.
        case t5b = "T5b"
        /// R1: emphatic "do do" after its subject ("We do do retros").
        case t6 = "T6"
        /// R1: "so so" / "my my" before a break ("The demo was so so, …").
        case t7 = "T7"
        /// R1: "up up" ("line them up up front").
        case t8 = "T8"
        /// R1: capitalised copies mid-sentence ("their opener was The The").
        case t9 = "T9"
        /// R1/R2/R3: a repeated non-word is content ("it beeps zz zz").
        case t10 = "T10"
        /// R3: the letter after "an" ("add an s").
        case t11a = "T11a"
        /// R3: a unit after digits ("2 g garlic").
        case t11b = "T11b"
        /// R5: across a sentence break, only a standalone number.
        case t13 = "T13"
        /// A range that crosses an earlier deletion covers the live tokens.
        case t14 = "T14"
        /// A bracket, quote or dash is not a sentence or clause end.
        case t15 = "T15"
        /// SpokenStructure's layout markers ("bullet point", "new line") are
        /// boundaries no rule reads, deletes or spans: two equal list items are
        /// two items, not a repeat.
        case t16 = "T16"
        /// A repair inside a mention is not taken: words reported, quoted,
        /// exemplified, specified or labelled ("the input is Friday, no wait,
        /// Saturday", "when I said I'm 34, actually 35"), read from the frames
        /// around them — a heuristic, not an understanding.
        case t17 = "T17"
        /// R1: a double that stands alone — the whole sentence, or its first
        /// or last clause — is an interjection, a sign-off or a chant ("Cool
        /// cool, see you then.", "see you Sunday, baci baci").
        case t18 = "T18"
        /// R1: English grammar doubles — a phrasal verb's particle and the same
        /// preposition ("swing by by noon", "think it over over the weekend"),
        /// and are / were / did after a wh-word and a subject ("what they are
        /// are"; "What are are you doing?" is a stutter).
        case t19 = "T19"
        /// R3a: a short word of another language, or of English, is a word, not
        /// a non-word ("ti amo", "kung fu", "a photo op") — `r3aKeep`.
        case t20 = "T20"
        /// R4: a mid-sentence "scratch that" before a bare noun phrase, after a
        /// clause with a verb, takes back only the noun phrase in the same slot
        /// ("Book a window seat, scratch that, an aisle seat" → "Book an aisle
        /// seat"), or nothing when no slot fits ("Sam fixed it, scratch that,
        /// Priya" stays).
        case t21 = "T21"
        /// R1 (a fix, not a stop, like T14): is / was / do / does after a
        /// wh-word stay doubled only with a subject between, as T19's are /
        /// were / did ("what it is is"; "What is is your name?" is a stutter).
        case t22 = "T22"
        /// R2 (v7): a one-word head of another language — not ASCII, or a
        /// word T3 lists as another language's — opens an idiom, not a
        /// restart ("Uno a uno we checked every room", "Passo a passo",
        /// "mais e mais").
        case t23 = "T23"
        /// R4 (v8; part stop, part fire, like T22): a verb heading its own
        /// phrase after the cue — an object or a verb particle right after it,
        /// or (v9) the noun before the cue said again as its object — is no
        /// replacement for the noun before the cue ("Reset the branch, I mean,
        /// fork the branch" keeps both); after "scratch that" it is a clause,
        /// and the clause before it goes ("…, scratch that, archive the logs"
        /// → "Archive the logs") — (v9) unless a noun with its own object reads
        /// the same and nothing shows a verb ("Send the team, scratch that,
        /// client the slides" keeps both).
        case t24 = "T24"
        /// R4 (v9; a stop and a wider swap): a compound noun's head is no slot
        /// for a lone word after the cue. Said again with a new modifier, the
        /// whole compound is replaced ("Use the staging bucket, I mean, prod
        /// bucket" → "Use the prod bucket"); corrected by its modifier alone,
        /// both are kept ("Restart the staging server, I mean, prod").
        case t25 = "T25"
        /// R4 (v9; a narrower fire): "scratch that" before a verb phrase with
        /// no subject takes back X's verb phrase, not its clause, when an
        /// auxiliary, "to", a coordinator, "please" or a contracted pronoun
        /// stands before its verb ("I'll call him, scratch that, text him
        /// tonight" → "I'll text him tonight").
        case t26 = "T26"
    }

    /// One applied deletion.
    public struct Fire: Sendable, Equatable {
        public let rule: Rule
        /// Indices of the deleted whitespace tokens of the input.
        public let deleted: [Int]
        /// The cue's token range (R4, R4S, R5).
        public let cue: Range<Int>?
        /// What fired ("repeat x2 n=1", "cue no wait", …) — no dictated text.
        public let note: String
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        public let fires: [Fire]
    }

    /// Repetitions, inflected restarts and fragments: nothing a speaker
    /// means. They run wherever the filler strip runs.
    public static let repetitionRules: Set<Rule> = [.r1, .r1b, .r3]
    /// Restarts and cued corrections: they change what is kept of what he
    /// said, so they run only where corrections are resolved today.
    public static let correctionRules: Set<Rule> = [.r2, .r2b, .r4, .r4s, .r5]

    /// The rules a cleanup level runs: none at `verbatim`, the repetition
    /// rules at `fillers`, all of them at `standard`.
    public static func rules(for level: AppConfig.Cleanup.Level) -> Set<Rule> {
        switch level {
        case .verbatim: return []
        case .fillers: return repetitionRules
        case .standard: return repetitionRules.union(correctionRules)
        }
    }

    /// Whether a level deletes R3a's non-words — a lone 1–2 letter word that
    /// is no English word ("the b chair"). Only `standard`: at `fillers` the
    /// rules take repeats and the cut-off words a following word completes
    /// ("lo logs"), never a short word on its own, which can be a lower-case
    /// abbreviation ("the pr is ready").
    public static func deletesNonWords(at level: AppConfig.Cleanup.Level) -> Bool {
        level == .standard
    }

    /// The stage `DictationPipeline` runs on one dictation, or nil when it
    /// does not run: a verbatim level or register (FillerStripper's own
    /// gate), or a dictation language other than English. With
    /// `collapseStutters` off (`[cleanup] collapse_stutters = false`) he asked
    /// for repetitions to be kept, so R1 does not run.
    public static func forDictation(
        level: AppConfig.Cleanup.Level, verbatimRegister: Bool,
        language: DictationLanguage, protecting dictionaryTerms: Set<String>,
        collapseStutters: Bool = true
    ) -> SelfRepair? {
        guard language == .english, !verbatimRegister else { return nil }
        var rules = rules(for: level)
        if !collapseStutters { rules.remove(.r1) }
        guard !rules.isEmpty else { return nil }
        return SelfRepair(rules: rules, protecting: dictionaryTerms, nonWords: deletesNonWords(at: level))
    }

    public let rules: Set<Rule>
    public let guards: Set<Guard>
    public let maxPasses: Int
    /// false: no lexical classes and no language gate (the reference's
    /// `tagger=False`), for tests that must not depend on NaturalLanguage.
    public let naturalLanguage: Bool
    /// R3a (a 1–2 letter non-word between words) on; off at the `fillers`
    /// level (`deletesNonWords(at:)`, the reference's `nonwords`).
    public let nonWords: Bool
    let protect: Set<ScalarString>

    /// - Parameters:
    ///   - protecting: dictionary terms (`DictionaryEngine.lowercasedTargets`)
    ///     — never deleted as a fragment, never re-cased.
    public init(rules: Set<Rule> = Set(Rule.allCases), protecting: Set<String> = [],
                guards: Set<Guard> = Set(Guard.allCases), maxPasses: Int = 4,
                naturalLanguage: Bool = true, nonWords: Bool = true) {
        self.rules = rules
        self.guards = guards
        self.maxPasses = maxPasses
        self.naturalLanguage = naturalLanguage
        self.nonWords = nonWords
        self.protect = Set(protecting.map { ScalarString(PyText.lower(Array($0.unicodeScalars))) })
    }

    /// What a dictation gets: `apply`'s deletions and case fixes with the
    /// input's own whitespace kept between the surviving tokens — a line
    /// break beside a deleted run survives it — and the text exactly as it
    /// came when nothing fired. (`apply` joins with single spaces, the
    /// reference's form, which the parity check compares byte for byte; the
    /// two differ only in whitespace.)
    public func repair(_ text: String) -> String {
        let result = evaluate(text, spacing: .original)
        return result.fires.isEmpty ? text : result.text
    }

    /// Load the language and tagging models now (~70 ms once), so the first
    /// dictation that needs them does not pay for it. Safe off the main thread.
    public static func prewarm() { SelfRepairLanguage.prewarm() }

    /// Remove the self-repairs in `text`: the kept tokens joined by single
    /// spaces, and which rule deleted which tokens. Empty fires ⇒ the text
    /// came back whitespace-normalized and otherwise unchanged.
    public func apply(_ text: String) -> Result { evaluate(text, spacing: .single) }

    /// How the kept tokens are joined: by one space (the reference's form),
    /// or by the input's own whitespace.
    enum Spacing { case single, original }

    private func evaluate(_ text: String, spacing: Spacing) -> Result {
        let scalars = Array(text.unicodeScalars)
        let toks = Self.tokenize(scalars, guards: guards)
        guard !toks.isEmpty else { return Result(text: "", fires: []) }
        let ctx = Context(toks: toks, text: text, scalars: scalars, protect: protect, guards: guards,
                          naturalLanguage: naturalLanguage, nonWords: nonWords)
        if !rules.isEmpty {
            // [T17] The mentions are read off the first view, every token
            // alive, and only consulted when a fire is about to land: a
            // dictation nothing fires on never pays for them.
            if guards.contains(.t17) {
                ctx.mentionView = View(ctx.toks, ctx.alive, aliveOnly: guards.contains(.t14))
            }
            // (v13) [the valve, at apply time] v11's rules run first on the
            // same tokens, guards, rules and level — the shadow run, which
            // reads this context's tags, language gate and mentions — and no
            // fire of any rule below deletes a token that run keeps.
            let shadow = Context(toks: toks, text: text, scalars: scalars, protect: protect, guards: guards,
                                 naturalLanguage: naturalLanguage, nonWords: nonWords, base: ctx)
            runPasses(shadow, legacy: true, within: nil)
            let d11 = Set(shadow.alive.indices.filter { !shadow.alive[$0] })
            runPasses(ctx, legacy: false, within: d11)
            // The language gate, read only when it can change the answer: a
            // closed gate returns the text as it came, and with no fire that
            // is what the render below returns anyway.
            if !ctx.fires.isEmpty, ctx.gateClosed {
                return Result(text: spacing == .single ? toks.map(\.string).joined(separator: " ") : text,
                              fires: [])
            }
        }
        return Result(text: Self.render(ctx, spacing: spacing), fires: ctx.fires)
    }

    /// The passes, recording into `ctx`: every rule reads a view of the
    /// tokens still alive; a rule's fires are all found before any is
    /// applied, so one view serves every rule until a deletion lands. With
    /// `legacy`, R4 and R5 read every cue as v11 did (`cued11`, the shadow
    /// run); (v13) with `d11`, the tokens the shadow run deleted, a fire that
    /// deletes any other token is not applied.
    private func runPasses(_ ctx: Context, legacy: Bool, within d11: Set<Int>?) {
        var view: View?
        passes: for _ in 0..<maxPasses {
            var changed = false
            for rule in Self.order where rules.contains(rule) {
                let current = view ?? View(ctx.toks, ctx.alive, aliveOnly: guards.contains(.t14))
                view = current
                for fire in Self.run(rule, ctx, current, legacy: legacy) {
                    let ids = fire.deleted
                    if ids.isEmpty || !ids.allSatisfy({ ctx.alive[$0] })
                        || ids.contains(where: { ctx.toks[$0].quoted }) { continue }
                    // [T16] a layout marker is never deleted; [T17] nor is
                    // a word he presents as words
                    if ids.contains(where: { ctx.toks[$0].marker != nil }) { continue }
                    if let words = ctx.mentions(), ids.contains(where: words.contains) { continue }
                    if guards.contains(.t5b), Self.unbalanced(ctx.toks, ids) { continue }
                    // (v12) a declined cue's clause and phrase stay (R4 checks its own fires)
                    if rule != .r4 && !ctx.kept.isEmpty && Self.touchesKept(rule, ctx, current, ids) { continue }
                    // (v13) v11's rules keep a token this fire deletes
                    if let d11, ids.contains(where: { !d11.contains($0) }) { continue }
                    for i in ids { ctx.alive[i] = false }
                    ctx.fires.append(fire)
                    changed = true
                    view = nil
                }
            }
            if !changed { break passes }
        }
    }

    /// Each pass runs the rules in this order.
    private static let order: [Rule] = [.r4s, .r5, .r4, .r2, .r2b, .r3, .r1, .r1b]

    /// (v12) The rules whose fire reads the words right after what it
    /// deletes: the copy a repeat keeps (R1, R1B), the head a restart says
    /// again (R2, R2B), the word a fragment's cut-off starts (R3).
    private static let readsAfter: Set<Rule> = [.r1, .r1b, .r2, .r2b, .r3]

    /// (v12) A fire that deletes a kept token, or, for a rule that reads the
    /// words after what it deletes, whose view tokens right after the last
    /// token it deletes, as many as it deletes, hold one: the copy, head or
    /// word it keeps (a repeat's other copy, a restart's head said again, the
    /// word a cut-off starts) is no longer than what it deletes.
    private static func touchesKept(_ rule: Rule, _ ctx: Context, _ view: View, _ ids: [Int]) -> Bool {
        if ids.contains(where: { ctx.kept.contains($0) }) { return true }
        guard readsAfter.contains(rule), let last = ids.max() else { return false }
        let k = view.firstAfter(last)
        return (k..<min(view.n, k + ids.count)).contains(where: { ctx.kept.contains(view.v[$0].index) })
    }

    private static func run(_ rule: Rule, _ ctx: Context, _ view: View, legacy: Bool) -> [Fire] {
        switch rule {
        case .r4s: return ruleR4S(ctx, view)
        case .r5: return legacy ? cued11(ctx, view, numeric: true) : cued(ctx, view, numeric: true)
        case .r4: return legacy ? cued11(ctx, view, numeric: false) : cued(ctx, view, numeric: false)
        case .r2: return ruleR2(ctx, view)
        case .r2b: return ruleR2B(ctx, view)
        case .r3: return ruleR3(ctx, view)
        case .r1: return ruleR1(ctx, view)
        case .r1b: return ruleR1B(ctx, view)
        }
    }
}

// MARK: - Tokens

private typealias Lex = SelfRepairLexicon

/// Words the rules compare against on every token, built once (a literal
/// `ScalarString` is an array allocation per comparison).
private enum Word {
    static let i: ScalarString = "i"
    static let like: ScalarString = "like"
    static let you: ScalarString = "you"
    static let know: ScalarString = "know"
    static let asWord: ScalarString = "as"
    static let of: ScalarString = "of"
    static let whereWord: ScalarString = "where"
    static let expected: ScalarString = "expected"
    static let to: ScalarString = "to"
    static let her: ScalarString = "her"
    static let one: ScalarString = "one"
    static let ones: ScalarString = "ones"
    static let when: ScalarString = "when"
    static let also: ScalarString = "also"
    static let well: ScalarString = "well"
    static let please: ScalarString = "please"
}

extension SelfRepair {
    /// What separates a token from the next one.
    enum Break: Int, Comparable {
        case none = 0, comma = 1, hard = 2
        static func < (a: Break, b: Break) -> Bool { a.rawValue < b.rawValue }
    }

    /// [T16] What a token of a spoken layout phrase marks: the end of a line
    /// ("new line", "new paragraph"), a list item ("bullet point", "next
    /// bullet": it ends the line before it too, and [T18] what follows it is
    /// an item, never an interjection), or the opening ("and I quote", "open
    /// quote") or closing ("unquote", "close quote", "end quote") of a spoken
    /// quotation, whose words [T17] keeps.
    enum Marker { case lineBreak, bullet, quoteOpen, quoteClose }

    /// A whitespace token. `lead` = its leading non-alphanumerics, `trail` =
    /// its trailing ones (a `%` stays in the core), `core` = the rest, `low` =
    /// the core lower-cased with ’ read as '. A class: every view holds the
    /// same tokens, by reference.
    final class Token {
        let index: Int
        let raw: [Unicode.Scalar]
        /// Offset of the first scalar in the text (for quotation spans).
        let start: Int
        let lead: [Unicode.Scalar]
        let core: [Unicode.Scalar]
        let trail: [Unicode.Scalar]
        let low: ScalarString
        /// The break after the token: HARD on . ? ! ; : … ) ] } " ” ’ — – or
        /// "--", else COMMA on a comma, else NONE.
        let brk: Break
        /// [T15] the trail ends a sentence or clause (. ? ! ; : …) — a
        /// closing bracket, quote or dash is HARD but is not a sentence end.
        let send: Bool
        /// The lead opens a clause (" “ ‘ ( [ { — – -).
        let leadBreak: Bool
        let alpha: Bool
        let cap: Bool
        let num: Bool
        var quoted = false
        var filler: Bool
        /// [T16] Part of a spoken layout phrase: a boundary, never a word.
        var marker: Marker?

        init(index: Int, raw: [Unicode.Scalar], start: Int) {
            self.index = index
            self.raw = raw
            self.start = start
            var a = 0, b = raw.count
            while a < b, !PyText.isAlnum(raw[a]) { a += 1 }
            while b > a, !(PyText.isAlnum(raw[b - 1]) || raw[b - 1] == "%") { b -= 1 }
            let lead = Array(raw[0..<a]), core = Array(raw[a..<b]), trail = Array(raw[b...])
            self.lead = lead
            self.core = core
            self.trail = trail
            var lowered = PyText.lower(core)
            for i in lowered.indices where lowered[i] == "\u{2019}" { lowered[i] = "'" }
            let low = ScalarString(lowered)
            self.low = low
            let doubleDash = zip(trail, trail.dropFirst()).contains { $0 == "-" && $1 == "-" }
            if trail.contains(where: Lex.hardTrail.contains) || doubleDash {
                brk = .hard
            } else if trail.contains(",") {
                brk = .comma
            } else {
                brk = .none
            }
            send = trail.contains(where: Lex.sentenceTrail.contains)
            leadBreak = lead.contains(where: Lex.openBreak.contains)
            alpha = core.first.map(PyText.isAlpha) ?? false
            cap = core.first.map(PyText.isUpperChar) ?? false
            num = SelfRepair.isNumber(low)
            // An ALL-CAPS "UM" is an initialism, not a filled pause.
            filler = Lex.coreFillers.contains(low) && !(core.count >= 2 && PyText.isUpper(core))
        }

        var string: String { String(String.UnicodeScalarView(raw)) }
        var allCaps: Bool { core.count >= 2 && PyText.isUpper(core) }
    }

    private static let numberSuffixes: Set<ScalarString> = ["k", "m", "b", "%", "st", "nd", "rd", "th", "s", "am", "pm", "x"]

    /// A number: `[$€£]?\d[\d,.:]*` plus an optional suffix (k m b % st nd rd
    /// th s am pm x) — "3", "7:30", "$1,200", "10k", "14th", "5pm" — or words
    /// that are all number words or ordinals ("forty-two", "twenty").
    static func isNumber(_ low: ScalarString) -> Bool {
        let s = low.scalars
        guard !s.isEmpty else { return false }
        var i = 0
        if s[i] == "$" || s[i] == "€" || s[i] == "£" { i += 1 }
        if i < s.count, PyText.isDecimal(s[i]) {
            i += 1
            while i < s.count, PyText.isDecimal(s[i]) || s[i] == "," || s[i] == "." || s[i] == ":" { i += 1 }
            if i == s.count || numberSuffixes.contains(ScalarString(s[i...])) { return true }
        }
        guard s.contains("-") else { return Lex.numWords.contains(low) || Lex.ordinals.contains(low) }
        let parts = s.split(separator: "-")
        return !parts.isEmpty && parts.allSatisfy {
            let part = ScalarString($0)
            return Lex.numWords.contains(part) || Lex.ordinals.contains(part)
        }
    }

    /// Tokens of `text` split as `str.split()` splits, with quotation marked:
    /// a token overlapping a span of paired straight double quotes, or of “
    /// with the next ”, is quoted; [T5] so is every token of a single-quoted
    /// span ('like this', within `quoteWindow` tokens).
    static func tokenize(_ text: [Unicode.Scalar], guards: Set<Guard>) -> [Token] {
        let toks = PyText.tokenRanges(text).enumerated().map {
            Token(index: $0.offset, raw: Array(text[$0.element]), start: $0.element.lowerBound)
        }
        let spans = quoteSpans(text)
        if !spans.isEmpty {
            for k in toks.indices {
                let a = toks[k].start, b = toks[k].start + toks[k].raw.count - 1
                if spans.contains(where: { $0.lowerBound <= b && a <= $0.upperBound }) {
                    toks[k].quoted = true
                    toks[k].filler = false
                }
            }
        }
        if guards.contains(.t5) {
            for run in singleQuoteRuns(toks) {
                for m in run {
                    toks[m].quoted = true
                    toks[m].filler = false
                }
            }
        }
        if guards.contains(.t16) {
            for (ids, kind) in spokenMarkers(toks) {
                for m in ids { toks[m].marker = kind }
            }
        }
        return toks
    }

    /// [T16] Every SpokenStructure layout phrase, found as SpokenStructure
    /// will find it once the fillers are stripped: its phrases, in its order,
    /// tried at each position and a match taken whole, over the tokens that
    /// are not fillers (a filler between the words belongs to the phrase). A
    /// token reads as its text lower-cased with everything but letters and
    /// digits dropped ("Bullet," → "bullet"), as SpokenStructure normalizes a
    /// word. Its own refusals ("a new line of credit", a register without
    /// bullets) are not applied: a phrase it leaves as words is still a
    /// boundary here, which can cost a fix but never an item.
    static func spokenMarkers(_ toks: [Token]) -> [(ids: ClosedRange<Int>, kind: Marker)] {
        let seq = toks.filter { !$0.filler }
        // A core of ASCII letters and digits reads as its `low` (no lead or
        // trail character lower-cases to a letter or digit); only the rare
        // other token pays for the full mapping.
        let words = seq.map { t -> ScalarString in
            t.core.allSatisfy(Self.isASCIIAlnum) ? t.low : ScalarString(PyText.lower(t.raw).filter(PyText.isAlnum))
        }
        var out: [(ids: ClosedRange<Int>, kind: Marker)] = []
        var k = 0
        scan: while k < seq.count {
            for phrase in Lex.spokenPhrases where k + phrase.words.count <= seq.count {
                let length = phrase.words.count
                if (0..<length).allSatisfy({ words[k + $0] == phrase.words[$0] }) {
                    out.append((seq[k].index...seq[k + length - 1].index, phrase.kind))
                    k += length
                    continue scan
                }
            }
            k += 1
        }
        return out
    }

    /// Scalar spans (inclusive) of straight double quotes paired in order,
    /// then of each “ with the next ”.
    private static func quoteSpans(_ text: [Unicode.Scalar]) -> [ClosedRange<Int>] {
        var spans: [ClosedRange<Int>] = []
        var start: Int?
        for (k, ch) in text.enumerated() where ch == "\"" {
            if let s = start { spans.append(s...k); start = nil } else { start = k }
        }
        start = nil
        for (k, ch) in text.enumerated() {
            if ch == "\u{201C}" {
                start = k
            } else if ch == "\u{201D}", let s = start {
                spans.append(s...k)
                start = nil
            }
        }
        return spans
    }

    /// [T5] The token opens a single-quoted span: its lead ends with ' or ‘
    /// right before a letter, and it is not an elision ('cause, 'em).
    static func singleQuoteOpener(_ t: Token) -> Bool {
        guard let last = t.lead.last, last == "'" || last == "\u{2018}" else { return false }
        return (t.core.first.map(PyText.isAlpha) ?? false) && !Lex.elisions.contains(t.low)
    }

    /// [T5] The token's trail holds ' or ’ (a closing quote, or an apostrophe).
    static func singleQuoteCloser(_ t: Token) -> Bool {
        t.trail.contains { $0 == "'" || $0 == "\u{2019}" }
    }

    /// [T5] Token ranges of single-quoted spans: an opener pairs with the
    /// nearest closer among itself and the next `quoteWindow - 1` tokens
    /// ('cat' is a span of one); with none in reach it quotes nothing.
    private static func singleQuoteRuns(_ toks: [Token]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var k = 0
        while k < toks.count {
            if singleQuoteOpener(toks[k]) {
                for j in k..<min(toks.count, k + Lex.quoteWindow) where singleQuoteCloser(toks[j]) {
                    runs.append(k...j)
                    k = j
                    break
                }
            }
            k += 1
        }
        return runs
    }

    private static func isASCIIAlnum(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    private static let openPair: [Unicode.Scalar: Unicode.Scalar] = ["(": ")", "[": "]", "{": "}", "\u{201C}": "\u{201D}"]
    private static let closePair: Set<Unicode.Scalar> = [")", "]", "}", "\u{201D}"]

    /// [T5b] Deleting these tokens would leave a bracket or quotation mark
    /// without its partner: ( [ { “ must close within the deleted tokens,
    /// straight double quotes must pair, and a single-quote opener needs its
    /// closer there too (a trailing ' with nothing open is an apostrophe:
    /// "the students' notes").
    static func unbalanced(_ toks: [Token], _ ids: [Int]) -> Bool {
        var stack: [Unicode.Scalar] = []
        var doubleQuotes = 0, singleQuotes = 0
        for i in ids.sorted() {
            let t = toks[i]
            for ch in t.raw {
                if let closer = openPair[ch] {
                    stack.append(closer)
                } else if closePair.contains(ch) {
                    if stack.last != ch { return true }
                    stack.removeLast()
                } else if ch == "\"" {
                    doubleQuotes += 1
                }
            }
            if singleQuoteOpener(t) { singleQuotes += 1 }
            if singleQuotes > 0, singleQuoteCloser(t) { singleQuotes -= 1 }
        }
        return !stack.isEmpty || doubleQuotes % 2 == 1 || singleQuotes > 0
    }
}

// MARK: - The view

extension SelfRepair {
    /// The live tokens that are neither fillers nor [T16] layout markers,
    /// rebuilt before every rule. `gap[k]` is the break between `v[k-1]` and
    /// `v[k]` — the strongest of `v[k-1]`'s and of every filler between them,
    /// HARD when `v[k]` opens a clause or a marker stood between them;
    /// `gap[0]` is HARD. `ev[k]`: a filler sat between them (repair
    /// evidence). `sent[k]` [T15]: a sentence ended between them (or a line,
    /// at a "new line" / "bullet point" marker). `sentenceStart[k]` /
    /// `clauseStart[k]`: where `v[k]`'s sentence and clause begin, computed
    /// once here — scanning back from every cue made a long comma-only chain
    /// of cues quadratic. [T18] (v7) `punctuationGap[k]`: the gap with the
    /// markers left out — a marker is a break but no sentence edge; (v8) the
    /// punctuation on a marker's own words still counts ("new line." ends a
    /// sentence as "eight." would); `bulletItem[k]`: a "bullet point" marker
    /// stood right before `v[k]`.
    struct View {
        private(set) var v: [Token] = []
        private(set) var gap: [Break] = []
        private(set) var ev: [Bool] = []
        private(set) var sent: [Bool] = []
        private(set) var punctuationGap: [Break] = []
        private(set) var bulletItem: [Bool] = []
        /// The largest j ≤ k with `gap[j] == .hard`.
        private(set) var sentenceStart: [Int] = []
        /// The largest j ≤ k with `gap[j] != .none` (0 at the latest).
        private(set) var clauseStart: [Int] = []
        let alive: [Bool]
        let aliveOnly: Bool
        private let cache = Cache()
        var n: Int { v.count }

        private final class Cache {
            var previousSame: [Int]?
            /// (v12) `phraseEnd` and `alsoFrom`, built on first use.
            var phraseEnds: [Int]?
            var alsoFrom: [Int]?
            /// (v12) The view ranges `decline` covered, disjoint and sorted, and
            /// the tokens' input indices (built on first use).
            var covered: [(lo: Int, hi: Int)] = []
            var inputIndices: [Int]?
        }

        init(_ toks: [Token], _ alive: [Bool], aliveOnly: Bool) {
            self.alive = alive
            self.aliveOnly = aliveOnly
            var pendBreak = Break.none, pendEvidence = false, pendSentence = false
            var pendPunctuation = Break.none, pendBullet = false
            for t in toks where alive[t.index] {
                if let marker = t.marker {
                    // [T16] a boundary, never a word the rules read
                    pendBreak = .hard
                    // [T18] (v8) its own punctuation counts: "new line." ends a sentence
                    pendPunctuation = max(pendPunctuation, t.brk)
                    pendSentence = pendSentence || marker == .lineBreak || marker == .bullet
                    pendBullet = pendBullet || marker == .bullet
                    continue
                }
                if t.filler {
                    pendBreak = max(pendBreak, t.brk)
                    pendPunctuation = max(pendPunctuation, t.brk)
                    pendEvidence = true
                    pendSentence = pendSentence || t.send
                    continue
                }
                if let last = v.last {
                    gap.append(t.leadBreak ? .hard : max(last.brk, pendBreak))
                    punctuationGap.append(t.leadBreak ? .hard : max(last.brk, pendPunctuation))
                    ev.append(pendEvidence)
                    sent.append(last.send || pendSentence)
                } else {
                    gap.append(.hard)
                    punctuationGap.append(.hard)
                    ev.append(false)
                    sent.append(true)
                }
                bulletItem.append(pendBullet)
                v.append(t)
                pendBreak = .none
                pendEvidence = false
                pendSentence = false
                pendPunctuation = .none
                pendBullet = false
            }
            sentenceStart = Array(repeating: 0, count: v.count)
            clauseStart = Array(repeating: 0, count: v.count)
            for k in v.indices.dropFirst() {
                sentenceStart[k] = gap[k] == .hard ? k : sentenceStart[k - 1]
                clauseStart[k] = gap[k] != .none ? k : clauseStart[k - 1]
            }
        }

        /// The largest j < k with `v[j].low == v[k].low`, or -1 (built on
        /// first use).
        func previousSame(_ k: Int) -> Int {
            if cache.previousSame == nil {
                var last: [ScalarString: Int] = [:]
                var out = [Int](repeating: -1, count: v.count)
                for (j, t) in v.enumerated() {
                    out[j] = last[t.low] ?? -1
                    last[t.low] = j
                }
                cache.previousSame = out
            }
            return cache.previousSame![k]
        }

        /// [T21] The index after the phrase that starts at y: the first e > y
        /// with `gap[e] != .none`, or n. (v12) Computed once per view, on first
        /// use: scanning for it at every cue made a long run with no break in
        /// it quadratic.
        func phraseEnd(_ y: Int) -> Int {
            if cache.phraseEnds == nil {
                var ends = [Int](repeating: n, count: n)
                var k = n - 2
                while k >= 0 {
                    ends[k] = gap[k + 1] != .none ? k + 1 : ends[k + 1]
                    k -= 1
                }
                cache.phraseEnds = ends
            }
            return cache.phraseEnds![y]
        }

        /// (v12) The first index ≥ y whose word is "also", or n (built on first
        /// use).
        func alsoFrom(_ y: Int) -> Int {
            if cache.alsoFrom == nil {
                var next = n
                var out = [Int](repeating: n, count: n)
                for k in stride(from: n - 1, through: 0, by: -1) {
                    if v[k].low == Word.also { next = k }
                    out[k] = next
                }
                cache.alsoFrom = out
            }
            return cache.alsoFrom![y]
        }

        /// (v12) The view indices in a..<b that no earlier call on this view
        /// covered, in order; a..<b is covered after. `decline` adds only
        /// these: a long run of declined cues with no break between them
        /// re-added the same phrase at every cue (quadratic).
        func cover(_ a: Int, _ b: Int) -> [Int] {
            var out: [Int] = []
            let cov = cache.covered
            var j = 0, top = cov.count                  // the first range that starts at a or after
            while j < top {
                let mid = (j + top) / 2
                if cov[mid].lo < a { j = mid + 1 } else { top = mid }
            }
            if j > 0 && cov[j - 1].hi >= a { j -= 1 }   // a range that starts before a and reaches it
            var k = j, lo = a, hi = b, pos = a
            while k < cov.count && cov[k].lo <= b {
                let (s, e) = cov[k]
                if s > pos { out.append(contentsOf: pos..<min(s, b)) }
                pos = max(pos, e); lo = min(lo, s); hi = max(hi, e)
                k += 1
            }
            if pos < b { out.append(contentsOf: pos..<b) }
            cache.covered.replaceSubrange(j..<k, with: [(lo: lo, hi: hi)])
            return out
        }

        /// (v12) The first view index whose token's input index is above i, or
        /// n (binary search; the indices are built on first use).
        func firstAfter(_ i: Int) -> Int {
            if cache.inputIndices == nil { cache.inputIndices = v.map(\.index) }
            let idx = cache.inputIndices!
            var lo = 0, hi = idx.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if idx[mid] <= i { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        /// The break after `v[k]`: `gap[k+1]`, or its own for the last token.
        func after(_ k: Int) -> Break { k + 1 < n ? gap[k + 1] : v[k].brk }
        /// `v[k]` opens a sentence.
        func initial(_ k: Int) -> Bool { k == 0 || gap[k] == .hard }
        /// Every gap strictly between `v[a]` and `v[b]` (inclusive) is NONE.
        func clean(_ a: Int, _ b: Int) -> Bool {
            a >= b || (a + 1...b).allSatisfy { gap[$0] == .none }
        }
        /// Input token indices of `v[a] ..< v[b]`.
        func ids(_ a: Int, _ b: Int) -> [Int] { span(v[a].index, v[b - 1].index + 1) }
        /// Input token indices from `v[a]` up to, not including, `v[b]` — the
        /// fillers right before `v[b]` go with the run.
        func upto(_ a: Int, _ b: Int) -> [Int] { span(v[a].index, v[b].index) }

        /// [T14] Only the tokens still alive: a range that crosses an earlier
        /// deletion must not list the dead ones, or the fire is dropped.
        private func span(_ lo: Int, _ hi: Int) -> [Int] {
            guard lo < hi else { return [] }
            return aliveOnly ? (lo..<hi).filter { alive[$0] } : Array(lo..<hi)
        }
    }

    /// One `apply` call's state. A class: the rules record into it, and the
    /// language reads are computed once, on first need.
    final class Context {
        let toks: [Token]
        let text: String
        let scalars: [Unicode.Scalar]
        let protect: Set<ScalarString>
        let guards: Set<Guard>
        let naturalLanguage: Bool
        let nonWords: Bool
        var alive: [Bool]
        var fires: [Fire] = []
        /// R1: the kept last copy → the deleted first copy (for the case fix).
        var caseFrom: [Int: Int] = [:]
        /// (v12) The input indices a v12 refusal keeps for the rest of the
        /// call: for each declined cue, the words v11's fire for it could have
        /// taken, the cue and the phrase after it (`decline`).
        var kept: Set<Int> = []
        /// (v13) The input index of each declined cue's first word: no later
        /// scan of R4 or R5 reads it again, in this pass or a later one.
        var declined: Set<Int> = []
        /// [T17] The first view, every token alive, which the mentions are
        /// read off, and the mentions, computed on first need (`mentions()`):
        /// a dictation nothing fires on never pays for them.
        var mentionView: View?
        private var mentionWords: Set<Int>?
        /// (v13) The context whose tags, language gate and mentions this one
        /// reads — the shadow run's reads the main one's, so NaturalLanguage
        /// runs once — or nil.
        let base: Context?

        init(toks: [Token], text: String, scalars: [Unicode.Scalar], protect: Set<ScalarString>,
             guards: Set<Guard>, naturalLanguage: Bool, nonWords: Bool, base: Context? = nil) {
            self.toks = toks
            self.text = text
            self.scalars = scalars
            self.protect = protect
            self.guards = guards
            self.naturalLanguage = naturalLanguage
            self.nonWords = nonWords
            self.base = base
            self.alive = Array(repeating: true, count: toks.count)
        }

        lazy var gateClosed: Bool = base?.gateClosed
            ?? (naturalLanguage && SelfRepairLanguage.gateCloses(text, tokenCount: toks.count))

        private lazy var tags: [String] = {
            let none = [String](repeating: "", count: toks.count)
            guard naturalLanguage, !gateClosed else { return none }
            let tags = SelfRepairLanguage.lexicalClasses(text)
            return tags.count == toks.count ? tags : none
        }()

        func tag(_ index: Int) -> String { base?.tag(index) ?? tags[index] }

        /// [T17] The input tokens no fire deletes, or nil with T17 off.
        func mentions() -> Set<Int>? {
            if let base { return base.mentions() }
            guard let first = mentionView else { return nil }
            if let words = mentionWords { return words }
            let words = SelfRepair.mentions(first, toks)
            mentionWords = words
            return words
        }
    }
}

// MARK: - [T17] Mentions

extension SelfRepair {
    /// [T17] The input tokens of every mention, which no fire deletes:
    /// describing a repair is not making one. A mention is a stretch of words
    /// he presents as words — reported, quoted, exemplified, specified or
    /// labelled — rather than as his message, read from the frames that
    /// introduce words as words (the reference's MENTIONS, frames 1–11). It is
    /// a heuristic over the words around the stretch, not an understanding of
    /// it: where a frame matches the words are kept, and a description no
    /// frame matches is still repaired (docs/self-repair.md §7). Computed once,
    /// on the first view: what each frame reaches, the fillers between two
    /// reached view tokens that are neighbours, and every token of a spoken
    /// quotation.
    static func mentions(_ view: View, _ toks: [Token]) -> Set<Int> {
        let v = view.v
        let cues = cuePositions(view)
        var marked: Set<Int> = []
        for k in 0..<view.n where !v[k].quoted {
            marked.formUnion(frameMentions(view, k, cues))
        }
        var out = Set(marked.map { v[$0].index })
        for j in marked where marked.contains(j + 1) {
            out.formUnion(v[j].index...v[j + 1].index)
        }
        return out.union(spokenQuotation(toks))
    }

    /// The view indices inside an occurrence of a cue: a mention reads across
    /// the commas around one ("Friday, no wait, Saturday" is one stretch).
    private static func cuePositions(_ view: View) -> Set<Int> {
        var out: Set<Int> = []
        for c in 0..<view.n {
            if let cue = matchCue(view, c, Lex.cues) { out.formUnion(c..<c + cue.count) }
        }
        return out
    }

    /// reach(j): from `start` to the end of its clause — up to the first token
    /// a HARD gap follows, or a COMMA gap that neither leaves nor enters a cue;
    /// `mentionReach` tokens at most.
    private static func reach(_ view: View, _ start: Int, _ cues: Set<Int>) -> [Int] {
        var out: [Int] = []
        var j = start
        while j < view.n, out.count < Lex.mentionReach {
            out.append(j)
            let g = view.after(j)
            if g == .hard { break }
            if g == .comma, !(cues.contains(j) || cues.contains(j + 1)) { break }
            j += 1
        }
        return out
    }

    /// back(e): from the sentence start (commas crossed) up to, not
    /// including, `end`; `mentionReachBack` tokens at most.
    private static func reachBack(_ view: View, _ end: Int) -> [Int] {
        guard end >= 1 else { return [] }
        return Array(max(view.sentenceStart[end - 1], end - Lex.mentionReachBack)..<end)
    }

    /// clause_back(e): back from `end` to the start of its clause — never past
    /// a coordinator, and stopping after a token a HARD gap opens or a COMMA
    /// gap that neither leaves nor enters a cue; `mentionReachBack` tokens at
    /// most. In input order.
    private static func clauseBack(_ view: View, _ end: Int, _ cues: Set<Int>) -> [Int] {
        var out: [Int] = []
        var j = end - 1
        while j >= 0, out.count < Lex.mentionReachBack, !Lex.coordinators.contains(view.v[j].low) {
            out.append(j)
            let g = view.gap[j]
            if g == .hard || (g == .comma && !(cues.contains(j) || cues.contains(j - 1))) { break }
            j -= 1
        }
        return out.reversed()
    }

    /// Y reads as X with words taken out: the first min(2, |Y|) words of Y
    /// occur in X in order — the description of a deletion ("send it Friday,
    /// no wait, Saturday" → "send it Saturday"), not a different replacement.
    private static func deletesTo(_ view: View, _ xs: [Int], _ ys: [Int]) -> Bool {
        let a = xs.map { view.v[$0].low }
        let need = min(2, ys.count)
        var j = 0
        for i in ys.prefix(need) {
            let w = view.v[i].low
            while j < a.count, a[j] != w { j += 1 }
            if j == a.count { return false }
            j += 1
        }
        return need > 0
    }

    /// The before side of a rewrite whose after side `ys` a frame introduced
    /// ("given meet at 2, actually 3, the rules return meet at 3"): back(s)
    /// when `ys` deletes to it, else nothing.
    private static func beforeSide(_ view: View, _ s: Int, _ ys: [Int]) -> [Int] {
        let xs = reachBack(view, s)
        return !xs.isEmpty && !ys.isEmpty && deletesTo(view, xs, ys) ? xs : []
    }

    /// `v[j]` ends the subject of a reporting verb: a subject pronoun; a noun
    /// phrase opened by an `npOpeners` word or a possessive within 3 tokens
    /// ("the bug report", "Sam's message"); or a capitalised word ("Priya") —
    /// not a sentence-initial one before a bare verb, which is an imperative.
    /// Returns the subject's first view index.
    private static func subjectEnd(_ view: View, _ j: Int, base: Bool) -> Int? {
        let v = view.v
        let t = v[j]
        if t.quoted { return nil }
        if Lex.subjectPronouns.contains(t.low) { return j }
        if Lex.function.contains(t.low) || !t.alpha || Lex.notSubject.contains(t.low)
            || Lex.reportAdverbs.contains(t.low) { return nil }
        for d in 1...3 {
            let i = j - d
            if i < 0 || view.gap[i + 1] != .none { break }
            let w = v[i]
            if Lex.npOpeners.contains(w.low) || w.low.hasSuffix(Suffix.possessive)
                || (w.low.hasSuffix(Suffix.s) && (w.trail.first == "'" || w.trail.first == "\u{2019}")) { return i }
            if Lex.function.contains(w.low) || !w.alpha { break }
        }
        if t.cap && (!view.initial(j) || !base) { return j }
        return nil
    }

    /// The verb `v[k]` reports or expects words: it has a subject (or always
    /// takes words: dictate, transcribe), and is not an imperative ("Say
    /// thanks"), a hedge ("I'd say") or a discourse phrase ("as I said"); an
    /// instrument's reading is not speech ("my watch says"). Returns the
    /// frame's first view index — the subject's, or `k` for a words-only verb
    /// with none.
    private static func reported(_ view: View, _ k: Int) -> Int? {
        let v = view.v
        let words = Lex.wordsVerbs.contains(v[k].low)
        var j = k - 1
        while j >= 0, view.gap[j + 1] == .none, Lex.reportAdverbs.contains(v[j].low) { j -= 1 }
        var chain = 0
        while j >= 0, view.gap[j + 1] == .none, Lex.reportChain.contains(v[j].low), chain < 2 {
            j -= 1
            chain += 1
        }
        if j < 0 || view.gap[j + 1] != .none || Lex.hedges.contains(v[j].low) { return words ? k : nil }
        if Lex.reportModals.contains(v[j].low) {
            j -= 1
            while j >= 0, view.gap[j + 1] == .none, Lex.reportAdverbs.contains(v[j].low) { j -= 1 }
            if j < 0 || view.gap[j + 1] != .none { return words ? k : nil }
        }
        guard let s = subjectEnd(view, j, base: Lex.baseVerbs.contains(v[k].low)) else { return words ? k : nil }
        if words { return s }
        if Lex.sayRead.contains(v[k].low), Lex.instruments.contains(v[j].low) { return nil }
        if s >= 1, view.gap[s] == .none, v[s - 1].low == Word.asWord || v[s - 1].low == Word.like { return nil }
        return s
    }

    /// `v[j]` opens the verb's object as a thing rather than words: an
    /// embedded question ("prints what would change"), or a noun phrase — a
    /// determiner, possessive or "'s" word, any determiners and numbers, then
    /// up to 3 words that are alphabetic and not function words (none after
    /// the first ending in "ed": "the meeting moved" is a clause), or else an
    /// object pronoun or demonstrative alone — that ends its clause or is
    /// followed by a preposition, a coordinator, a time or a number ("I wrote
    /// the report on Monday, …"). A clause is words: "she said the deadline is
    /// Friday, …".
    private static func thingObject(_ view: View, _ j: Int) -> Bool {
        let v = view.v, N = view.n
        let t = v[j]
        if Lex.whObject.contains(t.low) { return true }
        var e = j
        if Lex.npStart.contains(t.low) || t.low.hasSuffix(Suffix.possessive) {
            var i = j + 1
            while i < N, view.gap[i] == .none, Lex.npStart.contains(v[i].low) || v[i].num {
                e = i
                i += 1
            }
            var words = 0
            while words < 3, i < N, view.gap[i] == .none {
                let w = v[i]
                if !w.alpha || Lex.function.contains(w.low) { break }
                if words >= 1, w.low.hasSuffix(Suffix.ed) { return false }
                e = i
                i += 1
                words += 1
            }
        }
        if e == j, !Lex.objectPronouns.contains(t.low), !Lex.demonstratives.contains(t.low) { return false }
        let f = e + 1
        if f >= N || view.gap[f] != .none { return true }
        let w = v[f]
        return Lex.prepositions.contains(w.low) || Lex.coordinators.contains(w.low) || Lex.temporal.contains(w.low) || w.num
    }

    /// `v[j]` can open words rather than a plain noun phrase, a number or a
    /// time; a doubled word always does.
    private static func wordsStart(_ view: View, _ j: Int) -> Bool {
        let v = view.v
        if j + 1 < view.n, view.gap[j + 1] == .none, v[j + 1].low == v[j].low { return true }
        return !(Lex.npStart.contains(v[j].low) || v[j].num || Lex.temporal.contains(v[j].low))
    }

    /// Frame 3a: the linker `v[j]` after a framing noun introduces words at
    /// `v[j+1]`: "where" always; "like" unless a plain noun phrase follows (a
    /// doubled word is words); "of", "for", "with" when the words can start
    /// there, and "for" / "with" only with a second word right after.
    private static func linkedWords(_ view: View, _ j: Int) -> Bool {
        let v = view.v, N = view.n
        let link = v[j].low, w = j + 1
        let doubled = w + 1 < N && view.gap[w + 1] == .none && v[w + 1].low == v[w].low
        if link == Word.whereWord { return true }
        if link == Word.like { return !Lex.npStart.contains(v[w].low) || doubled }
        if !wordsStart(view, w) { return false }
        return link == Word.of || (w + 1 < N && view.gap[w + 1] == .none)
    }

    /// The trail with every trailing "," and ":" taken off (`str.rstrip(",:")`).
    private static func rstripCommaColon(_ trail: [Unicode.Scalar]) -> ArraySlice<Unicode.Scalar> {
        var end = trail.count
        while end > 0, trail[end - 1] == "," || trail[end - 1] == ":" { end -= 1 }
        return trail[..<end]
    }

    /// The view indices of every mention a frame at `v[k]` opens (frames 1–7
    /// and 9–11; frame 8 is `spokenQuotation`).
    private static func frameMentions(_ view: View, _ k: Int, _ cues: Set<Int>) -> [Int] {
        let v = view.v, N = view.n
        let t = v[k], low = t.low
        var out: [Int] = []
        let next = k + 1 < N && view.gap[k + 1] == .none
        // 1 a verb whose object can be words: "when I said <m>", "the log says
        //   <m>", "it should return <m>" — not a thing it takes ("I wrote the
        //   report on Monday"), a value or a prediction — and the before side
        //   of the rewrite it describes
        if Lex.reportVerbs.contains(low) || Lex.expectVerbs.contains(low), next {
            let n1 = v[k + 1]
            let doubled = k + 2 < N && view.gap[k + 2] == .none && v[k + 2].low == n1.low
            let value = (Lex.valueVerbs.contains(low) && (Lex.objectPronouns.contains(n1.low) || n1.num))
                || (Lex.predictVerbs.contains(low) && Lex.clauseOpeners.contains(n1.low))
            if !value, (!Lex.prepositions.contains(n1.low) && !Lex.particles.contains(n1.low)) || doubled,
               doubled || Lex.wordsVerbs.contains(low) || !thingObject(view, k + 1),
               let s = reported(view, k) {
                let ys = reach(view, k + 1, cues)
                out += ys + beforeSide(view, s, ys)
            }
        }
        // 2 a label before a colon: "Input: <m>", "Expected: <m>", "she wrote back: <m>"
        if t.trail.contains(":"), k + 1 < N {
            var label = Lex.frameNouns.contains(low) || Lex.expectVerbs.contains(low) || Lex.colonLabels.contains(low)
            if !label {
                var j = k
                while j > max(-1, k - 3) {
                    if j < k, view.gap[j + 1] != .none { break }
                    if Lex.colonReport.contains(v[j].low), !v[j].quoted {
                        label = true
                        break
                    }
                    j -= 1
                }
            }
            if label { out += reach(view, k + 1, cues) }
        }
        // 3 framing nouns
        let expected = Lex.expectedNouns.contains(low) && k >= 1 && view.gap[k] == .none && v[k - 1].low == Word.expected
        if Lex.frameNouns.contains(low) || Lex.repairNouns.contains(low) || expected, next {
            let n1 = v[k + 1]
            let n2: Token? = k + 2 < N && view.gap[k + 2] == .none ? v[k + 2] : nil
            // 3a a linker: "a test where <m>", "an input like <m>", "a fixture for <m>"
            if Lex.frameLinkers.contains(n1.low)
                || (n1.low == Word.of && (Lex.ofNouns.contains(low) || Lex.repairNouns.contains(low))),
               n2 != nil, linkedWords(view, k + 1) {
                out += reach(view, k + 2, cues)
            }
            // 3b the noun heads a subject: "the input is <m>", "the output should
            //    be <m>", "the transcript contains <m>", "an example of a repair is
            //    <m>" — not a value ("the output is 3 rows"), a place or a grade
            //    ("the message is from Sam", "the prompt is too long")
            if Lex.copulaNouns.contains(low) || Lex.repairNouns.contains(low) || expected {
                var hit: Int?
                if Lex.copulas.contains(n1.low) {
                    hit = k + 1
                } else if Lex.containVerbs.contains(n1.low), !Lex.repairNouns.contains(low), k + 2 < N,
                          view.gap[k + 2] == .none,
                          (k + 3 < N && view.gap[k + 3] == .none && v[k + 3].low == v[k + 2].low)
                            || !thingObject(view, k + 2) {
                    hit = k + 1
                } else if Lex.beModals.contains(n1.low), let n2, Lex.beLinks.contains(n2.low) {
                    hit = k + 2
                } else if n1.low == Word.of {
                    var j = k + 2
                    while j < min(N, k + 7) {
                        if view.gap[j] != .none { break }
                        if Lex.copulas.contains(v[j].low) {
                            hit = j
                            break
                        }
                        if Lex.function.contains(v[j].low), !Lex.npStart.contains(v[j].low) { break }
                        j += 1
                    }
                }
                if let hit, hit + 1 < N, view.gap[hit + 1] == .none {
                    let c = v[hit + 1]
                    let doubled = hit + 2 < N && view.gap[hit + 2] == .none && v[hit + 2].low == c.low
                    if !c.num || Lex.specimenNouns.contains(low) || Lex.repairNouns.contains(low),
                       doubled || (!Lex.prepositions.contains(c.low) && !Lex.degree.contains(c.low)) {
                        let ys = reach(view, hit + 1, cues)
                        // the before side: "for the input <m>, the output is <m>"
                        var s = expected ? k - 1 : k
                        if s >= 1, view.gap[s] == .none, Lex.npOpeners.contains(v[s - 1].low) { s -= 1 }
                        out += ys + beforeSide(view, s, ys)
                    }
                }
            }
            // 3c the words right after the noun ("the phrase <m>"): a doubled
            //    word after any framing noun ("the input over over"); after a
            //    noun that is never scheduled, words that open a clause, or a
            //    verb, a preposition and a number, name or time ("the example
            //    meet at 3, sorry, 4") — not a verb the noun is the subject of
            //    ("each example takes 5, sorry, 6 minutes")
            if k >= 1, view.gap[k] == .none, Lex.npOpeners.contains(v[k - 1].low), Lex.frameNouns.contains(low) {
                var words = n2 != nil && n2!.low == n1.low && !n1.core.isEmpty
                if !words, Lex.apposNouns.contains(low), !Lex.auxiliaries.contains(n1.low),
                   !Lex.prepositions.contains(n1.low) {
                    let finite = n1.alpha && n1.low.count > 3 && !Lex.clausey.contains(n1.low)
                        && ((n1.low.hasSuffix(Suffix.s) && !n1.low.hasSuffix(Suffix.ss)) || n1.low.hasSuffix(Suffix.ed))
                    func opens(_ x: Token) -> Bool { Lex.clausey.contains(x.low) || x.cap || x.num }
                    if !finite {
                        words = opens(n1) || (n2.map(opens) ?? false)
                        let n3: Token? = n2 != nil && k + 3 < N && view.gap[k + 3] == .none ? v[k + 3] : nil
                        if !words, let n2, Lex.prepositions.contains(n2.low), !Lex.function.contains(n1.low),
                           let n3, n3.num || n3.cap || Lex.temporal.contains(n3.low) {
                            words = true
                        }
                    }
                }
                if words { out += reach(view, k + 1, cues) }
            }
        }
        // 4 a rewrite verb: "turn <m> into <m>", "change <m> to <m>", "replace <m> with <m>"
        if let links = Lex.rewriteLinks[low], next {
            var j = k + 1
            while j < min(N, k + 1 + Lex.mentionReach) {
                if view.gap[j] == .hard { break }
                if links.contains(v[j].low) {
                    let xs = Array((k + 1)..<j)
                    let ys = j + 1 < N && view.gap[j + 1] == .none ? reach(view, j + 1, cues) : []
                    if !xs.isEmpty, !ys.isEmpty, deletesTo(view, xs, ys) { out += xs + ys }
                    break
                }
                j += 1
            }
        }
        // 5 a rewrite frame after the words: "<m> becomes <m>", "<m> should turn
        //   into <m>", "<m> comes out as <m>", "<m> is changed to <m>"
        for frame in Lex.postfixFrames {
            let L = frame.count
            if k + L < N, (0..<L).allSatisfy({ frame[$0].contains(v[k + $0].low) }), view.clean(k, k + L),
               !(0..<L).contains(where: { v[k + $0].quoted }) {
                var s = k
                while s >= 1, view.gap[s] == .none, Lex.frameAux.contains(v[s - 1].low) { s -= 1 }
                let xs = reachBack(view, s), ys = reach(view, k + L, cues)
                if !xs.isEmpty, !ys.isEmpty, deletesTo(view, xs, ys) { out += xs + ys }
                break
            }
        }
        // 6 an exemplifier: "for example <m>", "such as <m>", "like when <m>", "e.g. <m>"
        for ex in Lex.exemplifiers {
            let L = ex.count
            guard k + L < N, (0..<L).allSatisfy({ v[k + $0].low == ex[$0] }), view.clean(k, k + L - 1),
                  !(0..<L).contains(where: { v[k + $0].quoted }) else { continue }
            let g = view.gap[k + L]
            // "e.g." ends in its own full stop, which is no sentence end
            if g == .hard, !(L == 1 && rstripCommaColon(v[k].trail).elementsEqual(["."])) { break }
            // "For example, we could …" opens his own clause; "we could, for
            // example, meet at 2" is an aside inside his own sentence
            if g == .comma, Lex.subjectPronouns.contains(v[k + L].low) || Lex.hedges.contains(v[k + L].low)
                || (k >= 1 && view.gap[k] == .comma) { break }
            out += reach(view, k + L, cues)
            break
        }
        // 7 a repair named after the words: "<m> is a stutter", "<m> as a weekday swap"
        if Lex.repairNouns.contains(low), k >= 2 {
            var j = k - 1
            while j >= 1, view.gap[j + 1] == .none,
                  Lex.articles.contains(v[j].low) || (v[j].alpha && !Lex.function.contains(v[j].low) && k - j <= 2) {
                j -= 1
            }
            if view.gap[j + 1] == .none, Lex.naming.contains(v[j].low), j >= 1 { out += reachBack(view, j) }
        }
        // 9 literal fidelity right after the words: "keep <m> verbatim", "<m> stays as is"
        if k >= 1, view.gap[k] == .none {
            for mark in Lex.verbatim {
                let L = mark.count
                if k + L <= N, (0..<L).allSatisfy({ v[k + $0].low == mark[$0] }), view.clean(k, k + L - 1),
                   !(0..<L).contains(where: { v[k + $0].quoted }) {
                    out += clauseBack(view, k, cues)
                    break
                }
            }
        }
        // 10 a deletion described on the text: "deleted <x> from <m>", every word of x in m
        if Lex.editVerbs.contains(low), next {
            var j = k + 2
            while j < min(N, k + 6) {
                if view.gap[j] != .none { break }
                if Lex.editLinks.contains(v[j].low) {
                    let xs = Array((k + 1)..<j)
                    let ys = j + 1 < N && view.gap[j + 1] == .none ? reach(view, j + 1, cues) : []
                    let core = xs.map { v[$0].low }.filter { !Lex.articles.contains($0) }
                    let lows = Set(ys.map { v[$0].low })
                    if !ys.isEmpty, !core.isEmpty, core.allSatisfy(lows.contains) { out += xs + ys }
                    break
                }
                j += 1
            }
        }
        // 11 a test artifact the words are put into: "use <m> as the probe", "add <m> to the test"
        if Lex.specLinks.contains(low), k >= 1, view.gap[k] == .none, next {
            var i = k + 1
            while i < N, view.gap[i] == .none, Lex.npStart.contains(v[i].low) { i += 1 }
            var head: Int?
            for d in 0..<3 {
                if i + d >= N || view.gap[i + d] != .none { break }
                let w = v[i + d]
                if !w.alpha || Lex.function.contains(w.low) { break }
                head = i + d
            }
            if let head, Lex.specNouns.contains(v[head].low),
               head + 1 >= N || view.gap[head + 1] != .none || Lex.prepositions.contains(v[head + 1].low)
                || Lex.coordinators.contains(v[head + 1].low) {
                let back = clauseBack(view, k, cues)
                // the words are the object of a placing verb
                for (n, p) in back.enumerated() where Lex.placeVerbs.contains(v[p].low) && n + 1 < back.count {
                    out += back[(n + 1)...]
                    break
                }
            }
        }
        return out
    }

    /// Frame 8, a spoken quotation: every input token strictly between an
    /// opening marker phrase and the next closing one, paired as
    /// `SpokenStructure` pairs them — an opening one while a quotation is open
    /// is ignored, a closing one with none open closes nothing, and a pair
    /// with no word between quotes nothing.
    private static func spokenQuotation(_ toks: [Token]) -> Set<Int> {
        var out: Set<Int> = []
        var opened: Int?
        var k = 0
        let n = toks.count
        while k < n {
            guard let kind = toks[k].marker, kind == .quoteOpen || kind == .quoteClose else {
                k += 1
                continue
            }
            var j = k
            while j < n, toks[j].marker == kind { j += 1 }
            if kind == .quoteOpen {
                if opened == nil { opened = j }
            } else if let o = opened {
                if (o..<k).contains(where: { toks[$0].marker == nil }) { out.formUnion(o..<k) }
                opened = nil
            }
            k = j
        }
        return out
    }
}

/// Suffixes the mention frames test, built once.
private enum Suffix {
    static let possessive: ScalarString = "'s"
    static let s: ScalarString = "s"
    static let ss: ScalarString = "ss"
    static let ed: ScalarString = "ed"
    static let ing: ScalarString = "ing"
    static let en: ScalarString = "en"
    static let us: ScalarString = "us"
    static let isSuffix: ScalarString = "is"
}

// MARK: - R1 repetition, R1B inflected restart

extension SelfRepair {
    private enum RepeatHit {
        case skip(Int)
        case fire(n: Int, copies: [Int], kept: [Int])
    }

    /// R1. For each start p, units of n = 4, 3, 2, 1 view tokens said again
    /// right after (across a filler, a comma after a word that never closes a
    /// clause, or a soft "like" / "you know"): delete every copy but the last,
    /// keeping the soft fillers. A rejected one-word run is skipped whole —
    /// never fired on in part.
    static func ruleR1(_ ctx: Context, _ view: View) -> [Fire] {
        let v = view.v, N = view.n, G = ctx.guards
        var fires: [Fire] = []
        var p = 0
        while p < N {
            var hit: RepeatHit?
            units: for n in [4, 3, 2, 1] {
                if p + 2 * n > N { continue }
                // A second copy must start right after the unit (or, for one
                // word, after a soft "like" / "you know"): checked first, so
                // the common case allocates nothing.
                let next = v[p + n].low
                if n >= 2 ? next != v[p].low : (next != v[p].low && next != Word.like && next != Word.you) { continue }
                let unit = Array(v[p..<(p + n)])
                if unit.contains(where: { $0.quoted || $0.core.isEmpty }) || !view.clean(p, p + n - 1) { continue }
                let ulow = unit.map(\.low)
                // "again and again", "and so on and so on"
                if n >= 2, Set(ulow).count == 1 || ulow.contains(where: Lex.coordinators.contains) { continue }
                // "from time to time to see": the idiom X-prep-X
                if n == 2, !Lex.function.contains(ulow[0]), Lex.prepositions.contains(ulow[1]) { continue }
                // a chain "whack by whack by whack"
                if n >= 2, p >= 1, v[p - 1].low == ulow[n - 1], view.gap[p] == .none { continue }
                let hasNumber = unit.contains(where: \.num)
                var copies = [p], kept: [Int] = [], marked = false, q = p + n
                while q + n <= N {
                    var r = q, g = view.gap[q], soft: [Int] = []
                    if n == 1, v[q].low != ulow[0] {
                        soft = softInterregnum(view, q, ulow[0])
                        if soft.isEmpty { break }
                        r = q + soft.count
                        if r + n > N { break }
                        g = soft.reduce(g) { max($0, view.gap[$1 + 1]) }
                    }
                    if g == .hard { break }
                    let copy = v[r..<(r + n)]
                    if !copy.map(\.low).elementsEqual(ulow) || copy.contains(where: \.quoted)
                        || !view.clean(r, r + n - 1) { break }
                    let evidence = view.ev[q] || soft.contains { view.ev[$0 + 1] }
                    if g == .comma, !evidence, !(n == 1 && Lex.commaOK.contains(ulow[0])) { break }
                    if hasNumber, !evidence { break }
                    marked = marked || evidence || !soft.isEmpty || g != .none
                    copies.append(r)
                    kept += soft
                    q = r + n
                }
                if copies.count < 2 { continue }
                if repeatRejected(ctx, view, p: p, n: n, unit: unit, copies: copies, marked: marked, guards: G) {
                    if n == 1 {
                        hit = .skip(copies[copies.count - 1] + 1)
                        break units
                    }
                    continue
                }
                hit = .fire(n: n, copies: copies, kept: kept)
                break units
            }
            switch hit {
            case .skip(let next)?:
                p = next
            case .fire(let n, let copies, let kept)?:
                let keep = Set(kept.map { v[$0].index })
                let ids = view.upto(copies[0], copies[copies.count - 1]).filter { !keep.contains($0) }
                fires.append(Fire(rule: .r1, deleted: ids, cue: nil, note: "repeat x\(copies.count) n=\(n)"))
                ctx.caseFrom[v[copies[copies.count - 1]].index] = v[copies[0]].index
                p = copies[copies.count - 1] + n
            case nil:
                p += 1
            }
        }
        return fires
    }

    /// The doubles that are English, emphasis, names or symbols — not stutters.
    private static func repeatRejected(
        _ ctx: Context, _ view: View, p: Int, n: Int, unit: [Token], copies: [Int], marked: Bool,
        guards G: Set<Guard>
    ) -> Bool {
        let v = view.v, N = view.n
        let w = unit[0].low
        let ulow = unit.map(\.low)
        let copyTokens = copies.flatMap { c in (0..<n).map { v[c + $0] } }
        let last = v[copies[copies.count - 1]]
        let nxt = copies[copies.count - 1] + n
        let isFunction = Lex.function.contains(w)

        if n == 1 && Lex.legitDoubles.contains(w) { return true }
        // "what it is is": grammar after a wh-word in the same clause — with
        // [T22] (v6) only when a subject sits between ("What is is your name?"
        // is a stutter)
        if n == 1 && Lex.legitAfterWh.contains(w)
            && (G.contains(.t22) ? whSubject(view, p) : whBefore(view, p)) { return true }
        // "so so" (= mediocre) unless a pronoun or article follows ("so so I left")
        if n == 1 && w == "so"
            && !(nxt < N && (Lex.pronouns.contains(v[nxt].low) || Lex.articles.contains(v[nxt].low))) { return true }
        // "Bora Bora"
        if n == 1 && copies.allSatisfy({ v[$0].cap }) && !isFunction { return true }
        // chanted: "hee hee hee."
        if n == 1 && copies.count >= 3 && !isFunction && (nxt >= N || view.gap[nxt] == .hard) { return true }
        // FillerStripper collapses a bare function-word double identically
        if n == 1 && Lex.fillerStripperCollapsible.contains(w) && !marked
            && copyTokens.allSatisfy({ $0.raw == $0.core }) { return true }
        // "at AT&T"
        if copyTokens.contains(where: \.allCaps) && !copyTokens.allSatisfy(\.allCaps) { return true }
        // "the The Times"
        if !unit[0].cap && last.cap && !view.initial(copies[copies.count - 1]) && nxt < N && v[nxt].cap
            && view.gap[nxt] == .none { return true }

        // The red team's guards (reference v2; T3's list grew in v5)
        if G.contains(.t1) && n == 1 && !isFunction && auxDeterminerFrame(view, p) { return true }
        if G.contains(.t2a) && n == 1 && unit[0].cap && !view.initial(p) && !v[copies[1]].cap { return true }
        if G.contains(.t2b) && n == 1 && view.initial(p) && unit[0].cap && !v[copies[1]].cap
            && (Lex.namePast.contains(w) || (Lex.nameModal.contains(w) && !subjectAfter(view, nxt))) { return true }
        // T3: a fixed double, (v7) a word of another language English does
        // not use, or (v5) any double of a word that is not ASCII
        if G.contains(.t3) && n == 1 && (Lex.legitDoublesV2.contains(w) || Lex.foreignWords.contains(w)
            || !PyText.isASCII(w.scalars)
            || (w == "same" && !(p >= 1 && v[p - 1].low == "the" && view.gap[p] == .none))) { return true }
        if G.contains(.t4) && ((n == 1 && Lex.symbolWords.contains(w)) || Lex.spokenMarkers.contains(ulow)
            || Lex.symbolPhrases.contains(ulow)) { return true }
        if G.contains(.t6) && n == 1 && w == "do" && doEmphatic(view, p) { return true }
        if G.contains(.t7) && n == 1 && (w == "so" || w == "my") && (nxt >= N || view.gap[nxt] != .none) { return true }
        if G.contains(.t8) && n == 1 && w == "up" { return true }
        if G.contains(.t9) && n == 1 && w != "i" && copies.allSatisfy({ v[$0].cap }) && !view.initial(p) { return true }
        if G.contains(.t10) && n == 1 && nonword(unit[0])
            && !(nxt < N && v[nxt].alpha && v[nxt].low.hasPrefix(w) && v[nxt].low.count > w.count) { return true }

        // v5 guards (legitimate doubles, 2026-10-08)
        // T18: "Cool cool, see you then." — a double that stands alone
        if G.contains(.t18) && n == 1 && !isFunction && unit[0].alpha
            && !copies.dropFirst().contains(where: { view.ev[$0] }) && standsAlone(view, p, nxt) { return true }
        // T19: "what they are are"; "swing by by noon", "think it over over the weekend"
        if G.contains(.t19) && n == 1 {
            if Lex.whCopulas.contains(w) && whSubject(view, p) { return true }
            if copies.count == 2 && particleDouble(view, p, nxt, w) { return true }
        }
        return false
    }

    /// A wh-word among the 4 view tokens before p, with no HARD gap between it
    /// and p ("what it is is").
    private static func whBefore(_ view: View, _ p: Int) -> Bool {
        (max(0, p - 4)..<p).contains { k in
            Lex.whWords.contains(view.v[k].low) && !(k + 1...p).contains { view.gap[$0] == .hard }
        }
    }

    /// [T19] [T22] (v6) A wh-word among the 4 view tokens before p, then a
    /// subject that is no auxiliary, then the double, with no HARD gap between
    /// the wh-word and p ("what the options are are"; "Where are they, are are
    /// they coming?" is a stutter).
    private static func whSubject(_ view: View, _ p: Int) -> Bool {
        (max(0, p - 4)..<p).contains { k in
            Lex.whWords.contains(view.v[k].low) && p - k >= 2 && !Lex.auxiliaries.contains(view.v[k + 1].low)
                && !(k + 1...p).contains { view.gap[$0] == .hard }
        }
    }

    /// [T18] The run v[p] ..< v[nxt] has a break on both sides — the text's
    /// edge, a comma or a HARD gap — and a sentence edge on at least one: the
    /// whole sentence, or its first or last clause. (v7) A layout marker is a
    /// break but no sentence edge — the edge is the text's, or a HARD gap
    /// without the marker — and a run that opens a bulleted item is a list
    /// item, never alone ("bullet point eggs eggs bullet point milk" fires;
    /// "see you at eight new line hugs hugs" stays). (v8) Punctuation the
    /// recogniser wrote on the marker's own words is an edge like any other
    /// ("See you at eight new line. Hugs hugs, call me later." stays).
    private static func standsAlone(_ view: View, _ p: Int, _ nxt: Int) -> Bool {
        if view.bulletItem[p] { return false }
        let left = view.initial(p) || view.gap[p] == .comma
        let right = nxt >= view.n || view.gap[nxt] != .none
        let leftEdge = p == 0 || view.punctuationGap[p] == .hard
        let rightEdge = nxt >= view.n || view.punctuationGap[nxt] == .hard
        return left && right && (leftEdge || rightEdge)
    }

    /// [T19] The number v[k] reads as a clock time: an hour (1–12), or a time
    /// with ":" or am / pm, followed by a break, the end, a clock or time
    /// word, or a function word that does not count ("by 5 if you can"; not
    /// "by 5 percent", "by 5 each year").
    private static func clock(_ view: View, _ k: Int) -> Bool {
        let v = view.v, N = view.n
        let low = v[k].low
        guard Lex.hours.contains(low) || low.scalars.contains(":") || low.hasSuffix("am") || low.hasSuffix("pm")
        else { return false }
        if k + 1 >= N || view.gap[k + 1] != .none { return true }
        let next = v[k + 1].low
        return Lex.clockWords.contains(next) || Lex.temporal.contains(next)
            || (Lex.function.contains(next) && !Lex.amountFunction.contains(next))
    }

    /// [T19] v[k] opens a time after the particle w: a clock time after "by"
    /// or "around" ("by 5", "by 6 pm"; after "over" a number is an amount),
    /// or a time word after a determiner and up to two modifiers or numbers
    /// ("by noon", "by the end of the day", "the last two weeks"; "two weeks
    /// of data" is not a time).
    private static func timeAfter(_ view: View, _ k: Int, _ w: ScalarString) -> Bool {
        let v = view.v, N = view.n
        if k >= N || view.gap[k] != .none { return false }
        let t = v[k]
        if t.num { return Lex.clockParticles.contains(w) && clock(view, k) }
        var j = Lex.npStart.contains(t.low) || Lex.timeDeterminers.contains(t.low) ? k + 1 : k
        for _ in 0..<3 {
            if j >= N || view.gap[j] != .none { return false }
            let w = v[j].low
            if Lex.temporal.contains(w) || Lex.timeNouns.contains(w) {
                return !(j + 1 < N && view.gap[j + 1] == .none && v[j + 1].low == Word.of && !Lex.timeOf.contains(w))
            }
            if !Lex.timeModifiers.contains(w) && !v[j].num { return false }
            j += 1
        }
        return false
    }

    /// [T19] A phrasal verb's particle, then the same word heading a phrase.
    /// Right after the verb only a time can follow ("swing by by noon"; "we
    /// went over over these numbers" is a stutter); after verb and object, a
    /// noun phrase too ("think it over over the weekend", "pass the box over
    /// over the fence").
    private static func particleDouble(_ view: View, _ p: Int, _ nxt: Int, _ w: ScalarString) -> Bool {
        let v = view.v, N = view.n
        guard let verbs = Lex.particleVerbs[w], p >= 1, view.gap[p] == .none, view.gap[p + 1] == .none,
              !view.ev[p + 1] else { return false }
        if verbs.contains(v[p - 1].low) { return timeAfter(view, nxt, w) }
        let j = p - 1
        var k: Int
        if Lex.objectPronouns.contains(v[j].low) || Lex.demonstratives.contains(v[j].low) {
            k = j - 1
        } else {
            if !v[j].alpha || Lex.function.contains(v[j].low) { return false }
            var found: Int?
            for i in [j - 1, j - 2] {
                if i < 0 || view.gap[i + 1] != .none { break }
                if Lex.npStart.contains(v[i].low) { found = i - 1; break }
                if Lex.function.contains(v[i].low) || !v[i].alpha { break }
            }
            guard let f = found else { return false }
            k = f
        }
        if k < 0 || view.gap[k + 1] != .none || !verbs.contains(v[k].low) { return false }
        if timeAfter(view, nxt, w) { return true }
        if nxt >= N || view.gap[nxt] != .none { return false }
        let t = v[nxt]
        return Lex.npStart.contains(t.low) || Lex.temporal.contains(t.low) || (t.cap && t.alpha)
    }

    /// The view indices of a soft filler ("like" | "you know") at q, or [].
    private static func softInterregnum(_ view: View, _ q: Int, _ word: ScalarString) -> [Int] {
        guard Lex.softInterregnumOK.contains(word), !view.ev[q] else { return [] }
        let v = view.v
        if v[q].low == Word.like, !v[q].quoted { return [q] }
        if q + 1 < view.n, v[q].low == Word.you, v[q + 1].low == Word.know, view.gap[q + 1] == .none { return [q, q + 1] }
        return []
    }

    /// [T1] "Does the fix fix …": a determiner right before v[p] and a QAUX
    /// word 1–2 tokens before it, no HARD gap between. The first copy is the
    /// subject noun, the second the bare verb — so a plural-looking word
    /// ("Did the dishes dishes") is never in the frame.
    private static func auxDeterminerFrame(_ view: View, _ p: Int) -> Bool {
        let v = view.v
        if p < 2 || view.gap[p] != .none || !Lex.t1Determiners.contains(v[p - 1].low) { return false }
        let w = v[p].low
        if w.hasSuffix("s") && !(w.hasSuffix("ss") || w.hasSuffix("us") || w.hasSuffix("is") || w.hasSuffix("as")) {
            return false
        }
        for k in [p - 2, p - 3] {
            if k < 0 || view.gap[k + 1] == .hard { break }
            if Lex.questionAuxiliaries.contains(v[k].low) { return true }
        }
        return false
    }

    /// [T2b] v[k] follows with a NONE gap and can open a subject.
    private static func subjectAfter(_ view: View, _ k: Int) -> Bool {
        if k >= view.n || view.gap[k] != .none { return false }
        let t = view.v[k]
        return Lex.pronouns.contains(t.low) || Lex.articles.contains(t.low) || Lex.demonstratives.contains(t.low)
            || Lex.possessives.contains(t.low) || (t.cap && t.alpha)
    }

    /// [T6] "do do" is emphatic right after its subject: a DO_SUBJECTS word or
    /// a content word ("They do do code review", "clients do do read it").
    private static func doEmphatic(_ view: View, _ p: Int) -> Bool {
        if p < 1 || view.gap[p] != .none { return false }
        let b = view.v[p - 1]
        return Lex.doSubjects.contains(b.low) || (b.alpha && !Lex.function.contains(b.low))
    }

    /// [T10] A token R3a could call a non-word: 1–2 lower-case ASCII letters
    /// that are no short word, prefix or skipped letter.
    private static func nonword(_ t: Token) -> Bool {
        let c = t.core
        return !c.isEmpty && c.count <= 2 && PyText.isASCII(c) && PyText.isAlpha(c) && PyText.isLower(c)
            && !Lex.shortWords.contains(t.low) && !Lex.prefixSplits.contains(t.low)
            && !Lex.r3SkipLetters.contains(t.low)
    }

    private static func fragmentLike(_ t: Token) -> Bool {
        let c = t.core
        return !c.isEmpty && PyText.isASCII(c) && PyText.isAlpha(c) && PyText.isLower(c) && (1...2).contains(c.count)
            && !Lex.shortWords.contains(t.low)
    }

    private static let notPlural: Set<ScalarString> = ["one", "1", "zero", "0"]

    /// R1B. "two more server servers": a word restarted as its plural, after
    /// a plural trigger or a number within the two tokens before it.
    static func ruleR1B(_ ctx: Context, _ view: View) -> [Fire] {
        let v = view.v
        guard view.n >= 2 else { return [] }
        var fires: [Fire] = []
        var last = -1
        for p in 0..<(view.n - 1) {
            let a = v[p], b = v[p + 1]
            if p <= last || a.quoted || b.quoted || !(a.alpha && b.alpha) { continue }
            if view.gap[p + 1] != .none || a.low.count < 3 || Lex.function.contains(a.low) { continue }
            let al = a.low, bl = b.low
            guard bl == al + "s" || bl == al + "es" || (al.hasSuffix("y") && bl == al.droppingLast + "ies") else {
                continue
            }
            var trigger = false
            for k in [p - 1, p - 2] {
                if k < 0 || view.gap[k + 1] == .hard { break }
                let t = v[k]
                if Lex.pluralTriggers.contains(t.low) || (t.num && !notPlural.contains(t.low)) { trigger = true }
            }
            if trigger {
                fires.append(Fire(rule: .r1b, deleted: view.ids(p, p + 1), cue: nil, note: "inflected restart"))
                last = p + 1
            }
        }
        return fires
    }
}

// MARK: - R2 restart, R2B pronoun restart

extension SelfRepair {
    /// R2. "G B G": a head G (1–3 tokens) and an abandoned remainder B (1–3,
    /// |G| + |B| ≤ 4), then G again — "I told them to I told you to stop".
    /// Delete G B, or, on the keep-B reading ("the tickets go that go
    /// stale"), only the first G.
    static func ruleR2(_ ctx: Context, _ view: View) -> [Fire] {
        let v = view.v, N = view.n
        var fires: [Fire] = []
        var p = 0
        while p < N {
            var hit: (flen: Int, r: Int, keepB: Bool, h: Int)?
            search: for h in [3, 2, 1] {
                for blen in [1, 2, 3] {
                    let flen = h + blen
                    if flen > 4 || p + flen + h > N { continue }
                    // The restatement opens with the head's first word.
                    if v[p + flen].low != v[p].low { continue }
                    let F = Array(v[p..<(p + flen)])
                    if F.contains(where: { $0.num || $0.quoted || $0.core.isEmpty }) || !view.clean(p, p + flen - 1) {
                        continue
                    }
                    let r = p + flen
                    let H2 = Array(v[r..<(r + h)])
                    if H2.contains(where: { $0.num || $0.quoted }) || !view.clean(r, r + h - 1) { continue }
                    if !H2.map(\.low).elementsEqual(F[0..<h].map(\.low)) { continue }
                    // "ab ab ab": one repeated token is R1's call
                    if ctx.guards.contains(.t10), Set(F.map(\.low) + H2.map(\.low)).count == 1 { continue }
                    let g = view.gap[r]
                    if g == .hard || (g == .comma && !view.ev[r]) { continue }
                    let B = Array(F[h...])
                    let frag = B.map(fragmentLike)
                    let head = F[0].low
                    var keepB = false
                    if Lex.r2HeadBlock.contains(head) { continue }
                    // [T23] (v7) "Uno a uno we checked", "mais e mais": an idiom
                    if ctx.guards.contains(.t23), h == 1, otherLanguage(head) { continue }
                    if view.ev[r] {
                        // a filler between the attempt and the restart: B may be
                        // any closed-class words ("respect the limit before, um,
                        // respect the limit after")
                        if !zip(B, frag).allSatisfy({
                            (Lex.function.contains($0.low) && !Lex.coordinators.contains($0.low)) || $1
                        }) { continue }
                        if h == 1, Lex.function.contains(head), !Lex.r2FunctionHeads.contains(head) { continue }
                        if h >= 2, F[0..<h].contains(where: { Lex.coordinators.contains($0.low) }) { continue }
                    } else if h == 1 {
                        if F[0].core.count < 2 || blen != 1 { continue }
                        let b0 = B[0].low
                        if Lex.function.contains(head) {
                            if !Lex.r2FunctionHeads.contains(head) { continue }
                            if !(Lex.articles.contains(b0) || Lex.possessiveDeterminers.contains(b0) || b0 == "one"
                                 || frag[0]) { continue }
                        } else if frag[0] {
                            // a content head and a fragment: always a restart
                        } else if view.initial(p), Lex.r2InitialB.contains(b0) {
                            // an imperative or topic restart opening a sentence;
                            // the restatement must carry on ("Keep our keep the
                            // copy short")
                            if view.after(r) != .none || r + 1 >= N || Lex.coordinators.contains(v[r + 1].low) {
                                continue
                            }
                        } else {
                            if !Lex.r2KeepB.contains(b0) { continue }
                            // "the kids that kids admire": a relative clause
                            if p >= 1, Lex.slotOpeners.contains(v[p - 1].low) { continue }
                            keepB = true
                        }
                    } else {
                        if F[0..<h].contains(where: { Lex.coordinators.contains($0.low) }) { continue }
                        if !zip(B, frag).allSatisfy({ Lex.r2BInner.contains($0.low) || $1 }) { continue }
                        if !(Lex.r2BLast.contains(B[B.count - 1].low) || frag[frag.count - 1]) { continue }
                    }
                    hit = (flen, r, keepB, h)
                    break search
                }
            }
            if let hit {
                let ids = hit.keepB ? view.upto(p, p + hit.h) : view.upto(p, hit.r)
                fires.append(Fire(rule: .r2, deleted: ids, cue: nil,
                                  note: "restart |F|=\(hit.flen)" + (hit.keepB ? " keep B" : "")))
                p = hit.r
            } else {
                p += 1
            }
        }
        return fires
    }

    /// [T23] (v7) w is a word of another language, as T3 reads one: not
    /// ASCII, on `foreignWords`, or on `legitDoublesV2` but not one of its
    /// English words. R2's restart grammar is English: a one-word head of
    /// another language opens an idiom ("Uno a uno", "Dia a dia"), not an
    /// abandoned start.
    private static func otherLanguage(_ w: ScalarString) -> Bool {
        !PyText.isASCII(w.scalars) || Lex.foreignWords.contains(w)
            || (Lex.legitDoublesV2.contains(w) && !Lex.legitDoublesV2English.contains(w))
    }

    /// R2B. "I we should leave": a lone "I" restarted as another subject
    /// pronoun — not the numeral of "World War I".
    static func ruleR2B(_ ctx: Context, _ view: View) -> [Fire] {
        let v = view.v
        guard view.n >= 2 else { return [] }
        var fires: [Fire] = []
        for p in 0..<(view.n - 1) {
            let a = v[p], b = v[p + 1]
            if a.low != Word.i || a.quoted || b.quoted || view.gap[p + 1] != .none { continue }
            if p >= 1, v[p - 1].cap, !view.initial(p - 1), view.gap[p] == .none { continue }
            if Lex.r2bNext.contains(b.low), view.after(p + 1) != .hard, p + 2 < view.n {
                fires.append(Fire(rule: .r2b, deleted: view.ids(p, p + 1), cue: nil, note: "pronoun restart"))
            }
        }
        return fires
    }
}

// MARK: - R3 fragments

extension SelfRepair {
    private static let inflections: [ScalarString] = ["s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "y", "en", "ies"]
    private static let eInflections: [ScalarString] = ["ing", "ed", "er", "est", "y"]

    /// b is a, inflected ("run" → "runs", "running", "ran" is not).
    private static func isInflection(_ a: ScalarString, _ b: ScalarString) -> Bool {
        if inflections.contains(where: { b == a + $0 }) { return true }
        if let lastScalar = a.scalars.last,
           inflections.contains(where: { b == a + ScalarString([lastScalar]) + $0 }) { return true }
        if a.hasSuffix("e"), eInflections.contains(where: { b == a.droppingLast + $0 }) { return true }
        return false
    }

    /// R3. A cut-off word: R3c "the sto, the stock room" (the function word
    /// and the fragment go), R3b "sen sentences" (a prefix of the next word),
    /// R3a a 1–2 letter non-word between words. Never a dictionary term, a
    /// quoted token, an elision, a spelled letter or a unit.
    static func ruleR3(_ ctx: Context, _ view: View) -> [Fire] {
        let v = view.v, N = view.n, G = ctx.guards
        var fires: [Fire] = []
        for p in 0..<N {
            let t = v[p]
            let c = t.core
            if t.quoted || c.isEmpty || ctx.protect.contains(t.low) { continue }
            if !(PyText.isASCII(c) && PyText.isAlpha(c) && PyText.isLower(c)) { continue }
            // elisions ('em, wi'), symbols (&c)
            if t.raw.contains(where: { $0 == "'" || $0 == "\u{2019}" || $0 == "\u{2018}" }) || !t.lead.isEmpty {
                continue
            }
            let nxt: Token? = p + 1 < N ? v[p + 1] : nil
            let prv: Token? = p > 0 ? v[p - 1] : nil
            let after = view.after(p)
            // a repeated token is R1's call, not a fragment
            if G.contains(.t10), nxt?.low == t.low || prv?.low == t.low { continue }
            // "add an s so it's plural": the letter itself
            if G.contains(.t11a), c.count == 1, let prv, prv.low == "an", view.gap[p] == .none,
               Lex.anLetters.contains(t.low) { continue }
            // "a 10 k kind of", "5 mi, miles": a unit (after digits only — "the
            // second mi migration" is a fragment)
            if G.contains(.t11b), let prv, prv.num, let first = prv.core.first, PyText.isDigit(first),
               view.gap[p] == .none, Lex.unitAbbreviations.contains(t.low) { continue }
            let spelled = c.count == 1 && (max(0, p - 3)..<min(N, p + 4)).contains { k in
                k != p && v[k].core.count == 1 && v[k].alpha && v[k].low != "a" && v[k].low != "i"
            }
            let prefixOK = (1...3).contains(c.count) && !Lex.function.contains(t.low) && !Lex.r3bKeep.contains(t.low)
                && !(c.count == 3 && Lex.common3.contains(t.low)) && (after == .none || after == .comma) && !spelled
            // R3c: a function word, a fragment, the function word again, then
            // the word the fragment began
            if prefixOK, let prv, Lex.function.contains(prv.low), view.gap[p] == .none, p + 2 < N,
               v[p + 1].low == prv.low, view.gap[p + 2] == .none, v[p + 2].alpha, !v[p + 2].quoted,
               v[p + 2].low.hasPrefix(t.low), v[p + 2].low.count >= t.low.count + 1,
               !isInflection(t.low, v[p + 2].low) {
                fires.append(Fire(rule: .r3, deleted: view.upto(p - 1, p + 1), cue: nil, note: "fragment restart"))
                continue
            }
            // R3b: a fragment, then the word it began
            if prefixOK, let nxt, nxt.alpha, !nxt.quoted, nxt.low.hasPrefix(t.low),
               nxt.low.count >= t.low.count + 1, !isInflection(t.low, nxt.low) {
                fires.append(Fire(rule: .r3, deleted: view.ids(p, p + 1), cue: nil, note: "prefix fragment"))
                continue
            }
            // R3a: a 1–2 letter non-word between two words (not at the
            // `fillers` level)
            if !ctx.nonWords { continue }
            if !(1...2).contains(c.count) { continue }
            if Lex.shortWords.contains(t.low) || Lex.prefixSplits.contains(t.low) || Lex.r3SkipLetters.contains(t.low) {
                continue
            }
            // [T20] a word all the same: "ti amo", "kung fu"
            if G.contains(.t20), Lex.r3aKeep.contains(t.low) { continue }
            guard let prv, !view.initial(p), after != .hard else { continue }
            guard let nxt, nxt.alpha else { continue }
            if prv.num || nxt.num || prv.core.count == 1 || nxt.core.count == 1 { continue }
            if c.count == 1, Lex.letterNouns.contains(nxt.low) || Lex.letterBefore.contains(prv.low) { continue }
            // a designation: "Pegasi b", "Plan b"
            if c.count == 1, prv.cap, !view.initial(p - 1) { continue }
            // spelled letters: "m, n, and q"
            if spelled { continue }
            fires.append(Fire(rule: .r3, deleted: view.ids(p, p + 1), cue: nil, note: "non-word"))
        }
        return fires
    }
}

// MARK: - R4, R5 cued corrections; R4S sentence retraction

extension SelfRepair {
    enum Kind { case weekday, month, daytime, number, color, direction, frequency, name }

    /// A closed class two swapped words must share ("Monday" / "Tuesday").
    static func kind(_ view: View, _ k: Int) -> Kind? {
        let t = view.v[k], low = t.low
        if low.isEmpty { return nil }
        if Lex.weekdays.contains(low) { return .weekday }
        if Lex.months.contains(low) || (low == "may" && t.cap) { return .month }
        if Lex.daytime.contains(low) { return .daytime }
        if t.num { return .number }
        if Lex.colors.contains(low) { return .color }
        if Lex.directions.contains(low) { return .direction }
        if Lex.frequency.contains(low) { return .frequency }
        if t.cap && t.alpha && !view.initial(k) && !Lex.function.contains(low) { return .name }
        return nil
    }

    /// [T24] (v8) v[b] heads a verb phrase: a word that can be a verb
    /// (alphabetic, not a function word or a predeterminer, tagged Noun, Verb
    /// or Adjective — not "just the leads", "half the team") with, right after
    /// it and no break, an object — a determiner, a possessive or an object
    /// pronoun that does not open a time ("salad this time") — or a verb
    /// particle (NLTagger's Particle, not the infinitive "to") followed by an
    /// object, a preposition, a break or the end ("warm up the cache", "log
    /// out of it").
    static func headsVerbPhrase(_ ctx: Context, _ view: View, _ b: Int) -> Bool {
        let v = view.v, N = view.n
        let k = b + 1
        if k >= N || view.gap[k] != .none { return false }
        if !canBeVerb(ctx, v[b]) { return false }
        let t = v[k], j = k + 1
        if Lex.verbPhraseObjects.contains(t.low) {
            return !(Lex.timeOpeners.contains(t.low) && j < N && view.gap[j] == .none
                && Lex.timeWords.contains(v[j].low))
        }
        if ctx.tag(t.index) != "Particle" || t.low == Word.to { return false }
        return j >= N || view.gap[j] != .none || Lex.verbPhraseObjects.contains(v[j].low)
            || Lex.prepositions.contains(v[j].low)
    }

    /// [T24] A word that can be a verb: alphabetic, not a function word or a
    /// predeterminer, tagged Noun, Verb or Adjective ("just the leads", "half
    /// the team" are not).
    static func canBeVerb(_ ctx: Context, _ t: Token) -> Bool {
        if !t.alpha || Lex.function.contains(t.low) || Lex.predeterminers.contains(t.low) { return false }
        let tag = ctx.tag(t.index)
        return tag == "Noun" || tag == "Verb" || tag == "Adjective"
    }

    /// [T24] (v10) How the phrase after the cue says X_last again.
    enum Restatement { case none, ambiguous, object }

    /// [T24] (v9; v10: only as its object) The phrase from v[b] says X_last
    /// v[a] again as its object — the verb changed, the object stayed ("clear
    /// out the cache" after "the cache", "fork Sam's branch"). X_last is
    /// alphabetic, no function word and not tagged Verb; v[b] can be a verb;
    /// X_last's word comes back 2 to 4 tokens after v[b], not quoted, every
    /// gap none, with only determiners or possessives between — (v11) and
    /// the object's own modifiers after one ("archive the old files"), and a
    /// two-word verb's second word, not in -ing and not after a possessive,
    /// right before one ("power wash the deck") — after at most
    /// one particle right after v[b]: `.object` with none or one of out, up,
    /// down, back, away; `.ambiguous` after in, on, off, over ("hand in the
    /// forms" reads like "the lock on the door"); `.none` otherwise — X said
    /// again across a coordinator, another preposition or any other word is
    /// no object ("link to the file", "salad and pizza": v9 read them as the
    /// verb's).
    static func restatesX(_ ctx: Context, _ view: View, _ a: Int, _ b: Int) -> Restatement {
        let v = view.v, N = view.n
        let x = v[a]
        if !x.alpha || Lex.function.contains(x.low) || ctx.tag(x.index) == "Verb" || !canBeVerb(ctx, v[b]) {
            return .none
        }
        var particle: ScalarString?
        var determiner = false
        var k = b + 1
        while k < min(b + 5, N) {
            let t = v[k]
            if view.gap[k] != .none { return .none }
            if k >= b + 2 && t.low == x.low && !t.quoted {
                if let p = particle, Lex.ambiguousParticles.contains(p) { return .ambiguous }
                return .object
            }
            if k == b + 1 && (Lex.restateParticles.contains(t.low) || Lex.ambiguousParticles.contains(t.low)) {
                particle = t.low
            } else if Lex.npDeterminers.contains(t.low) || possessive(t) {
                determiner = true
            } else if t.alpha && !Lex.function.contains(t.low)
                        && (determiner || (k == b + 1 && !t.low.hasSuffix(Suffix.ing) && !possessive(v[b])
                                           && opensObject(view, k + 1))) {
                // (v11) the object's own modifier ("archive the old files"), or a
                // two-word verb's second word ("power wash the deck"; not a
                // reduced relative, "paralegal assisting the lawyer", nor after a
                // possessive, "Sam's summary a vendor")
            } else {
                return .none
            }
            k += 1
        }
        return .none
    }

    /// [T24] (v11) v[k] follows with no break and is a determiner or a
    /// possessive.
    private static func opensObject(_ view: View, _ k: Int) -> Bool {
        k < view.n && view.gap[k] == .none && (Lex.npDeterminers.contains(view.v[k].low) || possessive(view.v[k]))
    }

    /// [T24] (v12) The phrase after the cue opens with a capitalised word
    /// inside its sentence — a name, no new verb ("scratch that, Dana Smith
    /// the invoice", "Dana Smith's draft", "Sam the invoice").
    private static func named(_ view: View, _ y: Int) -> Bool {
        let t = view.v[y]
        return t.cap && t.alpha && !view.initial(y)
    }

    /// [T24] (v12) The word right after the word after the cue (no break) is
    /// no two-word verb's second word but an inflected form — alphabetic, no
    /// function word, determiner, possessive or particle, not in -ing, and in
    /// -ed (four or more letters), in -s (three or more, not -ss, -us or -is)
    /// or an irregular past (`irregularPast`): the two are a subject and its
    /// verb ("Sam called the vendor", "mom paid the invoice") or a plural noun
    /// phrase ("new hires the invoice"); a two-word verb's second word is its
    /// base form ("power wash the deck").
    private static func inflectedSecond(_ view: View, _ y: Int) -> Bool {
        let k = y + 1
        if k >= view.n || view.gap[k] != .none { return false }
        let t = view.v[k], w = t.low
        if !t.alpha || Lex.function.contains(w) || Lex.npDeterminers.contains(w) || possessive(t)
            || Lex.restateParticles.contains(w) || Lex.ambiguousParticles.contains(w) || w.hasSuffix(Suffix.ing) {
            return false
        }
        if w.count >= 4 && w.hasSuffix(Suffix.ed) { return true }
        if w.count >= 3 && w.hasSuffix(Suffix.s)
            && !(w.hasSuffix(Suffix.ss) || w.hasSuffix(Suffix.us) || w.hasSuffix(Suffix.isSuffix)) {
            return true
        }
        return Lex.irregularPast.contains(w)
    }

    /// [T24] (v12) A possessive right after the word after the cue (no break)
    /// whose own modifier that word is: it is tagged Adjective ("last week's
    /// report", "new hire's laptop"), or tagged Noun before a possessor in
    /// lower case that needs a determiner of its own ("head chef's notes";
    /// "email everyone's notes" is a verb and its object).
    private static func modifierPossessor(_ ctx: Context, _ view: View, _ y: Int) -> Bool {
        let k = y + 1
        if k >= view.n || view.gap[k] != .none || !possessive(view.v[k]) { return false }
        let tag = ctx.tag(view.v[y].index)
        if tag == "Adjective" { return true }
        return tag == "Noun" && !view.v[k].cap && !Lex.possessorsWithoutDeterminer.contains(view.v[k].low)
    }

    /// [T24] (v12) `restatesX`'s object reading is no verb's evidence — it
    /// still stops the noun swap — when the phrase after the cue opens with a
    /// name, when the word after its first word is inflected, or when its
    /// first word modifies a possessive.
    private static func restatementRefused(_ ctx: Context, _ view: View, _ y: Int) -> Bool {
        named(view, y) || inflectedSecond(view, y) || modifierPossessor(ctx, view, y)
    }

    /// [T24] (v12) X_last said again as the word after the cue's object
    /// (`.object`), read as a verb's evidence: not refused.
    private static func restatementEvidence(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int) -> Bool {
        restatesX(ctx, view, xl, y) == .object && !restatementRefused(ctx, view, y)
    }

    /// [T24] (v9) An object pronoun that is no determiner (it, them, him, me,
    /// us) after v[y], with no break — no noun takes one: right after a word
    /// that can be a verb, or after its particle (NLTagger's Particle, not
    /// "to") and a preposition ("delete it", "log out of it"); or after an
    /// adverb with a particle after the pronoun ("back them up"; not "maybe
    /// it"). (v10) After a word that can be a verb, "her" counts too where no
    /// noun can follow it: at a break or the end, or before a word of
    /// `herAfter` ("text her", "call her tonight"; v9 kept "Call the vendor,
    /// scratch that, text her" both ways).
    static func objectAfter(_ ctx: Context, _ view: View, _ y: Int) -> Bool {
        let v = view.v, N = view.n
        let t = v[y]
        var j = y + 1
        if canBeVerb(ctx, t) {
            if j < N && view.gap[j] == .none && ctx.tag(v[j].index) == "Particle" && v[j].low != Word.to {
                j += 1
                if j < N && view.gap[j] == .none && Lex.prepositions.contains(v[j].low) { j += 1 }
            }
            if j >= N || view.gap[j] != .none || v[j].quoted { return false }
            if Lex.objectPronounsStrict.contains(v[j].low) { return true }
            return v[j].low == Word.her
                && (j + 1 >= N || view.gap[j + 1] != .none || Lex.herAfter.contains(v[j + 1].low))
        }
        if t.alpha && !Lex.function.contains(t.low) && ctx.tag(t.index) == "Adverb" {
            return j + 1 < N && view.gap[j] == .none && Lex.objectPronounsStrict.contains(v[j].low) && !v[j].quoted
                && view.gap[j + 1] == .none && ctx.tag(v[j + 1].index) == "Particle" && v[j + 1].low != Word.to
        }
        return false
    }

    /// [T24] (v9) The phrase after the cue heads a verb phrase (v10: X_last
    /// said again as its object, not across in / on / off / over). (v12) A
    /// name opening the phrase is no `headsVerbPhrase` evidence ("Sam the
    /// invoice"), and the restatement counts only as evidence
    /// (`restatementEvidence`).
    static func verbPhraseAfter(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int) -> Bool {
        (headsVerbPhrase(ctx, view, y) && !named(view, y)) || restatementEvidence(ctx, view, xl, y)
            || objectAfter(ctx, view, y)
    }

    /// [T24] (v12) v11's `verbPhraseAfter`: the verb phrase v11 read. Where it
    /// holds and `verbPhraseAfter` does not, a refusal took that reading away.
    private static func verbPhraseRead(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int) -> Bool {
        headsVerbPhrase(ctx, view, y) || restatesX(ctx, view, xl, y) == .object || objectAfter(ctx, view, y)
    }

    /// [T24] (v9) After "scratch that", a verb-phrase shape a noun with its
    /// own object, indirect object or reduced relative has too ("client the
    /// slides", "electrician my neighbor recommended"): Y and X_last tagged
    /// Noun, X_last heading a noun phrase, and no verb's evidence (X_last said
    /// again as its object — v12: `restatementEvidence` — or an object
    /// pronoun).
    static func nounReading(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int) -> Bool {
        let v = view.v
        return ctx.tag(v[y].index) == "Noun" && ctx.tag(v[xl].index) == "Noun" && !Lex.function.contains(v[xl].low)
            && nounPhraseHead(ctx, view, xl) && !restatementEvidence(ctx, view, xl, y)
            && !objectAfter(ctx, view, y)
    }

    /// [T26] (v9) The phrase after the cue is a verb phrase with no subject of
    /// its own: no subject word, contracted pronoun or auxiliary first, and a
    /// verb to NLTagger or a verb phrase's shape.
    private static func bareVerbPhrase(_ ctx: Context, _ view: View, _ y: Int, _ vp: Bool) -> Bool {
        let t = view.v[y]
        if Lex.subjectWords.contains(t.low) || contracted(t) || Lex.auxiliaries.contains(t.low) { return false }
        return ctx.tag(t.index) == "Verb" || vp
    }

    /// [T26] (v10) v[i] opens a relative clause: who, whom, whose or which,
    /// alone or contracted ("who'll", "who's": the word before its "'"); or
    /// that or where (also "that'll", "that's") right after a word tagged
    /// Noun, or "one" / "ones", with no break ("the room that we can use",
    /// "the one that can fix it", "the room where we can meet"; "I think
    /// that we should", "tell me where we can park" are none); (v11) "when"
    /// only after an article and a time noun (`relativeTimeHeads`: "a time
    /// when we can meet"; not "the client when you can", "tomorrow when").
    private static func relative(_ ctx: Context, _ view: View, _ i: Int) -> Bool {
        let t = view.v[i]
        let base = ScalarString(t.low.scalars.prefix(while: { $0 != "'" }))
        if Lex.relativeWords.contains(base) { return true }
        if !Lex.nounRelativeWords.contains(base) || i < 1 || view.gap[i] != .none { return false }
        let p = view.v[i - 1]
        if base == Word.when {
            // (v11) "a time when", not "the client when" / "tomorrow when"
            return Lex.relativeTimeHeads.contains(p.low) && i >= 2 && view.gap[i - 1] == .none
                && Lex.articles.contains(view.v[i - 2].low)
        }
        return ctx.tag(p.index) == "Noun" || p.low == Word.one || p.low == Word.ones
    }

    /// [T26] (v9) Where "scratch that" takes back X_last's verb phrase and not
    /// its clause: the last verb in the clause after s (no auxiliary,
    /// contracted pronoun or quoted word) whose lead-in stays — an auxiliary
    /// or modal, a coordinator, "to", "please" or a contracted pronoun, across
    /// at most two adverbs ("I'll call him", "and then deleted", "want to
    /// delete"), or a subject pronoun after an auxiliary or a coordinator
    /// ("can you email", "and she texted"). None: s, the whole clause. (v10)
    /// A verb after a relative word is in a relative clause, not X's own verb
    /// phrase: the scan runs only before the first relative word from s on
    /// ("Email the guy who can fix it, scratch that, call him" → "Call him.";
    /// "Please email the guy who can fix it, …" still finds "email"). (v11)
    /// With no verb before the relative word the relative clause is in the
    /// subject, and the scan runs after `mainResumes` instead ("The client
    /// who called will email the contract, scratch that, mail the contract"
    /// → "The client who called will mail the contract").
    private static func verbPhraseStart(_ ctx: Context, _ view: View, _ s: Int, _ xl: Int) -> Int {
        let v = view.v
        var top = xl, low = s
        for i in s...xl where relative(ctx, view, i) {
            top = i - 1
            // (v11) a relative clause in the subject: the main clause resumes after it
            if !(s..<i).contains(where: { verbal(ctx, v[$0]) }), let m = mainResumes(ctx, view, i, xl) {
                top = xl
                low = m
            }
            break
        }
        for k in stride(from: top, to: low, by: -1) {
            let t = v[k]
            if ctx.tag(t.index) != "Verb" || Lex.auxiliaries.contains(t.low) || contracted(t) || t.quoted { continue }
            var j = k - 1, steps = 0
            while j > low && steps < 2 && view.gap[j + 1] == .none && Lex.reportAdverbs.contains(v[j].low) {
                j -= 1
                steps += 1
            }
            if view.gap[j + 1] != .none { continue }
            let lj = v[j].low
            if Lex.verbPhraseLeadIns.contains(lj) || contracted(v[j]) { return k }
            if Lex.subjectWords.contains(lj) && j - 1 >= s && view.gap[j] == .none
                && (Lex.auxiliaries.contains(v[j - 1].low) || Lex.coordinators.contains(v[j - 1].low)) {
                return k
            }
        }
        return s
    }

    /// [T26] (v11) Where the main clause resumes after a relative clause in
    /// the subject (no verb between the clause start and the relative word
    /// r): the relative clause's own verb is the first word after r tagged
    /// Verb that is no auxiliary or contracted pronoun ("who called", "who can
    /// fix it", "that we hired"); after it, the first auxiliary or modal, or
    /// the first word tagged Verb that "to" does not introduce, is the main
    /// clause's ("The client who called will email …", "The guy who fixed it
    /// said to call him"; in "The guy who wants to help called us" it is
    /// "called"). Nil when there is no such word, or a break comes first.
    private static func mainResumes(_ ctx: Context, _ view: View, _ r: Int, _ xl: Int) -> Int? {
        let v = view.v
        guard r + 1 <= xl else { return nil }
        var rv: Int?
        for j in (r + 1)...xl {
            if view.gap[j] != .none { return nil }
            let t = v[j]
            if ctx.tag(t.index) == "Verb" && !Lex.auxiliaries.contains(t.low) && !contracted(t) {
                rv = j
                break
            }
        }
        guard let ownVerb = rv, ownVerb + 1 <= xl else { return nil }
        for j in (ownVerb + 1)...xl {
            if view.gap[j] != .none { return nil }
            let t = v[j]
            if Lex.auxiliaries.contains(t.low)
                || (ctx.tag(t.index) == "Verb" && !contracted(t) && v[j - 1].low != Word.to) {
                return j
            }
        }
        return nil
    }

    /// [T25] (v9) v[xl-1] modifies X_last inside its noun phrase: X_last
    /// alphabetic, no number and no function word; v[xl-1] joined to it,
    /// alphabetic, no function word, not quoted and no possessive; and an
    /// opener before them (nounPhraseHead) — or, with no determiner, X_last
    /// no verb to NLTagger, v[xl-1] a noun (or a verb in -ing) and the word
    /// before it a verb: tagged Verb, the clause's first word tagged Noun (an
    /// imperative NLTagger reads as a noun: "Restart staging server"), or a
    /// "to" NLTagger reads as a preposition ("Deploy to staging cluster").
    private static func modifierBefore(_ ctx: Context, _ view: View, _ xl: Int) -> Bool {
        let v = view.v
        if !modifierTokens(view, xl) { return false }
        let x = v[xl], m = v[xl - 1]
        if nounPhraseHead(ctx, view, xl) { return true }
        let tm = ctx.tag(m.index)
        if xl < 2 || ctx.tag(x.index) == "Verb" || !(tm == "Noun" || (tm == "Verb" && m.low.hasSuffix(Suffix.ing))) {
            return false
        }
        let p = v[xl - 2]
        if view.gap[xl - 1] != .none || p.quoted { return false }
        let tp = ctx.tag(p.index)
        return tp == "Verb"
            || (xl - 2 == view.clauseStart[xl] && tp == "Noun" && p.alpha && !Lex.function.contains(p.low))
            || (p.low == Word.to && tp == "Preposition")
    }

    /// [T25] (v10) `modifierBefore`'s conditions on the tokens alone, read
    /// before any word class, so a dictation T25 cannot apply to is not
    /// tagged for it: X_last alphabetic, no number, no function word; v[xl-1]
    /// joined to it, alphabetic, no function word, not quoted, no word in 's.
    private static func modifierTokens(_ view: View, _ xl: Int) -> Bool {
        if xl < 1 || view.gap[xl] != .none { return false }
        let x = view.v[xl], m = view.v[xl - 1]
        return x.alpha && !x.num && !Lex.function.contains(x.low)
            && m.alpha && !Lex.function.contains(m.low) && !m.quoted && !m.low.hasSuffix(Suffix.possessive)
    }

    /// [T25] (v9) X_last heads a compound noun: tagged Noun, after a modifier
    /// NLTagger tags Noun, or Verb in -ing ("the staging server", "the credit
    /// card", "the meeting room").
    private static func compoundHead(_ ctx: Context, _ view: View, _ xl: Int) -> Bool {
        if !modifierTokens(view, xl) || ctx.tag(view.v[xl].index) != "Noun" || !modifierBefore(ctx, view, xl) {
            return false
        }
        let m = view.v[xl - 1]
        let tag = ctx.tag(m.index)
        return tag == "Noun" || (tag == "Verb" && m.low.hasSuffix(Suffix.ing))
    }

    /// [T25] (v9) The phrase after the cue is a new modifier and X_last again
    /// ("the staging bucket, I mean, prod bucket"): the modifier is
    /// alphabetic, no function word, not quoted, not the old one, not a verb
    /// unless in -ing ("meeting room"), and neither modifier is a number;
    /// (v11) and the word before X_last is no finite verb (`finiteAt`: "The
    /// kids ate pizza, I mean, cold pizza" keeps both).
    private static func restatedHead(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int) -> Bool {
        let v = view.v, N = view.n
        if !modifierTokens(view, xl) || y + 1 >= N || view.gap[y + 1] != .none { return false }
        let m = v[xl - 1], m2 = v[y], h2 = v[y + 1]
        if h2.low != v[xl].low || h2.quoted { return false }
        if !m2.alpha || Lex.function.contains(m2.low) || m2.quoted || m2.low == m.low || m.num || m2.num {
            return false
        }
        if !modifierBefore(ctx, view, xl) || finiteAt(ctx, view, xl - 1) { return false }
        return !(ctx.tag(m2.index) == "Verb" && !m2.low.hasSuffix(Suffix.ing))
    }

    /// [T25] (v11) v[i] is a finite verb after its subject, no modifier:
    /// tagged Verb, not in -ing, right after a word tagged Noun with no
    /// break; a form in -ed or -en only when no verb stands before it from
    /// its clause start (with one it is a participle: "Send the team updated
    /// numbers"), an imperative NLTagger reads as a noun included ("Hand the
    /// team updated numbers"). "The kids ate pizza", "The team shipped
    /// features".
    private static func finiteAt(_ ctx: Context, _ view: View, _ i: Int) -> Bool {
        let v = view.v
        if i < 1 || view.gap[i] != .none { return false }
        let m = v[i], p = v[i - 1]
        if ctx.tag(m.index) != "Verb" || m.low.hasSuffix(Suffix.ing) || ctx.tag(p.index) != "Noun" { return false }
        if !(m.low.hasSuffix(Suffix.ed) || m.low.hasSuffix(Suffix.en)) { return true }
        let s = view.clauseStart[i]
        if v[s].alpha && !Lex.function.contains(v[s].low) && s + 1 < i && opensObject(view, s + 1) {
            return false    // an imperative NLTagger reads as a noun
        }
        return !(s..<i).contains(where: { verbal(ctx, v[$0]) })
    }

    /// (v12) A v12 refusal declines the cue before v[y]: from f — the first
    /// word v11's fire for the cue could have taken (`v11Reach`) — or, with
    /// none, from Y, to the end of the phrase after the cue, the words are
    /// kept for the rest of the call. A later fire there would change the
    /// words the declined cue reads, and a later pass would read the cue
    /// again on other words ("Book the corner table, scratch that, Sam's
    /// table, scratch that, cancel it": the second cue would take "Sam's
    /// table", and the first, read again before "cancel it", the whole
    /// clause); and a repeat or a restart there would be fixed where v11's
    /// fire had taken its other copy ("Take the team the team photos, no
    /// wait, team's photos": v11's swap took the second "team", and R1 would
    /// now take the first "the team"). (v13) The kept words start at the
    /// earlier of f and x11 (v11's own start for the cue, `v11Start`), and
    /// the cue v[c] is declined for the rest of the call: no later scan of R4
    /// or R5, in this pass or a later one, reads it again — a later pass read
    /// it on other words (a stutter before it fixed: "Bring the kids my old
    /// snacks snacks, I mean, the client's snacks the client's snacks" lost
    /// "the kids my old snacks, I mean," to the restart onset in pass 2; v11
    /// kept them).
    private static func decline(_ ctx: Context, _ view: View, _ f: Int?, _ y: Int, _ c: Int, _ x11: Int? = nil) {
        var from = f
        if let x11, from == nil || x11 < from! { from = x11 }
        for k in view.cover(from ?? y, view.phraseEnd(y)) { ctx.kept.insert(view.v[k].index) }
        ctx.declined.insert(view.v[c].index)
    }

    /// (v13) `apply` would refuse a fire that deletes these input tokens: one
    /// is quoted, [T16] a layout marker or [T17] in a mention's reach, or
    /// [T5b] the deletion is unbalanced.
    private static func applyRefused(_ ctx: Context, _ ids: [Int]) -> Bool {
        if ids.contains(where: { ctx.toks[$0].quoted || ctx.toks[$0].marker != nil }) { return true }
        if let words = ctx.mentions(), ids.contains(where: words.contains) { return true }
        return ctx.guards.contains(.t5b) && unbalanced(ctx.toks, ids)
    }

    /// (v13) v11's `nounReading`, for `v11Start`: X_last said again as the
    /// Y-side word's object (`.object`) is the verb's evidence where v12 reads
    /// `restatementEvidence`.
    private static func nounReading11(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int) -> Bool {
        let v = view.v
        return ctx.tag(v[y].index) == "Noun" && ctx.tag(v[xl].index) == "Noun" && !Lex.function.contains(v[xl].low)
            && nounPhraseHead(ctx, view, xl) && restatesX(ctx, view, xl, y) != .object
            && !objectAfter(ctx, view, y)
    }

    /// (v13) v11's own start for the cue before v[y] on this view — the X
    /// start v11's R4 takes, nil where it makes no fire — given the restart
    /// onset both read alike. v11's R4 read the steps below; v12 and v13
    /// refuse or shorten some of its fires, never more. Where v11 replaced a
    /// possessive said with the head again from its phrase start (v11's
    /// `nounPhraseStart`, gone in v12), the start is the earliest that walk
    /// could reach, the later of X_last's clause start and xl-4, and the fire
    /// counts as made (v13 refuses every such fire).
    private static func v11Start(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int, _ cue: [ScalarString],
                                 hardBefore: Bool, _ onsetStart: Int?) -> Int? {
        if let start = onsetStart { return start }
        let v = view.v
        let kx = kind(view, xl), ky = kind(view, y)
        let strong = Lex.strongCues.contains(cue)
        let t25 = ctx.guards.contains(.t25) && !Lex.function.contains(v[xl].low)
            && !Lex.function.contains(v[y].low)
        if let kx, kx == ky, kx != .number { return xl }
        if hardBefore { return nil }
        if t25 && strong && restatedHead(ctx, view, xl, y) {
            if addition(view, y) { return nil }
            return possessive(v[y]) ? max(view.clauseStart[xl], xl - 4) : xl - 1
        }
        if !(t25 && compoundHead(ctx, view, xl)) && compatible(ctx, view, xl, y, strong: strong) { return xl }
        if cue != ["scratch", "that"] { return nil }
        var x0 = clauseStart(view, xl, strict: ctx.guards.contains(.t15))
        if let s = x0, ctx.guards.contains(.t21) {
            let e = phraseEnd(view, y)
            var clause = clauseAfter(ctx, view, y, e)
            let vp = ctx.guards.contains(.t24) && verbPhraseRead(ctx, view, xl, y)
            if clause && !vp && ctx.guards.contains(.t24) && ambiguousRunsOn(ctx, view, xl, y, e) { clause = false }
            if vp && nounReading11(ctx, view, xl, y) {
                x0 = nil
            } else if ctx.guards.contains(.t25) && !vp && compoundHead(ctx, view, xl)
                        && !nounPhraseOpens(view, y) && !opensClause(ctx, view, y) {
                x0 = nil
            } else if !(clause || vp) {
                if ctx.guards.contains(.t24) && restatesX(ctx, view, xl, y) == .ambiguous {
                    x0 = nil
                } else if (s...xl).contains(where: { verbal(ctx, v[$0]) }) {
                    x0 = nounPhraseSlot(ctx, view, s, xl, e)
                }
            } else if ctx.guards.contains(.t26) && bareVerbPhrase(ctx, view, y, vp) {
                x0 = verbPhraseStart(ctx, view, s, xl)
            }
        }
        return x0
    }

    /// (v12) For `possessiveAgain`, the first word v11's fire for the cue
    /// could have taken: with `restatedHead` (v11's possessive phrase start
    /// walked at most four words back inside X_last's clause) the later of
    /// X_last's clause start and xl-4; else, when no compound head stopped it
    /// and `compatible` held (v8's word swap), X_last; else, after "scratch
    /// that", X_last's clause start (T21's slot, or the clause); else nil
    /// (v11 made no fire).
    private static func v11Reach(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int, _ cue: [ScalarString],
                                 strong: Bool, t25: Bool) -> Int? {
        if t25 && strong && restatedHead(ctx, view, xl, y) { return max(view.clauseStart[xl], xl - 4) }
        if !(t25 && compoundHead(ctx, view, xl)) && compatible(ctx, view, xl, y, strong: strong) { return xl }
        if cue == ["scratch", "that"] { return view.clauseStart[xl] }
        return nil
    }

    /// [T25] (v12) A possessive: `possessive(t)` ("Sam's", "the team's"), or
    /// an s-final word written with the apostrophe alone ("James'", "the
    /// students'"): alphabetic, its word ending in "s" and its trail exactly
    /// "'".
    private static func possessiveForm(_ t: Token) -> Bool {
        possessive(t) || (t.alpha && t.low.hasSuffix(Suffix.s) && t.trail == ["'"])
    }

    /// [T25] (v12) The phrase after the cue is a possessive and X_last's word
    /// again: v[y+1] follows with no break, has X_last's word and is not
    /// quoted ("the shared folder, I mean, Sam's folder", "my notes, scratch
    /// that, Sam's notes"); or the same one word on, after a determiner of
    /// the possessive's own: v[y] a determiner (no possessive form), v[y+1]
    /// a possessive right after it, not quoted ("my manager sales reports,
    /// scratch that, the manager's reports", "our team's folder").
    private static func possessiveAgain(_ view: View, _ xl: Int, _ y: Int) -> Bool {
        let v = view.v
        var y = y
        if Lex.npDeterminers.contains(v[y].low) && !possessiveForm(v[y]) && y + 1 < view.n
            && view.gap[y + 1] == .none && !v[y + 1].quoted && possessiveForm(v[y + 1]) {
            y += 1
        }
        return possessiveForm(v[y]) && y + 1 < view.n && view.gap[y + 1] == .none && v[y + 1].low == v[xl].low
            && !v[y + 1].quoted
    }

    /// [T25] (v12) The head said again (v[y+1]) runs on into a verb of its
    /// own: v[y+2] follows with no break, is not quoted, is not "please"
    /// (NLTagger reads it as a verb) and is a verb, an auxiliary or a
    /// contracted pronoun — the phrase after the cue is a new clause's
    /// subject ("Book the big room, I mean, small room is free"), no
    /// correction of the old phrase's modifier (v9 to v11: "Book the small
    /// room is free.").
    private static func headVerb(_ ctx: Context, _ view: View, _ y: Int) -> Bool {
        let k = y + 2
        return k < view.n && view.gap[k] == .none && !view.v[k].quoted && view.v[k].low != Word.please
            && verbal(ctx, view.v[k])
    }

    /// [T24] (v12) The phrase after the cue says X_last's modifiers and
    /// X_last again right after its first word — for some k in 1...3,
    /// v[y+1 ... y+k+1] (no breaks, not quoted) have the words of
    /// v[xl-k ... xl], and v[xl-k ..< xl] (no breaks up to X_last) are
    /// alphabetic, no function words and not quoted: the object said again
    /// with no determiner ("Email expense receipts, I mean, print expense
    /// receipts", "Book old log files, no wait, cancel old log files"), where
    /// a swap of X_last would leave the old modifiers before the new phrase
    /// ("Email expense print expense receipts", v8 to v11), and T21's slot the
    /// old verb before the new one ("Send forward old log files").
    private static func restatesBare(_ view: View, _ xl: Int, _ y: Int) -> Bool {
        let v = view.v, N = view.n
        for k in 1...3 {
            if xl - k < 0 || y + k + 1 >= N { return false }
            var ok = true
            for j in 0...k {
                let a = v[xl - k + j], b = v[y + 1 + j]
                if b.quoted || b.low != a.low || view.gap[y + 1 + j] != .none
                    || (j < k && (!a.alpha || Lex.function.contains(a.low) || a.quoted))
                    || (j > 0 && view.gap[xl - k + j] != .none) {
                    ok = false
                    break
                }
            }
            if ok { return true }
        }
        return false
    }

    /// [T25] (v11) The phrase after the cue (to its first break) adds rather
    /// than corrects: it ends with too or either, or with "as well", or holds
    /// "also" ("prod bucket works too"). (v12) The phrase's end and the next
    /// "also" come from the view, so a long run with no break costs no scan
    /// per cue.
    private static func addition(_ view: View, _ y: Int) -> Bool {
        let v = view.v, e = view.phraseEnd(y)
        let last = v[e - 1].low
        if Lex.additionLast.contains(last) || view.alsoFrom(y) < e { return true }
        return e - y >= 2 && v[e - 2].low == Word.asWord && last == Word.well
    }

    /// [T25] (v9) The phrase after the cue opens a noun phrase of its own: a
    /// determiner, a number or a possessive ("an aisle seat", "two tables").
    private static func nounPhraseOpens(_ view: View, _ y: Int) -> Bool {
        let t = view.v[y]
        return Lex.npDeterminers.contains(t.low) || t.num || possessive(t)
    }

    /// A word in 's that is no contracted pronoun: a possessive ("Sam's",
    /// "the team's"; not "let's", "it's").
    private static func possessive(_ t: Token) -> Bool {
        t.alpha && t.low.hasSuffix(Suffix.possessive) && !contracted(t)
    }

    /// [T24] (v8) X_last v[a] heads a noun phrase: NLTagger does not read it
    /// as a verb, and before it, with no break, stands a noun-phrase opener —
    /// an article, demonstrative, possessive or determiner, a preposition
    /// other than "to", or (v9) a possessive in 's, not a contracted pronoun —
    /// directly or across at most three modifiers (words that are not
    /// function words, or numbers): "the branch", "the staging database", "in
    /// cold storage", "Sam's branch"; not "you fork", "to email", "the team
    /// fixed", "let's fork".
    static func nounPhraseHead(_ ctx: Context, _ view: View, _ a: Int) -> Bool {
        let v = view.v
        if ctx.tag(v[a].index) == "Verb" { return false }
        var k = a
        for _ in 0..<4 {
            if k == 0 || view.gap[k] != .none { return false }
            let t = v[k - 1]
            if Lex.nounPhraseHeadOpeners.contains(t.low) || possessive(t) {
                return true
            }
            if Lex.function.contains(t.low) || !(t.alpha || t.num) { return false }
            k -= 1
        }
        return false
    }

    /// The same inflectional ending (-ing / -ed / -ly) on two different words.
    private static func sameMorph(_ a: ScalarString, _ b: ScalarString) -> Bool {
        if a == b || !(PyText.isAlpha(a.scalars) && PyText.isAlpha(b.scalars)) { return false }
        for suffix in ["ing", "ed", "ly"] as [ScalarString] where a.hasSuffix(suffix) && b.hasSuffix(suffix)
            && a.count >= 5 && b.count >= 5 {
            return !Lex.ingStop.contains(a) && !Lex.ingStop.contains(b)
        }
        return false
    }

    /// X_last `a` and the Y-side token `b` fill the same slot: the same closed
    /// kind (not a number); or the same NLTagger open class or the same
    /// -ing/-ed/-ly ending — for a weak cue (sorry, actually, no, wait) only
    /// when `a` sits in a noun or prepositional phrase (a slot opener right
    /// before it); a strong cue in that slot also takes Noun vs Adjective
    /// ("with linear, I mean, exponential backoff").
    static func compatible(_ ctx: Context, _ view: View, _ a: Int, _ b: Int, strong: Bool) -> Bool {
        let v = view.v
        let ka = kind(view, a), kb = kind(view, b)
        if ka != nil || kb != nil { return ka == kb && ka != .number }
        let la = v[a].low, lb = v[b].low
        if Lex.function.contains(la) || Lex.function.contains(lb) || la == lb { return false }
        let slot = a >= 1 && view.gap[a] == .none && Lex.slotOpeners.contains(v[a - 1].low)
        if !strong && !slot { return false }
        // [T24] "the branch, I mean, fork the branch": a verb phrase, not a
        // noun; (v9) "the cache, I mean, clear out the cache" too; (v10) not
        // "the file, I mean, link to the file"
        if ctx.guards.contains(.t24)
            && ((headsVerbPhrase(ctx, view, b) && nounPhraseHead(ctx, view, a)) || restatesX(ctx, view, a, b) != .none) {
            return false
        }
        let ta = ctx.tag(v[a].index), tb = ctx.tag(v[b].index)
        if !ta.isEmpty && ta == tb && Lex.openClasses.contains(ta) { return true }
        if strong && slot && Set([ta, tb]) == ["Noun", "Adjective"] { return true }
        return sameMorph(la, lb)
    }

    static func matchCue(_ view: View, _ c: Int, _ cues: [[ScalarString]]) -> [ScalarString]? {
        let v = view.v
        for cue in cues {
            let L = cue.count
            if c + L > view.n { continue }
            // word by word, no copy: this runs for every token, nine cues each
            if !(0..<L).allSatisfy({ v[c + $0].low == cue[$0] && !v[c + $0].quoted }) { continue }
            let inner = (c + 1..<c + L).map { view.gap[$0] }
            if cue == ["no", "wait"] {
                if inner.contains(.hard) { continue }   // "No, wait," may hold a comma
            } else if inner.contains(where: { $0 != .none }) {
                continue
            }
            return cue
        }
        return nil
    }

    /// Where a cue may stand: "sorry" / "no" / "wait" set off by commas, "no
    /// wait" / "scratch that" with a break on each side, "actually" after a
    /// comma; "I mean" not after a word it completes ("what I mean"), nor
    /// defining one ("by done I mean merged").
    private static func cueShapeOK(_ view: View, _ xl: Int, _ c: Int, _ cue: [ScalarString]) -> Bool {
        let L = cue.count
        let before = view.gap[c]
        let after = view.after(c + L - 1)
        switch cue {
        case ["i", "mean"], ["i", "meant"]:
            if Lex.iMeanBlockBefore.contains(view.v[xl].low) { return false }
            if xl >= 1 && view.v[xl - 1].low == "by" && view.gap[xl] == .none { return false }
            return true
        case ["sorry"], ["no"], ["wait"]:
            return (before == .comma || before == .hard) && view.v[c + L - 1].brk == .comma
        case ["no", "wait"], ["scratch", "that"]:
            return (before == .comma || before == .hard) && (after == .comma || after == .hard)
        case ["or", "rather"]:
            return true
        case ["actually"]:
            return before == .comma && (after == .none || after == .comma)
        default:
            return false
        }
    }

    /// The X start by restart onset: Y's first word said again up to 4
    /// tokens before X_last. A function-word onset needs a parallel second
    /// word, or must be unambiguous with the Y-side word at the same offset
    /// filling X_last's slot ("at the bottom, no wait, at the top").
    private static func onset(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int, numeric: Bool) -> Int? {
        let v = view.v, N = view.n
        let s = view.sentenceStart[xl]
        for d in 1...4 {
            let o = xl - d
            if o < 0 || view.gap[o + 1] != .none { break }
            if v[o].low.isEmpty || v[o].low != v[y].low || v[o].quoted { continue }
            if !Lex.function.contains(v[o].low) { return o }
            // parallel: "at the bottom, no wait, at the top"
            if y + 1 < N && view.gap[y + 1] == .none && v[o + 1].low == v[y + 1].low && o + 1 < xl { return o }
            // "the weight of the water": which "the"? (the word occurs twice
            // from the sentence start to X_last)
            if view.previousSame(o) >= s || (o + 1...xl).contains(where: { v[$0].low == v[o].low }) { continue }
            let b = y + d
            if b >= N || !view.clean(y, b) { continue }
            if numeric {
                if isNumberX(view, xl) && v[b].num { return o }
            } else if compatible(ctx, view, xl, b, strong: true) {
                return o
            }
        }
        return nil
    }

    /// The start of the number X_last ends ("forty one", "two hundred and
    /// five"), taking a unit right after it ("3 hours").
    private static func numberStart(_ view: View, _ xl: Int) -> Int? {
        let v = view.v
        var k = xl
        if Lex.units.contains(v[k].low) && k > 0 && v[k - 1].num && view.gap[k] == .none { k -= 1 }
        if !v[k].num { return nil }
        var s = k
        while s > 0 && view.gap[s] == .none {
            let prev = v[s - 1]
            if prev.num {
                s -= 1
            } else if prev.low == "and" && s >= 2 && v[s - 2].num && view.gap[s - 1] == .none {
                s -= 1
            } else {
                break
            }
        }
        return s
    }

    /// X_last is a number, or a unit right after one.
    private static func isNumberX(_ view: View, _ xl: Int) -> Bool {
        let v = view.v
        return v[xl].num || (Lex.units.contains(v[xl].low) && xl > 0 && v[xl - 1].num && view.gap[xl] == .none)
    }

    /// [T13] The replacement stands alone: it ends the text or its sentence,
    /// alone or with one unit ("4? Sorry, 5."), not a clause ("5 is fine").
    private static func standalone(_ view: View, _ y: Int) -> Bool {
        let v = view.v, N = view.n
        if y + 1 >= N || view.after(y) == .hard { return true }
        return Lex.units.contains(v[y + 1].low) && view.gap[y + 1] == .none
            && (y + 2 >= N || view.after(y + 1) == .hard)
    }

    /// The first token of X_last's clause (after the nearest COMMA/HARD gap),
    /// nil past 12 tokens; [T15] nil when that gap is HARD only for a
    /// bracket, quote or dash.
    private static func clauseStart(_ view: View, _ xl: Int, strict: Bool) -> Int? {
        let s = view.clauseStart[xl]
        if strict && s > 0 && view.gap[s] == .hard && !view.sent[s] { return nil }
        return xl - s + 1 <= 12 ? s : nil
    }

    /// R4 (numeric: false) and R5 (numeric: true). "X <cue> Y": delete X
    /// through the cue. X runs back from X_last (the word before the cue) to
    /// the restart onset, or is X_last alone when it and Y are the same kind
    /// of slot; "scratch that" takes the clause. R5 takes only numbers — and
    /// an uncued restart ("five twenty five thousand") never fires.
    static func cued(_ ctx: Context, _ view: View, numeric: Bool) -> [Fire] {
        let v = view.v, N = view.n
        let rule: Rule = numeric ? .r5 : .r4
        var fires: [Fire] = []
        var c = 1, floor = -1, floor11 = -1
        while c < N {
            guard let cue = matchCue(view, c, Lex.cues) else { c += 1; continue }
            let L = cue.count, y = c + L, xl = c - 1
            if y >= N || view.after(c + L - 1) == .hard || xl <= floor || v[xl].quoted || v[xl].core.isEmpty
                || Lex.cueWords.contains(v[xl].low) || v[xl].low == v[y].low {
                c += 1
                continue
            }
            if cue == ["or", "rather"] && v[y].low == "than" { c += 1; continue }
            if (cue == ["i", "mean"] || cue == ["i", "meant"]) && Lex.iMeanBlockAfter.contains(v[y].low) {
                c += 1
                continue
            }
            if !cueShapeOK(view, xl, c, cue) { c += 1; continue }
            // (v13) a declined cue never fires again, in this pass or a later one
            if ctx.declined.contains(v[c].index) { c += 1; continue }
            let hardBefore = view.gap[c] == .hard
            var x0: Int?
            // (v13) v11's own start for this cue (`v11Start`; nil: v11 makes no fire)
            var x11: Int?
            let xnum = isNumberX(view, xl), ynum = v[y].num
            // "Do we need 4? I mean 5 is fine too."
            if numeric && xnum && hardBefore && ctx.guards.contains(.t13) && !standalone(view, y) {
                c += 1
                continue
            }
            let numberOnset = (hardBefore || !xnum) ? nil : onset(ctx, view, xl, y, numeric: true)
            if numeric {
                if xnum {
                    x0 = numberOnset
                    if x0 == nil && ynum { x0 = numberStart(view, xl) }
                }
                x11 = x0   // (v13) R5 reads every cue as v11's did
            } else if !(xnum && (ynum || numberOnset != nil)) {
                if !hardBefore { x0 = onset(ctx, view, xl, y, numeric: false) }
                x11 = v11Start(ctx, view, xl, y, cue, hardBefore: hardBefore, x0)
                if x11 != nil && xl <= floor11 { x11 = nil }   // v11's own floor: no fire for this cue
                if x0 == nil {
                    let kx = kind(view, xl), ky = kind(view, y)
                    let strong = Lex.strongCues.contains(cue)
                    // (v10) T25 reads word classes only where its answer can
                    // matter: compatible's own exits on the tokens, no
                    // function word on either side
                    let t25 = ctx.guards.contains(.t25) && !Lex.function.contains(v[xl].low)
                        && !Lex.function.contains(v[y].low)
                    if let kx, kx == ky, kx != .number {
                        x0 = xl
                    } else if hardBefore {
                        // no swap across a sentence break
                    } else if ctx.guards.contains(.t25) && possessiveAgain(view, xl, y) {
                        // [T25] (v12) a possessive said with the head again keeps both, at
                        // every cue ("the shared folder, I mean, Sam's folder")
                        decline(ctx, view, v11Reach(ctx, view, xl, y, cue, strong: strong, t25: t25), y, c, x11)
                        if let x = x11, x > floor11 { floor11 = y - 1 }   // (v13) v11's scan made a fire here
                        c += 1
                        continue
                    } else if t25 && strong && restatedHead(ctx, view, xl, y) {
                        // [T25] "the staging bucket, I mean, prod bucket" → "the prod bucket".
                        // Nothing fires for the cue, not even "scratch that", for (v11) an
                        // addition ("prod bucket works too") or (v12) a new clause's subject
                        // ("small room is free").
                        if addition(view, y) { c += 1; continue }
                        if headVerb(ctx, view, y) {
                            decline(ctx, view, xl - 1, y, c, x11)
                            if let x = x11, x > floor11 { floor11 = y - 1 }
                            c += 1
                            continue
                        }
                        x0 = xl - 1
                    } else if t25 && compoundHead(ctx, view, xl) {
                        // [T25] "the staging server, I mean, prod" keeps both
                    } else if compatible(ctx, view, xl, y, strong: strong) {
                        // [T24] (v12) "Email expense receipts, I mean, print expense receipts"
                        // keeps both
                        if ctx.guards.contains(.t24) && restatesBare(view, xl, y) {
                            decline(ctx, view, xl, y, c, x11)
                            if let x = x11, x > floor11 { floor11 = y - 1 }
                            c += 1
                            continue
                        }
                        x0 = xl
                    }
                }
                if x0 == nil && cue == ["scratch", "that"] && !hardBefore {
                    x0 = clauseStart(view, xl, strict: ctx.guards.contains(.t15))
                    // [T21] a bare noun phrase after a clause with a verb takes
                    // only its slot, or nothing
                    if let s = x0, ctx.guards.contains(.t21) {
                        let e = phraseEnd(view, y)
                        var clause = clauseAfter(ctx, view, y, e)
                        let vp = ctx.guards.contains(.t24) && verbPhraseAfter(ctx, view, xl, y)
                        // [T24] (v12) v11 read a verb phrase here and a refusal took that reading away
                        let held = ctx.guards.contains(.t24) && !vp && verbPhraseRead(ctx, view, xl, y)
                        var v11None = false
                        if clause && !vp && ctx.guards.contains(.t24) && ambiguousRunsOn(ctx, view, xl, y, e) {
                            clause = false   // [T24] (v11) "pressure in the tires before we leave"
                        }
                        if held && named(view, y) && inflectedSecond(view, y) {
                            clause = true    // [T24] (v12) a name and an inflected verb: "Sam books the room"
                        }
                        if vp && nounReading(ctx, view, xl, y) {
                            x0 = nil       // [T24] "Send the team, scratch that, client the slides"
                        } else if held && restatesX(ctx, view, xl, y) != .object && nounReading(ctx, view, xl, y) {
                            x0 = nil       // [T24] (v12) v11 kept both here too: "Client the slides"
                            v11None = true
                        } else if ctx.guards.contains(.t25) && !vp && compoundHead(ctx, view, xl)
                                    && !nounPhraseOpens(view, y) && !opensClause(ctx, view, y) {
                            x0 = nil       // [T25] "the staging server, scratch that, prod"
                        } else if !(clause || vp) {
                            if ctx.guards.contains(.t24) && restatesX(ctx, view, xl, y) == .ambiguous {
                                x0 = nil   // [T24] (v10) "the door, scratch that, lock on the door"
                            } else if (s...xl).contains(where: { verbal(ctx, v[$0]) }) {
                                x0 = nounPhraseSlot(ctx, view, s, xl, e)
                                if let slot = x0, ctx.guards.contains(.t24) && !nounPhraseOpens(view, y)
                                    && ctx.tag(v[y].index) != "Adjective" && restatesBare(view, xl, y) {
                                    // [T24] (v12) the slot would leave the old verb before the new one and
                                    // the object said again ("Send old log files, scratch that, forward
                                    // old log files")
                                    decline(ctx, view, held ? (ctx.guards.contains(.t26)
                                                               ? verbPhraseStart(ctx, view, s, xl) : s) : slot,
                                            y, c, x11)
                                    x0 = nil
                                }
                            }
                        } else if ctx.guards.contains(.t26) && bareVerbPhrase(ctx, view, y, vp) {
                            x0 = verbPhraseStart(ctx, view, s, xl)   // [T26] "I'll call him, scratch that, text him"
                        } else if held && ctx.guards.contains(.t26) && verbPhraseStart(ctx, view, s, xl) != s {
                            // [T24] (v12) v11 took back only the verb phrase here: "We need to call
                            // the vendor, scratch that, Sam called the vendor" keeps both
                            x0 = nil
                        }
                        if held && x0 == s && !named(view, y) && ctx.tag(v[y].index) != "Verb" {
                            // [T24] (v12) a refused reading takes back no whole clause unless a name
                            // opens the phrase ("team leads the contract" keeps both)
                            x0 = nil
                        }
                        if held && x0 == nil {
                            // (v12) held and kept both; v11 took from verbPhraseStart or s
                            decline(ctx, view, v11None ? nil
                                        : (ctx.guards.contains(.t26) ? verbPhraseStart(ctx, view, s, xl) : s),
                                    y, c, x11)
                        }
                    }
                }
            }
            // (v13) [the valve, per cue] v11's reading of this cue, on this
            // view, bounds what v13 takes for it. v13 fires only where v11's
            // scan fires (x11, after its own floor), from x11 or later, and
            // only where `apply` lets v11's fire through (T5b, a quoted token,
            // a marker, a mention: v11 then takes nothing for the cue, nor
            // does v13, and the scan moves on as v11's did). Where v11 takes
            // words v13 keeps — a refusal, a shorter fire, a fire `apply` or
            // the kept words stop — those words are kept from every later fire.
            if let x = x11, x <= floor11 || xl <= floor11 { x11 = nil }
            var ok11 = false
            if let x = x11 {
                ok11 = !applyRefused(ctx, view.upto(x, y))
                floor11 = y - 1
            }
            if let start = x0, start <= floor || x11 == nil || start < x11! { x0 = nil }
            if x0 != nil && !ok11 {
                floor = y - 1   // `apply` refuses v11's fire here: v13 takes nothing either
                c = y
                continue
            }
            var deleted: [Int]? = x0.map { view.upto($0, y) }
            if let ids = deleted, (!ctx.kept.isEmpty && ids.contains(where: { ctx.kept.contains($0) }))
                || applyRefused(ctx, ids) {
                // (v12) the words a declined cue reads after it stay; (v13) `apply` refuses it
                deleted = nil
            }
            guard let ids = deleted, let start = x0, let from11 = x11 else {
                if ok11, let from11 = x11 { decline(ctx, view, from11, y, c) }   // v11 takes [x11, y), v13 nothing
                c += 1
                continue
            }
            if start > from11 {
                // (v13) v11 took these too; v13 keeps them
                for k in view.cover(from11, start) { ctx.kept.insert(v[k].index) }
            }
            fires.append(Fire(rule: rule, deleted: ids, cue: v[c].index..<(v[c + L - 1].index + 1),
                              note: "cue " + cue.map(\.description).joined(separator: " ")))
            floor = y - 1
            c = y
        }
        return fires
    }

    /// (v13) v11's R4 (numeric: false) and R5 (numeric: true), reading every
    /// cue as rules.v11.py did: the shadow run's (`runPasses`, legacy). v11's
    /// readings v12 removed come back here only: a possessive said with the
    /// head again replaced the noun phrase from its start (`nounPhraseStart11`)
    /// unless a verb that takes two objects read the old phrase as two
    /// (`doubleObject11`).
    static func cued11(_ ctx: Context, _ view: View, numeric: Bool) -> [Fire] {
        let v = view.v, N = view.n
        let rule: Rule = numeric ? .r5 : .r4
        var fires: [Fire] = []
        var c = 1, floor = -1
        while c < N {
            guard let cue = matchCue(view, c, Lex.cues) else { c += 1; continue }
            let L = cue.count, y = c + L, xl = c - 1
            if y >= N || view.after(c + L - 1) == .hard || xl <= floor || v[xl].quoted || v[xl].core.isEmpty
                || Lex.cueWords.contains(v[xl].low) || v[xl].low == v[y].low {
                c += 1
                continue
            }
            if cue == ["or", "rather"] && v[y].low == "than" { c += 1; continue }
            if (cue == ["i", "mean"] || cue == ["i", "meant"]) && Lex.iMeanBlockAfter.contains(v[y].low) {
                c += 1
                continue
            }
            if !cueShapeOK(view, xl, c, cue) { c += 1; continue }
            let hardBefore = view.gap[c] == .hard
            var x0: Int?
            let xnum = isNumberX(view, xl), ynum = v[y].num
            if numeric && xnum && hardBefore && ctx.guards.contains(.t13) && !standalone(view, y) {
                c += 1
                continue
            }
            let numberOnset = (hardBefore || !xnum) ? nil : onset(ctx, view, xl, y, numeric: true)
            if numeric {
                if xnum {
                    x0 = numberOnset
                    if x0 == nil && ynum { x0 = numberStart(view, xl) }
                }
            } else if !(xnum && (ynum || numberOnset != nil)) {
                if !hardBefore { x0 = onset(ctx, view, xl, y, numeric: false) }
                if x0 == nil {
                    let kx = kind(view, xl), ky = kind(view, y)
                    let strong = Lex.strongCues.contains(cue)
                    let t25 = ctx.guards.contains(.t25) && !Lex.function.contains(v[xl].low)
                        && !Lex.function.contains(v[y].low)
                    if let kx, kx == ky, kx != .number {
                        x0 = xl
                    } else if hardBefore {
                        // no swap across a sentence break
                    } else if t25 && strong && restatedHead(ctx, view, xl, y) {
                        if addition(view, y) { c += 1; continue }
                        if possessive(v[y]) {
                            guard let start = nounPhraseStart11(ctx, view, xl, y) else { c += 1; continue }
                            x0 = start
                        } else {
                            x0 = xl - 1
                        }
                    } else if t25 && compoundHead(ctx, view, xl) {
                        // no swap of a compound's head
                    } else if compatible(ctx, view, xl, y, strong: strong) {
                        x0 = xl
                    }
                }
                if x0 == nil && cue == ["scratch", "that"] && !hardBefore {
                    x0 = clauseStart(view, xl, strict: ctx.guards.contains(.t15))
                    if let s = x0, ctx.guards.contains(.t21) {
                        let e = phraseEnd(view, y)
                        var clause = clauseAfter(ctx, view, y, e)
                        let vp = ctx.guards.contains(.t24) && verbPhraseRead(ctx, view, xl, y)
                        if clause && !vp && ctx.guards.contains(.t24) && ambiguousRunsOn(ctx, view, xl, y, e) {
                            clause = false
                        }
                        if vp && nounReading11(ctx, view, xl, y) {
                            x0 = nil
                        } else if ctx.guards.contains(.t25) && !vp && compoundHead(ctx, view, xl)
                                    && !nounPhraseOpens(view, y) && !opensClause(ctx, view, y) {
                            x0 = nil
                        } else if !(clause || vp) {
                            if ctx.guards.contains(.t24) && restatesX(ctx, view, xl, y) == .ambiguous {
                                x0 = nil
                            } else if (s...xl).contains(where: { verbal(ctx, v[$0]) }) {
                                x0 = nounPhraseSlot(ctx, view, s, xl, e)
                            }
                        } else if ctx.guards.contains(.t26) && bareVerbPhrase(ctx, view, y, vp) {
                            x0 = verbPhraseStart(ctx, view, s, xl)
                        }
                    }
                }
            }
            guard let start = x0, start > floor else { c += 1; continue }
            fires.append(Fire(rule: rule, deleted: view.upto(start, y), cue: v[c].index..<(v[c + L - 1].index + 1),
                              note: "cue " + cue.map(\.description).joined(separator: " ")))
            floor = y - 1
            c = y
        }
        return fires
    }

    /// (v13) v11's `nounPhraseStart`, for the shadow run: where the noun
    /// phrase the possessive v[y] replaces starts. Without
    /// `nounPhraseHead(xl)`, the modifier v[xl-1]; nil for a double object
    /// (`doubleObject11`). Else walk back from X_last, at most four steps,
    /// over the phrase's own modifiers — words tagged Adjective, a word tagged
    /// Verb that is no finite verb and is a participle or stands right after a
    /// determiner a possessive replaces, and words tagged Noun before any of
    /// those: a determiner a possessive replaces, or a possessive in 's, goes
    /// when the possessor takes none (capitalised, or in
    /// `possessorsWithoutDeterminer`) and stays otherwise; any other opener
    /// stays; a number gives nil; any other word ends the walk at the
    /// modifier v[xl-1].
    private static func nounPhraseStart11(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int) -> Int? {
        let v = view.v
        if !nounPhraseHead(ctx, view, xl) { return xl - 1 }
        if doubleObject11(ctx, view, xl) { return nil }
        let whole = v[y].cap || Lex.possessorsWithoutDeterminer.contains(v[y].low)
        var k = xl, adjective = false
        for _ in 0..<4 {
            let t = v[k - 1]
            if replacedDeterminer11(t) { return whole ? k - 1 : k }
            if Lex.nounPhraseHeadOpeners.contains(t.low) { return k }
            if t.num { return nil }
            let tag = ctx.tag(t.index)
            if tag == "Adjective"
                || (tag == "Verb" && !finiteAt(ctx, view, k - 1) && (participle11(t) || replacedDeterminer11(v[k - 2]))) {
                adjective = true
            } else if tag != "Noun" || adjective {
                return xl - 1
            }
            k -= 1
        }
        return xl - 1
    }

    /// (v13) v11's: a verb form that can modify a noun — alphabetic, four or
    /// more letters, ending in -ing, -ed or -en.
    private static func participle11(_ t: Token) -> Bool {
        t.alpha && t.low.count >= 4
            && (t.low.hasSuffix(Suffix.ing) || t.low.hasSuffix(Suffix.ed) || t.low.hasSuffix(Suffix.en))
    }

    /// (v13) v11's: a determiner a possessive replaces, or a possessive in 's.
    private static func replacedDeterminer11(_ t: Token) -> Bool {
        Lex.possessiveReplaces.contains(t.low) || possessive(t)
    }

    /// (v13) v11's `doubleObject`: a word of `twoObjectVerbs`, a determiner a
    /// possessive replaces, one word tagged Noun, then X_last, with no break,
    /// and X_last looks plural (four or more letters ending in "s", not "ss",
    /// "us" or "is").
    private static func doubleObject11(_ ctx: Context, _ view: View, _ xl: Int) -> Bool {
        let v = view.v
        if xl < 3 || [xl - 2, xl - 1, xl].contains(where: { view.gap[$0] != .none }) { return false }
        if !(Lex.twoObjectVerbs.contains(v[xl - 3].low) && Lex.possessiveReplaces.contains(v[xl - 2].low)
             && ctx.tag(v[xl - 1].index) == "Noun") {
            return false
        }
        let x = v[xl].low
        return x.count >= 4 && x.hasSuffix(Suffix.s)
            && !(x.hasSuffix(Suffix.ss) || x.hasSuffix(Suffix.us) || x.hasSuffix(Suffix.isSuffix))
    }

    /// [T24] (v11) After "scratch that", the phrase says X_last again across
    /// in / on / off / over (`.ambiguous`) and runs on after it, and what
    /// makes it a clause is only in that run: the words before X_last said
    /// again (at r, the first k in y+2 … y+4 with X_last's word; X_last's own
    /// word is a noun whatever NLTagger reads the second time) are no clause,
    /// and the word after r is "please" (NLTagger reads it as a verb) or no
    /// verb, auxiliary or contracted pronoun (one would make the phrase its
    /// subject: "lock on the door is broken").
    /// "Check the tires, scratch that, pressure in the tires before we leave"
    /// keeps both, as without the run.
    private static func ambiguousRunsOn(_ ctx: Context, _ view: View, _ xl: Int, _ y: Int, _ e: Int) -> Bool {
        if restatesX(ctx, view, xl, y) != .ambiguous { return false }
        let v = view.v
        guard y + 2 < min(y + 5, view.n),
              let r = ((y + 2)..<min(y + 5, view.n)).first(where: { v[$0].low == v[xl].low && !v[$0].quoted })
        else { return false }
        if r + 1 >= e || clauseAfter(ctx, view, y, r) { return false }
        return v[r + 1].low == Word.please || !verbal(ctx, v[r + 1])
    }

    /// [T21] The view index after the phrase that starts at y: the first gap
    /// that is not NONE, or the end (v12: read from the view, which computes
    /// them once).
    private static func phraseEnd(_ view: View, _ y: Int) -> Int {
        view.phraseEnd(y)
    }

    /// [T21] A pronoun contracted with a verb ("I'll", "it's", "let's").
    private static func contracted(_ t: Token) -> Bool {
        t.low.scalars.contains("'") && Lex.pronouns.contains(t.low)
    }

    /// [T21] A verb by NLTagger, an auxiliary, or a contracted pronoun.
    private static func verbal(_ ctx: Context, _ t: Token) -> Bool {
        Lex.auxiliaries.contains(t.low) || contracted(t) || ctx.tag(t.index) == "Verb"
    }

    /// [T21] The phrase after the cue opens with a subject pronoun, a
    /// contracted pronoun or a verb (an imperative).
    private static func opensClause(_ ctx: Context, _ view: View, _ y: Int) -> Bool {
        let t0 = view.v[y]
        return Lex.subjectWords.contains(t0.low) || contracted(t0) || verbal(ctx, t0)
    }

    /// [T21] The phrase v[y] ..< v[e] after the cue is a clause: it opens with
    /// a subject pronoun or a verb (an imperative), holds an auxiliary or a
    /// contracted pronoun, or has a verb after a noun, pronoun or number of
    /// its own ("the red one works"). Else it is a bare noun phrase ("an aisle
    /// seat", "only leads"). (v8 also read a verb phrase's shape here; v9
    /// reads it with the rest of its evidence in `verbPhraseAfter`.)
    private static func clauseAfter(_ ctx: Context, _ view: View, _ y: Int, _ e: Int) -> Bool {
        let v = view.v
        if opensClause(ctx, view, y) { return true }
        var nominal = false
        for k in y..<e {
            let t = v[k]
            if Lex.auxiliaries.contains(t.low) || contracted(t) { return true }
            let tag = ctx.tag(t.index)
            if tag == "Verb" && nominal { return true }
            if tag == "Noun" || tag == "Pronoun" || tag == "Number" || t.num { nominal = true }
        }
        return false
    }

    /// [T21] The start of the noun phrase that ends at X_last, when the bare
    /// noun phrase v[y] ..< v[e] can take its slot; nil keeps both. X_last is
    /// a noun; the two heads are not of two different closed kinds ("one" /
    /// "ones" stand for any noun); the phrase holds at most one determiner —
    /// (v9) a possessive counts as one, a contracted pronoun ("let's") does
    /// not — and a predeterminer before it, and starts after the clause's
    /// first token s.
    private static func nounPhraseSlot(_ ctx: Context, _ view: View, _ s: Int, _ xl: Int, _ e: Int) -> Int? {
        let v = view.v
        if ctx.tag(v[xl].index) != "Noun" || Lex.function.contains(v[xl].low) || v[xl].quoted { return nil }
        let yh = e - 1
        let kx = kind(view, xl), ky = kind(view, yh)
        if (kx != nil || ky != nil) && kx != ky && v[yh].low != "one" && v[yh].low != "ones" { return nil }
        var k0 = xl
        while k0 - 1 > s && xl - k0 < 4 && view.gap[k0] == .none {
            let t = v[k0 - 1]
            if t.quoted { break }
            if Lex.npDeterminers.contains(t.low) || possessive(t) {
                k0 -= 1
                if k0 - 1 > s && view.gap[k0] == .none && Lex.predeterminers.contains(v[k0 - 1].low) { k0 -= 1 }
                break
            }
            let tag = ctx.tag(t.index)
            if Lex.function.contains(t.low) || !(tag == "Noun" || tag == "Adjective" || tag == "Number" || t.num) {
                break
            }
            k0 -= 1
        }
        return k0
    }

    /// R4S. A sentence retracted by a cue opening the next one: "scratch
    /// that" takes the sentence before it; the other cues only when the
    /// sentence after restates the first two words ("The bar shows the day.
    /// No wait, the bar shows the week."). Never the whole text.
    static func ruleR4S(_ ctx: Context, _ view: View) -> [Fire] {
        let v = view.v, N = view.n, G = ctx.guards
        var fires: [Fire] = []
        var floor = -1
        for c in 1..<max(1, N) {
            // T15: a bracket, quote or dash is not a sentence end
            if view.gap[c] != .hard || (G.contains(.t15) && !view.sent[c]) { continue }
            guard let cue = matchCue(view, c, Lex.sentenceCues) else { continue }
            let L = cue.count
            let after = view.after(c + L - 1)
            if after != .comma && after != .hard { continue }
            let s = view.sentenceStart[c - 1]
            if s <= floor || c - s > 40 || v[s..<c].contains(where: \.quoted) { continue }
            // S1 would start inside a sentence ("Redis (version 7).")
            if G.contains(.t15) && !view.sent[s] { continue }
            let y = c + L
            if cue != ["scratch", "that"] {
                if c - s < 3 || y + 2 > N { continue }
                if v[y].low != v[s].low || v[y + 1].low != v[s + 1].low || view.gap[y + 1] == .hard { continue }
            }
            // would leave nothing: the app would paste the raw text
            if s == 0 && y >= N { continue }
            let ids = y < N ? view.upto(s, y) : view.ids(s, N)
            fires.append(Fire(rule: .r4s, deleted: ids, cue: v[c].index..<(v[c + L - 1].index + 1),
                              note: "sentence retraction " + cue.map(\.description).joined(separator: " ")))
            floor = y - 1
        }
        return fires
    }
}

// MARK: - Render

extension SelfRepair {
    /// The kept tokens joined with single spaces, with two case fixes:
    ///  - a deleted run that opened a sentence (or [T16] a line, right after
    ///    a layout marker) with a capital passes it on to the next kept
    ///    token, if that one is lower-case, has no inner capitals, is not
    ///    quoted and is not a dictionary term;
    ///  - R1: a kept copy written with a capital mid-sentence ("about About")
    ///    takes the deleted first copy's lower case (FillerStripper keeps the
    ///    first copy's casing the same way).
    static func render(_ ctx: Context, spacing: Spacing = .single) -> String {
        let toks = ctx.toks, alive = ctx.alive, n = toks.count
        var out = String.UnicodeScalarView()
        var prev: Token?
        func emit(_ t: Token, _ raw: [Unicode.Scalar]) {
            if let last = prev {
                if spacing == .single {
                    out.append(" ")
                } else {
                    out.append(contentsOf: separator(ctx, after: last.index, before: t.index))
                }
            }
            out.append(contentsOf: raw)
            prev = t
        }
        var k = 0
        while k < n {
            if alive[k] {
                let t = toks[k]
                var raw = t.raw
                if let f = ctx.caseFrom[k], !alive[f], let f0 = toks[f].core.first, PyText.isLowerChar(f0),
                   let c0 = t.core.first, PyText.isUpperChar(c0),
                   Array(t.core.dropFirst()) == PyText.lower(Array(t.core.dropFirst())),
                   let before = prev, before.brk != .hard, before.marker == nil, t.low != Word.i {
                    raw = recase(t, upper: false)
                }
                emit(t, raw)
                k += 1
                continue
            }
            var e = k
            while e < n && !alive[e] { e += 1 }
            // a sentence start: the text's, after a HARD break, or [T16] after
            // a layout marker
            if prev.map({ $0.brk == .hard || $0.marker != nil }) ?? true, toks[k].cap, e < n {
                let t = toks[e], c = t.core
                if let c0 = c.first, PyText.isLowerChar(c0), !ctx.protect.contains(t.low), !t.quoted,
                   !c.dropFirst().contains(where: PyText.isUpperChar) {
                    emit(t, recase(t, upper: true))
                    k = e + 1
                    continue
                }
            }
            k = e
        }
        return String(out)
    }

    /// The input's whitespace between kept tokens `a` and `b`. Across a
    /// deleted run, the first gap in it that breaks a line (so a line break
    /// next to a deletion is never lost), else the gap before the run.
    private static func separator(_ ctx: Context, after a: Int, before b: Int) -> Array<Unicode.Scalar>.SubSequence {
        func gap(_ k: Int) -> Array<Unicode.Scalar>.SubSequence {
            ctx.scalars[(ctx.toks[k - 1].start + ctx.toks[k - 1].raw.count)..<ctx.toks[k].start]
        }
        guard b > a + 1 else { return gap(b) }
        return (a + 1...b).lazy.map(gap).first { $0.contains(where: isLineBreak) } ?? gap(a + 1)
    }

    /// The boundaries `str.splitlines` breaks on.
    private static func isLineBreak(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// The token with its first core character upper- or lower-cased.
    private static func recase(_ t: Token, upper: Bool) -> [Unicode.Scalar] {
        let j = t.lead.count
        let mapped = upper ? PyText.upper([t.raw[j]]) : PyText.lower([t.raw[j]])
        return Array(t.raw[..<j]) + mapped + Array(t.raw[(j + 1)...])
    }
}
