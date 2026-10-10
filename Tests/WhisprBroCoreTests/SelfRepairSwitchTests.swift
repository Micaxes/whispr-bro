import XCTest
@testable import WhisprBroCore

/// "Fix self-corrections" — `[cleanup] self_repair`, the switch that turns
/// the self-repair rules off on their own: the key, the in-place edit
/// Settings writes, and the promise that off is the app before the rules,
/// byte for byte — against outputs recorded from that build
/// (`Fixtures/self-repair-off-base.json`), at every level and register.
final class SelfRepairSwitchTests: XCTestCase {

    // MARK: - The key

    func testOnByDefault() {
        XCTAssertTrue(AppConfig.Cleanup().selfRepair)
        XCTAssertTrue(ConfigStore.parse("").cleanup.selfRepair)
        XCTAssertTrue(ConfigStore.parse("[cleanup]\ncollapse_stutters = false").cleanup.selfRepair)
    }

    func testTheKeyParses() {
        XCTAssertFalse(ConfigStore.parse("[cleanup]\nself_repair = false").cleanup.selfRepair)
        XCTAssertFalse(ConfigStore.parse("[cleanup]\nself_repair = FALSE   # mine").cleanup.selfRepair)
        XCTAssertFalse(ConfigStore.parse("[cleanup]\n\"self_repair\" = false").cleanup.selfRepair)
        XCTAssertTrue(ConfigStore.parse("[cleanup]\nself_repair = true").cleanup.selfRepair)
        // Not a bool: ignored, the default stands (a hand-edit never bricks startup).
        XCTAssertTrue(ConfigStore.parse("[cleanup]\nself_repair = \"no\"").cleanup.selfRepair)
        // Only under [cleanup].
        XCTAssertTrue(ConfigStore.parse("self_repair = false\n[style]\nself_repair = \"x\"").cleanup.selfRepair)
    }

    func testTheGeneratedFileCarriesIt() {
        var config = AppConfig()
        XCTAssertTrue(ConfigStore.emit(config).contains("\nself_repair = true "))
        config.cleanup.selfRepair = false
        let text = ConfigStore.emit(config)
        XCTAssertTrue(text.contains("\nself_repair = false "))
        XCTAssertEqual(ConfigStore.parse(text), config)
    }

    // MARK: - The edit Settings makes

    private func set(_ value: Bool, in text: String, key: String = "self_repair") -> String? {
        ConfigStore.settingCleanupSwitch(key, to: value, in: text)
    }

