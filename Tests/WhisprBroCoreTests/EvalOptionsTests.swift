import XCTest
@testable import WhisprBroCore

/// `whispr-bench eval`'s flag parser and its derived lists (plan §6.1, D2):
/// every flag, every validation, the `<sha>-dirty` token
/// scripts/bench-eval.sh passes, the column expansion, the filtered
/// fixture-set name — and the tie between the flag lists the script walks
/// and the flags the parser consumes.
final class EvalOptionsTests: XCTestCase {
    private func parse(_ args: String...) -> EvalOptions? { try? EvalOptions.parse(args).get() }

    private func failure(_ args: String...) -> String? {
        if case .failure(let e) = EvalOptions.parse(args) { return e.description }
        return nil
    }

    func testDefaults() {
        let o = parse()!
        XCTAssertEqual(o, EvalOptions())
        XCTAssertEqual(o.fixturePaths, [])
        XCTAssertEqual(o.formatters, ["all"])
        XCTAssertNil(o.modelKey)
        XCTAssertNil(o.systemPromptPath)
        XCTAssertEqual(o.level, "fixture")
        XCTAssertNil(o.levelOverride)
        XCTAssertEqual(o.tags, [])
        XCTAssertEqual(o.only, .all)
        XCTAssertEqual([o.budgetMs, o.timeoutMs], [700, 3000])
        XCTAssertFalse(o.confirmedOnly)
        XCTAssertFalse(o.strictLatency)
        XCTAssertFalse(o.dirty)
        XCTAssertFalse(o.quiet)
        XCTAssertNil(o.jsonPath)
        XCTAssertNil(o.reportPath)
        XCTAssertNil(o.appendPath)
        XCTAssertNil(o.gitSha)
        XCTAssertNil(o.label)
    }

    func testEveryFlagParses() {
        let o = parse("a.json", "--formatter", "shipped, llama", "--model", "qwen3-1.7b", "--system-prompt", "p.md",
                      "--level", "fillers", "--tag", "hedge,repair", "--tag", "trap", "--only", "flagged",
                      "--confirmed-only", "--budget-ms", "500", "--timeout-ms", "6000", "--strict-latency",
                      "--json", "r.json", "--report", "r.md", "--append", "lb.jsonl", "--git-sha", "abc1234",
                      "--label", "baseline", "--quiet", "b.json")!
        XCTAssertEqual(o.fixturePaths, ["a.json", "b.json"])
        XCTAssertEqual(o.formatters, ["shipped", "llama"])
        XCTAssertEqual(o.modelKey, "qwen3-1.7b")
        XCTAssertEqual(o.systemPromptPath, "p.md")
        XCTAssertEqual(o.level, "fillers")
        XCTAssertEqual(o.levelOverride, .fillers)
        XCTAssertEqual(o.tags, ["hedge", "repair", "trap"])
        XCTAssertEqual(o.only, .flagged)
        XCTAssertTrue(o.confirmedOnly)
        XCTAssertEqual([o.budgetMs, o.timeoutMs], [500, 6000])
        XCTAssertTrue(o.strictLatency)
        XCTAssertEqual(o.jsonPath, "r.json")
        XCTAssertEqual(o.reportPath, "r.md")
        XCTAssertEqual(o.appendPath, "lb.jsonl")
        XCTAssertEqual(o.gitSha, "abc1234")
        XCTAssertFalse(o.dirty)
        XCTAssertEqual(o.label, "baseline")
        XCTAssertTrue(o.quiet)
        XCTAssertEqual(parse("--level", "standard")?.levelOverride, .standard)
    }

    func testGitShaDirtySuffixAndDirtyFlag() {
        let folded = parse("--git-sha", "abc1234-dirty")!
        XCTAssertEqual(folded.gitSha, "abc1234")
        XCTAssertTrue(folded.dirty)
        let flagged = parse("--git-sha", "abc1234", "--dirty")!
        XCTAssertEqual(flagged.gitSha, "abc1234")
        XCTAssertTrue(flagged.dirty)
    }

