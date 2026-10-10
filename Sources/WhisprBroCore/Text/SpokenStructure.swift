import Foundation

/// Layout the speaker said out loud — "new paragraph", "bullet point",
/// "and I quote … unquote" — turned into real line breaks, list markers and
/// quotation marks.
///
/// **Why this is deterministic and not a prompt.** Measured on the shipping
/// 1.5B (docs/formatting-benchmark.md): asked to handle structure, it produced
/// no line breaks at all, dropped "he said" from a quote, rewrote "new
/// paragraph" as "new line", and stopped capitalizing sentences it had been
/// getting right. A small model given two jobs does neither. So the model is
/// never told about structure: the markers are lifted out BEFORE it sees the
/// text and the real structure is applied AFTER the output gate has passed it.
///
/// That ordering is the whole design:
///
///     strip fillers → EXTRACT markers → LLM → output gate → APPLY structure
///
/// The model sees one clean line and does the job it is good at. The gate
/// compares one line against one line, so `ContentGuard`'s L1 (which refuses
/// invented lines and markdown, and exists because this model once answered a
/// question in a bulleted list) keeps working untouched — it never sees the
/// structure, because the structure isn't there yet. Nothing about the
/// catastrophe L1 guards against gets relaxed to make room for this.
///
/// Positions survive the rewrite by word ALIGNMENT (`Align.align`), not by
/// character offsets: the LLM re-punctuates and re-cases freely, so a mark
/// remembers the word it came before, and that word is found again in the
/// output.
public enum SpokenStructure {

    // MARK: - What the speaker can ask for

    public enum Kind: Equatable, Sendable {
        case lineBreak        // "new line"
        case paragraphBreak   // "new paragraph"
        case bullet           // "bullet point" / "next bullet"
        case numbered(Int)    // inferred: "first … second … third"
        case quoteOpen        // "and I quote" / "open quote"
        case quoteClose       // "unquote" / "close quote" / "end quote"
    }

    /// The feature a kind belongs to.
    static func feature(of kind: Kind) -> Feature {
        switch kind {
        case .lineBreak: return .lineBreak
        case .paragraphBreak: return .paragraphBreak
        case .bullet: return .bullet
        case .numbered: return .numbered
        case .quoteOpen, .quoteClose: return .quote
        }
    }

    /// One piece of layout, anchored to the word index it precedes in the
    /// marker-free text. `wordIndex == tokenCount` means end-of-text.
    public struct Mark: Equatable, Sendable {
        public let kind: Kind
        public let wordIndex: Int
        /// The word `join` appended a terminator to, normalized — nil when it
        /// appended none. Only a terminator this layer added may be taken back
        /// out, and only from the word it was added to: the anchor can move
        /// when the formatter drops words, and stripping blindly ate the
        /// period of "5 p.m." and his own full stops.
        public let terminatedWord: String?

        public var insertedTerminator: Bool { terminatedWord != nil }

        public init(kind: Kind, wordIndex: Int, terminatedWord: String? = nil) {
            self.kind = kind
            self.wordIndex = wordIndex
            self.terminatedWord = terminatedWord
        }

        func terminating(_ word: String?) -> Mark {
            Mark(kind: kind, wordIndex: wordIndex, terminatedWord: word)
        }
    }

    /// The marker phrases, longest first so "new paragraph" wins over a
    /// hypothetical "new", and "and i quote" wins over "quote".
    ///
    /// Deliberately NOT here: spoken punctuation ("period", "comma",
    /// "question mark"). Parakeet already punctuates, and those words carry
    /// their ordinary meaning far too often ("during that period", "the comma
    /// is wrong") to be worth the false positives. Layout words are safe
    /// because a dictation almost never discusses its own layout — and the
    /// determiner guard below covers the times it does.
    static let phrases: [(words: [String], kind: Kind)] = [
        // DELIBERATELY ABSENT: "start a new paragraph", "start a new line",
        // "skip a line". Each carries its own determiner, which blinds the
        // determiner guard below — and the replacement guard for them
        // (subject/modal prefixes) oscillated through five rounds of review
        // without ever separating "PLEASE start a new paragraph here is the
        // plan" from "I WILL start a new paragraph when the section changes".
        // They are the same sentence shape. The bare forms need no such guard,
        // so only the bare forms are supported. See docs/formatting-benchmark.md §3.
        (["new", "paragraph"], .paragraphBreak),
        (["new", "line"], .lineBreak),
        (["next", "line"], .lineBreak),
        (["line", "break"], .lineBreak),
        (["next", "bullet", "point"], .bullet),
        (["next", "bullet"], .bullet),
        (["bullet", "point"], .bullet),
        (["and", "i", "quote"], .quoteOpen),
        (["open", "quote"], .quoteOpen),
        (["close", "quote"], .quoteClose),
        (["end", "quote"], .quoteClose),
        (["unquote"], .quoteClose),
        // DELIBERATELY ABSENT: bare "quote". It is an ordinary verb ("please
        // quote the new price", "I will quote the terms") and matching it
        // deleted his verb and wrapped the rest of the sentence in quotation
        // marks. The explicit pairs above carry the intent unambiguously.
    ]