    func testTheGeneratedFileChangesByOneLine() throws {
        let original = ConfigStore.emit(AppConfig())
        let off = try XCTUnwrap(set(false, in: original))
        let changed = zip(original.components(separatedBy: "\n"), off.components(separatedBy: "\n"))
            .filter { $0 != $1 }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.1.hasPrefix("self_repair = false   # fix self-corrections"), true)
        XCTAssertEqual(off.count, original.count + 1, "\"true\" → \"false\", nothing else")
        XCTAssertFalse(ConfigStore.parse(off).cleanup.selfRepair)
        XCTAssertEqual(set(true, in: off), original, "and back, byte for byte")
        XCTAssertEqual(set(true, in: original), original, "already on: nothing to change")
    }

    func testHisCommentsAndLayoutSurvive() throws {
        let mine = """
        # my config — do not regenerate
        [[dictionary]]
        from = "self repair"   # a spoken phrase, not the key
        to = "self_repair = true"

        [cleanup]  # the knobs
          self_repair   =   true    # rules on, for now
        collapse_stutters = false
        verbatim_categories = ["ide", "terminal"]

        [style]
        mail = "formal"
        """
        let off = try XCTUnwrap(set(false, in: mine))
        XCTAssertEqual(off, mine.replacingOccurrences(of: "  self_repair   =   true    # rules on",
                                                      with: "  self_repair   =   false    # rules on"))
        let config = ConfigStore.parse(off)
        XCTAssertFalse(config.cleanup.selfRepair)
        XCTAssertFalse(config.cleanup.collapseStutters)
        XCTAssertEqual(config.dictionary.first?.to, "self_repair = true", "a value that spells the key is a value")
        XCTAssertEqual(config.style["mail"], "formal")
    }

    func testWindowsLineEndingsStay() throws {
        let crlf = "[cleanup]\r\nself_repair = true\r\ncollapse_stutters = true\r\n"
        XCTAssertEqual(set(false, in: crlf), "[cleanup]\r\nself_repair = false\r\ncollapse_stutters = true\r\n")
        let missing = "[cleanup]\r\ncollapse_stutters = true\r\n"
        XCTAssertEqual(set(false, in: missing), "[cleanup]\r\nself_repair = false\r\ncollapse_stutters = true\r\n")
    }

    func testAMissingKeyGoesUnderTheHeader() {
        let text = "[[dictionary]]\nfrom = \"a\"\nto = \"b\"\n\n[cleanup] # knobs\ncollapse_stutters = true\n"
        XCTAssertEqual(set(false, in: text),
                       "[[dictionary]]\nfrom = \"a\"\nto = \"b\"\n\n[cleanup] # knobs\nself_repair = false\ncollapse_stutters = true\n")
    }

    func testAMissingTableIsAppended() {
        XCTAssertEqual(set(false, in: "[style]\nmail = \"formal\"\n"),
                       "[style]\nmail = \"formal\"\n\n[cleanup]\nself_repair = false\n")
        XCTAssertEqual(set(false, in: "[style]\nmail = \"formal\""),
                       "[style]\nmail = \"formal\"\n\n[cleanup]\nself_repair = false\n",
                       "a file that ends without a newline gets one first")
        XCTAssertEqual(set(false, in: ""), "\n[cleanup]\nself_repair = false\n")
        XCTAssertEqual(set(true, in: ""), "\n[cleanup]\nself_repair = true\n", "written even when it is the default")
    }

    func testEveryCopyIsSetAndAnUnreadableValueIsReplaced() throws {
        let text = "[cleanup]\nself_repair = maybe\n[style]\n[cleanup]\nself_repair = true # again\n"
        XCTAssertEqual(set(false, in: text),
                       "[cleanup]\nself_repair = false\n[style]\n[cleanup]\nself_repair = false # again\n")
        // A quoted value with a # in it is one value, not a comment.
        XCTAssertEqual(set(false, in: "[cleanup]\nself_repair = \"a # b\"  # c\n"),
                       "[cleanup]\nself_repair = false  # c\n")
        // A key that only starts with the name is another key.
        XCTAssertEqual(set(false, in: "[cleanup]\nself_repair_note = true\n"),
                       "[cleanup]\nself_repair = false\nself_repair_note = true\n")
    }

    func testOnlyTheSwitchesItKnows() {
        // Anything but a known boolean switch is refused, never guessed at.
        XCTAssertNil(set(false, in: "[cleanup]\nverbatim_categories = []\n", key: "verbatim_categories"))
        XCTAssertNil(set(false, in: "[cleanup]\n", key: "level"))
        XCTAssertNotNil(set(false, in: "[cleanup]\n", key: "collapse_stutters"))
    }

    // MARK: - The file

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testTheFileIsEditedInPlaceAndKeepsItsPermissions() throws {
        let url = try scratchDirectory().appendingPathComponent("config.toml")
        let mine = "# mine\n[cleanup]\nself_repair = true  # on\n"
        try mine.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try ConfigStore.setCleanupSwitch("self_repair", to: false, at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# mine\n[cleanup]\nself_repair = false  # on\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAnAbsentFileIsCreatedWithTheSwitchSet() throws {
        let url = try scratchDirectory().appendingPathComponent("nested/config.toml")
        try ConfigStore.setCleanupSwitch("self_repair", to: false, at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        var expected = AppConfig()
        expected.cleanup.selfRepair = false
        XCTAssertEqual(ConfigStore.parse(text), expected)
        XCTAssertTrue(text.hasPrefix("# whispr-bro config"), "the self-documenting file, not a bare key")
    }

    func testASymlinkIsWrittenThrough() throws {
        let dir = try scratchDirectory()
        let real = dir.appendingPathComponent("dotfiles-config.toml")
        let link = dir.appendingPathComponent("config.toml")
        try "[cleanup]\nself_repair = true\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try ConfigStore.setCleanupSwitch("self_repair", to: false, at: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "[cleanup]\nself_repair = false\n")
    }

    func testARefusedEditWritesNothing() throws {
        let url = try scratchDirectory().appendingPathComponent("config.toml")
        try "[cleanup]\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore.setCleanupSwitch("level", to: false, at: url)) {
            XCTAssertEqual($0 as? ConfigStore.SwitchError, .unsafeEdit(key: "level"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[cleanup]\n")
    }

    // MARK: - Off is the app before the rules

    private struct BaseRecord: Decodable {
        struct Row: Decodable {
            let id: String
            let input: String
            let strip: String
            let stripKeepingRepeats: String
            /// Register list ("browser,mail") → what reached the formatter.
            let formatterInput: [String: String]
            let final: [String: String]
        }
        let rows: [Row]
    }

    private func baseRecord() throws -> [BaseRecord.Row] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/self-repair-off-base.json")
        let rows = try JSONDecoder().decode(BaseRecord.self, from: Data(contentsOf: url)).rows
        XCTAssertGreaterThanOrEqual(rows.count, 40)
        return rows
    }

    /// The value recorded for `register` (every register is in one key).
    private func recorded(_ byRegisters: [String: String], _ register: AppCategory,
                          file: StaticString = #filePath, line: UInt = #line) -> String? {
        let hits = byRegisters.filter { $0.key.split(separator: ",").contains(Substring(register.rawValue)) }
        XCTAssertEqual(hits.count, 1, "\(register) recorded once", file: file, line: line)
        return hits.first?.value
    }

    private let noDict = DictionaryEngine(rules: [])

    func testOffIsTheStripAloneAtEveryLevelAndRegister() throws {
        for row in try baseRecord() {
            for collapse in [true, false] {
                let stripper = FillerStripper(collapseStutters: collapse)
                for level in AppConfig.Cleanup.Level.allCases {
                    for verbatimRegister in [false, true] {
                        let expected = level == .verbatim || verbatimRegister
                            ? row.input : (collapse ? row.strip : row.stripKeepingRepeats)
                        XCTAssertEqual(
                            DictationPipeline.prePass(row.input, dictionary: noDict, stripper: stripper,
                                                      level: level, verbatimRegister: verbatimRegister,
                                                      language: .english, selfRepair: false),
                            expected, "\(row.id) \(level) verbatimRegister=\(verbatimRegister) collapse=\(collapse)")
                    }
                }
            }
        }
    }

    func testOffIsTheAppBeforeTheRulesEndToEnd() async throws {
        let verbatimCategories = AppConfig.Cleanup().verbatimCategories
        for row in try baseRecord() {
            for register in AppCategory.allCases {
                let verbatimRegister = verbatimCategories.contains(register.rawValue)
                for level in [AppConfig.Cleanup.Level.fillers, .standard] {
                    var seen: String?
                    let (text, _) = await DictationPipeline.finish(
                        row.input, dictionary: noDict, stripper: FillerStripper(), level: level,
                        verbatimRegister: verbatimRegister, register: register, language: .english,
                        selfRepair: false, format: { seen = $0; return $0 })
                    XCTAssertEqual(seen, recorded(row.formatterInput, register), "\(row.id) \(register) \(level)")
                    XCTAssertEqual(text, recorded(row.final, register), "\(row.id) \(register) \(level)")
                }
                // Off (verbatim) was untouched before the rules and still is.
                var formatted = false
                let (verbatim, _) = await DictationPipeline.finish(
                    row.input, dictionary: noDict, stripper: FillerStripper(), level: .verbatim,
                    verbatimRegister: verbatimRegister, register: register, language: .english,
                    selfRepair: false, format: { formatted = true; return $0 })
                XCTAssertEqual(verbatim, row.input)
                XCTAssertFalse(formatted)
            }
        }
    }

    func testTheSampleIsOneTheSwitchChanges() throws {
        // Most of these rows are ones the rules rewrite: the switch is what
        // makes the outputs above the app before the rules.
        let rows = try baseRecord()
        func changed(_ level: AppConfig.Cleanup.Level) -> Int {
            rows.filter {
                DictationPipeline.prePass($0.input, dictionary: noDict, stripper: FillerStripper(), level: level,
                                          verbatimRegister: false, language: .english) != $0.strip
            }.count
        }
        XCTAssertGreaterThanOrEqual(changed(.standard), 30)
        XCTAssertGreaterThanOrEqual(changed(.fillers), 12)
        XCTAssertLessThan(changed(.fillers), changed(.standard))
    }

    func testTheDictionaryIsStillProtectedWithTheRulesOff() {
        // "uhm" is a core filler; a dictionary target spelled the same survives.
        let dict = DictionaryEngine(rules: [.init(from: "uhm", to: "uhm")])
        XCTAssertEqual(DictationPipeline.prePass("um the uhm library", dictionary: dict, stripper: FillerStripper(),
                                                 level: .standard, verbatimRegister: false, language: .english,
                                                 selfRepair: false),
                       "the uhm library")
    }

    // MARK: - The bench

    func testTheBenchFlag() throws {
        XCTAssertTrue(EvalOptions().selfRepair)
        XCTAssertFalse(try EvalOptions.parse(["--no-self-repair", "f.json"]).get().selfRepair)
        XCTAssertEqual(try EvalOptions.parse(["--no-self-repair", "f.json"]).get().fixturePaths, ["f.json"])
    }

    func testARunWithoutTheRulesSaysSo() throws {
        // On: nothing recorded, so every run made before the switch reads
        // the same and keeps its key.
        let on = EvalRun.Config(label: "x")
        XCTAssertNil(on.selfRepair)
        XCTAssertTrue(on.ranSelfRepair)
        let onJSON = String(decoding: try JSONEncoder().encode(on), as: UTF8.self)
        XCTAssertFalse(onJSON.contains("self_repair"))
        let off = EvalRun.Config(label: "x", selfRepair: false)
        XCTAssertFalse(off.ranSelfRepair)
        let offJSON = String(decoding: try JSONEncoder().encode(off), as: UTF8.self)
        XCTAssertTrue(offJSON.contains("\"self_repair\":false"))
        XCTAssertEqual(try JSONDecoder().decode(EvalRun.Config.self, from: Data(offJSON.utf8)), off)
        let old = try JSONDecoder().decode(EvalRun.Config.self, from: Data(#"{"timeout_ms":3000,"budget_ms":700}"#.utf8))
        XCTAssertTrue(old.ranSelfRepair)
    }

    func testARowWithoutTheRulesIsMarkedEverywhere() throws {
        let seed = EvalCase.seeds[0]
        let observation = EvalRun.Observation(fixture: seed, stripped: seed.raw, out: seed.gold, source: nil, ms: nil,
                                              score: QualityScore.score(seed, out: seed.gold))
        func column(_ selfRepair: Bool) -> EvalRun.Column {
            EvalRun.Column.make(formatter: "rules", modelSha256: "rules", level: "fixture",
                                config: EvalRun.Config(selfRepair: selfRepair), runKey: "k", observations: [observation])
        }
        let run = EvalRun(runId: "r", date: "2026-10-08T00:00:00Z", gitSha: "abc1234", dirty: false,
                          machine: EvalRun.Machine(model: "Mac14,12", os: "26.5"),
                          fixtures: try EvalRun.Fixtures(path: "seeds", name: "seeds", cases: [seed]),
                          columns: [column(true), column(false)])
        let on = run.leaderboardRow(run.columns[0]), off = run.leaderboardRow(run.columns[1])
        XCTAssertNil(on.selfRepair)
        XCTAssertEqual(off.selfRepair, false)
        XCTAssertFalse(String(decoding: try on.canonicalJSON(), as: UTF8.self).contains("self_repair"))
        XCTAssertTrue(String(decoding: try off.canonicalJSON(), as: UTF8.self).contains("\"self_repair\":false"))
        // A different pipeline: never Δ-compared with a run that had the rules.
        XCTAssertNotEqual(on.comparabilityKey, off.comparabilityKey)
        let table = Leaderboard.table([on, off]).components(separatedBy: "\n")
        XCTAssertFalse(table[1].contains("self-repair"))
        XCTAssertTrue(table[2].hasSuffix("[self-repair off]"))
        XCTAssertTrue(EvalReport.markdown(run, cases: [seed]).contains("| rules | — | fixture (self-repair off) |"))
        // A rescore keeps the distinction in the key it recomputes.
        let rescored = try run.rescored(with: [seed])
        XCTAssertEqual(rescored.columns[1].runKey,
                       EvalRun.runKey(gitSha: "abc1234", formatter: "rules", modelSha256: "rules", promptSha256: nil,
                                      fixturesSha256: run.fixtures.sha256, level: "fixture", selfRepair: false))
        XCTAssertNotEqual(rescored.columns[0].runKey, rescored.columns[1].runKey)
    }

    func testTheRunKeyMovesOnlyWhenTheRulesAreOff() {
        func key(_ selfRepair: Bool? = nil) -> String {
            guard let selfRepair else {
                return EvalRun.runKey(gitSha: "abc1234", formatter: "rules", modelSha256: "rules",
                                      promptSha256: nil, fixturesSha256: "f", level: "standard")
            }
            return EvalRun.runKey(gitSha: "abc1234", formatter: "rules", modelSha256: "rules",
                                  promptSha256: nil, fixturesSha256: "f", level: "standard", selfRepair: selfRepair)
        }
        // The key every earlier run was given: the tuple, unchanged.
        let tuple = ["abc1234", "rules", "rules", "", "f", "standard", String(EvalRun.scoringVersion)]
        XCTAssertEqual(key(), String(EvalRun.sha256Hex(tuple.joined(separator: "\n")).prefix(12)))
        XCTAssertEqual(key(true), key())
        XCTAssertNotEqual(key(false), key())
    }
}
