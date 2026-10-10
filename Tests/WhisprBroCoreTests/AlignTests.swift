import XCTest
@testable import WhisprBroCore

/// Hand-counted pins for the shared alignment core. Every quality metric
/// (F / Fi / M, the content gates, fixture lint) reads off these op lists,
/// spans and canonical forms — a wrong tie-break here would silently move
/// every score above it, so each rule is pinned by an explicit expected
/// op list, never by "distance == n".
final class AlignTests: XCTestCase {
    private func toks(_ s: String) -> [EvalToken] { Align.canonicalTokens(s) }
    private func canon(_ s: String) -> [String] { toks(s).map(\.canonical) }
    private func ops(_ a: String, _ b: String) -> [AlignOp] { Align.align(toks(a), toks(b)).ops }

    // MARK: - Op lists (hand-counted)

    func testIdentityIsAllHits() {
        let al = Align.align(toks("the quick brown fox"), toks("the quick brown fox"))
        XCTAssertEqual(al.ops, [.hit(0, 0), .hit(1, 1), .hit(2, 2), .hit(3, 3)])
        XCTAssertEqual(al.hits, 4)
        XCTAssertEqual(al.errors, 0)
    }

    func testSubstitutionAndTrailingInsertion() {
        // S=1 (quick→fast), I=1 (jumps): the same pair TranscriptScoreTests
        // counts as 2 errors, now with the ops named.
        let al = Align.align(toks("the quick brown fox"), toks("the fast brown fox jumps"))
        XCTAssertEqual(al.ops, [.hit(0, 0), .sub(1, 1), .hit(2, 2), .hit(3, 3), .ins(4)])
        XCTAssertEqual([al.hits, al.subs, al.dels, al.ins], [3, 1, 0, 1])
        XCTAssertEqual(al.errors, 2)
    }

    func testDeletionKeepsLaterTokensKeyed() {
        // "brown" dropped: the b-index of "fox" shifts to 2 and stays paired.
        XCTAssertEqual(ops("the quick brown fox", "the quick fox"),
                       [.hit(0, 0), .hit(1, 1), .del(2), .hit(3, 2)])
    }

    func testInsertionInTheMiddle() {
        XCTAssertEqual(ops("ship it", "ship it now"), [.hit(0, 0), .hit(1, 1), .ins(2)])
        XCTAssertEqual(ops("ship now", "ship it now"), [.hit(0, 0), .ins(1), .hit(1, 2)])
    }

    func testStutterTieDeletesTheEarlierCopy() {
        // Both "the"s could be the hit at equal cost; the backtrace resolves
        // toward the LATER a-token, so a collapsed run reads as
        // del(first) + hit(second) — the shape Fi's stutter rule counts.
        XCTAssertEqual(ops("the the whisper bro", "the whisper bro"),
                       [.del(0), .hit(1, 0), .hit(2, 1), .hit(3, 2)])
    }

    func testDiagonalBeatsDeleteInsertPairOfEqualCost() {
        // Two subs cost 2, as would del+ins twice; the diagonal wins so the
        // punctuation/case axes still see two keyed pairs.
        XCTAssertEqual(ops("a b", "c d"), [.sub(0, 0), .sub(1, 1)])
        // The rule's known cost, pinned so no scorer above is surprised: when
        // a del and an ins would be ADJACENT (del brown, hit fox, ins jumps),
        // the same-cost diagonal path (three subs) is taken instead — so "fox"
        // is a sub here, not a hit, and D reads 0 rather than 1. Consistent
        // with the pre-Align scorer; a maximize-hits tie-break would be a
        // different algorithm.
        XCTAssertEqual(ops("the quick brown fox", "the fast fox jumps"),
                       [.hit(0, 0), .sub(1, 1), .sub(2, 2), .sub(3, 3)])
    }

