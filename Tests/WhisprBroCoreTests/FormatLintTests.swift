import XCTest
@testable import WhisprBroCore

/// `whispr-bench lint` for the format bench's fixtures (`FormatLint`), and
/// the routing that sends a file there. A format file is one of
/// `FormatFixture.repoPaths` in its checkout — declared, never guessed from
/// its rows — so an eval file is never waved past the invariant and a
/// format file never fails it. The repo guard is `EvalLint`'s own, so the
/// privacy rail refuses a history row or a shipped output in either kind of
/// file by one rule.
final class FormatLintTests: XCTestCase {
    private static let checkout = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func errors(_ fixtures: [FormatFixture], repoGuard: Bool = false) -> [String] {
        FormatLint.lint(fixtures, repoGuard: repoGuard).filter { $0.severity == .error }.map(\.message)
    }

    /// A well-formed row: a spoken line break and the layout it asks for.
    private func fixture(_ id: String = "f", raw: String = "buy milk new line buy eggs",
                         gold: String = "Buy milk\nBuy eggs.", tags: [String] = ["command", "line-break"],
                         register: String? = nil, policy: String? = nil, source: String? = nil,
                         observed: String? = nil, observedMs: Int? = nil) -> FormatFixture {
        FormatFixture(id: id, raw: raw, gold: gold, tags: tags, register: register, policy: policy,
                      source: source, observed: observed, observedMs: observedMs)
    }

    // MARK: - The checkout's own files

    func testTheDeclaredFilesExistLintCleanAndAreRoutedHere() throws {
        XCTAssertEqual(FormatFixture.repoPaths, ["docs/eval/formatting.json"])
        XCTAssertEqual(FormatFixture.inferringPolicy, "inferring")
        for path in FormatFixture.repoPaths {
            let url = Self.checkout.appendingPathComponent(path)
            let fixtures = try FormatFixture.decode(Data(contentsOf: url))
            XCTAssertFalse(fixtures.isEmpty, path)
            XCTAssertEqual(FormatLint.lint(fixtures, repoGuard: true), [], path)
            XCTAssertTrue(FormatFixture.isRepoPath(url.path), path)
            // The reason the file is not an eval file: its golds are layout.
            XCTAssertTrue(fixtures.contains { $0.gold.contains("\n") }, path)
            XCTAssertFalse(fixtures.contains { $0.source != nil || $0.observed != nil || $0.observedMs != nil }, path)
        }
    }

