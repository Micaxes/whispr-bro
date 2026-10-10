import Foundation

/// The leaderboard (plan §5): one `EvalRun.LeaderboardRow` per column per
/// run, one JSON object per line, written by appending — rows accumulate,
/// but exactly one baseline row per (formatter, fixtures, scoring version)
/// survives in a file, a regeneration replacing the ones it supersedes in
/// the same commit (docs §3). Reading, the "previous
/// comparable row" lookup a Δ is allowed against, the `--diff` refusal
/// (two rows scored on different fixtures or under a different scoring
/// version are not comparable, whatever their run keys), the text table,
/// and the two guards that keep his history out of the repo: the
/// repo-tree test behind `--append`'s refusal, and the model-manifest
/// reader that turns `scripts/models-llm.sha256` into `model_sha256`.
public enum Leaderboard {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// `--diff` across rows whose fixture set or scoring version differ.
        case incomparable(String)
        case unknownRunKey(String)
        case malformedLine(Int)

        public var description: String {
            switch self {
            case .incomparable(let why): return "not comparable: \(why)"
            case .unknownRunKey(let key): return "no leaderboard row has run_key \(key)"
            case .malformedLine(let n): return "leaderboard line \(n) is not a row"
            }
        }
    }

    // MARK: - Reading

    /// Parses JSONL; blank lines are skipped, a malformed line names its
    /// number (a half-written append must not read as a clean file).
    public static func load(_ data: Data) throws -> [EvalRun.LeaderboardRow] {
        let decoder = JSONDecoder()
        var rows: [EvalRun.LeaderboardRow] = []
        for (index, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let row = try? decoder.decode(EvalRun.LeaderboardRow.self, from: Data(trimmed.utf8)) else {
                throw Error.malformedLine(index + 1)
            }
            rows.append(row)
        }
        return rows
    }

    /// The most recent row a Δ may be printed against: same comparability
    /// tuple (formatter, model, prompt, fixtures, level, scoring version)
    /// — `git_sha` free, so the Δ reads as "what this commit changed".
    public static func previousComparable(to row: EvalRun.LeaderboardRow,
                                          in rows: [EvalRun.LeaderboardRow]) -> EvalRun.LeaderboardRow? {
        rows.last { $0.comparabilityKey == row.comparabilityKey }
    }

    /// The latest row with `runKey` (a key re-run on another day appends
    /// another line; the newest is the one he means).
    public static func row(runKey: String, in rows: [EvalRun.LeaderboardRow]) throws -> EvalRun.LeaderboardRow {
        guard let row = rows.last(where: { $0.runKey == runKey }) else { throw Error.unknownRunKey(runKey) }
        return row
    }

    // MARK: - Δ

    /// B minus A, field by field.
    public struct Delta: Sendable, Equatable {
        public let a: EvalRun.LeaderboardRow
        public let b: EvalRun.LeaderboardRow
        public let c: Double?
        public let f: Double?
        public let fi: Double?
        public let m: Double?
        /// Verdict → (a, b) counts, every verdict name.
        public let verdicts: [(name: String, a: Int, b: Int)]
        public let p50: Int?
        public let p90: Int?
        public let p99: Int?

        public static func == (lhs: Delta, rhs: Delta) -> Bool {
            lhs.a == rhs.a && lhs.b == rhs.b
        }
    }

    /// Refuses rows that are not the same measurement: a different fixture
    /// set or scoring version makes every number below incomparable.
    public static func diff(_ a: EvalRun.LeaderboardRow, _ b: EvalRun.LeaderboardRow) throws -> Delta {
        guard a.fixtures.sha256 == b.fixtures.sha256 else {
            throw Error.incomparable("fixtures.sha256 differ (\(a.fixtures.name) \(a.fixtures.sha256.prefix(12)) vs \(b.fixtures.name) \(b.fixtures.sha256.prefix(12)))")
        }
        guard a.scoringVersion == b.scoringVersion else {
            throw Error.incomparable("scoring_version differ (\(a.scoringVersion) vs \(b.scoringVersion)); re-score the older run")
        }
        func minus(_ x: Double?, _ y: Double?) -> Double? {
            guard let x, let y else { return nil }
            return EvalRun.round(y - x, places: 1)
        }
        let names = EvalVerdict.allCases.map(\.rawValue)
        return Delta(a: a, b: b,
                     c: minus(a.scores.c, b.scores.c), f: minus(a.scores.f, b.scores.f),
                     fi: minus(a.scores.fi, b.scores.fi), m: minus(a.scores.m, b.scores.m),
                     verdicts: names.map { ($0, a.verdicts[$0] ?? 0, b.verdicts[$0] ?? 0) },
                     p50: zip(a.latencyMs?.p50, b.latencyMs?.p50).map { $1 - $0 },
                     p90: zip(a.latencyMs?.p90, b.latencyMs?.p90).map { $1 - $0 },
                     p99: zip(a.latencyMs?.p99, b.latencyMs?.p99).map { $1 - $0 })
    }

    private static func zip<T>(_ a: T?, _ b: T?) -> (T, T)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    // MARK: - Rendering

    /// Signed number for a Δ column: `+2.3`, `-0.4`, `0`, or `—`.
    public static func signed(_ x: Double?) -> String {
        guard let x else { return "—" }
        if x == 0 { return "0" }
        return String(format: "%+.1f", x)
    }

    public static func signed(_ x: Int?) -> String {
        guard let x else { return "—" }
        return x == 0 ? "0" : String(format: "%+d", x)
    }

    /// The line `whispr-bench leaderboard --ratings …` prints above the
    /// table: the live rated count and whether a calibration record calls
    /// the set valid, plus how many rows in the FILE were written under a
    /// valid one. A row's own `calibrated` flag is history — it says what
    /// was true when the row was appended — so the two are printed side by
    /// side rather than one overwriting the other.
    public static func banner(_ rows: [EvalRun.LeaderboardRow], calibration: Calibration.Live) -> String {
        let calibrated = rows.filter(\.calibrated).count
        var line = calibration.banner + " · \(calibrated)/\(rows.count) row(s) written calibrated"
        if !calibration.zeroEditRates.isEmpty {
            line += " · zero-edit " + calibration.zeroEditRates.keys.sorted()
                .map { String(format: "%@ %.1f%%", $0, calibration.zeroEditRates[$0]!) }
                .joined(separator: " · ")
        }
        return line
    }

    /// The table `whispr-bench leaderboard` prints: file order, or with
    /// `top` the N highest composites (ties to the newer row) — a
    /// leaderboard ranks, the file only appends.
    public static func table(_ rows: [EvalRun.LeaderboardRow], top: Int? = nil) -> String {
        var shown = Array(rows.enumerated())
        if let top {
            shown = shown.sorted {
                let a = $0.element.scores.c ?? -1, b = $1.element.scores.c ?? -1
                return a != b ? a > b : $0.offset > $1.offset
            }
            shown = Array(shown.prefix(max(0, top)))
        }
        var lines = ["date              sha      formatter   model          level     fixtures         C      F      Fi     M      status  p50    p99    run_key       label"]
        for (_, r) in shown {
            let fixtures = "\(r.fixtures.name) n=\(r.fixtures.n)" + (r.fixtures.ratedN < r.fixtures.n ? " rated=\(r.fixtures.ratedN)" : "")
            lines.append([
                pad(String(r.date.prefix(16)), 17), pad(r.gitSha + (r.dirty ? "*" : ""), 8),
                pad(r.formatter, 11), pad(r.modelKey ?? "—", 14), pad(r.level, 9), pad(fixtures, 16),
                pad(score(r.scores.c), 6), pad(score(r.scores.f), 6), pad(score(r.scores.fi), 6), pad(score(r.scores.m), 6),
                pad(r.gate.status.rawValue, 7),
                pad(r.latencyMs?.p50.map(String.init) ?? "—", 6), pad(r.latencyMs?.p99.map(String.init) ?? "—", 6),
                pad(r.runKey, 13), [r.label, r.selfRepair == false ? "[self-repair off]" : nil]
                    .compactMap { $0 }.joined(separator: " "),
            ].joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    public static func render(_ d: Delta) -> String {
        var lines: [String] = []
        lines.append("diff  \(d.a.runKey) (\(d.a.gitSha) \(d.a.date.prefix(10)))  →  \(d.b.runKey) (\(d.b.gitSha) \(d.b.date.prefix(10)))")
        lines.append("      \(d.b.formatter) · \(d.b.modelKey ?? "—") · level \(d.b.level)"
                     + (d.b.selfRepair == false ? " · self-repair off" : "")
                     + " · fixtures \(d.b.fixtures.name) n=\(d.b.fixtures.n) · scoring v\(d.b.scoringVersion)")
        lines.append("scores    C \(score(d.a.scores.c)) → \(score(d.b.scores.c)) (\(signed(d.c)))"
                     + " · F \(score(d.a.scores.f)) → \(score(d.b.scores.f)) (\(signed(d.f)))"
                     + " · Fi \(score(d.a.scores.fi)) → \(score(d.b.scores.fi)) (\(signed(d.fi)))"
                     + " · M \(score(d.a.scores.m)) → \(score(d.b.scores.m)) (\(signed(d.m)))")
        lines.append("status    \(d.a.gate.status.rawValue) → \(d.b.gate.status.rawValue)")
        let moved = d.verdicts.filter { $0.a != $0.b }
        lines.append("verdicts  " + (moved.isEmpty ? "unchanged"
                                     : moved.map { "\($0.name) \($0.a) → \($0.b)" }.joined(separator: " · ")))
        if d.a.latencyMs != nil || d.b.latencyMs != nil {
            lines.append("latency   p50 \(signed(d.p50)) · p90 \(signed(d.p90)) · p99 \(signed(d.p99)) ms")
        }
        return lines.joined(separator: "\n")
    }

    static func score(_ x: Double?) -> String {
        x.map { String(format: "%.1f", $0) } ?? "—"
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - Guards

    /// True when `path` sits under a source checkout: any ancestor holds a
    /// `Package.swift` or a `.git`. `--append` refuses such a path for any
    /// fixture set but the seeds — the only leaderboard that belongs in
    /// the repo is the public one (§3.3 belt and braces).
    public static func isInsideRepoTree(_ path: String, fileManager: FileManager = .default) -> Bool {
        checkoutRoot(of: path, fileManager: fileManager) != nil
    }

    /// The checkout `path` sits in: its nearest ancestor directory holding
    /// `Package.swift` or `.git`, nil outside one. The one definition of
    /// "inside a checkout" for the refusals above — the wider net on
    /// purpose, so a package copied or unpacked without its `.git` is
    /// refused too. `FormatFixture.isRepoPath` walks `gitRoot` first and
    /// this only where no ancestor is a git repository at all.
    public static func checkoutRoot(of path: String, fileManager: FileManager = .default) -> URL? {
        nearestAncestor(of: path) { dir in
            ["Package.swift", ".git"].contains { fileManager.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    /// The git checkout `path` sits in: its nearest ancestor directory
    /// holding a `.git` that passes git's own test (`isGitRepository`),
    /// nil outside one. Narrower than `checkoutRoot`
    /// on purpose, for the one caller that routes on it rather than
    /// refuses on it (`FormatFixture.isRepoPath`): `.git` is the marker
    /// nothing in the tree can plant — git refuses the path component in
    /// an index and in a tree it reads — where a `Package.swift` committed
    /// under `docs/` would make a nearer "checkout" and move a declared
    /// path under it. Reading a `.git` with git's test means that, for the
    /// shapes git makes, a nested one is a nested repository, whose files
    /// `git ls-files` never lists, and one git does not take for a
    /// repository — a directory made by hand or with a `HEAD` it cannot
    /// read, a `gitdir:` file pointing at nothing — is a plain entry of the
    /// checkout above to both. Hand-made shapes can still differ (e.g. a
    /// `gitdir:` or `commondir` reached through a symlink and `..`,
    /// resolved here lexically; an unreadable gitfile or `commondir`; a
    /// repository initialised over files the outer checkout tracks).
    public static func gitRoot(of path: String, fileManager: FileManager = .default) -> URL? {
        nearestAncestor(of: path) { dir in
            isGitRepository(dir.appendingPathComponent(".git"), fileManager: fileManager)
        }
    }

    /// Whether `dotGit` passes git's test for a repository when git walks
    /// a tree (setup.c's `is_nonbare_repository_dir`, which decides what
    /// `git ls-files` lists and what it leaves to a nested repository): a
    /// directory `isGitDirectory` accepts, or a gitfile — a worktree's, a
    /// submodule's — whose `gitdir:` target is one. It follows git for the
    /// shapes git makes; see `gitRoot` for the hand-made ones it does not.
    static func isGitRepository(_ dotGit: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return isGitDirectory(dotGit, fileManager: fileManager) }
        guard let target = gitfileTarget(dotGit) else { return false }
        return isGitDirectory(target, fileManager: fileManager)
    }

    /// setup.c's `is_git_directory`: `HEAD` passes `validate_headref`, and
    /// `objects` and `refs` are searchable (`access(X_OK)`, as git tests
    /// them) in the common directory — the one `commondir` names, for a
    /// worktree's gitdir, which keeps a `HEAD` of its own and shares the
    /// rest; the directory itself otherwise.
    static func isGitDirectory(_ dir: URL, fileManager: FileManager) -> Bool {
        guard isValidHeadRef(dir.appendingPathComponent("HEAD"), fileManager: fileManager) else { return false }
        let common = commonDirectory(of: dir)
        return ["objects", "refs"].allSatisfy { fileManager.isExecutableFile(atPath: common.appendingPathComponent($0).path) }
    }

    /// path.c's `validate_headref`: a symlink whose text starts `refs/`,
    /// or a file whose first 255 bytes begin `ref:`, git's whitespace and
    /// `refs/` (a symbolic ref) or with an object id in hex (a detached
    /// head; 40 digits is the shortest git checks, so 64 passes too). An
    /// empty `HEAD` is neither.
    static func isValidHeadRef(_ head: URL, fileManager: FileManager) -> Bool {
        if let link = try? fileManager.destinationOfSymbolicLink(atPath: head.path) { return link.hasPrefix("refs/") }
        guard let data = try? Data(contentsOf: head) else { return false }
        let bytes = Array(data.prefix(255))
        if bytes.starts(with: Array("ref:".utf8)) {
            let refname = bytes.dropFirst(4).drop { [0x20, 0x09, 0x0a, 0x0d].contains($0) }
            if refname.starts(with: Array("refs/".utf8)) { return true }
        }
        let hex = Set("0123456789abcdefABCDEF".utf8)
        return bytes.count >= 40 && bytes.prefix(40).allSatisfy(hex.contains)
    }

    /// setup.c's `get_common_dir`: the directory `commondir` in `gitdir`
    /// names — a worktree's points back at the main repository's `.git`,
    /// relative to `gitdir` unless absolute — and `gitdir` itself when
    /// there is no such file.
    static func commonDirectory(of gitdir: URL) -> URL {
        guard let data = try? Data(contentsOf: gitdir.appendingPathComponent("commondir")) else { return gitdir }
        var bytes = Array(data)
        while let last = bytes.last, last == 0x0a || last == 0x0d { bytes.removeLast() }
        guard let path = String(bytes: bytes, encoding: .utf8), !path.isEmpty else { return gitdir }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitdir.appendingPathComponent(path)).standardizedFileURL
    }

    /// setup.c's `read_gitfile`: a regular file of at most a mebibyte that
    /// begins `gitdir: `, the rest — trailing newlines dropped — a path,
    /// taken relative to the file's own directory when it is not absolute.
    /// Nil for anything else; whether the target is a repository is the
    /// caller's question.
    static func gitfileTarget(_ file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file), data.count <= 1 << 20 else { return nil }
        var bytes = Array(data)
        guard bytes.starts(with: Array("gitdir: ".utf8)) else { return nil }
        while let last = bytes.last, last == 0x0a || last == 0x0d { bytes.removeLast() }
        guard bytes.count > 8, let path = String(bytes: bytes[8...], encoding: .utf8) else { return nil }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : file.deletingLastPathComponent().appendingPathComponent(path))
            .standardizedFileURL
    }

    /// The nearest ancestor directory of `path` that `marks` says is a root.
    private static func nearestAncestor(of path: String, where marks: (URL) -> Bool) -> URL? {
        var url = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        while true {
            if marks(url) { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// `--append`'s refusal (§3.3): a leaderboard inside a checkout may
    /// hold the seeds' rows and nothing else — a personal set's rows carry
    /// no text, but their existence in the public file is a leak of what
    /// he measured.
    public static func refusesAppend(path: String, fixtureSetIsSeeds: Bool,
                                     fileManager: FileManager = .default) -> Bool {
        !fixtureSetIsSeeds && isInsideRepoTree(path, fileManager: fileManager)
    }

    /// `--json` / `--report`'s refusal: a run file stores every row's raw
    /// text and output verbatim, so when any fixture carries what only an
    /// export writes (`EvalLint.carriesExportFields`: a `history:` source
    /// or a shipped output) neither file may land inside a checkout —
    /// the same test the repo guard applies to a fixtures file. Seeds and
    /// hand-written synthetic sets are free to.
    public static func refusesRunOutput(path: String, cases: [EvalCase],
                                        fileManager: FileManager = .default) -> Bool {
        cases.contains(where: EvalLint.carriesExportFields) && isInsideRepoTree(path, fileManager: fileManager)
    }

    /// `scripts/models-llm.sha256` lines are `<hex>  <relative path>`
    /// (shasum format); the digest for `relativePath`, nil when absent.
    public static func modelSha256(manifest: String, relativePath: String) -> String? {
        for line in manifest.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1] == Substring(relativePath) else { continue }
            let hex = String(parts[0])
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { continue }
            return hex.lowercased()
        }
        return nil
    }
}