    func testReparandumDeletesAsOneBlock() {
        // The plan's repair shape: raw echo vs the resolved gold. The
        // abandoned "on tuesday i mean" is four consecutive dels and the
        // surviving "on wednesday" pairs with the LATER "on" — exactly what
        // "reparandum span absent from out" needs to hold.
        let al = Align.align(toks("meet on tuesday i mean on wednesday"), toks("meet on wednesday"))
        XCTAssertEqual(al.ops, [.hit(0, 0), .del(1), .del(2), .del(3), .del(4), .hit(5, 1), .hit(6, 2)])
        XCTAssertEqual(al.dels, 4)
        XCTAssertEqual(al.hits, 3)
    }

    func testEmptySidesAreAllDelsOrAllIns() {
        XCTAssertEqual(ops("hello there", ""), [.del(0), .del(1)])
        XCTAssertEqual(ops("", "hello"), [.ins(0)])
        XCTAssertEqual(ops("", ""), [])
    }

    func testAlignmentIsPunctuationAndCaseBlind() {
        XCTAssertEqual(ops("Okay, we ship it.", "okay we SHIP it"),
                       [.hit(0, 0), .hit(1, 1), .hit(2, 2), .hit(3, 3)])
    }

    func testCanonicalKeyMakesNumberFormsAHit() {
        // The quality axes align on canonical forms: an ITN rewrite is a hit.
        // The continuity WER key (`\.normalized`) still sees a word edit.
        XCTAssertEqual(ops("fifty-four", "54"), [.hit(0, 0)])
        XCTAssertEqual(Align.align(toks("fifty-four"), toks("54"), by: \.normalized).ops, [.sub(0, 0)])
        // §4.3's stutter-plus-number row: one "and" hits, "a and" delete,
        // and the spelled run pairs with the hyphenated output as a hit.
        XCTAssertEqual(ops("and a and sixty two", "and sixty-two"),
                       [.del(0), .del(1), .hit(2, 0), .hit(3, 1)])
    }

    func testPairsAndPerSideOpsFollowTheOps() {
        // del and ins kept apart so the path is unambiguous (see the
        // diagonal-tie pin above): H4 S1 D1 I1, cost 3 — the sub-only
        // alternative would cost 4.
        let al = Align.align(toks("the quick brown fox runs fast"), toks("the slow brown runs fast today"))
        XCTAssertEqual(al.ops, [.hit(0, 0), .sub(1, 1), .hit(2, 2), .del(3), .hit(4, 3), .hit(5, 4), .ins(5)])
        XCTAssertEqual([al.hits, al.subs, al.dels, al.ins], [4, 1, 1, 1])
        XCTAssertEqual(al.pairs.map { [$0.0, $0.1] }, [[0, 0], [1, 1], [2, 2], [4, 3], [5, 4]])
        XCTAssertEqual(al.opsA, [.hit(0, 0), .sub(1, 1), .hit(2, 2), .del(3), .hit(4, 3), .hit(5, 4)])
        XCTAssertEqual(al.opsB, [.hit(0, 0), .sub(1, 1), .hit(2, 2), .hit(4, 3), .hit(5, 4), .ins(5)])
        XCTAssertTrue(AlignOp.sub(1, 1).isAligned)
        XCTAssertFalse(AlignOp.del(3).isAligned)
        XCTAssertNil(AlignOp.ins(5).aIndex)
        XCTAssertNil(AlignOp.del(3).bIndex)
    }

    // MARK: - Cardinal canonicalization (§4.1 cases)

    func testSpelledHyphenatedAndDigitFormsShareOneAtom() {
        XCTAssertEqual(canon("fifty four"), ["54"])
        XCTAssertEqual(canon("fifty-four"), ["54"])
        XCTAssertEqual(canon("54"), ["54"])
        XCTAssertEqual(canon("twenty six K"), ["26000"])
        XCTAssertEqual(canon("26K"), ["26000"])
        XCTAssertEqual(canon("two hundred"), ["200"])
        XCTAssertEqual(canon("1,200"), ["1200"])
        XCTAssertEqual(canon("one thousand two hundred"), ["1200"])
        XCTAssertEqual(canon("two thousand twenty six"), ["2026"])
    }

