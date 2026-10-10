import Foundation

/// Shared alignment core for the eval scorers: `TranscriptScore` (the
/// continuity line) and the quality scorer / content guard / fixture lint
/// that build on it. ONE tokenizer, ONE alignment, ONE span locator — so WER,
/// punctuation, casing, filler credit and novelty are all read off the same
/// token sequence and can never disagree about where a word is. Pure string
/// math, deterministic, zero dependencies; lives in WhisprBroCore (not
/// whispr-bench) so the test target can pin every rule by hand count.
enum Align {
    /// Boundary marks that count as punctuation. Other symbols (`+ = * #`,
    /// quotes, brackets, dashes) are orphan marks and dropped.
    static let scoredMarks: Set<Character> = [".", ",", "!", "?", ";", ":", "¿", "¡"]

    /// Function words whose deletion is never an over-edit and whose
    /// insertion is never novel content (the plan's STOP set).
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "to", "of", "in", "on", "for", "is", "are", "it", "that", "this",
    ]

    /// Polarity carriers (the plan's NEG set); `isNegation` adds every "n't"
    /// contraction so "don't" / "isn't" / "can't" need no list.
    static let negationWords: Set<String> = [
        "not", "never", "no", "none", "nothing", "nobody", "nowhere", "cannot",
    ]

    /// The same contractions WITHOUT the apostrophe — the form dictation
    /// actually produces ("i dont think we can ship this week"), whose
    /// apostrophe a formatter is expected to restore. What needs the list is
    /// the DROP rule: a raw "dont" deleted while the word it governed
    /// survives is a polarity flip, and the "n't" suffix rule cannot see it.
    /// The RESTORATION direction is no longer a lexicon question —
    /// `isApostropheRestored` decides it structurally, so a contraction
    /// missing here ("mustnt", "neednt") can never read as a negation
    /// INSERTED into a non-negation word. Listed rather than derived:
    /// dropping the apostrophe from the suffix rule would catch every word
    /// ending in "nt".
    ///
    /// The accepted cost is the two homographs, and it cuts BOTH ways — the
    /// original note here claimed a homograph could only silence a rule,
    /// which was wrong: a dropped noun "cant" (a tilt) or "wont" (a habit)
    /// makes the drop rule FIRE, i.e. a false NEGATED on an output that
    /// threw the noun away. Kept anyway: both nouns are rare in dictation,
    /// the outputs that drop them are over-edits a refusal is right about,
    /// and losing "cant" / "wont" from the list would miss the flip of the
    /// two commonest contractions he speaks.
    static let unapostrophizedNegations: Set<String> = [
        "dont", "cant", "wont", "didnt", "isnt", "arent", "wasnt", "werent", "doesnt",
        "couldnt", "wouldnt", "shouldnt", "havent", "hasnt", "hadnt", "aint",
        "mustnt", "neednt", "shant", "mightnt", "oughtnt", "darent",
    ]

    static func isNegation(_ normalized: String) -> Bool {
        negationWords.contains(normalized) || unapostrophizedNegations.contains(normalized)
            || normalized.hasSuffix("n't")
    }

    /// Is `out` `raw` with the apostrophe put back — an apostrophe inserted
    /// before a terminal "t" ("dont" → "don't", "mustnt" → "mustn't")? The
    /// structural reading of the restoration a formatter is asked for, so
    /// the class closes for EVERY contraction instead of for the ones a
    /// hand list happens to name.
    static func isApostropheRestored(_ raw: String, as out: String) -> Bool {
        out.hasSuffix("n't") && raw == unapostrophized(out)
    }

    /// A canonical form with its apostrophes removed — the key that makes a
    /// restored contraction the speaker's own word and not novel content
    /// (`isCovered`). Symmetric with the hyphen-split forgiveness: dictation
    /// drops the mark, the formatter puts it back, and the novelty
    /// vocabulary has to read both spellings as one word.
    static func unapostrophized(_ normalized: String) -> String {
        normalized.contains("'") ? normalized.replacingOccurrences(of: "'", with: "") : normalized
    }

    /// Words after which a "<hour> <tens>" pair reads as a CLOCK time rather
    /// than as two numbers ("meet at two thirty" → 2:30, while "three thirty
    /// minute rounds" is a count). A TENS-word minute and no other: "at nine
    /// fifteen" stays the two atoms "9" and "15", because a teen minute is a
    /// count just as often ("three fifteen minute breaks") and the merge
    /// moves the SHARED canon, i.e. the grader (`NumberCanon.clock`). It
    /// costs the shipping path nothing — the live witness reads "9:15" as
    /// the 9 and the 15 he said either way — and the grader one novel atom
    /// on such a row. Narrow on purpose, and narrower than the
    /// first cut: "after", "before", "around" and "from" routinely head a
    /// COUNT ("after three thirty minute rounds", "around four twenty minute
    /// demos"), where the merge changes the raw atom set and a CORRECT
    /// output ("2 40-minute sessions") then reads as novel content. With no
    /// anchor the pair stays two atoms — exactly the behaviour before clock
    /// pairs existed — so a wrong merge can never turn a quantity into a
    /// time.
    static let clockAnchors: Set<String> = ["at", "by", "until", "till"]

    /// Nouns that make a "<hour> <tens>" pair a COUNT even after an anchor
    /// ("at three thirty minute rounds" is three rounds of thirty minutes,
    /// never 3:30). The residual ambiguity the preposition cannot resolve —
    /// `canonicalize` re-reads such a run as cardinals.
    static let timeUnitNouns: Set<String> = [
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days",
        "week", "weeks", "month", "months", "year", "years",
    ]

    // MARK: - Tokenization

    /// In-word characters kept in the normalized form — letters/digits plus
    /// apostrophe/hyphen/underscore, consistent with FillerStripper's
    /// `wordChar` (so "it's" ≠ "its" and "top-notch" stays one token).
    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "-" || c == "_"
    }

    /// Split on whitespace; peel boundary marks off each chunk. Non-scored
    /// boundary symbols (quotes, brackets, dashes, …) are TRANSPARENT to the
    /// peel — dropped, but the peel continues past them — so a mark next to
    /// one still counts: «plan."» carries its period. A chunk with
    /// no word core (a stray "," between words) attaches its marks to the
    /// previous word — or is returned as an orphan mark when there is none —
    /// so residue punctuation still counts against precision/recall (the
    /// characters, not just a count, so the per-class punctuation axis can
    /// file an orphan under its class). Interior symbols are dropped from
    /// the word core ("e.g." → "eg") except inside a number, where a decimal
    /// point or time colon is KEPT (`numericCore`); a dotted abbreviation
    /// is remembered on the token so its period is not read as a sentence
    /// end.
    static func tokenize(_ text: String) -> (tokens: [EvalToken], orphanMarks: [Character]) {
        var tokens: [EvalToken] = []
        var orphans: [Character] = []
        for chunk in text.split(whereSeparator: \.isWhitespace) {
            var chars = Array(chunk).map { $0 == "’" ? Character("'") : $0 }
            var leading: [Character] = []
            var trailing: [Character] = []
            while let f = chars.first, !isWordChar(f) {
                if scoredMarks.contains(f) { leading.append(f) }
                chars.removeFirst()
            }
            while let l = chars.last, !isWordChar(l) {
                if scoredMarks.contains(l) { trailing.append(l) }
                chars.removeLast()
            }
            let cased = numericCore(chars) ?? String(chars.filter { isWordChar($0) })
            if cased.isEmpty {
                if tokens.isEmpty { orphans += leading + trailing }
                else { tokens[tokens.count - 1].trailingMarks += leading + trailing }
                continue
            }
            let normalized = cased.lowercased()
            tokens.append(EvalToken(normalized: normalized, cased: cased,
                                    leadingMarks: leading, trailingMarks: trailing,
                                    canonical: NumberCanon.canonical(normalized),
                                    isAbbreviation: isAbbreviation(chars)))
        }
        return (tokens, orphans)
    }

    /// A digits-only core with interior separators. Thousands commas are
    /// dropped (`1,200` → `1200`, a cardinal); decimal points and time colons
    /// are kept (`2.5`, `11:30`), so a decimal is never equal to its digit
    /// run (a "25" → "2.5" corruption stays a visible edit) and a time
    /// never reads as a cardinal (`11:30` for "eleven thirty" is one novel
    /// token, not an invented number — `EvalToken.isNumeral` is false).
    /// nil for any other shape, which takes the plain word-char filter.
    private static func numericCore(_ chars: [Character]) -> String? {
        var out = ""
        var expectDigit = true, sawSeparator = false
        for c in chars {
            if c.isASCII, c.isNumber {
                out.append(c)
                expectDigit = false
            } else if !expectDigit, c == "," || c == "." || c == ":" {
                if c != "," { out.append(c) }
                expectDigit = true
                sawSeparator = true
            } else {
                return nil
            }
        }
        return sawSeparator && !expectDigit ? out : nil
    }

    /// Mirrors `TextFormatter.isAbbreviationExempt` — the production rule
    /// for "this period does not end a sentence": a listed stem ("e.g",
    /// "etc", "p.m", "ph.d") or a dotted initialism of single letters
    /// ("U.S", a bare "J"). `chars` is the peeled core with its interior
    /// symbols still in place; the trailing period itself is already off.
    private static func isAbbreviation(_ chars: [Character]) -> Bool {
        guard chars.contains(where: \.isLetter) else { return false }
        let stem = String(chars).lowercased()
        if TextFormatter.capitalizationExemptAbbreviations.contains(stem) { return true }
        return stem.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { $0.count == 1 && $0.first!.isLetter }
    }

    /// Collapses runs of number words into one atom per spoken number
    /// (`fifty four` → `54`, `twenty six K` → `26000`, `a hundred and fifty`
    /// → `a` `150`, `twenty twenty six` → `2026`, `one point five` → `1.5`,
    /// `at two thirty` → `at` `2:30`) so a fixture that spells a number and
    /// an output that writes digits align 1:1 — without it the shipped
    /// column's "26" would read as an invented numeral against a raw "twenty
    /// six". A run breaks at any boundary mark (`twenty, six` is a list, not
    /// 26) and at the first word that would not extend a well-formed number
    /// (`one two three` stays three atoms); an "and" or a "point" is stepped
    /// over only where the grammar allows it to continue the run
    /// (`NumberCanon.mayContinue`), and never ends one. A clock pair needs
    /// the temporal preposition before it (`clockAnchors`) — that context is
    /// the only thing separating "at two thirty" from "three thirty minute
    /// rounds" — and a minute spoken as a TENS word, so "at nine fifteen"
    /// stays two atoms. Single-token forms are already canonical from `tokenize`;
    /// this pass exists for the multi-word ones. A merged token keeps the
    /// outer marks and the joined original words, so punctuation and casing
    /// still key to it.
    static func canonicalize(_ tokens: [EvalToken]) -> [EvalToken] {
        var out: [EvalToken] = []
        var i = 0
        while i < tokens.count {
            let anchored = i > 0 && clockAnchors.contains(tokens[i - 1].normalized)
            var run = numberRun(tokens, from: i, allowClock: anchored)
            // An anchored clock pair COUNTED by the noun after it is a
            // quantity, not a time ("at three thirty minute rounds"): read
            // the run again as cardinals, so a correct output's "30-minute"
            // still matches the atoms the speaker's words make.
            if anchored, let value = run.value, value.contains(":"),
               run.end + 1 < tokens.count, timeUnitNouns.contains(tokens[run.end + 1].normalized) {
                run = numberRun(tokens, from: i, allowClock: false)
            }
            if let value = run.value, run.end > i {
                let span = tokens[i...run.end]
                out.append(EvalToken(normalized: span.map(\.normalized).joined(separator: " "),
                                     cased: span.map(\.cased).joined(separator: " "),
                                     leadingMarks: tokens[i].leadingMarks,
                                     trailingMarks: tokens[run.end].trailingMarks,
                                     canonical: value, isAbbreviation: false))
                i = run.end + 1
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    /// The longest number run starting at `i` and the atom it canonicalizes
    /// to: greedy, stopping at a mark, at a word the grammar cannot continue
    /// past, or at the end. `end` is the last token of the run (`i - 1` when
    /// there is none), so `end > i` is "a MERGE happened".
    private static func numberRun(_ tokens: [EvalToken], from i: Int,
                                  allowClock: Bool) -> (value: String?, end: Int) {
        var words: [String] = []
        var end = i - 1, value: String?
        var j = i
        while j < tokens.count {
            if j > i, !tokens[j].leadingMarks.isEmpty { break }
            words.append(tokens[j].normalized)
            if let parsed = NumberCanon.parseAtom(words, allowClock: allowClock) {
                end = j; value = parsed
            } else if !NumberCanon.mayContinue(words) {
                break
            }
            if !tokens[j].trailingMarks.isEmpty { break }
            j += 1
        }
        return (value, end)
    }

    /// `tokenize` + `canonicalize` — the token sequence every eval alignment,
    /// span and vocabulary is built from.
    static func canonicalTokens(_ text: String) -> [EvalToken] {
        canonicalize(tokenize(text).tokens)
    }

    // MARK: - Alignment

    /// Word-level Levenshtein with backtrace (fixtures are sentence-sized, so
    /// the O(n·m) table is trivial). `key` picks the comparison form:
    /// `\.canonical` (default) makes an ITN rewrite a hit; `\.normalized` is
    /// the WER key `TranscriptScore` keeps. The backtrace prefers the diagonal
    /// so a substitution beats a delete+insert pair of the same cost (keeps
    /// punctuation keyed), then deletion over insertion; ties therefore
    /// resolve toward the LATER a-token ("the the" vs "the" deletes the first
    /// "the" and hits the second).
    static func align(_ a: [EvalToken], _ b: [EvalToken],
                      by key: KeyPath<EvalToken, String> = \.canonical) -> Alignment {
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dp[i][0] = i }
        for j in 0...b.count { dp[0][j] = j }
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count {
                for j in 1...b.count {
                    let sub = a[i - 1][keyPath: key] == b[j - 1][keyPath: key] ? 0 : 1
                    dp[i][j] = min(dp[i - 1][j - 1] + sub, dp[i - 1][j] + 1, dp[i][j - 1] + 1)
                }
            }
        }
        var ops: [AlignOp] = []
        var i = a.count, j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let equal = a[i - 1][keyPath: key] == b[j - 1][keyPath: key]
                if dp[i][j] == dp[i - 1][j - 1] + (equal ? 0 : 1) {
                    ops.append(equal ? .hit(i - 1, j - 1) : .sub(i - 1, j - 1)); i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                ops.append(.del(i - 1)); i -= 1   // a-token the other side dropped
            } else {
                ops.append(.ins(j - 1)); j -= 1   // b-token a doesn't have
            }
        }
        return Alignment(ops: ops.reversed())
    }

    // MARK: - Spans and vocabulary

    /// Index range of the `occurrence`-th (1-based) contiguous match of `span`
    /// in `tokens`, comparing canonical forms — punctuation-, case- and
    /// number-form-blind, so an annotation written as "fifty four other
    /// things" still finds "54 other things". `tokens` must already be
    /// canonicalized (`canonicalTokens`); the span is canonicalized here.
    /// Overlapping matches count as separate occurrences ("the the the"
    /// holds "the the" twice). Nil for an empty span or a missing occurrence.
    static func locate(_ span: String, in tokens: [EvalToken], occurrence: Int = 1) -> Range<Int>? {
        let needle = canonicalTokens(span).map(\.canonical)
        guard !needle.isEmpty, occurrence >= 1, needle.count <= tokens.count else { return nil }
        var seen = 0
        for start in 0...(tokens.count - needle.count) {
            guard needle.indices.allSatisfy({ tokens[start + $0].canonical == needle[$0] }) else { continue }
            seen += 1
            if seen == occurrence { return start..<(start + needle.count) }
        }
        return nil
    }

    /// The novelty test's vocabulary check (`vocabulary` = canonical forms).
    /// A token is covered when its canonical form is in the vocabulary, or
    /// when it is hyphenated and every hyphen-split part is — "walk up" →
    /// "walk-up" is a formatting choice, not new content.
    static func isCovered(_ token: EvalToken, by vocabulary: Set<String>) -> Bool {
        if vocabulary.contains(token.canonical) { return true }
        // An APOSTROPHE the formatter put back is the same word the speaker
        // said ("dont" → "don't"): strip the mark and look again, the way
        // the hyphen rule forgives a join. Without this the restoration the
        // negation rules were taught to accept still gates as INVENTED —
        // three of them in one utterance trips the count rule at any length.
        let bare = unapostrophized(token.canonical)
        if bare != token.canonical, vocabulary.contains(bare) { return true }
        let parts = token.canonical.split(separator: "-").map(String.init)
        return parts.count > 1 && parts.allSatisfy { vocabulary.contains($0) }
    }
}

