import XCTest
@testable import WhisprBroCore

/// The leaderboard file and its guards (plan §5, §3.3): JSONL reading,
/// the previous-comparable lookup a Δ is allowed against, the `--diff`
/// refusal across fixture sets / scoring versions, the table, the
/// repo-tree test behind `--append`, and the model-manifest reader.
final class LeaderboardTests: XCTestCase {
    private func obs(_ c: EvalCase, _ out: String, source: FormatterSource? = nil, ms: Int? = nil) -> EvalRun.Observation {
        EvalRun.Observation(fixture: c, stripped: c.raw, out: out, source: source, ms: ms,
                            score: QualityScore.score(c, out: out))
    }

    private func run(_ columns: [EvalRun.Column], sha: String = "36ff03b", date: String = "2026-09-14T18:02:00Z",
                     cases: [EvalCase] = EvalCase.seeds) throws -> EvalRun {
        EvalRun(runId: "\(date)-\(sha)-seeds", date: date, gitSha: sha, dirty: false,
                machine: EvalRun.Machine(model: "Mac14,12", os: "26.5.1"),
                fixtures: try EvalRun.Fixtures(path: "seeds", name: "seeds", cases: cases), columns: columns)
    }

    private func rulesColumn(_ observations: [EvalRun.Observation], formatter: String = "rules",
                             modelSha: String? = "rules", promptSha: String? = nil) -> EvalRun.Column {
        EvalRun.Column.make(formatter: formatter, modelKey: nil, modelSha256: modelSha, promptSha256: promptSha,
                            level: "fixture", config: EvalRun.Config(), runKey: "0123456789ab", observations: observations)
    }

    private var goldCopy: [EvalRun.Observation] { EvalCase.seeds.map { obs($0, $0.gold) } }

    private func rows(_ runs: [EvalRun]) -> [EvalRun.LeaderboardRow] {
        runs.flatMap { r in r.columns.map { r.leaderboardRow($0) } }
    }

    // MARK: - Reading