    func testMergedRunKeepsOuterMarksAndOriginalWords() {
        // Punctuation and casing still key to the merged token, so F reads
        // the comma after "four" as sitting on the number.
        let t = toks("Fifty four, then")
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t[0].canonical, "54")
        XCTAssertEqual(t[0].normalized, "fifty four")
        XCTAssertEqual(t[0].cased, "Fifty four")
        XCTAssertEqual(t[0].marks, [","])
        XCTAssertTrue(t[0].isNumeral)
        XCTAssertFalse(t[1].isNumeral)
    }

    func testListsAndSeparateNumbersStayApart() {
        // A mark breaks a run ("twenty, six" is a list), and two numbers that
        // do not compose ("45 25", "one two three", "2 actually 3") stay as
        // separate atoms — never silently summed into an invented value.
        XCTAssertEqual(canon("twenty, six"), ["20", "6"])
        XCTAssertEqual(canon("45 25"), ["45", "25"])
        XCTAssertEqual(canon("one two three"), ["1", "2", "3"])
        XCTAssertEqual(canon("2 actually 3"), ["2", "actually", "3"])
        XCTAssertEqual(canon("twelve percent"), ["12", "percent"])
        // A pair whose first word is below thirteen is not a year, and with
        // no temporal anchor it is not a time either: "three thirty minute
        // rounds" is a count, and that ambiguity is left as two atoms.
        XCTAssertEqual(canon("three thirty minute rounds"), ["3", "30", "minute", "rounds"])
        XCTAssertEqual(canon("eleven thirty"), ["11", "30"])
    }

    // MARK: - Years, decimals and clock times (§4.1, task-023)

    func testSpokenYearsDecimalsAndClockTimesAreOneAtom() {
        // The forms real dictation produces, each the atom an output writes,
        // so a digit rewrite is a hit and never an invented numeral.
        XCTAssertEqual(canon("twenty twenty six"), ["2026"])
        XCTAssertEqual(canon("twenty sixteen"), ["2016"])
        XCTAssertEqual(canon("nineteen ninety five"), ["1995"])
        XCTAssertEqual(canon("eighteen fifty"), ["1850"])
        // A decimal run stops AT the fraction: "one point five million" is
        // the two atoms the model writes, "1.5" and "million" (10⁶).
        XCTAssertEqual(canon("one point five"), ["1.5"])
        XCTAssertEqual(canon("one point five million"), ["1.5", "1000000"])
        XCTAssertEqual(canon("two point two five"), ["2.25"])
        XCTAssertEqual(canon("zero point oh five"), ["0.05"])
        // A clock pair needs the temporal preposition; the minute must be a
        // tens word, and the hour 1…12.
        XCTAssertEqual(canon("meet at two thirty"), ["meet", "at", "2:30"])
        XCTAssertEqual(canon("by eleven forty five"), ["by", "11:45"])
        XCTAssertEqual(canon("at twenty thirty"), ["at", "2030"])       // hour > 12 → the year
        XCTAssertEqual(canon("at three fifteen"), ["at", "3", "15"])    // teen minute stays a count
        XCTAssertEqual(canon("three thirty"), ["3", "30"])              // no anchor
        XCTAssertEqual(NumberCanon.parseAtom(["two", "thirty"], allowClock: true), "2:30")
        XCTAssertNil(NumberCanon.parseAtom(["two", "thirty"]))
        // An anchor is not enough: a TIME-UNIT noun after the pair makes it
        // a count again ("at three thirty minute rounds" is three rounds of
        // thirty minutes). Merging it would change the raw atom set, and a
        // correct output's "30-minute" would then read as novel content.
        XCTAssertEqual(canon("at three thirty minute rounds"), ["at", "3", "30", "minute", "rounds"])
        XCTAssertEqual(canon("by four twenty minute demos"), ["by", "4", "20", "minute", "demos"])
        XCTAssertEqual(canon("at two thirty on tuesday"), ["at", "2:30", "on", "tuesday"])
        // …and the prepositions that head a count far more often than a
        // time are not anchors at all: only at / by / until / till are.
        XCTAssertEqual(Align.clockAnchors, ["at", "by", "until", "till"])
        XCTAssertEqual(canon("after three thirty minute rounds"), ["after", "3", "30", "minute", "rounds"])
        XCTAssertEqual(canon("before two forty minute sessions"), ["before", "2", "40", "minute", "sessions"])
        XCTAssertEqual(canon("around four twenty minute demos"), ["around", "4", "20", "minute", "demos"])
        XCTAssertEqual(canon("from six thirty"), ["from", "6", "30"])
        XCTAssertEqual(NumberCanon.parseAtom(["nineteen", "ninety", "five"]), "1995")
        XCTAssertNil(NumberCanon.parseAtom(["twelve", "thirty", "five", "six"]))
    }

    func testTheNewFormsKeepTheWellFormednessGuards() {
        // A noun "point" never merges (both sides must be numbers), a mark
        // still breaks a run, and a pair that does not compose stays apart —
        // the same guards the cardinal grammar has always applied.
        XCTAssertEqual(canon("we have one point to make"), ["we", "have", "1", "point", "to", "make"])
        XCTAssertEqual(canon("twenty, twenty six"), ["20", "26"])
        // Greedy longest match: the year wins and the stray scale word
        // stands alone as its own cardinal, never a silent 9500.
        XCTAssertEqual(canon("nineteen ninety five hundred"), ["1995", "100"])
        XCTAssertNil(NumberCanon.parseAtom(["point", "five"]))
        XCTAssertNil(NumberCanon.parseAtom(["one", "point"]))
        XCTAssertNil(NumberCanon.parseAtom(["nineteen", "five"]))       // tail < 10
        XCTAssertNil(NumberCanon.parseAtom(["twelve", "thirty"]))       // century < 13
        XCTAssertTrue(NumberCanon.mayContinue(["one", "point"]))
        XCTAssertFalse(NumberCanon.mayContinue(["point"]))
        XCTAssertFalse(NumberCanon.mayContinue(["the", "point"]))
    }

    func testAndContinuesACardinalOnlyAfterHundredOrScale() {
        // The standard spoken forms: "and" after a hundred / scale word joins
        // the run; anywhere else it is the conjunction and breaks it. The
        // gold-free shipped column depends on this — "a hundred and fifty"
        // → "150" must not read as an invented numeral.
        XCTAssertEqual(canon("a hundred and fifty"), ["a", "150"])
        XCTAssertEqual(canon("two hundred and fifty dollars"), ["250", "dollars"])
        XCTAssertEqual(canon("two thousand and twenty six"), ["2026"])
        XCTAssertEqual(canon("one million and one"), ["1000001"])
        XCTAssertEqual(canon("two thousand and five hundred"), ["2500"])
        XCTAssertEqual(canon("forty two and twenty eight"), ["42", "and", "28"])
        XCTAssertEqual(canon("one and two"), ["1", "and", "2"])
        // A dangling "and" never ends a run: the run stops before it, and a
        // mark on the "and" stops it too.
        XCTAssertEqual(canon("two hundred and the rest"), ["200", "and", "the", "rest"])
        XCTAssertEqual(canon("a hundred and, fifty"), ["a", "100", "and", "50"])
        XCTAssertNil(NumberCanon.parse(["two", "hundred", "and"]))
        XCTAssertNil(NumberCanon.parse(["and", "fifty"]))
        XCTAssertNil(NumberCanon.parse(["fifty", "and", "two"]))
        XCTAssertNil(NumberCanon.parse(["two", "hundred", "and", "thousand"]))
        XCTAssertEqual(NumberCanon.parse(["hundred", "and", "one"]), 101)
        XCTAssertTrue(NumberCanon.mayContinue(["two", "hundred", "and"]))
        XCTAssertTrue(NumberCanon.mayContinue(["one", "thousand", "and"]))
        XCTAssertFalse(NumberCanon.mayContinue(["fifty", "and"]))
        XCTAssertFalse(NumberCanon.mayContinue(["and"]))
        XCTAssertFalse(NumberCanon.mayContinue(["two", "hundred"]))
    }

    func testValuesThatDoNotFitAnIntAreNotCardinals() {
        // The scorer runs on arbitrary text; a value past Int.max is "not a
        // number", never a trap that loses a whole run. The threshold is
        // pinned from both sides: 9223372036 billion fits, 9223372037
        // billion does not (Int.max = 9223372036854775807).
        XCTAssertEqual(NumberCanon.parse(["9223372036", "billion"]), 9_223_372_036_000_000_000)
        XCTAssertNil(NumberCanon.parse(["9223372037", "billion"]))
        XCTAssertNil(NumberCanon.parse(["999999999999", "billion"]))
        XCTAssertNil(NumberCanon.parse(["999999999999", "million", "k"]))
        XCTAssertNil(NumberCanon.parse(["9223372036854775807", "k"]))   // > 12 digits: not a digit group
        XCTAssertEqual(NumberCanon.parse(["999999999999", "k"]), 999_999_999_999_000)
        // End to end: the run stops before the scale word, which then
        // stands alone as its own cardinal (a lone "billion" is 10⁹, as a
        // lone "hundred" is 100); a hyphenated overflow stays a word. The
        // sentence still scores.
        XCTAssertEqual(canon("raised 9223372037 billion lire"), ["raised", "9223372037", "1000000000", "lire"])
        XCTAssertEqual(canon("raised 9223372037-billion lire"), ["raised", "9223372037-billion", "lire"])
        let g = ContentGuard.check(raw: "we raised 9223372037 billion dollars last year", out: "We raised it.")
        XCTAssertEqual(g.gates, [.overEditFact])
    }

    func testDecimalsAndTimesKeepTheirSeparatorAndAreNotCardinals() {
        // Thousands commas drop (a cardinal); a decimal point or a time colon
        // stays, so "2.5" ≠ "25" and "11:30" ≠ "1130" — and neither is a
        // numeral for the INVENTED gate. Anything else in a number-looking
        // chunk takes the plain word-char filter, as before.
        XCTAssertEqual(canon("1,200"), ["1200"])
        XCTAssertEqual(canon("2.5"), ["2.5"])
        XCTAssertEqual(canon("11:30"), ["11:30"])
        XCTAssertEqual(canon("1,234.56"), ["1234.56"])
        XCTAssertEqual(canon("3."), ["3"])          // a boundary period is a mark
        XCTAssertEqual(canon("3.5."), ["3.5"])
        XCTAssertEqual(canon("v1.2"), ["v12"])      // letters inside: the filter
        XCTAssertEqual(canon("2..5"), ["25"])       // not a number shape: the filter
        XCTAssertEqual(ops("2.5", "25"), [.sub(0, 0)])
        XCTAssertFalse(toks("2.5")[0].isNumeral)
        XCTAssertFalse(toks("11:30")[0].isNumeral)
        XCTAssertTrue(toks("1,200")[0].isNumeral)
        XCTAssertEqual(toks("3.5.")[0].marks, ["."])
        // The continuity WER sees the same distinction.
        XCTAssertEqual(TranscriptScore.score(hypothesis: "put a 2.5 on", gold: "put a 25 on").wordErrors, 1)
    }

    func testDottedAbbreviationsAreFlagged() {
        // Mirrors TextFormatter's guard exactly: a listed stem or a dotted
        // initialism of single letters. A number with a point is not one,
        // nor a plain word, nor the ambiguous stems the guard leaves out.
        for chunk in ["e.g.", "i.e.", "U.S.", "p.m.", "a.m.", "Ph.D.", "U.S.A.", "etc.", "Dr.", "J."] {
            XCTAssertTrue(toks(chunk)[0].isAbbreviation, chunk)
        }
        for chunk in ["3.5.", "v1.2", "plan.", "no.", "npm", "fox", "min."] {
            XCTAssertFalse(toks(chunk)[0].isAbbreviation, chunk)
        }
        // The flag rides on the token; the period is still a scored mark
        // and the word core still drops the interior dots.
        XCTAssertEqual(toks("e.g.")[0].marks, ["."])
        XCTAssertEqual(toks("e.g.")[0].normalized, "eg")
        XCTAssertFalse(toks("Fifty four, then")[0].isAbbreviation)
    }

    func testOnlyCardinalsCanonicalize() {
        // Ordinals, times, alphanumerics and a bare "k" are left as words —
        // the typed canonicalizer was rejected; gold + novelty cover those.
        XCTAssertEqual(canon("third 3rd 3pm k fox"), ["third", "3rd", "3pm", "k", "fox"])
        XCTAssertEqual(canon("fifty-four-year-old"), ["fifty-four-year-old"])
        XCTAssertNil(NumberCanon.parse(["k"]))
        XCTAssertNil(NumberCanon.parse(["twenty", "twelve"]))
        XCTAssertNil(NumberCanon.parse(["thousand", "million"]))
        XCTAssertNil(NumberCanon.parse(["two", "thousand", "k"]))
        XCTAssertEqual(NumberCanon.parse(["fifty", "four"]), 54)
        XCTAssertEqual(NumberCanon.parse(["ten", "k"]), 10_000)
        XCTAssertEqual(NumberCanon.parse(["two", "hundred", "thousand"]), 200_000)
        XCTAssertEqual(NumberCanon.parse(["zero"]), 0)
    }

    // MARK: - Span locator

    func testSpanMatchIsContiguousAndFormBlind() {
        let raw = toks("I don't know, try some broad benchmarking on the gravlin tabs and a and sixty two other things.")
        XCTAssertEqual(Align.locate("I don't know", in: raw), 0..<3)
        XCTAssertEqual(Align.locate("i don't know,", in: raw), 0..<3)
        // The spelled run is one canonical token at index 14, so the
        // annotation finds it whichever form it was written in.
        XCTAssertEqual(Align.locate("sixty two other things", in: raw), 14..<17)
        XCTAssertEqual(Align.locate("62 other things", in: raw), 14..<17)
        XCTAssertEqual(Align.locate("sixty-two other things", in: raw), 14..<17)
        XCTAssertNil(Align.locate("deep tabs", in: raw))        // not contiguous
        XCTAssertNil(Align.locate("", in: raw))
        XCTAssertNil(Align.locate("benchmarking", in: raw, occurrence: 0))
        XCTAssertNil(Align.locate("a much longer span than the text", in: toks("short text")))
    }

    func testOccurrenceDisambiguatesRepeats() {
        let t = toks("push it and push it again")
        XCTAssertEqual(Align.locate("push it", in: t), 0..<2)
        XCTAssertEqual(Align.locate("push it", in: t, occurrence: 2), 3..<5)
        XCTAssertNil(Align.locate("push it", in: t, occurrence: 3))
        // Overlapping matches are separate occurrences.
        let stutter = toks("the the the")
        XCTAssertEqual(Align.locate("the the", in: stutter), 0..<2)
        XCTAssertEqual(Align.locate("the the", in: stutter, occurrence: 2), 1..<3)
        XCTAssertNil(Align.locate("the the", in: stutter, occurrence: 3))
    }

    // MARK: - Hyphen rule and vocabulary

    func testHyphenatedTokenWhosePartsAreInRawIsCovered() {
        let vocab = Set(canon("please walk up to the door"))
        XCTAssertTrue(Align.isCovered(toks("walk-up")[0], by: vocab))
        XCTAssertFalse(Align.isCovered(toks("top-notch")[0], by: Set(["top"])))   // "notch" missing
        XCTAssertTrue(Align.isCovered(toks("walk-up")[0], by: Set(["walk-up"])))
        XCTAssertFalse(Align.isCovered(toks("notch")[0], by: Set(["top"])))
        // Numbers are covered through their canonical atom, not their parts.
        XCTAssertTrue(Align.isCovered(toks("fifty-four")[0], by: Set(canon("fifty four"))))
        XCTAssertFalse(Align.isCovered(toks("fifty-four")[0], by: Set(canon("fifty, four"))))
    }

    // MARK: - STOP and NEG sets

    func testStopAndNegationSetsMatchThePlan() {
        XCTAssertEqual(Align.stopWords, ["a", "an", "the", "and", "or", "to", "of", "in", "on", "for",
                                         "is", "are", "it", "that", "this"])
        XCTAssertEqual(Align.negationWords, ["not", "never", "no", "none", "nothing", "nobody", "nowhere", "cannot"])
        for word in ["not", "never", "cannot", "don't", "isn't", "can't", "won't"] {
            XCTAssertTrue(Align.isNegation(word), word)
        }
        // The apostrophe dictation drops: "dont" is the same negation as
        // "don't", so a raw "dont" deleted while the word it governed
        // survives is still a flip the DROP rule has to see.
        for word in Align.unapostrophizedNegations {
            XCTAssertTrue(Align.isNegation(word), word)
        }
        XCTAssertEqual(Align.unapostrophizedNegations.count, 22)
        XCTAssertTrue(Align.unapostrophizedNegations.isSuperset(of: ["dont", "cant", "wont", "didnt",
                                                                    "isnt", "havent", "aint"]))
        // The six the first list forgot — a NEGATED verdict is the third
        // rung of the ladder, so a missing form cost the user the whole
        // cleanup ("we mustnt push straight to main" → "We mustn't…").
        XCTAssertTrue(Align.unapostrophizedNegations.isSuperset(of: ["mustnt", "neednt", "shant",
                                                                    "mightnt", "oughtnt", "darent"]))
        for word in ["know", "knot", "nothingness", "not-so", "want", "meant"] {
            XCTAssertFalse(Align.isNegation(word), word)
        }
    }

    func testApostropheRestorationIsStructuralNotALexicon() {
        // The restoration direction does NOT read the list: an apostrophe
        // inserted before a terminal "t" is the formatting fix, whatever the
        // contraction — so a form nobody thought to list closes too.
        for (raw, out) in [("dont", "don't"), ("mustnt", "mustn't"), ("neednt", "needn't"),
                           ("shant", "shan't"), ("darent", "daren't"), ("oughtnt", "oughtn't")] {
            XCTAssertTrue(Align.isApostropheRestored(raw, as: out), raw)
        }
        // Not a restoration: a different word, a different mark, the reverse
        // direction, or a negation the speaker did not carry at all.
        XCTAssertFalse(Align.isApostropheRestored("do", as: "don't"))
        XCTAssertFalse(Align.isApostropheRestored("cant", as: "couldn't"))
        XCTAssertFalse(Align.isApostropheRestored("don't", as: "dont"))
        XCTAssertFalse(Align.isApostropheRestored("will", as: "won't"))
        // The mark-blind key the novelty vocabulary is widened with.
        XCTAssertEqual(Align.unapostrophized("don't"), "dont")
        XCTAssertEqual(Align.unapostrophized("it's"), "its")
        XCTAssertEqual(Align.unapostrophized("plain"), "plain")
    }

    func testARestoredContractionIsCoveredByItsUnapostrophizedRaw() {
        // The novelty side of the same class: dictation says "dont", the
        // formatter writes "don't", and the vocabulary must read one word —
        // three restorations in an utterance trip the count rule otherwise.
        let vocabulary = Set(canon("i dont think we cant tell whether its ready"))
        XCTAssertTrue(Align.isCovered(toks("don't")[0], by: vocabulary))
        XCTAssertTrue(Align.isCovered(toks("can't")[0], by: vocabulary))
        XCTAssertTrue(Align.isCovered(toks("it's")[0], by: vocabulary))
        // A word he did not say is still novel, apostrophe or not.
        XCTAssertFalse(Align.isCovered(toks("won't")[0], by: vocabulary))
        XCTAssertFalse(Align.isCovered(toks("they're")[0], by: vocabulary))
    }

    // MARK: - TranscriptScore continuity

    /// The continuity line must not move under the refactor: every raw-vs-
    /// gold count on the 17 ORIGINAL seeds is pinned to what the pre-Align
    /// scorer produced (the docs' "raw baseline" row is their
    /// micro-aggregate). The 64 seeds added in step 5 are not part of that
    /// baseline; they are pinned by id so the originals cannot drift
    /// behind them.
    func testSeedBaselineCountsAreUnchanged() {
        // id: (wordErrors, goldWords, punctMatched, punctInHyp, punctInGold, caseMatched, caseComparable)
        let pinned: [String: [Int]] = [
            "correct-time": [2, 4, 0, 0, 1, 3, 4],
            "correct-day": [3, 3, 0, 0, 1, 1, 3],
            "cue-is-content": [0, 5, 0, 0, 1, 5, 5],
            "correct-long-span": [2, 10, 0, 0, 1, 9, 10],
            "correct-number": [3, 5, 0, 0, 1, 4, 5],
            "premise-fillers": [7, 12, 2, 6, 2, 10, 12],
            "bench-standup": [2, 14, 0, 0, 3, 12, 14],
            "bench-quarterly": [0, 26, 0, 0, 2, 24, 26],
            "bench-meeting": [1, 27, 0, 0, 2, 23, 27],
            "bench-code": [0, 28, 0, 0, 2, 26, 28],
            "cap-mid": [0, 7, 1, 1, 2, 5, 7],
            "abbrev-eg": [0, 6, 1, 1, 2, 5, 6],
            "abbrev-us": [0, 8, 2, 2, 3, 6, 8],
            "comma-leading": [0, 5, 0, 1, 2, 4, 5],
            "comma-double": [0, 4, 1, 2, 2, 3, 4],
            "comma-terminal": [0, 3, 1, 2, 1, 2, 3],
            "punct-double": [0, 6, 2, 4, 3, 3, 6],
        ]
        let originals = EvalCase.seeds.prefix(17)
        XCTAssertEqual(Set(originals.map(\.id)), Set(pinned.keys))
        var all: [TranscriptScore] = []
        for c in originals {
            let s = TranscriptScore.score(hypothesis: c.raw, gold: c.gold)
            all.append(s)
            XCTAssertEqual([s.wordErrors, s.goldWordCount, s.punctMatched, s.punctInHypothesis,
                            s.punctInGold, s.caseMatched, s.caseComparable], pinned[c.id], c.id)
        }
        // docs/llm-measurement-gate.md "raw baseline": wer 0.116 | P 0.53 R 0.32 F1 0.400 | case 0.838
        let agg = TranscriptScore.aggregate(all)
        XCTAssertEqual(agg.wer, 0.116, accuracy: 0.0005)
        XCTAssertEqual(agg.punctPrecision, 0.53, accuracy: 0.005)
        XCTAssertEqual(agg.punctRecall, 0.32, accuracy: 0.005)
        XCTAssertEqual(agg.punctF1, 0.400, accuracy: 0.0005)
        XCTAssertEqual(agg.caseAccuracy, 0.838, accuracy: 0.0005)
    }

    func testContinuityWerStaysCanonicalBlind() {
        // An ITN rewrite is still a word edit on the WER axis; forgiving it is
        // the quality scorer's job, not the continuity line's.
        let s = TranscriptScore.score(hypothesis: "and 54 other things.", gold: "and fifty-four other things.")
        XCTAssertEqual(s.wordErrors, 1)
        XCTAssertEqual(s.punctF1, 1)
    }
}