/// One whitespace-delimited word with its boundary punctuation pulled off.
/// `normalized` is the WER key (`TranscriptScore` stays canonical-blind: an
/// ITN rewrite is still a word edit on that axis); `canonical` is the key the
/// quality scorer aligns on — the normalized form with a cardinal reduced to
/// digits (`fifty-four` → `54`), or a whole spelled run after `canonicalize`.
struct EvalToken: Sendable, Equatable {
    var normalized: String       // lowercased word core (see `Align.isWordChar`)
    var cased: String            // word core with original casing
    var leadingMarks: [Character] // scored marks peeled off the front
    var trailingMarks: [Character] // scored marks peeled off the back (+ orphans)
    var canonical: String
    /// The chunk was a dotted abbreviation or initialism ("e.g.", "U.S.",
    /// "p.m."), so a trailing period is part of the word, not a sentence
    /// end — the casing axis scores the word after it.
    var isAbbreviation: Bool = false

    /// All scored marks, leading first — the multiset the punctuation axes
    /// compare.
    var marks: [Character] { leadingMarks + trailingMarks }
    /// A cardinal atom (digits only after canonicalization); the novelty
    /// gate's "invented number" signal. A decimal or a time (`2.5`, `11:30`)
    /// keeps its separator and is NOT a numeral — a correct ITN of "two and
    /// a half" must not gate, so those forms count as plain novel tokens.
    var isNumeral: Bool { !canonical.isEmpty && canonical.allSatisfy { $0.isASCII && $0.isNumber } }
}