    func testValidationMessages() {
        XCTAssertEqual(failure("--level", "verbatim"), "--level must be fixture | fillers | standard, not 'verbatim'")
        XCTAssertEqual(failure("--only", "worst"), "--only must be gated | flagged | unrated | all, not 'worst'")
        XCTAssertEqual(failure("--budget-ms", "0"), "--budget-ms needs a positive integer")
        XCTAssertEqual(failure("--timeout-ms", "soon"), "--timeout-ms needs a positive integer")
        XCTAssertEqual(failure("--formatter", "gpt"),
                       "unknown --formatter 'gpt' (rules | llama | foundation | shipped | all, or a comma list)")
        XCTAssertEqual(failure("--formatter", "rules,gpt"),
                       "unknown --formatter 'gpt' (rules | llama | foundation | shipped | all, or a comma list)")
        XCTAssertEqual(failure("--json"), "--json needs a value")
        XCTAssertEqual(failure("--verbose"), "unknown flag '--verbose'")
        XCTAssertNil(failure("--formatter", "rules"))
    }

    func testFlagListsAreTheParsersOwn() {
        // Every value flag is accepted with a value and refused without
        // one; every boolean flag stands alone; the lists are disjoint;
        // nothing else with a leading `--` is a flag. This is what lets
        // scripts/bench-eval.sh take `valueFlags` from the binary.
        let sample = ["--formatter": "rules", "--level": "standard", "--only": "gated", "--budget-ms": "1", "--timeout-ms": "1"]
        for flag in EvalOptions.valueFlags {
            XCTAssertNotNil(parse(flag, sample[flag] ?? "x"), flag)
            XCTAssertEqual(failure(flag), "\(flag) needs a value")
        }
        for flag in EvalOptions.booleanFlags {
            XCTAssertNotNil(parse(flag), flag)
        }
        XCTAssertTrue(Set(EvalOptions.valueFlags).isDisjoint(with: EvalOptions.booleanFlags))
        XCTAssertEqual(EvalOptions.valueFlags.count, 14)
        XCTAssertEqual(EvalOptions.booleanFlags.count, 5)
        // A value flag's value is never read as a fixtures path, even when
        // it looks like one.
        XCTAssertEqual(parse("--json", "runs/x.json")?.fixturePaths, [])
        XCTAssertEqual(parse("--report", "x.md", "f.json")?.fixturePaths, ["f.json"])
    }

    func testColumnsExpandAllInPlaceAndDedupe() {
        XCTAssertEqual(EvalOptions().columns(hasObserved: false), ["rules", "llama", "foundation"])
        XCTAssertEqual(EvalOptions().columns(hasObserved: true), ["rules", "llama", "foundation", "shipped"])
        XCTAssertEqual(parse("--formatter", "shipped,all,llama")!.columns(hasObserved: true),
                       ["shipped", "rules", "llama", "foundation"])
        XCTAssertEqual(parse("--formatter", "shipped")!.columns(hasObserved: false), ["shipped"])
        XCTAssertEqual(parse("--formatter", "llama,llama")!.columns(hasObserved: true), ["llama"])
        XCTAssertEqual(parse("--formatter", "shipped,llama,foundation")!.columns(hasObserved: true),
                       ["shipped", "llama", "foundation"])
    }

    func testFixturesNameCarriesTheFilters() {
        XCTAssertEqual(EvalOptions().fixturesName(base: "seeds"), "seeds")
        XCTAssertEqual(parse("--tag", "hedge,repair", "--only", "gated", "--confirmed-only")!.fixturesName(base: "personal"),
                       "personal[--tag hedge,repair --only gated --confirmed-only]")
        XCTAssertEqual(parse("--only", "unrated")!.fixturesName(base: "personal"), "personal[--only unrated]")
        XCTAssertEqual(parse("--only", "all")!.fixturesName(base: "personal"), "personal")
    }

    func testRatingsPathParses() {
        XCTAssertNil(EvalOptions().ratingsPath)
        XCTAssertEqual(parse("--ratings", "/tmp/eval/ratings.jsonl")!.ratingsPath, "/tmp/eval/ratings.jsonl")
        // scripts/bench-eval.sh skips the value, so the flag must be listed.
        XCTAssertTrue(EvalOptions.valueFlags.contains("--ratings"))
        guard case .failure = EvalOptions.parse(["--ratings"]) else {
            return XCTFail("--ratings with no value must be a usage error")
        }
    }

    func testUsageErrorPrintsItsMessage() {
        XCTAssertEqual("\(EvalUsageError("boom"))", "boom")
        XCTAssertEqual(EvalUsageError("a"), EvalUsageError("a"))
    }
}