    /// A marker phrase preceded by one of these is ordinary speech about a
    /// thing, not an instruction about layout: "a new line of credit", "the
    /// bullet point I made", "every new paragraph". The guard is what lets the
    /// vocabulary stay small and literal instead of needing a classifier.
    static let literalizingPrefixes: Set<String> = [
        // Determiners and prepositions: he is describing the thing.
        "a", "an", "the", "this", "that", "these", "those", "each", "every",
        "another", "one", "any", "no", "my", "your", "his", "her", "its",
        "our", "their", "of", "on", "per", "in", "with", "without", "about",
        // A name, not a layout: "the product is CALLED new line".
        "called", "named",
    ]

    /// A verb frame in front of **`bullet` only**. "bullet point" is the one
    /// marker that is also an ordinary English verb — "can you bullet point
    /// that for me", "just bullet point it and send it over" — and the
    /// determiner guard cannot see it, because there is no determiner.
    ///
    /// This list guards ONE kind for ONE reason. It is not the general frame
    /// guard that oscillated through five review rounds: that one tried to
    /// separate "thank you NEW PARAGRAPH best regards" from "I asked you NEW
    /// PARAGRAPH or new line", which are the same sentence shape, and a word
    /// list cannot do it. The phrases that needed it were removed instead.
    /// Object pronouns are deliberately absent: "email ME bullet point finish
    /// the deck" is a real list, and "ship IT bullet point then rest" would
    /// have been declined too. "let me bullet point the risks" is therefore
    /// read as a command — the words survive, and a bullet appears where he
    /// did not want one, which is the cheap side of an ambiguity that has no
    /// lexical answer.
    static let bulletVerbFrames: Set<String> = [
        "to", "just", "you", "we", "i", "please", "can", "could", "would",
        "should", "shall", "will", "may", "might", "must", "lets",
    ]

    // MARK: - Phase 1: lift the markers out

    public struct Extraction: Equatable, Sendable {
        /// The text with every marker phrase replaced by a sentence boundary —
        /// what the LLM sees. The boundary matters: handed "buy milk buy eggs
        /// buy bread" the model writes one comma-spliced run-on and the lines
        /// come out as "buy milk," / "buy eggs,". Handed "buy milk. buy eggs.
        /// buy bread." it punctuates and capitalizes each one properly. A
        /// period adds no WORD, so the marks' anchors are unaffected.
        public let text: String
        /// The layout, anchored into `text`'s word stream.
        public let marks: [Mark]
        public var isEmpty: Bool { marks.isEmpty }
    }

    /// Find the spoken layout and remove it from the text.
    ///
    /// `policy` decides what this register accepts: a terminal takes none (a
    /// line break there is a Return, which RUNS the half-typed command), an
    /// IDE takes breaks but not bullets. A rejected or pruned marker is left in
    /// the text exactly as spoken — silently dropping the speaker's words is
    /// the one outcome worse than not understanding them.
    public static func extract(from text: String, policy: Policy = .prose) -> Extraction {
        let words = splitWords(text)
        guard !words.isEmpty else { return Extraction(text: text, marks: []) }

        // ONE scan: every marker phrase with the word range it occupies.
        // Deciding which survive, and rebuilding the text, are separate passes
        // over THIS list — an earlier version re-matched the phrases while
        // rebuilding and correlated the two by kind, which silently deleted the
        // first of two identical markers.
        var candidates: [(range: Range<Int>, kind: Kind)] = []
        var i = 0
        while i < words.count {
            if let (length, kind) = matchPhrase(words, at: i),
               policy.features.contains(feature(of: kind)),
               !isLiteralUse(words, at: i, phraseLength: length, kind: kind) {
                candidates.append((i..<(i + length), kind))
                i += length
                continue
            }
            i += 1
        }

        if candidates.isEmpty {
            // Nothing was asked for by name. Only then may a list be inferred,
            // and only where the register allows one.
            guard policy.features.contains(.numbered) else { return Extraction(text: text, marks: []) }
            let enumerators = inferEnumeration(words)
            guard !enumerators.isEmpty else { return Extraction(text: text, marks: []) }
            return enumerate(words, at: enumerators, policy: policy)
        }

        let verdict = surviving(candidates, in: words)
        return assemble(words, candidates: candidates, keeping: verdict.kept,
                        redundant: verdict.redundant, policy: policy)
    }