/// One step of a word alignment between sequence `a` (left) and `b` (right).
enum AlignOp: Sendable, Equatable {
    case hit(Int, Int)   // equal keys
    case sub(Int, Int)   // aligned, keys differ
    case del(Int)        // a-token with no counterpart
    case ins(Int)        // b-token with no counterpart

    var aIndex: Int? {
        switch self {
        case .hit(let i, _), .sub(let i, _), .del(let i): return i
        case .ins: return nil
        }
    }
    var bIndex: Int? {
        switch self {
        case .hit(_, let j), .sub(_, let j), .ins(let j): return j
        case .del: return nil
        }
    }
    /// Hit or sub — the a-token has a counterpart on the b side, whatever
    /// that counterpart says.
    var isAligned: Bool {
        switch self {
        case .hit, .sub: return true
        case .del, .ins: return false
        }
    }
    /// A hit alone — the WORD is still there, spelled the same. "Does it
    /// survive in the gold" is this question and never `isAligned`: a
    /// filler the gold REPLACES is aligned and gone, so reading it as kept
    /// names a word the gold does not carry.
    var survives: Bool {
        switch self {
        case .hit: return true
        case .sub, .del, .ins: return false
        }
    }
}

/// The op list of one `Align.align` call plus the H/S/D/I counts every metric
/// starts from. Ops are in left-to-right order (both indices increase), so
/// `opsA` / `opsB` — the op that consumed each a- / b-token — are plain filters.
struct Alignment: Sendable {
    let ops: [AlignOp]
    let hits: Int
    let subs: Int
    let dels: Int
    let ins: Int

