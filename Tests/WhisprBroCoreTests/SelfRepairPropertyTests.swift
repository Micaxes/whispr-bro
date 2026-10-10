import XCTest
@testable import WhisprBroCore

/// What `SelfRepair` promises on ANY input, checked over every reference
/// fixture and a few thousand generated dictations (seeded, so a failure
/// reproduces): it only deletes whole tokens; it reaches a fixed point (its
/// output fires nothing, so running it twice changes nothing) — but on the
/// four fixtures the valve leaves half-repaired (`valveSecondPass`); it never
/// deletes a quoted token, never deletes a dictionary term as a fragment or
/// re-cases one, never orphans a bracket or quotation mark; and the spoken
/// layout markers around a repair survive it, so `SpokenStructure` sees the
/// same layout after the repair as before.
///
/// The generated dictations mix every repair the rules know (stutters,
/// fragments, restarts, cued and numeric corrections, fillers) with the
/// look-alikes they must keep (quotations, brackets, names, symbols, doubles
/// that are English), and the dictionary terms a developer dictates.
final class SelfRepairPropertyTests: XCTestCase {

    /// SplitMix64 — the same sequence on every machine.
    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) < p * 10_000 }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    static let dictionaryTerms: Set<String> = ["getuserdata", "zq", "npm", "postgres", "kubectl"]

    private static let subjects = ["I", "we", "they", "the team", "my manager", "Sam", "the build", "our client",
                                   "the new intern", "everyone"]
    private static let verbs = ["moved", "checked", "shipped", "reviewed", "need to fix", "can send", "will update",
                                "opened", "renamed", "should test", "wanted to merge"]
    private static let objects = ["the report", "the logs", "the cache keys", "a new tab", "the 3 files",
                                  "twenty rows", "the API docs", "getUserData", "the zq tool", "npm install",
                                  "the Postgres table", "the staging server", "kubectl apply", "two more servers"]
    private static let times = ["on Monday", "at 7:30", "tomorrow", "next week", "by Friday", "this morning",
                                "in May", "after lunch"]
    private static let corrections = ["on Monday, no wait, on Tuesday", "at 3, sorry, 4", "tomorrow, I mean tonight",
                                      "by Friday, actually Saturday", "in the red, I mean blue folder",
                                      "at the top, no, the bottom"]
    private static let lookAlikes = ["the fact that that matters", "what it is is a problem", "C plus plus",
                                     "dash dash verbose", "a win win", "very very good", "Bora Bora",
                                     "had had enough", "from time to time to check"]
    static let markers = ["new line", "new paragraph", "bullet point", "next bullet", "next line", "line break"]

    /// One sentence: subject, verb, object, maybe a time — with repairs and
    /// look-alikes dropped in.
    static func sentence(_ g: inout Generator) -> [String] {
        var words = (g.pick(subjects) + " " + g.pick(verbs) + " " + g.pick(objects)).split(separator: " ").map(String.init)
        if g.chance(0.6) { words += (g.chance(0.4) ? g.pick(corrections) : g.pick(times)).split(separator: " ").map(String.init) }
        if g.chance(0.25) { words += g.pick(lookAlikes).split(separator: " ").map(String.init) }
        // stutters: a word or a two-word unit said twice, maybe across a filler
        for _ in 0..<g.below(3) where words.count >= 2 {
            let at = g.below(words.count - 1)
            let unit = g.chance(0.3) ? Array(words[at...at + 1]) : [words[at]]
            let bridge = g.chance(0.3) ? [g.pick(["um", "uh,", "like"])] : []
            words.insert(contentsOf: unit + bridge, at: at)
        }
        // a cut-off start of the next word
        if g.chance(0.3), let at = words.indices.randomElement(using: &g),
           words[at].count > 4, words[at].allSatisfy(\.isLetter) {
            words.insert(String(words[at].prefix(g.chance(0.5) ? 2 : 3)).lowercased(), at: at)
        }
        if g.chance(0.2) { words.insert(g.pick(["um", "uh", "er"]), at: g.below(words.count)) }
        // a quotation or a bracket around a few words
        if g.chance(0.25), words.count >= 3 {
            let a = g.below(words.count - 2), b = a + 1 + g.below(2)
            let (open, close) = g.pick([("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"), ("(", ")")])
            words[a] = open + words[a]
            words[b] += close
        }
        words[words.count - 1] += g.pick([".", ".", "?", ""])
        return words
    }

    /// Sentences joined plainly, or (`markers`) with a spoken layout marker
    /// between them; `markerTokens` are the marker words' token indices.
    static func dictation(_ g: inout Generator, markers withMarkers: Bool) -> (text: String, markerTokens: Set<Int>) {
        var words: [String] = []
        var markerTokens: Set<Int> = []
        for n in 0..<(1 + g.below(4)) {
            if n > 0, withMarkers {
                for word in g.pick(markers).split(separator: " ") {
                    markerTokens.insert(words.count)
                    words.append(String(word))
                }
            }
            words += sentence(&g)
        }
        return (words.joined(separator: " "), markerTokens)
    }

    // MARK: - The properties

    private struct Violation: CustomStringConvertible {
        let input: String
        let why: String
        var description: String { "\(why): \(input)" }
    }

    /// Every property but the layout one, for one input.
    private func violations(_ input: String, _ repair: SelfRepair) -> [Violation] {
        var out: [Violation] = []
        let result = repair.apply(input)
        let inTokens = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let outTokens = result.text.split(separator: " ").map(String.init)
        let deleted = result.fires.flatMap(\.deleted)
        let toks = SelfRepair.tokenize(Array(input.unicodeScalars), guards: repair.guards)

        if !Self.isSubsequenceModuloCase(outTokens, of: inTokens) { out.append(Violation(input: input, why: "not deletion-only")) }
        if Set(deleted).count != deleted.count { out.append(Violation(input: input, why: "a token deleted twice")) }
        if outTokens.count != inTokens.count - deleted.count {
            out.append(Violation(input: input, why: "output length != input - deleted"))
        }
        let again = repair.apply(result.text)
        if !again.fires.isEmpty { out.append(Violation(input: input, why: "not a fixed point: \(again.fires.map(\.rule))")) }
        let repaired = repair.repair(input)
        if repair.repair(repaired) != repaired { out.append(Violation(input: input, why: "repair() not idempotent")) }
        if repaired.split(whereSeparator: { $0.isWhitespace }).map(String.init) != outTokens {
            out.append(Violation(input: input, why: "repair() and apply() keep different tokens"))
        }
        if deleted.contains(where: { toks[$0].quoted }) { out.append(Violation(input: input, why: "deleted a quoted token")) }
        for fire in result.fires where SelfRepair.unbalanced(toks, fire.deleted) {
            out.append(Violation(input: input, why: "\(fire.rule) orphaned a bracket or quote"))
        }
        let protect = Set(repair.protect)
        for fire in result.fires where fire.rule == .r3 && fire.deleted.contains(where: { protect.contains(toks[$0].low) }) {
            out.append(Violation(input: input, why: "R3 deleted a dictionary term"))
        }
        // kept dictionary terms come out byte for byte
        let kept = toks.indices.filter { !deleted.contains($0) }
        if kept.count == outTokens.count {
            for (k, word) in zip(kept, outTokens) where protect.contains(toks[k].low) && toks[k].string != word {
                out.append(Violation(input: input, why: "re-cased a dictionary term"))
            }
        }
        return out
    }

    /// The output tokens are input tokens, in order, each the same or with
    /// its first letter's case flipped (the two case fixes).
    static func isSubsequenceModuloCase(_ out: [String], of input: [String]) -> Bool {
        var j = 0
        for word in out {
            while j < input.count, input[j] != word,
                  !(input[j].dropFirst() == word.dropFirst()
                    && input[j].prefix(1).lowercased() == word.prefix(1).lowercased()) {
                j += 1
            }
            if j == input.count { return false }
            j += 1
        }
        return true
    }

    /// (v13) The valve's cost to the fixed point, pinned: on these fixtures
    /// v11's rules keep, on the input, words they take on the output — a
    /// stutter fixed before a refused correction lets the restart onset
    /// reach it, a restart is left in front of a fire shorter than v11's —
    /// so the output fires again (docs/self-repair.md §4). Every other
    /// property holds on them, and they do fire again: a fixture that stops
    /// doing so must leave this list.
    static let valveSecondPass: Set<String> = [
        "Bring the kids my old snacks snacks, I mean, the client's snacks the client's snacks please.",
        "Please use my room room, sorry, my boss's room instead, scratch that, cancel it.",
        "We need to give to give the plants, scratch that, Dana the plants.",
        "I should pay the car, scratch um that, Dana the car car?",
    ]

    func testPropertiesHoldOnEveryReferenceFixture() {
        let repair = SelfRepair(protecting: Self.dictionaryTerms)
        var failures: [Violation] = []
        for c in SelfRepairTests.fixtures {
            var found = violations(c.input, repair)
            if Self.valveSecondPass.contains(c.input) {
                let n = found.count
                found.removeAll { $0.why.hasPrefix("not a fixed point") || $0.why == "repair() not idempotent" }
                XCTAssertEqual(n - found.count, 2, "a fixed point now: \(c.input)")
            }
            failures += found
        }
        XCTAssertGreaterThan(SelfRepairTests.fixtures.count, 0)
        XCTAssertEqual(Self.valveSecondPass.filter { said in !SelfRepairTests.fixtures.contains { $0.input == said } }, [])
        XCTAssertEqual(failures.map(\.description), [])
    }

    func testPropertiesHoldOnGeneratedDictations() {
        var g = Generator(state: 20_261_008)
        let repair = SelfRepair(protecting: Self.dictionaryTerms)
        var failures: [Violation] = []
        var fired = 0
        for _ in 0..<1000 {
            let (text, _) = Self.dictation(&g, markers: g.chance(0.5))
            if !repair.apply(text).fires.isEmpty { fired += 1 }
            failures += violations(text, repair)
        }
        XCTAssertEqual(failures.prefix(20).map(\.description), [])
        // The generator exercises the rules, not only the guards.
        XCTAssertGreaterThan(fired, 400)
    }

    /// Spoken layout around repairs: no marker word is ever deleted, and the
    /// layout `SpokenStructure` lifts out of the repaired text is the layout
    /// it lifts out of the text the filler strip alone would have left.
    func testLayoutMarkersSurviveTheRepairsAroundThem() {
        var g = Generator(state: 7)
        let dictionary = DictionaryEngine(rules: [])
        let stripper = FillerStripper()
        let repair = SelfRepair()
        var changed = 0
        for _ in 0..<600 {
            let (text, markerTokens) = Self.dictation(&g, markers: true)
            let deleted = Set(repair.apply(text).fires.flatMap(\.deleted))
            XCTAssertTrue(deleted.isDisjoint(with: markerTokens), text)
            let before = stripper.strip(text)
            let after = DictationPipeline.prePass(text, dictionary: dictionary, stripper: stripper, level: .standard,
                                                  verbatimRegister: false, language: .english)
            if after != before { changed += 1 }
            let kinds = { (s: String) in SpokenStructure.extract(from: s).marks.map(\.kind) }
            XCTAssertEqual(kinds(after), kinds(before), text)
        }
        XCTAssertGreaterThan(changed, 250, "the repairs must actually run next to the markers")
    }

    /// A spoken list whose items repeat — "bullet point yes bullet point yes
    /// bullet point no", a roll call, a tally — keeps every item at both
    /// levels: with nothing to repair inside the items, the rules change
    /// nothing at all, whatever the markers' spelling, punctuation, or a
    /// filler inside one ("new, um, line").
    func testEqualListItemsAreNeverMerged() {
        var g = Generator(state: 16)
        let dictionary = DictionaryEngine(rules: [])
        let stripper = FillerStripper()
        let items = ["yes", "no", "maybe", "call mom", "buy milk", "present", "absent", "done", "pending",
                     "approve", "reject", "same", "okay", "the cache", "fix the build", "ship it", "Monday",
                     "3 boxes", "next week", "it works"]
        let markers = ["bullet point", "next bullet", "next bullet point", "new line", "next line", "line break",
                       "new paragraph", "Bullet point,", "New line.", "new, um, line", "next uh bullet"]
        var repeats = 0
        for _ in 0..<2000 {
            var words = g.pick(["survey answers", "votes", "roll call", "todo", "status", "hi team"])
                .split(separator: " ").map(String.init)
            var previous = g.pick(items)
            for n in 0..<(2 + g.below(5)) {
                let item = n > 0 && g.chance(0.6) ? previous : g.pick(items)
                if n > 0, item == previous { repeats += 1 }
                words += g.pick(markers).split(separator: " ").map(String.init)
                words += item.split(separator: " ").map(String.init)
                previous = item
            }
            let text = words.joined(separator: " ")
            for level in [AppConfig.Cleanup.Level.fillers, .standard] {
                let after = DictationPipeline.prePass(text, dictionary: dictionary, stripper: stripper, level: level,
                                                      verbatimRegister: false, language: .english)
                XCTAssertEqual(after, stripper.strip(text), "\(level): \(text)")
            }
        }
        XCTAssertGreaterThan(repeats, 2000, "equal items next to each other, often")
    }
}

extension SelfRepairPropertyTests.Generator: RandomNumberGenerator {}