    func testLoadSkipsBlankLinesAndNamesAMalformedOne() throws {
        let r = try run([rulesColumn(goldCopy)])
        let line = try r.leaderboardRow(r.columns[0]).canonicalJSON()
        var data = Data()
        data.append(line); data.append(Data("\n\n".utf8)); data.append(line); data.append(Data("\n".utf8))
        let loaded = try Leaderboard.load(data)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0], r.leaderboardRow(r.columns[0]))
        XCTAssertEqual(try Leaderboard.load(Data()), [])
        var broken = Data()
        broken.append(line); broken.append(Data("\n{\"half\":\n".utf8))
        XCTAssertThrowsError(try Leaderboard.load(broken)) { error in
            XCTAssertEqual(error as? Leaderboard.Error, .malformedLine(2))
            XCTAssertEqual("\(error as! Leaderboard.Error)", "leaderboard line 2 is not a row")
        }
    }

    // MARK: - Previous comparable row and run-key lookup

    func testPreviousComparableIsTheLastRowWithTheSameTupleMinusGitSha() throws {
        let a = try run([rulesColumn(goldCopy)], sha: "aaaaaaa", date: "2026-09-10T00:00:00Z")
        let b = try run([rulesColumn(goldCopy)], sha: "bbbbbbb", date: "2026-09-11T00:00:00Z")
        let other = try run([rulesColumn(goldCopy, formatter: "llama", modelSha: "m", promptSha: "p")],
                            sha: "ccccccc", date: "2026-09-12T00:00:00Z")
        let history = rows([a, b, other])
        let mine = try run([rulesColumn(goldCopy)], sha: "ddddddd").leaderboardRow(rulesColumn(goldCopy))
        XCTAssertEqual(Leaderboard.previousComparable(to: mine, in: history)?.gitSha, "bbbbbbb")
        // A different fixture set is never comparable, whatever the formatter.
        let subset = try run([rulesColumn(goldCopy)], cases: Array(EvalCase.seeds.prefix(3)))
        XCTAssertNil(Leaderboard.previousComparable(to: subset.leaderboardRow(subset.columns[0]), in: history))
        XCTAssertNil(Leaderboard.previousComparable(to: mine, in: []))
        // run_key lookup: the newest line wins; unknown throws.
        var older = history[0]; older.runKey = "k"
        var newer = history[1]; newer.runKey = "k"
        XCTAssertEqual(try Leaderboard.row(runKey: "k", in: [older, newer]).gitSha, "bbbbbbb")
        XCTAssertThrowsError(try Leaderboard.row(runKey: "zz", in: history)) { error in
            XCTAssertEqual(error as? Leaderboard.Error, .unknownRunKey("zz"))
        }
    }

    // MARK: - Δ

    func testDiffRefusesDifferentFixturesOrScoringVersion() throws {
        let full = try run([rulesColumn(goldCopy)])
        let a = full.leaderboardRow(full.columns[0])
        let subset = try run([rulesColumn(goldCopy)], cases: Array(EvalCase.seeds.prefix(3)))
        let b = subset.leaderboardRow(subset.columns[0])
        XCTAssertThrowsError(try Leaderboard.diff(a, b)) { error in
            guard case .incomparable(let why)? = error as? Leaderboard.Error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.hasPrefix("fixtures.sha256 differ"), why)
        }
        var older = a; older.scoringVersion = 0
        XCTAssertThrowsError(try Leaderboard.diff(older, a)) { error in
            guard case .incomparable(let why)? = error as? Leaderboard.Error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.hasPrefix("scoring_version differ (0 vs 4)"), why)
        }
        // Formatter and git sha may differ — that is what a diff is for.
        var llama = a; llama.formatter = "llama"; llama.gitSha = "1234567"
        XCTAssertNoThrow(try Leaderboard.diff(a, llama))
    }

    func testDeltaIsBMinusAFieldByField() throws {
        // 80 seeds at 100 and one emptied → 8000/81 = 98.8 on C, F and M
        // (EvalRunTests pins C); the empty output is OVER_EDIT_FACT, and one
        // in 81 (1.2%) stays under the 5% FAIL share.
        var worse = goldCopy
        worse[0] = obs(EvalCase.seeds[0], "")
        let a = try run([rulesColumn(worse)], sha: "aaaaaaa")
        let b = try run([rulesColumn(goldCopy)], sha: "bbbbbbb")
        let d = try Leaderboard.diff(a.leaderboardRow(a.columns[0]), b.leaderboardRow(b.columns[0]))
        XCTAssertEqual(d.c, 1.2)
        XCTAssertEqual(d.m, 1.2)
        XCTAssertEqual(d.f, 1.2)
        XCTAssertEqual(d.fi, 0)
        XCTAssertEqual(d.verdicts.count, EvalVerdict.allCases.count)
        XCTAssertEqual(d.verdicts.first { $0.name == "PASS" }.map { [$0.a, $0.b] }, [80, 81])
        XCTAssertEqual(d.verdicts.first { $0.name == "OVER_EDIT_FACT" }.map { [$0.a, $0.b] }, [1, 0])
        XCTAssertNil(d.p50)
        let text = Leaderboard.render(d)
        XCTAssertTrue(text.contains("diff  0123456789ab (aaaaaaa 2026-09-14)  →  0123456789ab (bbbbbbb 2026-09-14)"), text)
        XCTAssertTrue(text.contains("scores    C 98.8 → 100.0 (+1.2) · F 98.8 → 100.0 (+1.2) · Fi 100.0 → 100.0 (0) · M 98.8 → 100.0 (+1.2)"), text)
        XCTAssertTrue(text.contains("status    PASS → PASS"), text)
        XCTAssertTrue(text.contains("verdicts  OVER_EDIT_FACT 1 → 0 · PASS 80 → 81"), text)
        XCTAssertFalse(text.contains("latency"))
        // Latency deltas appear for a timed column.
        let slow = rulesColumn(goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 900) }, formatter: "llama", modelSha: "m", promptSha: "p")
        let fast = rulesColumn(goldCopy.map { obs($0.fixture, $0.out, source: .model, ms: 400) }, formatter: "llama", modelSha: "m", promptSha: "p")
        let l = try Leaderboard.diff(try run([slow]).leaderboardRow(slow), try run([fast]).leaderboardRow(fast))
        XCTAssertEqual([l.p50, l.p90, l.p99], [-500, -500, -500])
        XCTAssertTrue(Leaderboard.render(l).contains("latency   p50 -500 · p90 -500 · p99 -500 ms"))
    }

    func testSignedFormatting() {
        XCTAssertEqual(Leaderboard.signed(2.34), "+2.3")
        XCTAssertEqual(Leaderboard.signed(-0.4), "-0.4")
        XCTAssertEqual(Leaderboard.signed(0.0), "0")
        XCTAssertEqual(Leaderboard.signed(nil as Double?), "—")
        XCTAssertEqual(Leaderboard.signed(7), "+7")
        XCTAssertEqual(Leaderboard.signed(-7), "-7")
        XCTAssertEqual(Leaderboard.signed(0), "0")
        XCTAssertEqual(Leaderboard.signed(nil as Int?), "—")
    }

    // MARK: - Table

    func testTableListsFileOrderAndTopRanksByComposite() throws {
        var worse = goldCopy
        worse[0] = obs(EvalCase.seeds[0], "")
        let low = try run([rulesColumn(worse)], sha: "aaaaaaa", date: "2026-09-10T10:00:00Z")
        let high = try run([rulesColumn(goldCopy)], sha: "bbbbbbb", date: "2026-09-11T10:00:00Z")
        let table = Leaderboard.table(rows([low, high]))
        let lines = table.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("date              sha      formatter   model"))
        XCTAssertTrue(lines[1].hasPrefix("2026-09-10T10:00  aaaaaaa  rules       —              fixture   seeds n=81       98.8   98.8   100.0  98.8   PASS    —      —      0123456789ab"), String(lines[1]))
        XCTAssertTrue(lines[2].contains("bbbbbbb  rules") && lines[2].contains("100.0  100.0  100.0  100.0  PASS"), String(lines[2]))
        let top = Leaderboard.table(rows([low, high]), top: 1).split(separator: "\n")
        XCTAssertEqual(top.count, 2)
        XCTAssertTrue(top[1].contains("bbbbbbb"))
        XCTAssertEqual(Leaderboard.table([], top: 3).split(separator: "\n").count, 1)
        // A dirty sha is starred; a partly rated set shows rated=.
        var dirty = high.leaderboardRow(high.columns[0]); dirty.dirty = true; dirty.fixtures.ratedN = 40
        XCTAssertTrue(Leaderboard.table([dirty]).contains("bbbbbbb* rules       —              fixture   seeds n=81 rated=40"))
    }

    // MARK: - Guards

    func testRepoTreeDetection() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-lb-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo/docs/eval", isDirectory: true)
        let plain = base.appendingPathComponent("home/eval", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertFalse(Leaderboard.isInsideRepoTree(repo.appendingPathComponent("leaderboard.jsonl").path))
        try Data().write(to: base.appendingPathComponent("repo/Package.swift"))
        XCTAssertTrue(Leaderboard.isInsideRepoTree(repo.appendingPathComponent("leaderboard.jsonl").path))
        XCTAssertTrue(Leaderboard.isInsideRepoTree(base.appendingPathComponent("repo/lb.jsonl").path))
        // The checkout itself, for the callers that need the directory.
        XCTAssertEqual(Leaderboard.checkoutRoot(of: repo.appendingPathComponent("leaderboard.jsonl").path)?.path,
                       base.appendingPathComponent("repo").path)
        // The git checkout alone, for the routing a manifest must not
        // move (`FormatFixture.isRepoPath`): a package without `.git` is
        // refused above and nothing here.
        XCTAssertNil(Leaderboard.gitRoot(of: repo.appendingPathComponent("leaderboard.jsonl").path))
        XCTAssertFalse(Leaderboard.isInsideRepoTree(plain.appendingPathComponent("leaderboard.jsonl").path))
        // A `.git` marker counts too; the file itself need not exist.
        try FileManager.default.createDirectory(at: plain.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertTrue(Leaderboard.isInsideRepoTree(plain.appendingPathComponent("sub/leaderboard.jsonl").path))
        // The routing's walk wants what git calls a repository: a `HEAD`
        // git can read with `objects` and `refs` beside it, or a `gitdir:`
        // file pointing at one (`testGitRepositoryIsWhatGitTakesForOne`).
        XCTAssertNil(Leaderboard.gitRoot(of: plain.appendingPathComponent("sub/leaderboard.jsonl").path))
        for entry in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: plain.appendingPathComponent(".git/\(entry)"), withIntermediateDirectories: true)
        }
        try Data().write(to: plain.appendingPathComponent(".git/HEAD"))
        XCTAssertNil(Leaderboard.gitRoot(of: plain.appendingPathComponent("sub/leaderboard.jsonl").path))
        try Data("ref: refs/heads/main\n".utf8).write(to: plain.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(Leaderboard.gitRoot(of: plain.appendingPathComponent("sub/leaderboard.jsonl").path)?.path, plain.path)
        // A `gitdir:` file is a checkout only while its target is a repository.
        try Data("gitdir: elsewhere\n".utf8).write(to: base.appendingPathComponent("repo/.git"))
        XCTAssertNil(Leaderboard.gitRoot(of: repo.appendingPathComponent("leaderboard.jsonl").path))
        try Data("gitdir: ../home/eval/.git\n".utf8).write(to: base.appendingPathComponent("repo/.git"))
        XCTAssertEqual(Leaderboard.gitRoot(of: repo.appendingPathComponent("leaderboard.jsonl").path)?.path,
                       base.appendingPathComponent("repo").path)
    }

    func testGitRepositoryIsWhatGitTakesForOne() throws {
        // `Leaderboard.isGitRepository` is git's own test of a `.git`
        // (setup.c's `is_git_directory` and `read_gitfile`), shape by
        // shape, so the routing's "nested repository" is exactly what
        // `git ls-files` leaves out and its "nothing" exactly what git
        // lists as plain files of the checkout above.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-git-\(UUID().uuidString)", isDirectory: true)
        let git = base.appendingPathComponent(".git", isDirectory: true)
        let head = git.appendingPathComponent("HEAD")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let isRepo = { (url: URL) in Leaderboard.isGitRepository(url, fileManager: .default) }
        // Absent, a plain file, a directory made by hand.
        XCTAssertFalse(isRepo(git))
        try Data("hello".utf8).write(to: git)
        XCTAssertFalse(isRepo(git))
        try FileManager.default.removeItem(at: git)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        XCTAssertFalse(isRepo(git))
        // `objects` and `refs` without a `HEAD`, then with one git cannot
        // read: empty, or a symbolic ref that is not under `refs/`.
        for entry in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: git.appendingPathComponent(entry), withIntermediateDirectories: true)
        }
        XCTAssertFalse(isRepo(git))
        try Data().write(to: head)
        XCTAssertFalse(isRepo(git))
        try Data("ref: heads/main\n".utf8).write(to: head)
        XCTAssertFalse(isRepo(git))
        // A symbolic ref, spaced as git writes it or not at all, or a
        // detached head: an object id in hex, 40 digits at the least.
        for text in ["ref: refs/heads/main\n", "ref:refs/heads/main", "ref:\t refs/tags/v1",
                     String(repeating: "a0", count: 20), String(repeating: "F", count: 40) + "\n",
                     String(repeating: "0", count: 64) + "\n"] {
            try Data(text.utf8).write(to: head)
            XCTAssertTrue(isRepo(git), text)
        }
        for text in [String(repeating: "a", count: 39), "g" + String(repeating: "a", count: 39),
                     " ref: refs/heads/main", "refs/heads/main"] {
            try Data(text.utf8).write(to: head)
            XCTAssertFalse(isRepo(git), text)
        }
        // The old symlink form of a symbolic ref: the link's text decides,
        // whether or not the branch it names exists.
        try FileManager.default.removeItem(at: head)
        try FileManager.default.createSymbolicLink(atPath: head.path, withDestinationPath: "refs/heads/main")
        XCTAssertTrue(isRepo(git))
        try FileManager.default.removeItem(at: head)
        try FileManager.default.createSymbolicLink(atPath: head.path, withDestinationPath: "elsewhere")
        XCTAssertFalse(isRepo(git))
        try FileManager.default.removeItem(at: head)
        try Data("ref: refs/heads/main\n".utf8).write(to: head)
        // A `HEAD` alone is not enough: `objects` and `refs` must be there.
        try FileManager.default.removeItem(at: git.appendingPathComponent("objects"))
        XCTAssertFalse(isRepo(git))
        try FileManager.default.createDirectory(at: git.appendingPathComponent("objects"), withIntermediateDirectories: true)
        XCTAssertTrue(isRepo(git))
        // A worktree's gitdir keeps a `HEAD` of its own and names the
        // repository whose `objects` and `refs` it shares in `commondir`.
        let wt = git.appendingPathComponent("worktrees/wt", isDirectory: true)
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try Data("ref: refs/heads/topic\n".utf8).write(to: wt.appendingPathComponent("HEAD"))
        XCTAssertFalse(isRepo(wt))
        try Data("../..\n".utf8).write(to: wt.appendingPathComponent("commondir"))
        XCTAssertTrue(isRepo(wt))
        try Data(git.path.utf8).write(to: wt.appendingPathComponent("commondir"))
        XCTAssertTrue(isRepo(wt))
        try Data("nowhere\n".utf8).write(to: wt.appendingPathComponent("commondir"))
        XCTAssertFalse(isRepo(wt))
        try Data("../..\n".utf8).write(to: wt.appendingPathComponent("commondir"))
        // A gitfile: `gitdir: ` then a path, relative to the file's own
        // directory, whose target must itself be a repository.
        let file = base.appendingPathComponent("sub/.git")
        for text in ["gitdir: ../.git\n", "gitdir: ../.git", "gitdir: ../.git\r\n",
                     "gitdir: ../.git/worktrees/wt\n", "gitdir: \(git.path)\n"] {
            try Data(text.utf8).write(to: file)
            XCTAssertTrue(isRepo(file), text)
        }
        for text in ["gitdir: nowhere\n", "gitdir: \n", "gitdir:../.git\n", "../.git\n",
                     " gitdir: ../.git\n", "gitdir: ../.git/objects\n"] {
            try Data(text.utf8).write(to: file)
            XCTAssertFalse(isRepo(file), text)
        }
    }

    func testAppendAndRunOutputRefusals() throws {
        // The decisions behind `--append` and `--json` / `--report`, as pure
        // predicates: a repo path is refused for a personal set — a
        // `history:` source or an observed output, the fields only an export
        // writes — and allowed for the seeds or a hand-written synthetic
        // set; an out-of-tree path is always allowed.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("repo/docs/eval"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home/eval/runs"), withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent("repo/Package.swift"))
        defer { try? FileManager.default.removeItem(at: base) }
        let inRepo = base.appendingPathComponent("repo/docs/eval/leaderboard.jsonl").path
        let outside = base.appendingPathComponent("home/eval/leaderboard.jsonl").path
        XCTAssertFalse(Leaderboard.refusesAppend(path: inRepo, fixtureSetIsSeeds: true))
        XCTAssertTrue(Leaderboard.refusesAppend(path: inRepo, fixtureSetIsSeeds: false))
        XCTAssertFalse(Leaderboard.refusesAppend(path: outside, fixtureSetIsSeeds: false))
        XCTAssertFalse(Leaderboard.refusesAppend(path: outside, fixtureSetIsSeeds: true))

        let history = EvalCase(id: "h70", raw: "ship it now", gold: "", source: "history:70", goldSource: "history-unrated",
                               observed: "Ship it now.", observedMs: 400)
        let observedOnly = EvalCase(id: "o", raw: "ship it now", gold: "Ship it now.", observed: "Ship it now.")
        let synthetic = EvalCase(id: "s", raw: "ship it now", gold: "Ship it now.")
        let runInRepo = base.appendingPathComponent("repo/runs/personal.json").path
        let runOutside = base.appendingPathComponent("home/eval/runs/personal.json").path
        XCTAssertTrue(Leaderboard.refusesRunOutput(path: runInRepo, cases: [synthetic, history]))
        XCTAssertTrue(Leaderboard.refusesRunOutput(path: runInRepo, cases: [observedOnly]))
        XCTAssertFalse(Leaderboard.refusesRunOutput(path: runInRepo, cases: [synthetic]))
        XCTAssertFalse(Leaderboard.refusesRunOutput(path: runInRepo, cases: EvalCase.seeds))
        XCTAssertFalse(Leaderboard.refusesRunOutput(path: runOutside, cases: [history]))
        XCTAssertFalse(Leaderboard.refusesRunOutput(path: runInRepo, cases: []))
    }

    func testTheLiveBannerCountsTheRowsWrittenCalibrated() throws {
        let r = try run([rulesColumn(goldCopy)])
        let a = r.leaderboardRow(r.columns[0],
                                 calibration: Calibration.Live(rated: 81, valid: true, zeroEditRates: [:]))
        let b = r.leaderboardRow(r.columns[0])
        let live = Calibration.Live(rated: 124, valid: true, zeroEditRates: ["llama": 72.8])
        XCTAssertEqual(Leaderboard.banner([a, b], calibration: live),
                       "CALIBRATION: VALID (n=124 rated) · 1/2 row(s) written calibrated · zero-edit llama 72.8%")
        XCTAssertEqual(Leaderboard.banner([a, b], calibration: .none),
                       "CALIBRATION: PENDING (n=0 rated) · 1/2 row(s) written calibrated")
        XCTAssertEqual(Leaderboard.banner([], calibration: .none),
                       "CALIBRATION: PENDING (n=0 rated) · 0/0 row(s) written calibrated")
    }

    func testModelManifestLookup() {
        let manifest = """
        6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83  llama3.2-1b/Llama-3.2-1B-Instruct-Q4_K_M.gguf
        1ADF0B11065D8AD2E8123EA110D1EC956DAB4AB038EAB665614ADBA04B6C3370  qwen2.5-1.5b/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf
        not-a-digest  qwen3-1.7b/Qwen_Qwen3-1.7B-Q4_K_M.gguf
        """
        XCTAssertEqual(Leaderboard.modelSha256(manifest: manifest, relativePath: LlmCatalog.llama3_2_1b.relativePath),
                       "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83")
        XCTAssertEqual(Leaderboard.modelSha256(manifest: manifest, relativePath: LlmCatalog.qwen2_5_1_5b.relativePath),
                       "1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370")
        XCTAssertNil(Leaderboard.modelSha256(manifest: manifest, relativePath: LlmCatalog.qwen3_1_7b.relativePath))
        XCTAssertNil(Leaderboard.modelSha256(manifest: "", relativePath: "x"))
    }
}