    init(ops: [AlignOp]) {
        self.ops = ops
        var h = 0, s = 0, d = 0, n = 0
        for op in ops {
            switch op {
            case .hit: h += 1
            case .sub: s += 1
            case .del: d += 1
            case .ins: n += 1
            }
        }
        hits = h; subs = s; dels = d; ins = n
    }

    /// Levenshtein distance: S + D + I.
    var errors: Int { subs + dels + ins }
    /// (a, b) index pairs of hits AND subs — the keyed pairs the punctuation
    /// and case axes read.
    var pairs: [(Int, Int)] {
        ops.compactMap { op in
            guard let i = op.aIndex, let j = op.bIndex else { return nil }
            return (i, j)
        }
    }
    /// The op that consumed a-token i (`.hit` / `.sub` / `.del`), indexed by i.
    var opsA: [AlignOp] { ops.filter { $0.aIndex != nil } }
    /// The op that consumed b-token j (`.hit` / `.sub` / `.ins`), indexed by j.
    var opsB: [AlignOp] { ops.filter { $0.bIndex != nil } }
}

/// Spoken number words → the written atom a formatter is expected to
/// produce. Cardinals are the core (`parse`, integers only: "fifty four" →
/// 54, "twenty six K" → 26000); `parseAtom` adds the three non-cardinal
/// forms real dictation produces every day, each keeping the cardinal
/// grammar's well-formedness guards so a list or a pair of quantities is
/// never silently summed:
///  - a **year pair** — "twenty twenty six" → 2026, "nineteen ninety five"
///    → 1995 (century word 13…20 + a 10…99 tail);
///  - a **decimal run** — "one point five" → 1.5 (a cardinal, "point", then
///    digit words); the run stops at the fraction, so "one point five
///    million" is the two atoms an output writes, `1.5` and `million`;
///  - a **clock pair** — "two thirty" → 2:30, "eleven forty five" → 11:45
///    (hour 1…12 + a tens-word minute, never a TEEN one: "nine fifteen"
///    stays two atoms), only where the caller says the context allows it
///    (`Align.clockAnchors`).
/// Needed because the shipped column has no gold, so "26" from "twenty six",
/// "2026" from "twenty twenty six" and "1.5" from "one point five" must not
/// read as invented numerals. Still deliberately absent: ordinals, month
/// names, "oh"-infixed years ("nineteen oh five"), fractions other than
/// "point" runs — a fixture covers those with `alternates`, and the live
/// gate exempts a numeral whose digits the speaker demonstrably said
/// (`ContentGuard.Profile.live`).
enum NumberCanon {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    private enum Kind { case start, unit, teen, tens, hundred, scale, digits, k, and }