    /// Which candidates are real layout, by index into `candidates`.
    ///
    /// Dropped: a break with no content after it (it structures nothing — and
    /// printing "New line." into his text is worse than dropping a word whose
    /// intent is unambiguous), a break with no content before it, the earlier
    /// of two breaks with nothing between them, and a quotation mark that does
    /// not pair around at least one word.
    static func surviving(
        _ candidates: [(range: Range<Int>, kind: Kind)], in words: [String]
    ) -> (kept: Set<Int>, redundant: Set<Int>) {
        var isMarker = Array(repeating: false, count: words.count)
        for candidate in candidates { for j in candidate.range { isMarker[j] = true } }
        func hasContent(_ range: Range<Int>) -> Bool {
            range.clamped(to: 0..<words.count).contains { !isMarker[$0] }
        }

        var out: Set<Int> = []
        var redundant: Set<Int> = []
        var lastBreak: (index: Int, end: Int)?
        var open: (index: Int, end: Int)?
        for (n, candidate) in candidates.enumerated() {
            if isBreak(candidate.kind) {
                guard hasContent(candidate.range.upperBound..<words.count) else { continue }
                guard hasContent(0..<candidate.range.lowerBound) || isItem(candidate.kind) else { continue }
                // Two breaks with nothing between them are one break. The
                // earlier is REDUNDANT, not misunderstood, so its words go with
                // it — keeping them printed "Buy milk new line ⏎ Buy eggs."
                if let previous = lastBreak, !hasContent(previous.end..<candidate.range.lowerBound) {
                    out.remove(previous.index)
                    redundant.insert(previous.index)
                }
                out.insert(n)
                lastBreak = (n, candidate.range.upperBound)
            } else if candidate.kind == .quoteOpen {
                guard open == nil else { continue }   // already inside a quotation
                open = (n, candidate.range.upperBound)
            } else {
                guard let opened = open else { continue }   // a close quotes nothing
                guard hasContent(opened.end..<candidate.range.lowerBound) else { open = nil; continue }
                out.insert(opened.index)
                out.insert(n)
                open = nil
            }
        }
        return (out, redundant)
    }

    /// Rebuild the text from the surviving candidates in one pass, so a mark's
    /// word index is exactly the position it is written at.
    private static func assemble(
        _ words: [String], candidates: [(range: Range<Int>, kind: Kind)],
        keeping survivors: Set<Int>, redundant: Set<Int>, policy: Policy
    ) -> Extraction {
        var kept: [String] = []
        var marks: [Mark] = []
        var next = 0
        var i = 0
        while i < words.count {
            if next < candidates.count, candidates[next].range.lowerBound == i {
                let candidate = candidates[next]
                if survivors.contains(next) {
                    // A connective before a spoken break is KEPT. Trimming it
                    // turned "we could ship friday OR new line we could wait"
                    // into two unrelated statements — a dangling "and" is
                    // awkward, a deleted "or" changes what he said.
                    marks.append(Mark(kind: candidate.kind, wordIndex: kept.count))
                } else if !redundant.contains(next) {
                    // Pruned because it was MISUNDERSTOOD — a break that
                    // structures nothing, an unpaired quotation. Its words go
                    // back exactly as spoken: dropping them was a silent
                    // deletion before the output gate. A REDUNDANT marker
                    // ("new line new line") is dropped outright — he said it
                    // twice and meant it once.
                    kept.append(contentsOf: words[candidate.range])
                }
                next += 1
                i = candidate.range.upperBound
                continue
            }
            kept.append(words[i])
            i += 1
        }
        let joined = join(kept, breakingAt: marks, policy: policy)
        return Extraction(text: joined.text, marks: joined.marks)
    }

    /// What a register may have done to it, without the payload a `Kind`
    /// carries — a policy is about which FEATURES are allowed, not which
    /// numbers appear.
    public enum Feature: String, CaseIterable, Sendable {
        case lineBreak, paragraphBreak, bullet, numbered, quote
    }

    /// What a given app is allowed to have done to its text. One place for
    /// every register rule, so a new surface answers three questions at once.
    public struct Policy: Equatable, Sendable {
        /// The layout features this register accepts.
        public let features: Set<Feature>
        /// End each segment with a period before handing it to the formatter,
        /// so it punctuates and capitalizes the segments separately. Off for
        /// code, where an invented period is a syntax error.
        public let sentenceBoundaries: Bool
        /// Capitalize the first word of each new line. Off for code.
        public let capitalizeLines: Bool
        /// Capitalize the first word of the whole dictation when the model
        /// left it lowercase. Off for code and for instant messages, where
        /// `StyleRules` says a lowercase start is fine.
        // (A finishing pass — forcing an opening capital and a closing full
        // stop on every prose dictation — lived here. It was scope creep
        // beyond layout and it is where "can do" became "can do?" and "cd"
        // became "Cd". The model's own punctuation ships now, as it did
        // before this feature.)
        /// Give the finished text an opening capital and a closing full stop
        /// when the model left them off. Off for code and for shells, where an
        /// invented capital or period is a syntax error.
        /// Give the finished text an opening capital and a closing full stop
        /// when the model left them off. Off for code and shells (an invented
        /// capital or period is a syntax error), and off for instant messages
        /// and verbatim registers, where `StyleRules` tells the model "a
        /// lowercase start is fine" — overriding its compliant output there is
        /// formalizing him.
        public let finishes: Bool

        public init(features: Set<Feature>, sentenceBoundaries: Bool,
                    capitalizeLines: Bool, finishes: Bool? = nil) {
            self.features = features
            self.sentenceBoundaries = sentenceBoundaries
            self.capitalizeLines = capitalizeLines
            self.finishes = finishes ?? capitalizeLines
        }

