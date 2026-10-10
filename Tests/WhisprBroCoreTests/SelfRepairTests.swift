import XCTest
@testable import WhisprBroCore

/// `SelfRepair` against the reference implementation's own test cases
/// (`Fixtures/self-repair-fixtures.json`, invented text, written by the
/// reference's test suite): every case, the same three checks the reference
/// runs on them — the expected output; a negative stays negative with every
/// rule on; and each guard is load-bearing (with it off, the case fires).
/// Byte parity on the full eval sets is `whispr-bench repairs --compare`
/// (docs/self-repair.md); this file pins the behaviour in-tree.
final class SelfRepairTests: XCTestCase {

    struct Fixture: Decodable {
        let rules: String
        let input: String
        let expected: String
        let needsNLTagger: Bool
        let guardName: String?

        enum CodingKeys: String, CodingKey {
            case rules, input, expected
            case needsNLTagger = "needs_nltagger"
            case guardName = "guard"
        }
    }

    private struct FixtureFile: Decodable { let cases: [Fixture] }

    static let fixtures: [Fixture] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/self-repair-fixtures.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FixtureFile.self, from: data) else { return [] }
        return file.cases
    }()

    /// A fixture's rule set: "all", one rule's name, or a level of the app
    /// ("fillers": its rules, and no R3a non-words).
    private func stage(_ spec: String, guards: Set<SelfRepair.Guard> = Set(SelfRepair.Guard.allCases)) -> SelfRepair {
        if let level = AppConfig.Cleanup.Level(rawValue: spec) {
            return SelfRepair(rules: SelfRepair.rules(for: level), guards: guards,
                              nonWords: SelfRepair.deletesNonWords(at: level))
        }
        let rules = spec == "all" ? Set(SelfRepair.Rule.allCases) : Set([SelfRepair.Rule(rawValue: spec)].compactMap { $0 })
        return SelfRepair(rules: rules, guards: guards)
    }

    // MARK: - The reference cases

    func testTheFixtureFileIsThere() {
        XCTAssertEqual(Self.fixtures.count, 591)
        XCTAssertEqual(Self.fixtures.filter(\.needsNLTagger).count, 213)
        XCTAssertEqual(Self.fixtures.filter { $0.guardName != nil }.count, 329)
        XCTAssertEqual(Self.fixtures.filter { $0.rules == "fillers" }.count, 20)
    }

    func testEveryReferenceCase() {
        for c in Self.fixtures {
            let got = stage(c.rules).apply(c.input).text
            XCTAssertEqual(got, c.expected, "[\(c.rules)] \(c.input)")
        }
    }

    /// The full rule set agrees with each rule alone on that rule's negatives.
    func testEveryNegativeHoldsWithEveryRuleOn() {
        for c in Self.fixtures where c.expected == c.input && c.rules != "all" && c.rules != "fillers" {
            XCTAssertEqual(SelfRepair().apply(c.input).text, c.input, c.input)
        }
    }

    /// A guarded negative depends on its guard: with the guard off, the rules
    /// fire. So no guard can be deleted without a fixture failing.
    func testEveryGuardIsLoadBearing() {
        let cases = Self.fixtures.filter { $0.guardName != nil && $0.expected == $0.input }
        XCTAssertEqual(cases.count, 229)
        var pinned: Set<SelfRepair.Guard> = []
        for c in cases {
            let names = c.guardName!.split(separator: "+").map(String.init)
            let dropped = Set(names.compactMap(SelfRepair.Guard.init(rawValue:)))
            XCTAssertEqual(dropped.count, names.count, "unknown guard in \(c.guardName!)")
            let off = stage(c.rules, guards: Set(SelfRepair.Guard.allCases).subtracting(dropped))
            XCTAssertNotEqual(off.apply(c.input).text, c.input, "needs-\(c.guardName!): \(c.input)")
            if dropped.count == 1 { pinned.formUnion(dropped) }
        }
        // Every stopping guard is pinned alone by some case — but T5, whose
        // quotations T5b's balance check also holds (so they are pinned
        // together), T14 and T22, which let a fire through, and T26, which
        // narrows one (their cases fire).
        XCTAssertEqual(Set(SelfRepair.Guard.allCases).subtracting(pinned), [.t5, .t14, .t22, .t26])
    }

    /// [T22] lets through a stutter v1 kept: with it off, every one of its
    /// cases is kept whole again ("What is is your name?").
    func testT22LetsItsStuttersThrough() {
        let cases = Self.fixtures.filter { $0.guardName == "T22" }
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            XCTAssertNotEqual(stage(c.rules).apply(c.input).text, c.input, c.input)
            let off = stage(c.rules, guards: Set(SelfRepair.Guard.allCases).subtracting([.t22]))
            XCTAssertEqual(off.apply(c.input).text, c.input, "T22 off: \(c.input)")
        }
    }

    /// [T25] (v9) widens a swap to the compound it corrects: with it off,
    /// each of its firing cases comes out otherwise (v8 kept the old modifier:
    /// "Use the staging prod bucket.").
    func testT25ReplacesTheWholeCompound() {
        let cases = Self.fixtures.filter { $0.guardName == "T25" && $0.expected != $0.input }
        XCTAssertEqual(cases.count, 9)
        let off = Set(SelfRepair.Guard.allCases).subtracting([.t25])
        for c in cases {
            XCTAssertEqual(stage(c.rules).apply(c.input).text, c.expected, c.input)
            XCTAssertNotEqual(stage(c.rules, guards: off).apply(c.input).text, c.expected, "T25 off: \(c.input)")
        }
        XCTAssertEqual(SelfRepair(guards: off).apply("Use the staging bucket, I mean, prod bucket.").text,
                       "Use the staging prod bucket.")
        // a number in the phrase keeps both (a word swap never takes a number), even after "scratch that",
        // where T21 would take the slot (v8: "Book Sam's tables.")
        let stage = SelfRepair()
        XCTAssertEqual(stage.apply("Print the 3 sales reports, I mean, Dana's reports.").text,
                       "Print the 3 sales reports, I mean, Dana's reports.")
        XCTAssertEqual(stage.apply("Book the 2 corner tables, scratch that, Sam's tables.").text,
                       "Book the 2 corner tables, scratch that, Sam's tables.")
    }

    /// [T25] (v12, the valve) A possessive said with the head again keeps
    /// both, at every cue: v10 and v11 replaced the noun phrase, and their
    /// walk to its start took an indirect object, a subject and its verb,
    /// the determiner a capitalised common noun needs, a second modifier
    /// ("Send Dana's reports.", "Use CEO's laptop.", "Send the team updated
    /// Sam's numbers."). A new modifier with a verb after the head said again
    /// is a new clause's subject and keeps both too; an "I mean" that adds,
    /// a finite verb before the head and a double object keep both, as in v11.
    func testT25KeepsAPossessiveBothWays() {
        let stage = SelfRepair()
        for said in ["Use the shared folder, I mean, Sam's folder.", "Use the old laptop, I mean, manager's laptop.",
                     "Use the old laptop, I mean, CEO's laptop.", "Send my manager sales reports, I mean, Dana's reports.",
                     "Tell the kids stories, I mean, Dana's stories.", "Give the interns snacks, I mean, Sam's snacks.",
                     "Send the team updated sales numbers, I mean, Sam's numbers.",
                     "The kids ate cold pizza, I mean, Sam's pizza.", "Bring both old chargers, I mean, Sam's chargers.",
                     "Book the corner table, scratch that, Sam's table.",
                     "Book the corner table, scratch that, Sam's table is free.",
                     "Book the big room, I mean, small room is free.",
                     "The kids ate pizza, I mean, cold pizza.", "The team shipped features, I mean, new features.",
                     "We can use the shared folder, I mean, Sam's folder works too.",
                     "Give the dog treats, I mean, Sam's treats."] {
            XCTAssertEqual(stage.apply(said).text, said, said)
        }
        // ... on every path: T21's slot after "scratch that" (v8 to v11 "Use Sam's folder."), a weak cue's
        // swap (v8 to v11 "Grab the mom's charger."), an s-final name's apostrophe
        for said in ["Use the folder, scratch that, Sam's folder.", "Our vendor sent invoices, scratch that, Dana's invoices.",
                     "Grab the charger, sorry, mom's charger.", "Use the shared folder, I mean, James' folder.",
                     "Review the first draft, I mean, everyone's draft."] {
            XCTAssertEqual(stage.apply(said).text, said, said)
        }
        // ... with a determiner of the possessive's own too (v8 to v11 "Give the manager's plans.": T21's slot
        // took the recipient), also where the slot was right (v8 to v11 "Use the client's room."); a determiner
        // said again before the possessive is still the onset of a restart, as in v8
        for said in ["Give the kids draft plans, scratch that, the manager's plans.",
                     "Use the big room, scratch that, the client's room.",
                     "Use the shared folder, scratch that, our team's folder."] {
            XCTAssertEqual(stage.apply(said).text, said, said)
        }
        XCTAssertEqual(stage.apply("Use the folder, scratch that, the team's folder.").text, "Use the team's folder.")
        // the phrase after a cue a v12 refusal declined stays: no later cue takes it (else the second cue took
        // "Sam's table", and a second pass read the first cue again before "cancel it": "Cancel it.")
        for said in ["Book the corner table, scratch that, Sam's table, scratch that, cancel it.",
                     "We need to call the vendor, scratch that, Sam called the vendor, I mean, supplier."] {
            XCTAssertEqual(stage.apply(said).text, said, said)
        }
        // ... and so do the words v11's fire for that cue could have taken: no repeat is fixed there where
        // v11's swap took its other copy (R1 would take the first "the team"); a repeat v11 fixed still is
        XCTAssertEqual(stage.apply("Take the team the team photos, no wait, team's photos, then call me.").text,
                       "Take the team the team photos, no wait, team's photos, then call me.")
        XCTAssertEqual(stage.apply("We went over over the numbers, I mean, Sam's numbers.").text,
                       "We went over the numbers, I mean, Sam's numbers.")
        // ... as far as the copy, head or word a repair keeps: a fragment right before those words is fixed
        let fragment = "Check the lo logs, then the coach updated main contracts, or rather, team's contracts."
        XCTAssertEqual(stage.apply(fragment).text,
                       "Check the logs, then the coach updated main contracts, or rather, team's contracts.")
        // a new modifier said with the head again still replaces the old one; "please" is no verb there
        XCTAssertEqual(stage.apply("Send the team updated numbers, I mean, final numbers.").text,
                       "Send the team final numbers.")
        XCTAssertEqual(stage.apply("Use the staging bucket, I mean, prod bucket please.").text,
                       "Use the prod bucket please.")
    }

    /// [T24] (v12, the valve) X said again after the cue's word stays a stop
    /// of the noun swap, but is no verb's evidence when the phrase opens with
    /// a name, when the word after its first is inflected, or when its first
    /// word modifies a possessive: after "scratch that" the bare noun phrase
    /// takes T21's slot, as in v8 (v11 "Can you Dana Smith the invoice?",
    /// "Dana Smith's draft.", "Last week's report."), and a clause goes only
    /// where v11 took the whole clause too (v11 "We need to Sam called the
    /// vendor."). The object said again with no determiner keeps both (v8 to
    /// v11 "Email expense print expense receipts.", and after "scratch that"
    /// "Send forward old log files.").
    func testT24ReadsNoNameAsAVerb() {
        let stage = SelfRepair()
        let slot = [
            ("Can you send the invoice, scratch that, Dana Smith the invoice?", "Can you send Dana Smith the invoice?"),
            ("Review the draft, scratch that, Dana Smith's draft.", "Review Dana Smith's draft."),
            ("Send the soup, scratch that, Sam some hot soup.", "Send Sam some hot soup."),
            ("Can you send the invoice, scratch that, Sam the invoice?", "Can you send Sam the invoice?"),
            ("Print the weekly report, scratch that, last week's report.", "Print last week's report."),
            ("Can you print the weekly report, scratch that, last week's report.", "Can you print last week's report."),
            ("Print the weekly report, scratch that, head chef's report.", "Print head chef's report."),
            ("Call the vendor, scratch that, Sam called the vendor.", "Sam called the vendor."),
            ("Book the room, scratch that, Sam books the room.", "Sam books the room."),
            ("Run the build, scratch that, stress test the build.", "Stress test the build."),
            ("Send the report, scratch that, email everyone's report.", "Email everyone's report."),
        ]
        for (said, kept) in slot {
            XCTAssertEqual(stage.apply(said).text, kept, said)
        }
        for said in ["We need to call the vendor, scratch that, Sam called the vendor.",
                     "Can we pay the invoice, scratch that, mom paid the invoice?",
                     "Send the team, scratch that, Client the slides.",
                     "Send the contract, scratch that, team leads the contract.",
                     "Call the vendor, scratch that, mom called the vendor.",
                     "Email expense receipts, I mean, print expense receipts.",
                     "Email expense receipts, scratch that, print expense receipts.",
                     "Book old log files, no wait, cancel old log files tonight.",
                     "Send old log files, scratch that, forward old log files.",
                     "Wash the deck, I mean, power wash the deck."] {
            XCTAssertEqual(stage.apply(said).text, said, said)
        }
        // a new modifier still takes the slot after "scratch that"
        XCTAssertEqual(stage.apply("Email spare keys, scratch that, new spare keys, then call me.").text,
                       "Email new spare keys, then call me.")
        XCTAssertEqual(stage.apply("Fix the sink, I mean, guest bathroom sink.").text, "Fix the guest bathroom sink.")
    }

    /// (v13) The valve: no fire takes a word v11's rules keep. A declined cue
    /// never fires again (v12's second pass, the stutter before it fixed,
    /// took "the kids my old snacks, I mean,"); a fire shorter than v11's
    /// keeps the words v11 took, so no restart is fixed there (v12 "We need
    /// to give Dana the plants."); where `apply` refuses v11's fire (it would
    /// orphan a bracket) the cue takes nothing (v12 "I should check the )
    /// Doctor Kim's lease"); and the shadow run of v11's rules stops what is
    /// left — another copy of a restart v11 fixed, a guard reading a word
    /// v11 had taken.
    func testTheValveKeepsWhatV11Keeps() {
        let stage = SelfRepair()
        let cases = [
            ("Bring the kids my old snacks snacks, I mean, the client's snacks the client's snacks please.",
             "Bring the kids my old snacks, I mean, the client's snacks the client's snacks please."),
            ("Please use my room room, sorry, my boss's room instead, scratch that, cancel it.",
             "Please use my room, sorry, my boss's room instead, scratch that, cancel it."),
            ("We need to give to give the plants, scratch that, Dana the plants.",
             "We need to give to give Dana the plants."),
            ("I should check the ) lease, scratch that, Doctor Kim's lease",
             "I should check the ) lease, scratch that, Doctor Kim's lease"),
            ("Remember to sign shared to sign shared files, no wait, scan shared files!",
             "Remember to sign shared to sign shared files, no wait, scan shared files!"),
            ("I should pay the car, scratch um that, Dana the car car?", "I should pay Dana the car car?"),
            // what v11 takes still goes
            ("Book a window seat, scratch that, an aisle seat.", "Book an aisle seat."),
            ("We need to give the plants, scratch that, Dana the plants.", "We need to give Dana the plants."),
        ]
        for (said, kept) in cases {
            XCTAssertEqual(stage.apply(said).text, kept, said)
        }
    }

    /// [T26] (v9) narrows a "scratch that" retraction to the verb phrase:
    /// with it off, the subject, the auxiliary or the first conjunct goes too.
    func testT26KeepsWhatStandsBeforeTheVerb() {
        let cases = Self.fixtures.filter { $0.guardName == "T26" }
        XCTAssertEqual(cases.count, 15)
        let off = Set(SelfRepair.Guard.allCases).subtracting([.t26])
        for c in cases {
            let on = stage(c.rules).apply(c.input).text, wide = stage(c.rules, guards: off).apply(c.input).text
            XCTAssertEqual(on, c.expected, c.input)
            XCTAssertNotEqual(wide, c.expected, "T26 off: \(c.input)")
            XCTAssertLessThan(wide.split(separator: " ").count, on.split(separator: " ").count, c.input)
        }
        XCTAssertEqual(SelfRepair(guards: off).apply("I'll call him, scratch that, text him tonight.").text,
                       "Text him tonight.")
    }

    /// [T26] (v10) A verb inside a relative clause is not X's own verb
    /// phrase: "scratch that" takes the whole clause back, as before T26 (v9
    /// grafted the correction onto the relative clause: "Email the guy who
    /// can call him."), and a verb before the relative word still narrows it.
    func testT26StopsAtARelativeClause() {
        let stage = SelfRepair()
        let whole = [
            ("Email the guy who can fix it, scratch that, call him.", "Call him."),
            ("Book the room that we can use, scratch that, cancel it.", "Cancel it."),
            ("Book the room where we can meet, scratch that, cancel it.", "Cancel it."),
            ("Email the one that can fix it, scratch that, call them.", "Call them."),
        ]
        let off = SelfRepair(guards: Set(SelfRepair.Guard.allCases).subtracting([.t26]))
        for (said, kept) in whole {
            XCTAssertEqual(stage.apply(said).text, kept, said)
            XCTAssertEqual(off.apply(said).text, kept, "the clause, as with T26 off: \(said)")
        }
        XCTAssertEqual(stage.apply("Please email the guy who can fix it, scratch that, call him.").text,
                       "Please call him.")
        // "that" after a verb, "where" after a pronoun: no relative clause
        XCTAssertEqual(stage.apply("I think that we should email her, scratch that, call her.").text,
                       "I think that we should call her.")
        XCTAssertEqual(stage.apply("Ask them where we can park the car, scratch that, leave it.").text,
                       "Ask them where we can leave it.")
        // (v11) "when" is relative only after an article and a time noun
        XCTAssertEqual(stage.apply("Call the client when you can review it, scratch that, merge it.").text,
                       "Call the client when you can merge it.")
        XCTAssertEqual(stage.apply("Ping me tomorrow when you can review it, scratch that, merge it.").text,
                       "Ping me tomorrow when you can merge it.")
        XCTAssertEqual(stage.apply("Find a time when we can all meet, scratch that, call them.").text, "Call them.")
        // (v11) a relative clause in the subject: the scan resumes at the main clause
        XCTAssertEqual(stage.apply("The client who called will email the contract, scratch that, mail the contract.").text,
                       "The client who called will mail the contract.")
        XCTAssertEqual(stage.apply("The guy who fixed it said to call him, scratch that, email him.").text,
                       "The guy who fixed it said to email him.")
        XCTAssertEqual(stage.apply("The guy who wants to help called us, scratch that, emailed us.").text, "Emailed us.")
    }

    /// [T24] (v10) X said again after the cue's word is that word's object
    /// only across determiners, possessives and one particle: across a
    /// preposition or a coordinator it is a noun's phrase and the swap goes
    /// through (v9 kept both, and after "scratch that" lost the verb: "Link to
    /// the file."); across in / on / off / over, a particle or a preposition,
    /// both are kept.
    func testT24ReadsOnlyAnObjectAsARestatement() {
        let stage = SelfRepair()
        XCTAssertEqual(stage.apply("Send the file, I mean, link to the file.").text, "Send the link to the file.")
        XCTAssertEqual(stage.apply("Order the pizza, scratch that, salad and pizza.").text, "Order the salad and pizza.")
        XCTAssertEqual(stage.apply("Toss the cables, scratch that, pack up the cables.").text, "Pack up the cables.")
        for said in ["Fix the door, I mean, lock on the door.", "Fix the door, scratch that, lock on the door.",
                     "Pack the charger, I mean, plug in the charger."] {
            XCTAssertEqual(stage.apply(said).text, said, said)
        }
        // "her" ending the phrase is the object pronoun; before a noun it is a possessive
        XCTAssertEqual(stage.apply("Call the vendor, scratch that, text her.").text, "Text her.")
        XCTAssertEqual(stage.apply("Ask the manager, scratch that, director her question.").text,
                       "Ask the manager, scratch that, director her question.")
        // (v11) the object's own modifier after its determiner, and a two-word verb's second word,
        // still read X said again as the object (v10 "Wash the power wash the deck.")
        XCTAssertEqual(stage.apply("Wash the deck, I mean, power wash the deck.").text,
                       "Wash the deck, I mean, power wash the deck.")
        XCTAssertEqual(stage.apply("Run the build, scratch that, stress test the build.").text, "Stress test the build.")
        XCTAssertEqual(stage.apply("Delete the old files, scratch that, archive the old files.").text, "Archive the old files.")
        XCTAssertEqual(stage.apply("Fix the sink, I mean, guest bathroom sink.").text, "Fix the guest bathroom sink.")
        // (v11) in / on / off / over running on after "scratch that": the run's clause is no clause of the
        // phrase (v10 "Pressure in the tires before we leave?"); a verb right after makes it a subject
        let runOn = "Can you check the tires, scratch that, pressure in the tires before we leave?"
        XCTAssertEqual(stage.apply(runOn).text, runOn)
        XCTAssertEqual(stage.apply("I'll fix the door, scratch that, lock on the door is broken.").text,
                       "Lock on the door is broken.")
    }

    // MARK: - Dictionary terms, the language gate

    func testADictionaryTermIsNeverAFragment() {
        let text = "run the zq tool now"
        XCTAssertEqual(SelfRepair(rules: [.r3], naturalLanguage: false).apply(text).text, "run the tool now",
                       "unprotected, a two-letter non-word between words is a fragment")
        XCTAssertEqual(SelfRepair(rules: [.r3], protecting: ["zq"], naturalLanguage: false).apply(text).text, text)
        // The terms come in as DictionaryEngine.lowercasedTargets; matching is
        // on the token's lower-cased core, so punctuation around it is fine.
        XCTAssertEqual(SelfRepair(rules: [.r3], protecting: ["ZQ"], naturalLanguage: false)
            .apply("run the zq, tool now").text, "run the zq, tool now")
    }

    func testADictionaryTermIsNeverRecasedAtASentenceStart() {
        // A deleted run that opened the sentence passes its capital on…
        XCTAssertEqual(SelfRepair(naturalLanguage: false).apply("The, the cache install fails").text,
                       "The cache install fails")
        let text = "Monday, no wait, tuesday works"
        XCTAssertEqual(SelfRepair(naturalLanguage: false).apply(text).text, "Tuesday works")
        // …but never onto a dictionary term: its casing is the dictionary's.
        XCTAssertEqual(SelfRepair(protecting: ["tuesday"], naturalLanguage: false).apply(text).text, "tuesday works")
    }

    func testTheLanguageGateLeavesAnotherLanguageAlone() {
        // A doubled content word R1 takes in English…
        let italian = "Il burro burro e la farina sono sul tavolo della cucina."
        XCTAssertEqual(SelfRepair(naturalLanguage: false).apply(italian).text,
                       "Il burro e la farina sono sul tavolo della cucina.")
        // …is left alone once the recognizer is sure the text is Italian.
        let result = SelfRepair().apply(italian)
        XCTAssertEqual(result.text, italian)
        XCTAssertEqual(result.fires, [])
        // The reference's own gate case.
        let reference = "Il burro e la farina sono sul tavolo della cucina."
        XCTAssertEqual(SelfRepair().apply(reference).text, reference)
        // Under 4 tokens the gate never closes (too little to be sure).
        XCTAssertFalse(SelfRepairLanguage.gateCloses("burro burro grazie", tokenCount: 3))
    }

    func testNoDictationLanguageButEnglishRunsTheStage() {
        for language in DictationLanguage.allCases {
            let stage = SelfRepair.forDictation(level: .standard, verbatimRegister: false,
                                                language: language, protecting: [])
            XCTAssertEqual(stage != nil, language == .english, "\(language)")
        }
    }

    // MARK: - Levels

    func testRulesByLevel() {
        XCTAssertEqual(SelfRepair.rules(for: .verbatim), [])
        XCTAssertEqual(SelfRepair.rules(for: .fillers), [.r1, .r1b, .r3])
        XCTAssertEqual(SelfRepair.rules(for: .standard), Set(SelfRepair.Rule.allCases))
        XCTAssertTrue(SelfRepair.repetitionRules.isDisjoint(with: SelfRepair.correctionRules))
        XCTAssertEqual(SelfRepair.repetitionRules.union(SelfRepair.correctionRules), Set(SelfRepair.Rule.allCases))
        XCTAssertFalse(SelfRepair.deletesNonWords(at: .fillers))
        XCTAssertTrue(SelfRepair.deletesNonWords(at: .standard))
        XCTAssertNil(SelfRepair.forDictation(level: .verbatim, verbatimRegister: false, language: .english, protecting: []))
        XCTAssertNil(SelfRepair.forDictation(level: .standard, verbatimRegister: true, language: .english, protecting: []))
        let fillers = SelfRepair.forDictation(level: .fillers, verbatimRegister: false, language: .english,
                                              protecting: ["zq"])
        XCTAssertEqual(fillers?.rules, [.r1, .r1b, .r3])
        XCTAssertEqual(fillers?.nonWords, false)
        XCTAssertEqual(SelfRepair.forDictation(level: .standard, verbatimRegister: false, language: .english,
                                               protecting: [])?.nonWords, true)
    }

    func testFillersLevelTakesRepeatsButNotCorrections() {
        let text = "the dog dog park opens Thursday, no wait, Friday"
        XCTAssertEqual(SelfRepair(rules: SelfRepair.rules(for: .fillers)).apply(text).text,
                       "the dog park opens Thursday, no wait, Friday")
        XCTAssertEqual(SelfRepair(rules: SelfRepair.rules(for: .standard)).apply(text).text,
                       "the dog park opens Friday")
    }

    func testFillersLevelKeepsAShortWordOnItsOwn() {
        // R3a takes a lone 1–2 letter non-word — at Standard. At the default
        // level it could be a lower-case abbreviation, so it stays; a cut-off
        // word the next word completes still goes.
        func at(_ level: AppConfig.Cleanup.Level, _ text: String) -> String {
            SelfRepair.forDictation(level: level, verbatimRegister: false, language: .english,
                                    protecting: [])!.apply(text).text
        }
        XCTAssertEqual(at(.standard, "the desk and the b chair are new"), "the desk and the chair are new")
        XCTAssertEqual(at(.fillers, "the desk and the b chair are new"), "the desk and the b chair are new")
        XCTAssertEqual(at(.fillers, "the pt said to rest the knee"), "the pt said to rest the knee")
        XCTAssertEqual(at(.fillers, "check the lo logs from last night"), "check the logs from last night")
    }

    func testRepetitionsStayWhenStutterCollapseIsOff() {
        // `[cleanup] collapse_stutters = false`: he asked for repetitions to
        // be kept, so R1 does not run — the other rules do.
        for level in [AppConfig.Cleanup.Level.fillers, .standard] {
            let off = SelfRepair.forDictation(level: level, verbatimRegister: false, language: .english,
                                              protecting: [], collapseStutters: false)
            XCTAssertEqual(off?.rules, SelfRepair.rules(for: level).subtracting([.r1]))
            XCTAssertEqual(off?.apply("we went over over these numbers").text, "we went over over these numbers")
            XCTAssertEqual(off?.apply("check the lo logs").text, "check the logs")
        }
    }

    // MARK: - [T16] Spoken layout, [T17] mentions

    func testASpokenLayoutMarkerIsABoundary() {
        // Two equal list items are two items, not a repeat; the rules never
        // touch a marker and never read across one…
        for text in ["survey answers bullet point yes bullet point yes bullet point no",
                     "roll call new line here new line here new line away",
                     "status next bullet done next bullet done next bullet pending",
                     "groceries new um line milk new um line milk",
                     "Bullet point, socks. Bullet point, socks. Bullet point, charger.",
                     "buy milk new line new line buy eggs"] {
            let result = SelfRepair().apply(text)
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.fires, [])
        }
        // …which with T16 off they did: one "yes" went, and the tally with it.
        XCTAssertEqual(SelfRepair(guards: Set(SelfRepair.Guard.allCases).subtracting([.t16]))
            .apply("survey answers bullet point yes bullet point yes bullet point no").text,
                       "survey answers bullet point yes bullet point no")
        // Inside an item the rules work as before.
        XCTAssertEqual(SelfRepair().apply("todo bullet point book book the vet bullet point buy milk").text,
                       "todo bullet point book the vet bullet point buy milk")
        // A retraction never takes a marker with it: across one, both stay;
        // after one, the retracted line goes and the next line starts upper-case.
        XCTAssertEqual(SelfRepair().apply("Buy milk. Scratch that, new line buy eggs and bread.").text,
                       "Buy milk. Scratch that, new line buy eggs and bread.")
        XCTAssertEqual(SelfRepair().apply("bullet point We ship Friday. Scratch that, we ship Monday.").text,
                       "bullet point We ship Monday.")
    }

    func testTheMarkersAreSpokenStructures() {
        // The phrases, in SpokenStructure's own order, so the rules find
        // exactly what it will lift out.
        XCTAssertEqual(SelfRepairLexicon.spokenPhrases.map(\.words),
                       SpokenStructure.phrases.map { $0.words.map { ScalarString(stringLiteral: $0) } })
        XCTAssertEqual(SelfRepairLexicon.spokenPhrases.filter { $0.kind == .lineBreak }.count, 4)
        XCTAssertEqual(SelfRepairLexicon.spokenPhrases.filter { $0.kind == .bullet }.count, 3)
        XCTAssertEqual(SelfRepairLexicon.spokenPhrases.filter { $0.kind == .quoteOpen }.count, 2)
        XCTAssertEqual(SelfRepairLexicon.spokenPhrases.filter { $0.kind == .quoteClose }.count, 3)
        let toks = SelfRepair.tokenize(Array("ok New, um, line. and I quote next BULLET point unquote".unicodeScalars),
                                       guards: Set(SelfRepair.Guard.allCases))
        let marks: [String] = toks.map {
            switch $0.marker {
            case nil: return "-"
            case .lineBreak: return "L"
            case .bullet: return "B"
            case .quoteOpen: return "O"
            case .quoteClose: return "C"
            }
        }
        XCTAssertEqual(marks, ["-", "L", "L", "L", "O", "O", "O", "B", "B", "B", "C"])
    }

    func testDescribingARepairIsNotMakingOne() {
        // Words he reports, quotes, exemplifies, specifies or labels: kept.
        for text in ["Write a fixture where the input is meet on Tuesday, no wait, Wednesday and nothing else.",
                     "When I said it costs 30, sorry, 40 dollars the app kept only 40.",
                     "The rule should turn we need need it into we need it.",
                     "Write a test where fix the ty typo becomes fix the typo.",
                     "If you dictate red, I mean blue, it should keep blue.",
                     "I just said the the cache cache is stale and it dropped a word.",
                     "The bug report says it costs 30, sorry, 40 dollars now.",
                     "In the screenshot the text reads thirty, sorry, forty dollars.",
                     "The phrase send it Friday, no wait, Saturday should become send it Saturday.",
                     "Given meet at 2, actually 3, the rules return meet at 3.",
                     "Expected: meet at 2, actually 3.",
                     "Make sure the app keeps call at 3, sorry, 4 verbatim.",
                     "Use leave at 4, sorry, 5 as the probe.",
                     "She told us and I quote 3, sorry, 4 tickets end quote."] {
            XCTAssertEqual(SelfRepair().apply(text).text, text)
        }
        // Not a mention: "as I said", a hedge, an instrument's reading, a comma
        // after the verb, a thing the verb takes, a prediction.
        XCTAssertEqual(SelfRepair().apply("As I said we ship Monday, no wait, Tuesday.").text,
                       "As I said we ship Tuesday.")
        XCTAssertEqual(SelfRepair().apply("I'd say Monday, sorry, Tuesday works best.").text,
                       "I'd say Tuesday works best.")
        XCTAssertEqual(SelfRepair().apply("My watch says the pace pace dropped again.").text,
                       "My watch says the pace dropped again.")
        XCTAssertEqual(SelfRepair().apply("I said, the cache cache is stale").text, "I said, the cache is stale")
        XCTAssertEqual(SelfRepair().apply("I wrote the report on Monday, sorry, Tuesday.").text,
                       "I wrote the report on Tuesday.")
        XCTAssertEqual(SelfRepair().apply("I expect we'll land at 6, sorry, 7.").text, "I expect we'll land at 7.")
        // A mention reaches to the end of its clause, twelve words at most.
        XCTAssertEqual(SelfRepair().apply("When I said Friday, we moved it. The the cache cache is stale.").text,
                       "When I said Friday, we moved it. The the cache is stale.")
    }

    // MARK: - [T3] [T18] [T19] Doubles that are content

    func testDoublesThatAreContentAreKept() {
        for level in [AppConfig.Cleanup.Level.fillers, .standard] {
            let stage = SelfRepair.forDictation(level: level, verbatimRegister: false, language: .english,
                                                protecting: [])!
            // T3: the fixed and emphatic doubles of other languages, and any
            // double of a word English does not spell.
            for text in ["Ti mando tanti tanti baci, see you soon.", "Baci baci", "Forza forza!",
                         "Quasi quasi I'll stay another week.", "Book the lomi lomi massage for Sunday.",
                         "Tchau tchau, see you Monday.", "The dog went woof woof all night.",
                         "My aunt answered già già and hung up.",
                         // T3 (v7): everyday words of other languages that
                         // English does not use, doubled for emphasis
                         "The pasta was buona buona tonight, grazie mille.", "It was caldo caldo at the beach.",
                         "We walked lento lento along the river.", "The puppy is lindo lindo in that photo.",
                         // T18: a double that stands alone; T19: grammar
                         "Sorry sorry, I meant the other file.", "See you at eight, hugs hugs.",
                         "Can you swing by by noon tomorrow?", "Think it over over the weekend and call me Monday.",
                         "What the options are are listed below.",
                         // v1 already kept these
                         "By then she had had enough of the noise.", "He said that that was fine.",
                         "What it is is a timing bug.", "Please log in in the morning."] {
                let result = stage.apply(text)
                XCTAssertEqual(result.text, text, "\(level)")
                XCTAssertEqual(result.fires, [], "\(level): \(text)")
            }
            // The same shapes as a stutter still go: an everyday English word,
            // a double between two commas, a particle before what its verb
            // takes, an amount, a filler between the copies.
            for (text, fixed) in [("Check the wiki wiki page for the address.", "Check the wiki page for the address."),
                                  ("We need eggs, milk milk, and bread.", "We need eggs, milk, and bread."),
                                  ("We went over over these numbers yesterday.", "We went over these numbers yesterday."),
                                  ("Can you swing by by the office later?", "Can you swing by the office later?"),
                                  ("Sales could drop by by 5 percent.", "Sales could drop by 5 percent."),
                                  ("I looked over over 40 resumes today.", "I looked over 40 resumes today."),
                                  ("Prices drop by by 5 each year.", "Prices drop by 5 each year."),
                                  ("Cool, um, cool, see you then.", "Cool, see you then."),
                                  // v7: an English look-alike stays off T3's list
                                  ("We ordered pizza pizza for the whole team.", "We ordered pizza for the whole team."),
                                  // v7: a list item is no interjection
                                  ("groceries bullet point eggs eggs bullet point milk",
                                   "groceries bullet point eggs bullet point milk"),
                                  ("to do new line invoices invoices new line pay rent",
                                   "to do new line invoices new line pay rent"),
                                  ("shopping list bullet point milk bullet point eggs eggs",
                                   "shopping list bullet point milk bullet point eggs")] {
                XCTAssertEqual(stage.apply(text).text, fixed, "\(level)")
            }
        }
        // Each is a guard's: with it off, the double goes.
        let off = Set(SelfRepair.Guard.allCases).subtracting([.t3, .t18, .t19])
        XCTAssertEqual(SelfRepair(guards: off).apply("Book the lomi lomi massage for Sunday.").text,
                       "Book the lomi massage for Sunday.")
        XCTAssertEqual(SelfRepair(guards: off).apply("Cool cool, see you then.").text, "Cool, see you then.")
        XCTAssertEqual(SelfRepair(guards: off).apply("Can you swing by by noon tomorrow?").text,
                       "Can you swing by noon tomorrow?")
    }

    // MARK: - Contract details

    func testFiresSayWhatWasDeleted() {
        let result = SelfRepair().apply("ship it Thursday, no wait, Friday after lunch")
        XCTAssertEqual(result.text, "ship it Friday after lunch")
        XCTAssertEqual(result.fires, [SelfRepair.Fire(rule: .r4, deleted: [2, 3, 4], cue: 3..<5, note: "cue no wait")])
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(SelfRepair().apply("").text, "")
        XCTAssertEqual(SelfRepair().apply(" \n\t ").text, "")
        XCTAssertEqual(SelfRepair().repair(""), "")
    }

    func testApplyNormalizesWhitespaceRepairKeepsIt() {
        // apply: the reference's form, one space between kept tokens.
        XCTAssertEqual(SelfRepair().apply("we  went over over\tthese").text, "we went over these")
        // repair: what the pipeline gets — his own whitespace, and the text
        // exactly as it came when nothing fired.
        XCTAssertEqual(SelfRepair().repair("we  went\tthere"), "we  went\tthere")
        XCTAssertEqual(SelfRepair().apply("Best,\nSam dog dog park").text, "Best, Sam dog park")
        XCTAssertEqual(SelfRepair().repair("Best,\nSam dog dog park"), "Best,\nSam dog park")
        // a line break beside a deleted run survives it
        XCTAssertEqual(SelfRepair().repair("check the lo\nlogs now"), "check the\nlogs now")
        XCTAssertEqual(SelfRepair().repair("we went over\nover these"), "we went\nover these")
    }

    func testQuotedTextIsNeverTouched() {
        for text in ["he typed \"the the dog dog\" twice", "she wrote \u{201C}fix fix\u{201D} on it",
                     "Name the branch 'fix fix' for now.", "(the the cat sat there)"] {
            XCTAssertEqual(SelfRepair().apply(text).text, text)
        }
    }

    // MARK: - The word lists are the reference's

    func testWordListsMatchTheReference() {
        // Sizes of the reference's lists (rules.py v13): a changed list must
        // be a deliberate change to both.
        let sizes: [(Set<ScalarString>, Int)] = [
            (SelfRepairLexicon.numWords, 33), (SelfRepairLexicon.ordinals, 29), (SelfRepairLexicon.units, 48),
            (SelfRepairLexicon.weekdays, 14), (SelfRepairLexicon.months, 11), (SelfRepairLexicon.daytime, 11),
            (SelfRepairLexicon.prepositions, 50), (SelfRepairLexicon.auxiliaries, 46),
            (SelfRepairLexicon.pronouns, 60), (SelfRepairLexicon.determiners, 22), (SelfRepairLexicon.function, 222),
            (SelfRepairLexicon.legitDoubles, 111), (SelfRepairLexicon.legitDoublesV2, 138),
            (SelfRepairLexicon.symbolWords, 29),
            (SelfRepairLexicon.questionAuxiliaries, 24), (SelfRepairLexicon.unitAbbreviations, 27),
            (SelfRepairLexicon.elisions, 16), (SelfRepairLexicon.commaOK, 18), (SelfRepairLexicon.softInterregnumOK, 15),
            (SelfRepairLexicon.pluralTriggers, 28), (SelfRepairLexicon.r2InitialB, 22), (SelfRepairLexicon.shortWords, 138),
            (SelfRepairLexicon.r3bKeep, 30), (SelfRepairLexicon.letterNouns, 46), (SelfRepairLexicon.letterBefore, 12),
            (SelfRepairLexicon.prefixSplits, 15), (SelfRepairLexicon.r3SkipLetters, 12), (SelfRepairLexicon.common3, 307),
            (SelfRepairLexicon.ingStop, 19), (SelfRepairLexicon.cueWords, 11), (SelfRepairLexicon.slotOpeners, 86),
            (SelfRepairLexicon.r2BInner, 64), (SelfRepairLexicon.r2BLast, 9),
            // T17 (rules.py v4, MENTIONS)
            (SelfRepairLexicon.reportVerbs, 49), (SelfRepairLexicon.expectVerbs, 11), (SelfRepairLexicon.valueVerbs, 36),
            (SelfRepairLexicon.baseVerbs, 15), (SelfRepairLexicon.predictVerbs, 4), (SelfRepairLexicon.clauseOpeners, 29),
            (SelfRepairLexicon.particles, 1), (SelfRepairLexicon.whObject, 12), (SelfRepairLexicon.wordsVerbs, 8),
            (SelfRepairLexicon.sayRead, 16), (SelfRepairLexicon.subjectPronouns, 36), (SelfRepairLexicon.hedges, 15),
            (SelfRepairLexicon.reportModals, 9), (SelfRepairLexicon.reportAdverbs, 20), (SelfRepairLexicon.reportChain, 17),
            (SelfRepairLexicon.notSubject, 5), (SelfRepairLexicon.npOpeners, 19), (SelfRepairLexicon.instruments, 34),
            (SelfRepairLexicon.objectPronouns, 7), (SelfRepairLexicon.frameNouns, 40), (SelfRepairLexicon.repairNouns, 18),
            (SelfRepairLexicon.expectedNouns, 48), (SelfRepairLexicon.apposNouns, 16), (SelfRepairLexicon.copulaNouns, 32),
            (SelfRepairLexicon.specimenNouns, 4), (SelfRepairLexicon.frameLinkers, 4), (SelfRepairLexicon.ofNouns, 6),
            (SelfRepairLexicon.copulas, 10), (SelfRepairLexicon.beLinks, 3), (SelfRepairLexicon.containVerbs, 9),
            (SelfRepairLexicon.degree, 8), (SelfRepairLexicon.beModals, 7), (SelfRepairLexicon.naming, 5),
            (SelfRepairLexicon.clausey, 89), (SelfRepairLexicon.npStart, 36), (SelfRepairLexicon.temporal, 36),
            (SelfRepairLexicon.colonLabels, 10), (SelfRepairLexicon.colonReport, 79), (SelfRepairLexicon.frameAux, 17),
            (SelfRepairLexicon.editVerbs, 27), (SelfRepairLexicon.editLinks, 3), (SelfRepairLexicon.specLinks, 4),
            (SelfRepairLexicon.placeVerbs, 27), (SelfRepairLexicon.specNouns, 22),
            // T19 (rules.py v5)
            (SelfRepairLexicon.whCopulas, 3), (SelfRepairLexicon.timeNouns, 34), (SelfRepairLexicon.timeModifiers, 11),
            (SelfRepairLexicon.timeDeterminers, 2), (SelfRepairLexicon.timeOf, 4),
            (SelfRepairLexicon.clockParticles, 2), (SelfRepairLexicon.hours, 24), (SelfRepairLexicon.clockWords, 4),
            (SelfRepairLexicon.amountFunction, 8),
            // T20, T21 (rules.py v6)
            (SelfRepairLexicon.r3aKeep, 60), (SelfRepairLexicon.subjectWords, 7),
            (SelfRepairLexicon.npDeterminers, 36), (SelfRepairLexicon.predeterminers, 3),
            // T3, T23 (rules.py v7)
            (SelfRepairLexicon.foreignWords, 653), (SelfRepairLexicon.legitDoublesV2English, 21),
            // T24 (rules.py v8)
            (SelfRepairLexicon.verbPhraseObjects, 18), (SelfRepairLexicon.timeOpeners, 7),
            (SelfRepairLexicon.timeWords, 71), (SelfRepairLexicon.nounPhraseHeadOpeners, 85),
            // T24, T26 (rules.py v9)
            (SelfRepairLexicon.objectPronounsStrict, 5), (SelfRepairLexicon.verbPhraseLeadIns, 58),
            // T24, T26 (rules.py v10)
            (SelfRepairLexicon.herAfter, 8), (SelfRepairLexicon.restateParticles, 5),
            (SelfRepairLexicon.ambiguousParticles, 4), (SelfRepairLexicon.relativeWords, 4),
            (SelfRepairLexicon.nounRelativeWords, 3),
            // T25, T26 (rules.py v11)
            (SelfRepairLexicon.relativeTimeHeads, 20), (SelfRepairLexicon.possessorsWithoutDeterminer, 22),
            (SelfRepairLexicon.additionLast, 2),
            // T24 (rules.py v12)
            (SelfRepairLexicon.irregularPast, 56),
            // the shadow run of v11's rules (rules.py v13: v11's own lists)
            (SelfRepairLexicon.possessiveReplaces, 20), (SelfRepairLexicon.twoObjectVerbs, 116),
        ]
        for (n, (list, size)) in sizes.enumerated() {
            XCTAssertEqual(list.count, size, "list #\(n)")
        }
        XCTAssertEqual(SelfRepairLexicon.exemplifiers.count, 8)
        XCTAssertEqual(SelfRepairLexicon.verbatim.count, 12)
        XCTAssertEqual(SelfRepairLexicon.postfixFrames.count, 10)
        XCTAssertEqual(SelfRepairLexicon.rewriteLinks.count, 57)
        XCTAssertEqual(SelfRepairLexicon.mentionReach, 12)
        XCTAssertEqual(SelfRepairLexicon.mentionReachBack, 12)
        XCTAssertEqual(SelfRepairLexicon.particleVerbs.mapValues(\.count), ["by": 25, "over": 91, "around": 20, "down": 13])
    }

    func testListsSharedWithOtherStagesAreTheirs() {
        XCTAssertEqual(SelfRepairLexicon.coreFillers, Set(FillerStripper.coreFillers.map { ScalarString(stringLiteral: $0) }))
        XCTAssertEqual(SelfRepairLexicon.fillerStripperCollapsible,
                       Set(["i", "a", "an", "the", "we", "you", "he", "she", "they", "it", "and", "to"].map {
                           ScalarString(stringLiteral: $0) }))
        // SpokenStructure's phrases are the T4 markers — every one the
        // reference lists, and the rest of SpokenStructure's.
        let reference: [[ScalarString]] = [["new", "line"], ["new", "paragraph"], ["next", "line"], ["line", "break"],
                                           ["bullet", "point"], ["next", "bullet"], ["next", "bullet", "point"],
                                           ["open", "quote"], ["close", "quote"], ["end", "quote"], ["unquote"]]
        XCTAssertTrue(Set(reference).isSubset(of: SelfRepairLexicon.spokenMarkers))
        XCTAssertEqual(SelfRepairLexicon.spokenMarkers.count, SpokenStructure.phrases.count)
    }

    // MARK: - Python string semantics the port depends on

    func testCodePointComparison() {
        // Swift's String equality is canonical equivalence; the rules compare
        // code points, as the reference does.
        XCTAssertEqual("caf\u{E9}", "cafe\u{301}")
        XCTAssertNotEqual(ScalarString(stringLiteral: "caf\u{E9}"), ScalarString(stringLiteral: "cafe\u{301}"))
    }

    func testCharacterClasses() {
        XCTAssertTrue(PyText.isSpace("\u{1C}"), "str.isspace takes the file separator; Character.isWhitespace does not")
        XCTAssertFalse(Character("\u{1C}").isWhitespace)
        XCTAssertTrue(PyText.isSpace("\u{A0}"))
        XCTAssertFalse(PyText.isSpace("\u{200B}"))
        XCTAssertTrue(PyText.isAlnum("\u{BD}"), "½ is numeric")
        XCTAssertFalse(PyText.isAlpha("\u{301}"), "a combining mark is not a letter")
        XCTAssertTrue(PyText.isDecimal("\u{663}"), "Arabic-Indic three is \\d")
        XCTAssertFalse(PyText.isDecimal("\u{B2}"), "superscript two is a digit, not \\d")
        XCTAssertTrue(PyText.isDigit("\u{B2}"))
        XCTAssertTrue(PyText.isUpper(Array("AT&T".unicodeScalars)))
        XCTAssertFalse(PyText.isUpper(Array("Ab".unicodeScalars)))
        XCTAssertFalse(PyText.isUpper(Array("&".unicodeScalars)))
        XCTAssertTrue(PyText.isLower(Array("e.g".unicodeScalars)))
    }

    func testCaseMapping() {
        func lower(_ s: String) -> String { String(String.UnicodeScalarView(PyText.lower(Array(s.unicodeScalars)))) }
        func upper(_ s: String) -> String { String(String.UnicodeScalarView(PyText.upper(Array(s.unicodeScalars)))) }
        XCTAssertEqual(lower("ΟΔΥΣΣΕΥΣ"), "οδυσσευς", "a word-final capital sigma becomes ς")
        XCTAssertEqual(lower("Σ"), "σ")
        XCTAssertEqual(Array(lower("İ").unicodeScalars), ["i", "\u{307}"])
        XCTAssertEqual(upper("straße"), "STRASSE")
    }

    func testNumbers() {
        for word in ["3", "7:30", "$1,200", "10k", "14th", "5pm", "forty-two", "twenty", "second", "\u{663}", "50%"] {
            XCTAssertTrue(SelfRepair.isNumber(ScalarString(PyText.lower(Array(word.unicodeScalars)))), word)
        }
        // "forty-" is a number word with an empty part, as in the reference.
        XCTAssertTrue(SelfRepair.isNumber("forty-"))
        for word in ["", "k", "-", "five-ish", "3d", "v2", "$"] {
            XCTAssertFalse(SelfRepair.isNumber(ScalarString(stringLiteral: word)), word)
        }
    }
}