    /// Canonical form of one token: its cardinal value as digits, else the
    /// normalized word itself.
    static func canonical(_ normalized: String) -> String {
        parse([normalized]).map(String.init) ?? normalized
    }

    /// Parses normalized tokens as ONE cardinal; nil when any word is not a
    /// number word or the sequence is not well formed ("one two" is a list,
    /// "45 25" two numbers). Hyphenated tokens are split first so "fifty-four"
    /// and "fifty four" parse alike, and a "K" suffix (attached or spaced)
    /// multiplies by a thousand. Digit groups arrive with their thousands
    /// commas already dropped by the tokenizer (`1,200` → `1200`; a decimal
    /// keeps its point and is not a cardinal). "and" continues a cardinal
    /// after a hundred or a scale word — "a hundred and fifty" → 150, "two
    /// thousand and twenty six" → 2026, the standard spoken forms his
    /// history uses — and never starts or ends one, so "forty two and
    /// twenty eight" stays two atoms. Every prefix of a well-formed cardinal
    /// is well formed or ends in such an "and" (`mayContinue`), which is
    /// what lets `canonicalize` extend a run greedily. A value that does
    /// not fit an `Int` is not a cardinal (nil, never a trap): the scorer
    /// runs on arbitrary text and a crash mid-run loses the whole run.
    static func parse(_ tokens: [String]) -> Int? {
        let words = splitWords(tokens)
        guard !words.isEmpty else { return nil }
        var total = 0, group = 0, lastScale = Int.max
        var last = Kind.start
        for word in words {
            // A "k" is terminal: nothing extends "twenty six k".
            guard last != .k else { return nil }
            let kind: Kind
            let n: Int
            if let u = units[word] { kind = u < 10 ? .unit : .teen; n = u }
            else if let t = tens[word] { kind = .tens; n = t }
            else if word == "hundred" { kind = .hundred; n = 100 }
            else if let s = scales[word] { kind = .scale; n = s }
            else if word == "k" { kind = .k; n = 1_000 }
            else if word == "and" { kind = .and; n = 0 }
            else if isDigits(word[...]), word.count <= 12, let d = Int(word) { kind = .digits; n = d }
            else { return nil }
            switch kind {
            case .unit, .teen:
                guard [.start, .scale, .hundred, .and].contains(last) || (last == .tens && kind == .unit) else { return nil }
                group += n
            case .tens:
                guard [.start, .scale, .hundred, .and].contains(last) else { return nil }
                group += n
            case .hundred:
                guard [.start, .scale, .unit, .teen, .digits].contains(last), group < 100 else { return nil }
                group = max(group, 1) * 100
            case .scale:
                guard n < lastScale, last != .and else { return nil }   // "thousand million" is not a number
                let (product, o1) = max(group, 1).multipliedReportingOverflow(by: n)
                let (sum, o2) = total.addingReportingOverflow(product)
                guard !o1, !o2 else { return nil }
                total = sum; group = 0; lastScale = n
            case .k:
                guard last != .scale, last != .and else { return nil }
                let (sum, o1) = total.addingReportingOverflow(group)
                guard !o1, sum > 0 else { return nil }
                let (product, o2) = sum.multipliedReportingOverflow(by: n)
                guard !o2 else { return nil }
                total = product; group = 0
            case .digits:
                guard last == .start || last == .scale else { return nil }   // "45 25" is two numbers
                group = n
            case .and:
                guard last == .hundred || last == .scale else { return nil }
            case .start:
                return nil   // a sentinel for `last`, never classified
            }
            last = kind
        }
        guard last != .and else { return nil }   // "two hundred and" is unfinished
        let (result, overflow) = total.addingReportingOverflow(group)
        return overflow ? nil : result
    }

