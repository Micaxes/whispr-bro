import Foundation

/// One `whispr-bench format` fixture (docs/formatting-benchmark.md): a
/// dictation and the one string the shipping path must turn it into. The
/// bench's `FormatBench` runs them; this lives in Core so `FormatLint` and
/// XCTest can read the same type the bench decodes.
///
/// Not an `EvalCase`. An eval gold is scored by `QualityScore`, whose L1
/// gate refuses added lines and markdown — exactly the layout these golds
/// exist to pin — so the two kinds of fixtures file are told apart before
/// either lint runs, by `repoPaths` below, never by what their rows look
/// like.
public struct FormatFixture: Decodable, Sendable, Equatable {
    public let id: String
    public let raw: String
    public let gold: String
    /// The per-tag table and the control check key off these; a fixture
    /// carries at least one so a regression names the feature it broke.
    public let tags: [String]
    /// An `AppCategory` raw value; nil runs the fixture as `.unknown`.
    public let register: String?
    /// `inferringPolicy` opts this fixture into inferred numbered lists,
    /// which no register enables by default (see `SpokenStructure.Policy`).
    public let policy: String?
    /// This dictation contains no layout instruction, so nothing may
    /// restructure it — checked on every run, independently of whether its
    /// gold matches.
    public let mustNotRestructure: Bool?
    /// The fields only a history export writes (`EvalCase.source`,
    /// `observed`, `observed_ms`). The bench never reads them; they are
    /// decoded so the repo guard refuses them in a format file exactly as
    /// it does in an eval file.
    public let source: String?
    public let observed: String?
    public let observedMs: Int?

    enum CodingKeys: String, CodingKey {
        case id, raw, gold, tags, register, policy, mustNotRestructure, source, observed
        case observedMs = "observed_ms"
    }

    public init(id: String, raw: String, gold: String, tags: [String] = [], register: String? = nil,
                policy: String? = nil, mustNotRestructure: Bool? = nil, source: String? = nil,
                observed: String? = nil, observedMs: Int? = nil) {
        self.id = id
        self.raw = raw
        self.gold = gold
        self.tags = tags
        self.register = register
        self.policy = policy
        self.mustNotRestructure = mustNotRestructure
        self.source = source
        self.observed = observed
        self.observedMs = observedMs
    }

    /// The one `policy` value the bench reads; any other name would run
    /// the register's own policy silently, so `FormatLint` refuses it.
    public static let inferringPolicy = "inferring"

    /// The format-bench fixtures files a checkout carries, relative to its
    /// root. `whispr-bench format` runs them when given no path, and
    /// `whispr-bench lint` sends them to `FormatLint` instead of `EvalLint`
    /// — the one place that routing is declared. A new file is added here
    /// before it can pass CI: until it is, the eval lint reads it and its
    /// layout golds fail loudly rather than being waved through.
    public static let repoPaths = ["docs/eval/formatting.json"]

    /// Whether `path` is one of `repoPaths` of the checkout it sits in: the
    /// git checkout — the nearest ancestor holding a `.git` that passes
    /// git's own test for a repository (`Leaderboard.gitRoot`) — and, where
    /// no ancestor is one at all (an export, a tarball), the nearest
    /// `Package.swift` or `.git` the repo-tree refusals anchor on
    /// (`Leaderboard.checkoutRoot`). A copy of the file anywhere else, or
    /// an eval file dropped beside it, is not: the routing reads the path,
    /// never the rows.
    ///
    /// Inside a git repository the anchor is git's, not the `Package.swift`
    /// the refusals also accept, because this walk exempts a file from the
    /// eval invariant where those only refuse a path: a `Package.swift`
    /// committed under `docs/eval/x/` would make that directory the
    /// nearest "checkout" and `docs/eval/x/docs/eval/formatting.json` its
    /// declared path — a file at an undeclared path waved through. A
    /// `.git` cannot be committed: git refuses the path component in an
    /// index and in any tree it reads back. And the walk reads a `.git`
    /// with git's own test, so for the shapes git makes (a clone's
    /// directory, a worktree's or a submodule's gitfile) one on disk is a
    /// nested repository — its own checkout, whose files `git ls-files`
    /// never lists, so none of them reaches the rail — and one git does
    /// not recognise is a plain entry of the checkout above, as it is to
    /// git. Hand-made shapes can still differ on a local disk (e.g. a
    /// `gitdir:` or `commondir` reached through a symlink and `..`, an
    /// unreadable gitfile or `commondir`, a repository initialised over
    /// tracked files); none can be committed. Outside any git repository
    /// the rail does not run (it needs `git ls-files`), and the nearest
    /// checkout marker is the only anchor there is.
    public static func isRepoPath(_ path: String, fileManager: FileManager = .default) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard let root = Leaderboard.gitRoot(of: file.path, fileManager: fileManager)
                ?? Leaderboard.checkoutRoot(of: file.path, fileManager: fileManager) else { return false }
        return repoPaths.contains { root.appendingPathComponent($0).standardizedFileURL.path == file.path }
    }

    /// A fixtures file: a JSON array of fixtures, as the bench reads it.
    public static func decode(_ data: Data) throws -> [FormatFixture] {
        try JSONDecoder().decode([FormatFixture].self, from: data)
    }
}