    func testDecodesWhatTheBenchReads() throws {
        let json = """
        [{"id": "list-inferred", "raw": "first we ship it second we tell the team third we rest",
          "gold": "1. We ship it\\n2. We tell the team\\n3. We rest", "tags": ["inferred", "opt-in"],
          "register": "notes", "policy": "inferring", "mustNotRestructure": false, "note": "ignored"}]
        """
        let fixtures = try FormatFixture.decode(Data(json.utf8))
        XCTAssertEqual(fixtures, [FormatFixture(
            id: "list-inferred", raw: "first we ship it second we tell the team third we rest",
            gold: "1. We ship it\n2. We tell the team\n3. We rest", tags: ["inferred", "opt-in"],
            register: "notes", policy: "inferring", mustNotRestructure: false)])
        XCTAssertEqual(FormatLint.lint(fixtures, repoGuard: true), [])
        // A row without `id`, `raw`, `gold` or `tags` is not a fixture at all.
        XCTAssertThrowsError(try FormatFixture.decode(Data(#"[{"id": "x", "raw": "hi", "gold": "Hi."}]"#.utf8)))
    }

    // MARK: - Row rules

    func testDuplicateIds() {
        let a = fixture("a")
        let issues = FormatLint.lint([a, a])
        XCTAssertEqual(issues, [EvalLint.Issue(.error, id: "a", "duplicate id")])
        XCTAssertTrue(EvalLint.hasErrors(issues))
        XCTAssertEqual(issues[0].description, "error: [a] duplicate id")
        XCTAssertEqual(FormatLint.lint([a, fixture("b")]), [])
    }

    func testEmptyRawGoldOrTags() {
        XCTAssertEqual(errors([fixture("r", raw: " \n")]), ["empty raw"])
        XCTAssertEqual(errors([fixture("g", gold: "")]), ["empty gold"])
        XCTAssertEqual(errors([fixture("t", tags: [])]), ["no tags"])
        XCTAssertEqual(errors([fixture("all", raw: "", gold: " ", tags: [])]), ["empty raw", "empty gold", "no tags"])
    }

    func testRegisterAndPolicyAreReadByName() {
        // The bench maps an unknown register to `.unknown` and an unknown
        // policy to the register's own, both silently; the lint does not.
        XCTAssertEqual(errors([fixture(register: "ide")]), [])
        XCTAssertEqual(errors([fixture(register: "shell")]), [
            "register 'shell' is not an app category (expected one of: "
                + AppCategory.allCases.map(\.rawValue).joined(separator: ", ") + ")",
        ])
        XCTAssertEqual(errors([fixture(policy: "inferring")]), [])
        XCTAssertEqual(errors([fixture(policy: "inferred")]),
                       ["policy 'inferred' is not one the format bench reads (only 'inferring')"])
    }

    // MARK: - Repo guard

    func testRepoGuardRefusesExportFieldsInAFormatFile() throws {
        // The fields only a history export writes, dropped into a format
        // file: refused under the guard by the rule `EvalLint` applies to
        // an eval file, and — like an eval file outside the tree — fine
        // without it.
        let json = """
        [
          {"id": "clean", "raw": "buy milk new line buy eggs", "gold": "Buy milk\\nBuy eggs.", "tags": ["command"]},
          {"id": "h", "raw": "ship it", "gold": "Ship it.", "tags": ["control"], "source": "history:70"},
          {"id": "o", "raw": "ship it", "gold": "Ship it.", "tags": ["control"], "observed": "Ship it.", "observed_ms": 12},
          {"id": "ot", "raw": "ship it", "gold": "Ship it.", "tags": ["control"], "observed": "Ship it."},
          {"id": "om", "raw": "ship it", "gold": "Ship it.", "tags": ["control"], "observed_ms": 7}
        ]
        """
        let fixtures = try FormatFixture.decode(Data(json.utf8))
        // Each export key is read under its own name, alone as well as
        // together: the guard can only refuse what the decoder saw.
        XCTAssertEqual(fixtures.map(\.source), [nil, "history:70", nil, nil, nil])
        XCTAssertEqual(fixtures.map(\.observed), [nil, nil, "Ship it.", "Ship it.", nil])
        XCTAssertEqual(fixtures.map(\.observedMs), [nil, nil, 12, nil, 7])
        XCTAssertEqual(FormatLint.lint(fixtures), [])
        XCTAssertEqual(FormatLint.lint(fixtures, repoGuard: true), [
            EvalLint.Issue(.error, id: "h", "repo guard: source 'history:70' is a history row"),
            EvalLint.Issue(.error, id: "o", "repo guard: 'observed' / 'observed_ms' is shipped-binary output"),
            EvalLint.Issue(.error, id: "ot", "repo guard: 'observed' / 'observed_ms' is shipped-binary output"),
            EvalLint.Issue(.error, id: "om", "repo guard: 'observed' / 'observed_ms' is shipped-binary output"),
        ])
        // A declared synthetic source passes.
        XCTAssertEqual(errors([fixture("s", source: "synthetic")], repoGuard: true), [])
        // The same rule, not a copy of it: the eval guard says the same of
        // the same fields.
        XCTAssertEqual(FormatLint.lint([fixtures[1]], repoGuard: true),
                       EvalLint.guardRow(EvalCase(id: "h", raw: "ship it", gold: "Ship it.", source: "history:70")))
        XCTAssertEqual(FormatLint.lint([fixtures[2]], repoGuard: true),
                       EvalLint.guardRow(EvalCase(id: "o", raw: "ship it", gold: "Ship it.", observed: "Ship it.", observedMs: 12)))
    }

    // MARK: - Routing

    func testRoutingIsTheDeclaredPathInItsCheckoutNeverTheRows() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-format-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for dir in ["repo/docs/eval/nested/docs/eval", "repo/docs/other", "plain/docs/eval", "main/.git/objects", "main/.git/refs"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        // A repository for the `gitdir:` files below to point at.
        try Data("ref: refs/heads/main\n".utf8).write(to: base.appendingPathComponent("main/.git/HEAD"))
        // The same format rows everywhere: what a file holds decides nothing.
        let rows = Data(#"[{"id": "a", "raw": "buy milk new line buy eggs", "gold": "Buy milk\nBuy eggs.", "tags": ["command"]}]"#.utf8)
        let declared = base.appendingPathComponent("repo/docs/eval/formatting.json")
        let otherName = base.appendingPathComponent("repo/docs/eval/cases.json")
        let otherDir = base.appendingPathComponent("repo/docs/other/formatting.json")
        let nested = base.appendingPathComponent("repo/docs/eval/nested/docs/eval/formatting.json")
        let noCheckout = base.appendingPathComponent("plain/docs/eval/formatting.json")
        for file in [declared, otherName, otherDir, nested, noCheckout] { try rows.write(to: file) }
        let repo = base.appendingPathComponent("repo").path
        let nestedDir = base.appendingPathComponent("repo/docs/eval/nested").path

        // Nothing above it marks a checkout: not routed, whatever it holds.
        XCTAssertNil(Leaderboard.checkoutRoot(of: declared.path))
        XCTAssertFalse(FormatFixture.isRepoPath(declared.path))
        // Where no ancestor is a git repository at all — an export, a
        // tarball — the checkout is the one the repo-tree refusals see,
        // the nearest `Package.swift`, and the declared file is routed
        // from it. Such a tree has no `git ls-files` and no rail, and the
        // nearest package is the only anchor it has, so a package planted
        // beside a copy re-roots the copy there: the export's behaviour,
        // pinned so that a change to it is deliberate.
        try Data().write(to: base.appendingPathComponent("repo/Package.swift"))
        XCTAssertEqual(Leaderboard.checkoutRoot(of: declared.path)?.path, repo)
        XCTAssertNil(Leaderboard.gitRoot(of: declared.path))
        XCTAssertTrue(FormatFixture.isRepoPath(declared.path))
        try Data().write(to: base.appendingPathComponent("repo/docs/eval/nested/Package.swift"))
        XCTAssertEqual(Leaderboard.checkoutRoot(of: nested.path)?.path, nestedDir)
        XCTAssertTrue(FormatFixture.isRepoPath(nested.path))
        // A `.git` file pointing at nothing is no repository to git, which
        // lists the files beside it as plain files, and no git checkout
        // here: the checkout root is still the anchor.
        try Data("gitdir: elsewhere\n".utf8).write(to: base.appendingPathComponent("repo/.git"))
        XCTAssertNil(Leaderboard.gitRoot(of: declared.path))
        XCTAssertTrue(FormatFixture.isRepoPath(declared.path))
        // A worktree's `.git` is a file pointing at a repository, a
        // clone's a directory that is one; either is the checkout, and
        // inside one the anchor is git's: the planted package (a commit
        // can carry one) is a nearer checkout to the refusals and nothing
        // to the routing, so docs/eval/nested/docs/eval/formatting.json is
        // at an undeclared path of the real root, the eval lint reads it,
        // and the declared file is unaffected.
        try Data("gitdir: ../main/.git\n".utf8).write(to: base.appendingPathComponent("repo/.git"))
        XCTAssertEqual(Leaderboard.gitRoot(of: declared.path)?.path, repo)
        XCTAssertTrue(FormatFixture.isRepoPath(declared.path))
        XCTAssertEqual(Leaderboard.checkoutRoot(of: nested.path)?.path, nestedDir)
        XCTAssertEqual(Leaderboard.gitRoot(of: nested.path)?.path, repo)
        XCTAssertFalse(FormatFixture.isRepoPath(nested.path))
        // Compared as a path, not as a string.
        XCTAssertTrue(FormatFixture.isRepoPath(base.appendingPathComponent("repo/docs/../docs/eval/formatting.json").path))
        // The declared name in another directory, another name in the
        // declared directory, or no checkout at all: the eval lint reads
        // these, so an undeclared format file fails loudly and an eval file
        // dropped beside the declared one is never exempted.
        XCTAssertFalse(FormatFixture.isRepoPath(otherName.path))
        XCTAssertFalse(FormatFixture.isRepoPath(otherDir.path))
        XCTAssertFalse(FormatFixture.isRepoPath(noCheckout.path))
        XCTAssertNil(Leaderboard.gitRoot(of: noCheckout.path))
        XCTAssertNil(Leaderboard.checkoutRoot(of: noCheckout.path))
        // A `.git` directory made by hand — no `HEAD`, `objects`, `refs` —
        // is no repository to git, which lists the files under it, and no
        // root to the routing: the checkout is still the one above.
        let nestedGit = base.appendingPathComponent("repo/docs/eval/nested/.git")
        try FileManager.default.createDirectory(at: nestedGit, withIntermediateDirectories: true)
        XCTAssertEqual(Leaderboard.gitRoot(of: nested.path)?.path, repo)
        XCTAssertFalse(FormatFixture.isRepoPath(nested.path))
        // Nor is one with `objects` and `refs` but a `HEAD` git cannot
        // read, nor a `.git` file pointing at nothing: git lists the files
        // under either as plain files of the checkout above, and the copy
        // is still at an undeclared path of it.
        for entry in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: nestedGit.appendingPathComponent(entry), withIntermediateDirectories: true)
        }
        try Data().write(to: nestedGit.appendingPathComponent("HEAD"))
        XCTAssertEqual(Leaderboard.gitRoot(of: nested.path)?.path, repo)
        XCTAssertFalse(FormatFixture.isRepoPath(nested.path))
        try FileManager.default.removeItem(at: nestedGit)
        try Data("gitdir: nowhere\n".utf8).write(to: nestedGit)
        XCTAssertEqual(Leaderboard.gitRoot(of: nested.path)?.path, repo)
        XCTAssertFalse(FormatFixture.isRepoPath(nested.path))
        // One git takes for a repository — a file pointing at one, or a
        // directory with a `HEAD` it can read — is a nested repository:
        // its own checkout, whose files the outer one never tracks or
        // lists, so the rail never sees them — and within it, that file is
        // the declared path. The outer file is unmoved either way.
        try Data("gitdir: ../../../../main/.git\n".utf8).write(to: nestedGit)
        XCTAssertEqual(Leaderboard.gitRoot(of: nested.path)?.path, nestedDir)
        XCTAssertTrue(FormatFixture.isRepoPath(nested.path))
        try FileManager.default.removeItem(at: nestedGit)
        for entry in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: nestedGit.appendingPathComponent(entry), withIntermediateDirectories: true)
        }
        try Data("ref: refs/heads/main\n".utf8).write(to: nestedGit.appendingPathComponent("HEAD"))
        XCTAssertEqual(Leaderboard.gitRoot(of: nested.path)?.path, nestedDir)
        XCTAssertTrue(FormatFixture.isRepoPath(nested.path))
        XCTAssertTrue(FormatFixture.isRepoPath(declared.path))
    }
}