    /// The canonical ATOM for a run of number words: a cardinal's digits, or
    /// one of the three non-cardinal spoken forms written the way an output
    /// writes them ("1.5", "2:30", "2026"). Cardinals are tried FIRST, so a
    /// form the integer grammar already covers never changes meaning ("two
    /// thousand and twenty six" stays 2026 by the cardinal route); nil when
    /// the run is not one number.
    /// - `allowClock`: the caller's context check — `Align.canonicalize`
    ///   passes true only after a temporal preposition, because "<hour>
    ///   <tens>" is a time in "meet at two thirty" and a count in "three
    ///   thirty minute rounds". The clock is tried before the year so an
    ///   anchored "at eleven thirty" is 11:30 and not the year 1130.
    static func parseAtom(_ tokens: [String], allowClock: Bool = false) -> String? {
        if let value = parse(tokens) { return String(value) }
        let words = splitWords(tokens)
        if let decimal = decimal(words) { return decimal }
        if allowClock, let clock = clock(words) { return clock }
        return year(words)
    }

    /// "one point five" → "1.5": a cardinal, the word "point", then digit
    /// words ("oh" is a zero). The run ENDS at the fraction — "one point
    /// five million" is the two atoms an output writes, "1.5" and "million"
    /// — and a "point" that is a noun never merges, because both sides of it
    /// must be numbers ("we have one point to make" stays four atoms).
    private static func decimal(_ words: [String]) -> String? {
        guard let i = words.firstIndex(of: "point"), i > 0, i + 1 < words.count,
              let whole = parse(Array(words[..<i])) else { return nil }
        var digits = ""
        for word in words[(i + 1)...] {
            if let unit = units[word], unit < 10 { digits += String(unit) }
            else if word == "oh" || word == "o" { digits += "0" }
            else if isDigits(word[...]), word.count <= 12 { digits += word }
            else { return nil }
        }
        return "\(whole).\(digits)"
    }