        /// Everything the speaker states outright. **`.numbered` is not in
        /// here**: inferring a list from "one … two … three" wrecks ordinary
        /// counting speech — "we need one more week for QA, two more engineers
        /// for the port and three days of buffer" came out as a three-item
        /// list with "one", "two" and "and" deleted. The rules that separate a
        /// list from a count are semantic, and the ones tried here were a word
        /// count. See `inferEnumeration` and the controls in
        /// `SpokenStructureTests.testProseThatMerelyCountsStaysProse`.
        public static let prose = Policy(
            features: Set(Feature.allCases).subtracting([.numbered]),
            sentenceBoundaries: true, capitalizeLines: true)
        /// Opt in to inferred numbered lists as well. Not reachable from any
        /// register today — it exists so the measurement stays runnable.
        public static let inferring = Policy(
            features: Set(Feature.allCases), sentenceBoundaries: true, capitalizeLines: true)
        /// An instant message: full layout, and its own register — his
        /// opening word and his ending stay his.
        public static let casual = Policy(
            features: Set(Feature.allCases).subtracting([.numbered]), sentenceBoundaries: true,
            capitalizeLines: true, finishes: false)
        /// A register where Auto-Clean is off for this app: take the layout he
        /// asked for, leave the rest exactly as the model produced it.
        public static let verbatimish = Policy(
            features: Set(Feature.allCases).subtracting([.numbered]), sentenceBoundaries: true,
            capitalizeLines: true, finishes: false)
        /// A shell: nothing at all. A newline there is Return, which RUNS the
        /// half-typed command.
        public static let none = Policy(features: [], sentenceBoundaries: false, capitalizeLines: false)
        /// Code takes line breaks; a "- " bullet is a syntax error, and so is
        /// a period the layer added or a capital it forced onto `let`.
        public static let code = Policy(
            features: [.lineBreak, .paragraphBreak, .quote],
            sentenceBoundaries: false, capitalizeLines: false)
    }

    public static func policy(for category: AppCategory, verbatim: Bool = false) -> Policy {
        switch category {
        case .terminal: return .none
        case .ide: return .code
        case .messaging: return .casual
        // Auto-Clean is off for this app: take the layout he asked for, but
        // leave his opening word and his ending alone.
        // "Auto-Clean is off for this app" has to mean his text is left
        // alone, so the finishing pass is off there too.
        default: return verbatim ? .verbatimish : .prose
        }
    }

    // MARK: - Finishing

    /// Words whose lower case IS the word. Deliberately short and deliberately
    /// unambiguous-for-him: he is an engineer, so "cd into the repo" is the
    /// reading that matters, not "CD rates are up". Anything genuinely
    /// two-sided ("make", "cat", "swift", "node", "python") is left out, and
    /// his personal dictionary is the real answer for the rest.
    static let lowercaseByNature: Set<String> = [
        "npm", "npx", "git", "grep", "curl", "wget", "ssh", "scp", "sudo",
        "brew", "docker", "kubectl", "pip", "yarn", "pnpm", "cargo", "swiftc",
        "xcodebuild", "ffmpeg", "pytest", "chmod", "mkdir", "ls", "cd", "rm",
        "vim", "nano", "python3", "iphone", "ipad", "macos", "ios", "watchos",
        "tvos",
    ]

    /// Finish a dictation the model left unfinished: an opening capital and a
    /// closing full stop.
    ///
    /// **Always a period, never a guessed question mark.** Inferring "?" from
    /// the opening word turned "can do" into "can do?" and "do the dishes
    /// tonight" into a question, and every attempt to narrow the predicate
    /// (auxiliary + pronoun, then + determiner) traded one wrong mark for
    /// another. The model marks its own questions correctly almost always; on
    /// the rare one it leaves bare, a period is the small, predictable error.
    public static func terminating(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?:,;\u{2026}".contains(last) else { return text }
        let lastLine: String = trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? trimmed
        // A list item is not a sentence.
        if lastLine.hasPrefix("- ") || isNumberedItem(lastLine) { return text }
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        if last == "\"" || last == "\u{201D}" {
            // `right."` — the period belongs inside the quotation it ends,
            // unless one is already in there (`done."` must not become `done.."`).
            let inside = trimmed.dropLast()
            if let innermost = inside.last, ".!?,;:".contains(innermost) { return text }
            return String(inside) + "." + String(last)
        }
        return trimmed + "."
    }

    /// "1. Clone the repo" — a numbered list item.
    private static func isNumberedItem(_ line: String) -> Bool {
        let digits = line.prefix { $0.isNumber }
        return !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(". ")
    }