    /// "two thirty" → "2:30", "eleven forty five" → "11:45": an hour 1…12
    /// and a minute spoken as a TENS word (optionally + a unit). A teen
    /// minute is excluded on purpose — "three fifteen minute breaks" is a
    /// count, and that ambiguity is not worth a wrong atom. It STAYS
    /// excluded: this canon is shared, so merging teens moves the grader and
    /// every stored leaderboard number, while the live gate already witnesses
    /// "9:15" digit by digit from "nine fifteen" (`ContentGuard`, pinned in
    /// `OutputGateTests`). The limit is stated wherever the pair is claimed
    /// rather than papered over.
    private static func clock(_ words: [String]) -> String? {
        guard (2...3).contains(words.count) else { return nil }
        let hour: Int
        if let unit = units[words[0]] { hour = unit }
        else if isDigits(words[0][...]), let digits = Int(words[0]) { hour = digits }
        else { return nil }
        let minuteWords = Array(words[1...])
        guard (1...12).contains(hour), tens[minuteWords[0]] != nil,
              let minute = parse(minuteWords), (1...59).contains(minute) else { return nil }
        return String(format: "%d:%02d", hour, minute)
    }

    /// "twenty twenty six" → "2026", "nineteen ninety five" → "1995": a
    /// century word (thirteen…nineteen or twenty — the only ones dictation
    /// speaks) and a 10…99 tail. Below thirteen the pair is a count or a
    /// time far more often than a year ("eleven thirty"), so it stays two
    /// atoms.
    private static func year(_ words: [String]) -> String? {
        guard (2...3).contains(words.count),
              let century = units[words[0]] ?? tens[words[0]], (13...20).contains(century) else { return nil }
        let tail = Array(words[1...])
        guard units[tail[0]] != nil || tens[tail[0]] != nil,
              let value = parse(tail), (10...99).contains(value) else { return nil }
        return String(century * 100 + value)
    }

    /// `words` is a run the canonicalizer may extend past a word that does
    /// not parse on its own: a well-formed cardinal plus a trailing "and"
    /// that the grammar lets continue it ("two hundred and", "a thousand
    /// and") — `canonicalize` steps over it and looks at the next word; if
    /// nothing follows, the run ends before the "and" — or a cardinal plus
    /// "point", whose fraction digits follow.
    static func mayContinue(_ words: [String]) -> Bool {
        guard words.count >= 2, let last = words.last else { return false }
        if last == "point" { return parse(Array(words.dropLast())) != nil }
        guard last == "and" else { return false }
        let previous = words[words.count - 2]
        guard previous == "hundred" || scales[previous] != nil else { return false }
        return parse(Array(words.dropLast())) != nil
    }

    /// Hyphen-split, and "26k" → "26" "k": the word list every parser reads,
    /// so the spaced and the attached spelling share one grammar.
    private static func splitWords(_ tokens: [String]) -> [String] {
        var words: [String] = []
        for part in tokens.flatMap({ $0.split(separator: "-", omittingEmptySubsequences: false) }) {
            let word = String(part)
            if word.count > 1, word.hasSuffix("k"), isDigits(word.dropLast()) {
                words.append(String(word.dropLast())); words.append("k")
            } else {
                words.append(word)
            }
        }
        return words
    }

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