    /// Capitalize the first letter of a finished dictation when the model left
    /// it lowercase — it does so unpredictably, and a sentence that opens in
    /// lower case is a visible defect. Deliberate casing is left alone.
    public static func capitalizingFirstWord(
        _ text: String, preserveCasingFor: Set<String> = []
    ) -> String {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return text }
        let end = text[start...].firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
        let word = String(text[start..<end])
        let capitalized = self.capitalized(word, preserveCasingFor: preserveCasingFor)
        guard capitalized != word else { return text }
        return text.replacingCharacters(in: start..<end, with: capitalized)
    }

    // MARK: - Inference: a list he never asked for by name

    /// Enumeration words. Position in the list is the item number, and each
    /// entry carries the forms that mean it.
    static let ordinals: [[String]] = [
        ["first", "firstly"], ["second", "secondly"], ["third", "thirdly"],
        ["fourth", "fourthly"], ["fifth"], ["sixth"], ["seventh"], ["eighth"],
    ]
    static let cardinals: [[String]] = [
        ["one"], ["two"], ["three"], ["four"], ["five"], ["six"], ["seven"], ["eight"],
    ]

    /// A word in front of an enumerator that makes it a modifier rather than a
    /// marker: "THE first thing", "MY second attempt". Reuses the same idea as
    /// the marker guard — a determiner means he is describing, not counting.
    static let enumeratorModifiers: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his",
        "her", "its", "our", "their", "every", "each", "another", "any",
    ]

    /// A connective that introduces the next item rather than ending the
    /// previous one — dropped with the enumerator it belongs to.
    static let enumeratorLeadIns: Set<String> = ["and", "then", "also", "next", "plus", "or"]

    /// Minimum items before a run of enumerators is treated as a list. Two is
    /// far too common in ordinary speech ("first we ship, second we tell
    /// them") to restructure without being asked.
    static let minimumListItems = 3
    /// Minimum words in an item. "one dog two cats and three birds" counts
    /// animals; "one clone the repo, two run the installer" counts steps. The
    /// difference that survives without a parser is how much follows each
    /// number.
    static let minimumItemWords = 2

    /// Find "first … second … third" (or "one … two … three") and return the
    /// index of each enumerator word.
    ///
    /// This is the one thing in this file that GUESSES. Wispr Flow does the
    /// same job with a fine-tuned cloud model and no spoken markers at all;
    /// this app has a generic 1.5B running locally, which measurably cannot be
    /// prompted into it (docs/formatting-benchmark.md), so the inference is
    /// rules instead — and the rules are deliberately strict:
    ///
    ///  - the run starts at the FIRST item ("first" / "one"), so a stray
    ///    "second" mid-sentence starts nothing;
    ///  - it ascends with no gaps, and one enumerator used as a modifier
    ///    ("the second time") voids the whole run;
    ///  - it is at least `minimumListItems` long;
    ///  - no enumerator is preceded by a determiner or followed by "of"
    ///    ("one OF the things");
    ///  - and every item carries at least `minimumItemWords` words of its own.
    ///
    /// Anything less and the text stays prose, which is always a safe answer.
    static func inferEnumeration(_ words: [String]) -> [Int] {
        let byOrdinal = enumeratorRun(words, vocabulary: ordinals)
        if byOrdinal.count >= minimumListItems { return byOrdinal }
        let byCardinal = enumeratorRun(words, vocabulary: cardinals)
        return byCardinal.count >= minimumListItems ? byCardinal : []
    }

    private static func enumeratorRun(_ words: [String], vocabulary: [[String]]) -> [Int] {
        var found: [Int] = []
        var expecting = 0
        for (i, word) in words.enumerated() {
            guard expecting < vocabulary.count,
                  vocabulary[expecting].contains(normalize(word)) else { continue }
            guard isEnumerator(words, at: i) else {
                // A marker used as a modifier mid-run means this was prose
                // that happened to count. Abandon the whole thing.
                if expecting > 0 { return [] }
                continue
            }
            found.append(i)
            expecting += 1
        }
        guard found.count >= minimumListItems, itemsAreSubstantial(words, at: found) else { return [] }
        return found
    }

    /// The enumerator is marking an item, not modifying a noun.
    private static func isEnumerator(_ words: [String], at i: Int) -> Bool {
        if i > 0, enumeratorModifiers.contains(normalize(words[i - 1])) { return false }
        // "one of the things", "first of all" — a partitive, not a marker.
        if i + 1 < words.count, ["of"].contains(normalize(words[i + 1])) { return false }
        return i + 1 < words.count   // an enumerator with nothing after it counts nothing
    }

    /// Each item — and the run must reach the end of the text — carries enough
    /// words to be a line of its own.
    private static func itemsAreSubstantial(_ words: [String], at enumerators: [Int]) -> Bool {
        for (n, start) in enumerators.enumerated() {
            let end = n + 1 < enumerators.count ? enumerators[n + 1] : words.count
            if end - start - 1 < minimumItemWords { return false }
        }
        return true
    }

    // MARK: - Phase 2: put the structure back

    /// Apply `marks` to `formatted`, the LLM's (or the rules path's) output for
    /// `source` — the marker-free text the marks were anchored into.
    ///
    /// The output has been re-punctuated and re-cased, so positions are mapped
    /// by word alignment rather than arithmetic. A mark whose anchor word the
    /// output dropped is skipped: better a missing line break than one in the
    /// middle of a sentence.
    ///
    /// Everything is done on the ORIGINAL whitespace-separated chunks, never on
    /// a rebuild from parsed tokens: a token carries a word and its punctuation,
    /// so anything that is neither — the `=` in `let x = 1`, an arrow, an
    /// ampersand — would simply not come back. This layer moves text around; it
    /// may never lose a character of it.
    ///
    /// - Parameters:
    ///   - policy: the register's rules (see `Policy`).
    ///   - preserveCasingFor: dictionary targets whose casing is deliberate
    ///     ("npm", "getUserData") — never capitalized at a line start.
    public static func apply(
        _ marks: [Mark], to formatted: String, from source: String,
        policy: Policy = .prose, preserveCasingFor: Set<String> = []
    ) -> String {
        guard !marks.isEmpty else { return formatted }
        let sourceChunks = splitWords(source)
        let outChunks = splitWords(formatted)
        guard !outChunks.isEmpty else { return formatted }

        let mapped = mapIndices(marks, from: sourceChunks, to: outChunks)
        guard !mapped.isEmpty else { return formatted }
        // Whether the text handed to the formatter already ended in a
        // terminator. If it did, the one at the end of the output is HIS — an
        // abbreviation's period, a full stop he spoke — and a list's closing
        // strip must leave it alone.
        let sourceTerminated = source.trimmingCharacters(in: .whitespaces).last.map {
            ".!?".contains($0)
        } ?? false
        return render(outChunks, breaks: mapped, capitalizeLines: policy.capitalizeLines,
                      preserveCasingFor: preserveCasingFor, sourceTerminated: sourceTerminated)
    }

    // MARK: - Matching

    private static func matchPhrase(_ words: [String], at i: Int) -> (length: Int, kind: Kind)? {
        for (phrase, kind) in phrases where i + phrase.count <= words.count {
            if (0..<phrase.count).allSatisfy({ normalize(words[i + $0]) == phrase[$0] }) {
                return (phrase.count, kind)
            }
        }
        return nil
    }

    /// "a new line of credit" — the phrase is a noun here, not an instruction.
    /// Checked on the word BEFORE the phrase, and on the word after for the
    /// possessive/relative shapes ("the bullet point I made" is caught by the
    /// prefix; "new line of credit" by the follower).
    private static func isLiteralUse(
        _ words: [String], at i: Int, phraseLength: Int, kind: Kind
    ) -> Bool {
        if i > 0 {
            let previous = normalize(words[i - 1])
            // The determiner guard: he is describing a thing, not asking for
            // layout. Five rounds of adding a SECOND general guard on top of
            // this one each broke a real command; the phrases that needed one
            // were removed instead.
            if literalizingPrefixes.contains(previous) { return true }
            // …plus the verb frames, for the one marker that is a verb.
            if kind == .bullet, bulletVerbFrames.contains(previous) { return true }
        }
        let after = i + phraseLength
        // "new line OF credit", "bullet point ABOUT pricing".
        if after < words.count, ["of", "about", "for"].contains(normalize(words[after])) { return true }
        return false
    }

    private static func normalize(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - Kinds

    static func isBreak(_ kind: Kind) -> Bool {
        switch kind {
        case .lineBreak, .paragraphBreak, .bullet, .numbered: return true
        case .quoteOpen, .quoteClose: return false
        }
    }

    /// A list item — a line that is not a sentence, and whose lead-in ends in
    /// a colon rather than a period.
    static func isItem(_ kind: Kind) -> Bool {
        switch kind {
        case .bullet, .numbered: return true
        default: return false
        }
    }

    /// Turn a detected enumeration into numbered marks, consuming the
    /// enumerator words themselves ("first", "two", …) — they become the
    /// number in front of the line.
    private static func enumerate(_ words: [String], at enumerators: [Int], policy: Policy) -> Extraction {
        let positions = Set(enumerators)
        var kept: [String] = []
        var marks: [Mark] = []
        var n = 0
        for (i, word) in words.enumerated() {
            if positions.contains(i) {
                // "…call marco AND third book the flights": the connective
                // introduced the next item, it did not end the previous one.
                if let last = kept.last, enumeratorLeadIns.contains(normalize(last)) {
                    kept.removeLast()
                }
                n += 1
                marks.append(Mark(kind: .numbered(n), wordIndex: kept.count))
                continue
            }
            kept.append(word)
        }
        let joined = join(kept, breakingAt: marks, policy: policy)
        return Extraction(text: joined.text, marks: joined.marks)
    }

    /// Join the marker-free words, ending the word before each BREAK with a
    /// terminator so the formatter treats each segment as its own sentence.
    /// Returns the text plus the marks, each recording whether a terminator was
    /// actually INSERTED here — only what this layer added may later be taken
    /// back out (see `Mark.insertedTerminator`).
    ///
    /// A quotation mark is intra-sentence and gets no boundary.
    static func join(_ words: [String], breakingAt marks: [Mark],
                     policy: Policy) -> (text: String, marks: [Mark]) {
        guard policy.sentenceBoundaries else { return (words.joined(separator: " "), marks) }
        let breaks = marks.filter { isBreak($0.kind) }
        var boundary: [Int: String] = [:]
        var segmentStart = 0
        for (n, mark) in breaks.enumerated() {
            // The lead-in to a list ends in a colon — "three things today:" —
            // a segment that opens as a question ends in "?" (forcing a period
            // there is how "can you look at the PR" lost its question mark),
            // and everything else ends as its own sentence.
            // A colon introduces a list; everything else is a period. The
            // question guess that used to live here turned "do it this week
            // new line then tell me" into "Do it this week?" — the same failed
            // trade `terminating` retired, and worse here, because the model
            // never sees the text again to correct it.
            boundary[mark.wordIndex] = (n == 0 && isItem(mark.kind) && mark.wordIndex > 0) ? ":" : "."
            segmentStart = mark.wordIndex
        }
        var inserted: [Int: String] = [:]
        var out: [String] = []
        for (i, word) in words.enumerated() {
            var w = word
            if let terminator = boundary[i + 1], let last = w.last,
               // A line ending on a bare connective is not a sentence:
               // "thanks for the update and." reads worse than the dangling
               // "and" does. The break itself is the separator.
               !enumeratorLeadIns.contains(normalize(w)) {
                // ALREADY punctuated — his full stop, an abbreviation
                // ("5 p.m."), an ellipsis, a question mark, a comma he paused
                // on, the colon introducing what follows. Not one character of
                // it is ours to replace: an earlier version swapped ",;:" for
                // its own terminator and then stripped that, so both his
                // punctuation and the replacement disappeared.
                if ".!?,;:".contains(last) {
                    out.append(w)
                    continue
                }
                w += terminator
                inserted[i + 1] = normalize(word)
            }
            out.append(w)
        }
        var updated: [Mark] = []
        for mark in marks {
            updated.append(mark.terminating(inserted[mark.wordIndex]))
        }
        let text: String = out.joined(separator: " ")
        return (text, updated)
    }

    // MARK: - Mapping through the rewrite

    /// Map each mark's source word index onto an output word index.
    private static func mapIndices(_ marks: [Mark], from source: [String], to out: [String]) -> [Mark] {
        guard !source.isEmpty, !out.isEmpty else { return [] }
        let alignment = Align.align(source.map(alignmentToken), out.map(alignmentToken))
        // source index → output index, for every chunk the output kept.
        var map: [Int: Int] = [:]
        for (a, b) in alignment.pairs { map[a] = b }

        var mapped: [Mark] = []
        for mark in marks {
            if mark.wordIndex >= source.count {
                mapped.append(Mark(kind: mark.kind, wordIndex: out.count,
                                   terminatedWord: mark.terminatedWord))
                continue
            }
            // The anchor word itself, or the next surviving word after it —
            // the break belongs before whichever of them the output kept.
            var anchor: Int?
            for i in mark.wordIndex..<source.count {
                if let o = map[i] { anchor = o; break }
            }
            guard let index = anchor else { continue }
            mapped.append(Mark(kind: mark.kind, wordIndex: index,
                               terminatedWord: mark.terminatedWord))
        }
        return droppingUnclosedQuotes(mapped)
    }

    /// An open whose close did not survive the rewrite would put a lone `"` in
    /// his text. Drop it — the pair is all or nothing.
    private static func droppingUnclosedQuotes(_ marks: [Mark]) -> [Mark] {
        var out: [Mark] = []
        var openIndex: Int?
        for mark in marks {
            switch mark.kind {
            case .quoteOpen:
                openIndex = out.count
                out.append(mark)
            case .quoteClose:
                guard openIndex != nil else { continue }
                openIndex = nil
                out.append(mark)
            default:
                out.append(mark)
            }
        }
        if let dangling = openIndex { out.remove(at: dangling) }
        return out
    }

    /// A chunk as an alignment key: letters and digits only, so the
    /// formatter's punctuation and casing changes still align ("milk." ==
    /// "milk"). A chunk with neither — a lone `=` or `->` — keeps its own
    /// text, so symbols stay distinguishable from each other.
    private static func alignmentToken(_ chunk: String) -> EvalToken {
        let core = chunk.lowercased().filter { $0.isLetter || $0.isNumber }
        let key = core.isEmpty ? chunk.lowercased() : core
        return EvalToken(normalized: key, cased: chunk, leadingMarks: [], trailingMarks: [], canonical: key)
    }

    // MARK: - Rendering

    /// Rebuild the text with breaks, bullets and quotation marks inserted,
    /// from the output's own chunks — nothing is re-derived, so nothing is lost.
    private static func render(_ chunks: [String], breaks: [Mark], capitalizeLines: Bool,
                               preserveCasingFor: Set<String>, sourceTerminated: Bool) -> String {
        var opens: Set<Int> = [], closes: Set<Int> = []
        var layout: [Int: Kind] = [:]
        var strippable: [Int: String] = [:]
        for mark in breaks {
            switch mark.kind {
            case .quoteOpen: opens.insert(mark.wordIndex)
            case .quoteClose: closes.insert(mark.wordIndex)
            case .bullet, .numbered, .lineBreak, .paragraphBreak:
                // Two marks on one word: the formatter dropped everything
                // between them. The FIRST wins — a later one would renumber a
                // list ("1." then "3.") or turn a line break into a bullet.
                guard layout[mark.wordIndex] == nil else { continue }
                layout[mark.wordIndex] = mark.kind
                if let word = mark.terminatedWord { strippable[mark.wordIndex] = word }
            }
        }
        // A quotation whose whole span the formatter dropped opens and closes
        // at one index; emitting both would give `he said" "today`.
        let collapsed = opens.intersection(closes)
        opens.subtract(collapsed)
        closes.subtract(collapsed)

        var out = ""
        // False at the start: the FIRST line is the formatter's to case (it
        // knows the dictionary and the register). This layer only owns the
        // lines it creates.
        var atLineStart = false
        for (i, chunk) in chunks.enumerated() {
            // A quotation closes tight against the word it followed, before
            // any separator or line break — `shipping." today`, never
            // `shipping "today`.
            if closes.contains(i), !endsQuoted(out) { out = closeQuote(out) }
            if let kind = layout[i] {
                out = trimTrailingSpaces(out)
                if kind != .paragraphBreak, i > 0,
                   let terminated = strippable[i],
                   normalize(chunks[i - 1]) == terminated {
                    // A bullet or a soft line break is not a sentence end, so
                    // the terminator reads as noise once the line stands on its
                    // own — but ONLY the one this layer inserted. His own full
                    // stop, an abbreviation's period, an ellipsis, a semicolon
                    // in code: not ours to remove.
                    out = stripLineTerminator(out)
                }
                // Nothing to break away from yet: the first line starts here.
                if !out.isEmpty { out += kind == .paragraphBreak ? "\n\n" : "\n" }
                switch kind {
                case .bullet: out += "- "
                case .numbered(let n): out += "\(n). "
                default: break
                }
                atLineStart = true
            } else if i > 0, !atLineStart {
                out += " "
            }
            // The formatter sometimes quotes the span itself ("she said ship
            // it" → `"ship it."`). Adding a second pair would give `""ship
            // it.""`, so only quote what is not quoted already.
            if opens.contains(i), !chunk.hasPrefix("\"") { out += "\"" }
            out += atLineStart && capitalizeLines
                ? capitalized(chunk, preserveCasingFor: preserveCasingFor)
                : chunk
            atLineStart = false
        }
        if closes.contains(chunks.count), !endsQuoted(out) { out = closeQuote(out) }
        // A BULLET list ends without a terminator too — the last item is an
        // item like the others. A soft line break keeps the final period: the
        // dictation still ended in a sentence.
        // The last item of a LIST ends without a terminator, like the items
        // above it — but only when the formatter is the one that put it there.
        // If the source already ended in a terminator, that period is his (he
        // said "meet at 5 p.m."), and an unconditional strip ate it.
        if let last = breaks.last(where: { isBreak($0.kind) }), isItem(last.kind),
           out.hasSuffix("."), !sourceTerminated {
            out = stripLineTerminator(out)
        }
        return out
    }

    /// Capitalize a line's first word, unless its casing is deliberate — a
    /// dictionary target ("npm") or an identifier with internal capitals
    /// ("getUserData").
    private static func capitalized(_ chunk: String, preserveCasingFor: Set<String>) -> String {
        let core = chunk.filter { $0.isLetter || $0.isNumber }
        guard let first = chunk.firstIndex(where: { $0.isLetter }) else { return chunk }
        guard !preserveCasingFor.contains(core.lowercased()),
              !lowercaseByNature.contains(core.lowercased()),
              // An address, a path, a flag or a domain is never a sentence.
              !chunk.contains("@"), !chunk.contains("/"), !chunk.hasPrefix("-"),
              !core.dropFirst().contains(where: { $0.isUppercase })
        else { return chunk }
        var out = chunk
        out.replaceSubrange(first...first, with: String(chunk[first]).uppercased())
        return out
    }

    /// Put the closing quote inside any trailing sentence punctuation the
    /// formatter added — `right."` not `right".`
    private static func closeQuote(_ text: String) -> String {
        var s = text
        var tail = ""
        while let last = s.last, ".,!?;:".contains(last) {
            tail.insert(last, at: tail.startIndex)
            s.removeLast()
        }
        return s + tail + "\""
    }

    /// Whether the text already ends in a closing quotation mark, ignoring
    /// any sentence punctuation after it.
    private static func endsQuoted(_ text: String) -> Bool {
        var s = text
        while let last = s.last, ".,!?;: ".contains(last) { s.removeLast() }
        return s.last == "\"" || s.last == "\u{201D}"
    }

    private static func trimTrailingSpaces(_ s: String) -> String {
        var out = s
        while out.last == " " { out.removeLast() }
        return out
    }


    private static func stripLineTerminator(_ s: String) -> String {
        var out = s
        // ":" is deliberate — it is the lead-in to the list below it.
        if let last = out.last, ".,;".contains(last) { out.removeLast() }
        return out
    }
}
