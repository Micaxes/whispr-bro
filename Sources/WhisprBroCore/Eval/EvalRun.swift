import Foundation
import CryptoKit

/// One `whispr-bench eval` run (plan §5, §6.2): the fixture-set identity,
/// one `Column` per formatter, and inside each column the aggregates the
/// terminal and the leaderboard read — macro composite, per-axis means,
/// verdict histogram, the run-status gate, fallback provenance, latency
/// percentiles — plus every row's OUTPUT, so a `scoringVersion` bump can
/// re-grade a stored run with `whispr-bench score` and no model.
///
/// Codable in Core so tests round-trip it. `canonicalJSON` sorts keys and
/// omits nothing but nil fields, so two runs of the same outputs encode
/// byte-identical except for `date` — the reproducibility contract the
/// leaderboard's `run_key` rests on. JSON keys are snake_case; the four
/// axis scores keep their one-letter names (`F`, `Fi`, `M`, `C`).
public struct EvalRun: Codable, Sendable, Equatable {
    /// Bumped when the JSON shape changes. 3: rows carry `lost` (§4.4's D,
    /// what M and the verdict charge) beside the alignment's `D`; latency
    /// percentiles are absent when no timed row exists, and `n_llm` counts
    /// the rows they are over.
    public static let schema = 3
    /// Bumped when any formula or threshold in `EvalThresholds` /
    /// `QualityScore` changes; stored runs are re-graded under the new one.
    /// 2: Fi survival is read off the out window between the neighbours'
    /// paired positions, not off the span's own ops (the diagonal
    /// tie-break made a clean removal beside an appended word read as a
    /// substitution).
    /// 3: Fi credits per span inside a shared window — two expected
    /// removals of one form between the same neighbours ("um um") were
    /// both missed under 2 when either survived; now one of two is 50.
    /// 4: that window's expectation follows each span's PROVENANCE — the
    /// gold for a derived span (never the members' `keep`s summed, which
    /// read the gold's own copy of a restart as a deficit), the annotation
    /// for an explicit one — and a gold-free row, having no gold to read,
    /// gives every span its own entitlement, so a shortfall charges the
    /// spans it leaves short instead of the whole group.
    public static let scoringVersion = 4

    public var schema: Int
    /// `<date>-<git_sha>-<fixtures name>`, the run file's stem.
    public var runId: String
    /// ISO-8601, the ONE non-reproducible field.
    public var date: String
    public var gitSha: String
    public var dirty: Bool
    public var machine: Machine
    public var scoringVersion: Int
    public var fixtures: Fixtures
    public var columns: [Column]

    enum CodingKeys: String, CodingKey {
        case schema, date, dirty, machine, fixtures, columns
        case runId = "run_id"
        case gitSha = "git_sha"
        case scoringVersion = "scoring_version"
    }

    public init(runId: String, date: String, gitSha: String, dirty: Bool, machine: Machine,
                fixtures: Fixtures, columns: [Column]) {
        self.schema = EvalRun.schema
        self.runId = runId
        self.date = date
        self.gitSha = gitSha
        self.dirty = dirty
        self.machine = machine
        self.scoringVersion = EvalRun.scoringVersion
        self.fixtures = fixtures
        self.columns = columns
    }

    /// Worst column status — the process exit code's input.
    public var status: Status {
        columns.map(\.gate.status).min(by: { $0.rank < $1.rank }) ?? .pass
    }

    // MARK: - Nested records

    public struct Machine: Codable, Sendable, Equatable {
        public var model: String
        public var os: String
        public init(model: String, os: String) { self.model = model; self.os = os }
    }

    /// Fixture-set identity and the rated / draft / unrated split
    /// (dispatcher decision D1: drafts are scored but never counted as
    /// rated; `rated_n` is what a calibration claim can stand on).
    public struct Fixtures: Codable, Sendable, Equatable {
        public var path: String
        public var name: String
        public var sha256: String
        public var n: Int
        /// Gold present and `annotations_status: confirmed`.
        public var ratedN: Int
        /// Gold present and `annotations_status: draft`.
        public var draftN: Int
        /// Gold-free (`gold: ""`).
        public var unratedN: Int

        enum CodingKeys: String, CodingKey {
            case path, name, sha256, n
            case ratedN = "rated_n"
            case draftN = "draft_n"
            case unratedN = "unrated_n"
        }

        public init(path: String, name: String, sha256: String, cases: [EvalCase]) {
            self.path = path
            self.name = name
            self.sha256 = sha256
            n = cases.count
            unratedN = cases.filter(\.isGoldFree).count
            draftN = cases.filter { !$0.isGoldFree && $0.isDraft }.count
            ratedN = n - unratedN - draftN
        }

        /// Hashes `cases` with `EvalCase.fixtureSetHash`.
        public init(path: String, name: String, cases: [EvalCase]) throws {
            self.init(path: path, name: name, sha256: try EvalCase.fixtureSetHash(cases), cases: cases)
        }
    }

    /// Run status (§5), worst first: INVALID (the harness is broken — a
    /// model row silently measured rules) > FAIL (a gated verdict or the
    /// controls moved) > WARN (latency) > PASS.
    public enum Status: String, Codable, Sendable, CaseIterable {
        case invalid = "INVALID"
        case fail = "FAIL"
        case warn = "WARN"
        case pass = "PASS"

        public var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
        public func isWorse(than other: Status) -> Bool { rank < other.rank }

        /// §6.4: `0` PASS or WARN (`3` for WARN with `--strict-latency`),
        /// `1` INVALID, `2` FAIL.
        public func exitCode(strictLatency: Bool) -> Int32 {
            switch self {
            case .pass: return 0
            case .warn: return strictLatency ? 3 : 0
            case .invalid: return 1
            case .fail: return 2
            }
        }
    }

    /// Macro means over the gold-scored rows (each fixture weighs 1); nil
    /// when a column has none (a personal set before its first rating).
    /// `Fi` averages every row with a defined Fi, gold-free rows included —
    /// the stripper's contract needs no gold.
    public struct Scores: Codable, Sendable, Equatable {
        public var f: Double?
        public var fi: Double?
        public var m: Double?
        public var c: Double?

        enum CodingKeys: String, CodingKey {
            case f = "F", fi = "Fi", m = "M", c = "C"
        }

        public init(f: Double?, fi: Double?, m: Double?, c: Double?) {
            self.f = f; self.fi = fi; self.m = m; self.c = c
        }
    }

    /// The continuity line: `TranscriptScore.aggregate` (micro, raw counts
    /// summed) over the gold-scored rows.
    public struct Micro: Codable, Sendable, Equatable {
        public var wer: Double
        public var punctF1: Double
        public var caseAccuracy: Double

        enum CodingKeys: String, CodingKey {
            case wer
            case punctF1 = "punct_f1"
            case caseAccuracy = "case"
        }

        public init(wer: Double, punctF1: Double, caseAccuracy: Double) {
            self.wer = wer; self.punctF1 = punctF1; self.caseAccuracy = caseAccuracy
        }
    }

    /// The §5 status ladder's inputs and its answer.
    public struct Gate: Codable, Sendable, Equatable {
        public var status: Status
        public var answered: Int
        public var invented: Int
        public var negated: Int
        /// OVER_EDIT_FACT verdicts among the gold-scored rows.
        public var overEditFact: Int
        /// Control fixtures scored, and how many the formatter left
        /// word-for-word alone (S + D + I = 0 vs gold).
        public var controls: Int
        public var controlsUnchanged: Int
        /// nil when the set has no controls (the gate cannot fail on them).
        public var controlsUnchangedPct: Double?
        /// p99 over the ≤ 60-word LLM-path rows exceeded the budget.
        public var latencyOverBudget: Bool

        enum CodingKeys: String, CodingKey {
            case status, answered, invented, negated, controls
            case overEditFact = "over_edit_fact"
            case controlsUnchanged = "controls_unchanged"
            case controlsUnchangedPct = "controls_unchanged_pct"
            case latencyOverBudget = "latency_over_budget"
        }
    }

    /// Per-column fallback provenance (`FormatterSource`). `unavailable` /
    /// `requestFailed` are harness failures (INVALID); `timedOut` and
    /// `rejected` (the output gate's `.implausible`, llama and FM stages
    /// alike) are real behaviour, scored as the text the user actually got.
    public struct Fallbacks: Codable, Sendable, Equatable {
        public var fastPath = 0
        public var tooLong = 0
        public var rawMode = 0
        public var timedOut = 0
        public var rejected = 0
        public var unavailable = 0
        public var requestFailed = 0

        public init() {}

        /// Tolerant decode: every counter defaults to 0 when absent, so a
        /// leaderboard row written before a reason existed still reads. Rows
        /// on disk outlive the enum — `tooLong` was added after the 2026-09-16
        /// baseline and must not invalidate it.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fastPath = try c.decodeIfPresent(Int.self, forKey: .fastPath) ?? 0
            tooLong = try c.decodeIfPresent(Int.self, forKey: .tooLong) ?? 0
            rawMode = try c.decodeIfPresent(Int.self, forKey: .rawMode) ?? 0
            timedOut = try c.decodeIfPresent(Int.self, forKey: .timedOut) ?? 0
            rejected = try c.decodeIfPresent(Int.self, forKey: .rejected) ?? 0
            unavailable = try c.decodeIfPresent(Int.self, forKey: .unavailable) ?? 0
            requestFailed = try c.decodeIfPresent(Int.self, forKey: .requestFailed) ?? 0
        }

        public init(sources: [FormatterSource?]) {
            for case .fallback(let reason)? in sources {
                switch reason {
                case .fastPath: fastPath += 1
                case .tooLong: tooLong += 1
                case .rawMode: rawMode += 1
                case .timedOut: timedOut += 1
                case .implausible: rejected += 1
                case .unavailable: unavailable += 1
                case .requestFailed: requestFailed += 1
                }
            }
        }

        /// Rows that scored `ruleBasedCleanup` because the harness — not
        /// the design — failed; any → INVALID.
        public var harnessFailures: Int { unavailable + requestFailed }
    }

    /// Latency over the LLM-path rows (the model ran: `.model`,
    /// `timed-out`, `implausible`; fast-path and raw-mode rows are the
    /// stage's design and carry no model latency). For a column with a
    /// live model (`reprimeApplies`) the first row after each register/
    /// level switch pays a KV re-prime inside the measured window; it is
    /// excluded from every number here and listed in `reprime_ms`, so
    /// `n_llm`, the percentiles and `over_budget` are all over ONE
    /// population — the timed rows. Nearest-rank percentiles, as
    /// `whispr-bench latency`.
    public struct Latency: Codable, Sendable, Equatable {
        /// Rows in the percentiles (model-path rows minus the re-primes).
        public var nLlm: Int
        /// nil with no timed row (a one-fixture run whose only model row is
        /// its group's first) — never 0, so an empty sample cannot read as
        /// a fast column or an `ok` gate.
        public var p50: Int?
        public var p90: Int?
        public var p99: Int?
        public var max: Int?
        /// p99 over the ≤ `warnLatencyMaxWords`-word rows — the WARN
        /// gate's number (a 150-word prompt at 1.4 s is not the failure a
        /// 12-word one at 900 ms is). nil with no such row.
        public var p99Short: Int?
        public var budget: Int
        public var overBudget: Int
        /// Σ ms / Σ spoken words over the percentile rows.
        public var msPerWord: Double?
        public var reprimeMs: [Int]
        /// Length buckets by spoken words: `<=15`, `16-60`, `61-150`,
        /// `>150`; only buckets with rows are written.
        public var byLength: [String: Bucket]

        public struct Bucket: Codable, Sendable, Equatable {
            public var n: Int
            public var p50: Int
            public var p99: Int
        }

        enum CodingKeys: String, CodingKey {
            case p50, p90, p99, max, budget
            case nLlm = "n_llm"
            case p99Short = "p99_le60"
            case overBudget = "over_budget"
            case msPerWord = "ms_per_word"
            case reprimeMs = "reprime_ms"
            case byLength = "by_length"
        }

        /// Nearest-rank percentile (`q` in 0…1) over an unsorted sample.
        public static func percentile(_ xs: [Int], _ q: Double) -> Int {
            guard !xs.isEmpty else { return 0 }
            let sorted = xs.sorted()
            let rank = Int((q * Double(sorted.count)).rounded(.up))
            return sorted[Swift.min(Swift.max(rank, 1), sorted.count) - 1]
        }

        public static func bucket(words: Int) -> String {
            words <= 15 ? "<=15" : words <= 60 ? "16-60" : words <= 150 ? "61-150" : ">150"
        }

        /// - `samples`: (ms, spoken words, re-prime row) per LLM-path row.
        public init(samples: [(ms: Int, words: Int, reprime: Bool)], budget: Int) {
            let timed = samples.filter { !$0.reprime }
            let ms = timed.map(\.ms)
            nLlm = timed.count
            p50 = ms.isEmpty ? nil : Self.percentile(ms, 0.50)
            p90 = ms.isEmpty ? nil : Self.percentile(ms, 0.90)
            p99 = ms.isEmpty ? nil : Self.percentile(ms, 0.99)
            max = ms.max()
            let short = timed.filter { $0.words <= EvalThresholds.warnLatencyMaxWords }.map(\.ms)
            p99Short = short.isEmpty ? nil : Self.percentile(short, 0.99)
            self.budget = budget
            overBudget = ms.filter { $0 > budget }.count
            let words = timed.reduce(0) { $0 + $1.words }
            msPerWord = words == 0 ? nil : EvalRun.round(Double(ms.reduce(0, +)) / Double(words), places: 1)
            reprimeMs = samples.filter(\.reprime).map(\.ms)
            var buckets: [String: Bucket] = [:]
            for (key, rows) in Dictionary(grouping: timed, by: { Self.bucket(words: $0.words) }) {
                let xs = rows.map(\.ms)
                buckets[key] = Bucket(n: xs.count, p50: Self.percentile(xs, 0.50), p99: Self.percentile(xs, 0.99))
            }
            byLength = buckets
        }
    }

    /// Per-tag macro means over the gold-scored rows carrying the tag.
    public struct TagScores: Codable, Sendable, Equatable {
        public var c: Double?
        public var f: Double?
        public var fi: Double?
        public var m: Double?
        public var n: Int

        enum CodingKeys: String, CodingKey {
            case c = "C", f = "F", fi = "Fi", m = "M", n
        }
    }

    public struct Config: Codable, Sendable, Equatable {
        public var timeoutMs: Int
        public var budgetMs: Int
        public var label: String?
        /// `false` when the pre-pass ran without the self-repair rules
        /// (`--no-self-repair`); absent when they ran, as in every run made
        /// before the switch existed — so those files and their run keys
        /// are unchanged.
        public var selfRepair: Bool?

        enum CodingKeys: String, CodingKey {
            case label
            case timeoutMs = "timeout_ms"
            case budgetMs = "budget_ms"
            case selfRepair = "self_repair"
        }

        public init(timeoutMs: Int = EvalThresholds.defaultTimeoutMs,
                    budgetMs: Int = EvalThresholds.defaultBudgetMs, label: String? = nil,
                    selfRepair: Bool = true) {
            self.timeoutMs = timeoutMs
            self.budgetMs = budgetMs
            self.label = label
            self.selfRepair = selfRepair ? nil : false
        }

        /// Whether the run's pre-pass ran the self-repair rules.
        public var ranSelfRepair: Bool { selfRepair ?? true }
    }

    /// One formatter's pass over the fixture set.
    public struct Column: Codable, Sendable, Equatable {
        public var formatter: String
        public var modelKey: String?
        public var modelSha256: String?
        public var promptSha256: String?
        public var level: String
        public var config: Config
        public var runKey: String
        public var scores: Scores
        /// nil with no gold-scored row.
        public var micro: Micro?
        public var gate: Gate
        /// Every `EvalVerdict` → count (zeros included, so the histogram's
        /// columns line up across runs).
        public var verdicts: [String: Int]
        public var fallbacks: Fallbacks
        /// nil when no row carried a model latency (rules column).
        public var latencyMs: Latency?
        public var byTag: [String: TagScores]
        public var rows: [Row]

        enum CodingKeys: String, CodingKey {
            case formatter, level, config, scores, micro, gate, verdicts, fallbacks, rows
            case modelKey = "model_key"
            case modelSha256 = "model_sha256"
            case promptSha256 = "prompt_sha256"
            case runKey = "run_key"
            case latencyMs = "latency_ms"
            case byTag = "by_tag"
        }

        public var status: Status { gate.status }
    }

    /// One fixture's outcome under one formatter — the output itself plus
    /// every number the verdict rests on.
    public struct Row: Codable, Sendable, Equatable {
        public var id: String
        /// What the formatter was given (post-strip).
        public var stripped: String
        public var out: String
        /// `model`, a `FormatterFallbackReason` raw value, or the column's
        /// formatter name for a stage with no model (`rules`, `shipped`).
        public var source: String
        public var ms: Int?
        /// Measured over the on-device hang timeout — would have fallen
        /// back in production.
        public var wouldTimeout3s: Bool
        /// First row after a register/level switch; excluded from percentiles.
        public var reprime: Bool
        public var verdict: String
        /// Fired gate triggers by name (why a gated verdict fired).
        public var triggers: [String]
        public var f: Double?
        public var fi: Double?
        public var m: Double?
        public var c: Double?
        public var hits: Int
        public var subs: Int
        /// The gold↔out alignment's `.del` count.
        public var dels: Int
        /// §4.4's D: `dels` plus the `.sub`s whose gold word is gone and
        /// whose replacement is not novel (`QualityScore.Meaning.lost`) —
        /// what M and the verdict charge, so a row can explain its own
        /// OVER_EDIT_HEDGE. nil for a gold-free row.
        public var lost: Int?
        public var ins: Int
        public var novel: Int
        public var novelNumerals: Int
        public var droppedContent: Int
        public var ratio: Double
        public var missedMustKeep: [String]
        public var unresolvedRepairs: [String]
        public var cInitial: Double?
        /// Which of `acceptableGolds` scored best (0 = `gold`).
        public var goldIndex: Int
        /// `.implausible` rows (the output gate, either model stage): the
        /// verdict of the REJECTED pre-gate text, so the report reads
        /// "stage PASS, model ANSWERED".
        public var modelVerdict: String?
        public var rejected: String?

        enum CodingKeys: String, CodingKey {
            case id, stripped, out, source, ms, reprime, verdict, triggers, lost, novel, ratio, rejected
            case wouldTimeout3s = "would_timeout_3s"
            case f = "F", fi = "Fi", m = "M", c = "C"
            case hits = "H", subs = "S", dels = "D", ins = "I"
            case novelNumerals = "novel_numerals"
            case droppedContent = "dropped_content"
            case missedMustKeep = "missed_must_keep"
            case unresolvedRepairs = "unresolved_repairs"
            case cInitial = "c_initial"
            case goldIndex = "gold_index"
            case modelVerdict = "model_verdict"
        }
    }

    // MARK: - Building a column from scored rows

    /// What the bench collects per fixture before the column is aggregated.
    public struct Observation: Sendable {
        public var fixture: EvalCase
        public var stripped: String
        public var out: String
        /// nil for a stage with no model provenance — the rules column, and
        /// any row whose `ms` is not model time. The shipped column passes
        /// `.model` for the rows the production stage ran the model on
        /// (its `observed_ms` is real LLM time) and `.fallback(.fastPath)`
        /// for the short rows it did not, so only model latency reaches the
        /// percentiles and the WARN gate — and nil for a row whose
        /// provenance cannot be inferred (`EvalPlan.shippedSource(candidates:)`).
        public var source: FormatterSource?
        /// nil when the row was not timed.
        public var ms: Int?
        public var reprime: Bool
        public var rejected: String?
        public var score: QualityScore
        /// The rejected pre-gate text, scored.
        public var modelScore: QualityScore?

        public init(fixture: EvalCase, stripped: String, out: String, source: FormatterSource? = nil,
                    ms: Int? = nil, reprime: Bool = false, rejected: String? = nil,
                    score: QualityScore, modelScore: QualityScore? = nil) {
            self.fixture = fixture
            self.stripped = stripped
            self.out = out
            self.source = source
            self.ms = ms
            self.reprime = reprime
            self.rejected = rejected
            self.score = score
            self.modelScore = modelScore
        }

        /// The model ran (or was given the chance and timed out / was
        /// rejected): this row's latency is model latency. A row with no
        /// provenance never is — a timed rules row must not feed the WARN
        /// gate of a stage that has no model.
        public var isModelPath: Bool {
            switch source {
            case .model?, .fallback(.timedOut)?, .fallback(.implausible)?: return true
            case nil, .fallback?: return false
            }
        }
    }

    /// Formatters that run a live model in the bench process and so pay a
    /// KV re-prime on a register/level switch. The plan's `reprime` mark
    /// on the first row of each group applies to THEIR percentiles only:
    /// the shipped column's `observed_ms` was measured by the production
    /// binary at dictation time (there is no engine to re-prime) and the
    /// rules column has no model at all — every timed row of those counts.
    public static let liveModelFormatters: Set<String> = ["llama", "foundation"]

    public static func reprimeApplies(formatter: String) -> Bool {
        liveModelFormatters.contains(formatter)
    }
}

extension EvalRun.Column {
    /// Aggregates scored observations into a column (§5): macro means over
    /// gold-scored rows, the verdict histogram, the status ladder, fallback
    /// provenance, latency percentiles, per-tag means. Fixture order is
    /// irrelevant to every aggregate (rows keep the given order). The
    /// re-prime mark is honoured only for a formatter with a live model
    /// (`EvalRun.reprimeApplies`); on any other column it is dropped here,
    /// so the row and the percentiles agree whatever the caller passed.
    public static func make(formatter: String, modelKey: String? = nil, modelSha256: String? = nil,
                            promptSha256: String? = nil, level: String, config: EvalRun.Config,
                            runKey: String, observations: [EvalRun.Observation]) -> EvalRun.Column {
        let reprimes = EvalRun.reprimeApplies(formatter: formatter)
        let observations = observations.map { o -> EvalRun.Observation in
            var o = o
            o.reprime = o.reprime && reprimes
            return o
        }
        let scored = observations.filter { !$0.score.isGoldFree }

        func mean(_ xs: [Double]) -> Double? {
            xs.isEmpty ? nil : EvalRun.round(xs.reduce(0, +) / Double(xs.count), places: 1)
        }
        let scores = EvalRun.Scores(
            f: mean(scored.compactMap { $0.score.formatting?.score }),
            fi: mean(observations.compactMap { $0.score.fillers?.score }),
            m: mean(scored.compactMap { $0.score.meaning?.score }),
            c: mean(scored.compactMap(\.score.composite)))

        let micro: EvalRun.Micro? = scored.isEmpty ? nil : {
            let a = TranscriptScore.aggregate(scored.compactMap(\.score.continuity))
            return EvalRun.Micro(wer: EvalRun.round(a.wer, places: 3),
                                 punctF1: EvalRun.round(a.punctF1, places: 3),
                                 caseAccuracy: EvalRun.round(a.caseAccuracy, places: 3))
        }()

        var verdicts: [String: Int] = [:]
        for verdict in EvalVerdict.allCases { verdicts[verdict.rawValue] = 0 }
        for o in observations { verdicts[o.score.verdict.rawValue, default: 0] += 1 }

        let fallbacks = EvalRun.Fallbacks(sources: observations.map(\.source))

        let timed = observations.filter { $0.ms != nil && $0.isModelPath }
        let latency: EvalRun.Latency? = timed.isEmpty ? nil : EvalRun.Latency(
            samples: timed.map { (ms: $0.ms!, words: $0.fixture.wordCount, reprime: $0.reprime) },
            budget: config.budgetMs)

        var byTag: [String: EvalRun.TagScores] = [:]
        for tag in Set(scored.flatMap(\.fixture.tags)) {
            let rows = scored.filter { $0.fixture.tags.contains(tag) }
            byTag[tag] = EvalRun.TagScores(
                c: mean(rows.compactMap(\.score.composite)),
                f: mean(rows.compactMap { $0.score.formatting?.score }),
                fi: mean(rows.compactMap { $0.score.fillers?.score }),
                m: mean(rows.compactMap { $0.score.meaning?.score }),
                n: rows.count)
        }

        // The gate (§5). Gated verdicts count on every row (a gold-free
        // shipped row can be ANSWERED); the OVER_EDIT_FACT share and the
        // controls read the gold-scored rows.
        let controls = scored.filter(\.fixture.isControl)
        let unchanged = controls.filter { $0.score.wordEdits == 0 }.count
        let pct: Double? = controls.isEmpty ? nil
            : EvalRun.round(100 * Double(unchanged) / Double(controls.count), places: 1)
        let answered = observations.filter { $0.score.verdict == .answered }.count
        let invented = observations.filter { $0.score.verdict == .invented }.count
        let negated = observations.filter { $0.score.verdict == .negated }.count
        let overEditFact = scored.filter { $0.score.verdict == .overEditFact }.count
        let latencyOver = latency?.p99Short.map { $0 > config.budgetMs } ?? false
        let status: EvalRun.Status
        if fallbacks.harnessFailures > 0 {
            status = .invalid
        } else if answered > 0 || invented > 0 || negated > 0
                    || (!scored.isEmpty
                        && Double(overEditFact) / Double(scored.count) > EvalThresholds.failOverEditFactShare)
                    || (pct.map { $0 < EvalThresholds.failControlsUnchangedPct } ?? false) {
            status = .fail
        } else if latencyOver {
            status = .warn
        } else {
            status = .pass
        }
        let gate = EvalRun.Gate(status: status, answered: answered, invented: invented, negated: negated,
                                overEditFact: overEditFact, controls: controls.count,
                                controlsUnchanged: unchanged, controlsUnchangedPct: pct,
                                latencyOverBudget: latencyOver)

        let rows = observations.map { o -> EvalRun.Row in
            let q = o.score
            let source: String
            switch o.source {
            case nil: source = formatter
            case .model?: source = "model"
            case .fallback(let reason)?: source = reason.rawValue
            }
            return EvalRun.Row(
                id: o.fixture.id, stripped: o.stripped, out: o.out, source: source, ms: o.ms,
                wouldTimeout3s: o.ms.map { $0 > EvalThresholds.defaultTimeoutMs } ?? false,
                reprime: o.reprime, verdict: q.verdict.rawValue, triggers: q.triggerNames,
                f: q.formatting.map { EvalRun.round($0.score, places: 1) },
                fi: q.fillers.map { EvalRun.round($0.score, places: 1) },
                m: q.meaning.map { EvalRun.round($0.score, places: 1) },
                c: q.composite.map { EvalRun.round($0, places: 1) },
                hits: q.hits, subs: q.subs, dels: q.dels, lost: q.meaning?.lost, ins: q.ins,
                novel: q.contentGuard.novel.count, novelNumerals: q.contentGuard.novelNumerals,
                droppedContent: q.contentGuard.droppedContent.count,
                ratio: EvalRun.round(q.contentGuard.ratio, places: 3),
                missedMustKeep: q.meaning?.missedMustKeep.map(\.span) ?? [],
                unresolvedRepairs: q.meaning?.unresolvedRepairs ?? [],
                cInitial: q.formatting?.cInitial.map { EvalRun.round($0, places: 3) },
                goldIndex: q.goldIndex,
                modelVerdict: o.modelScore?.verdict.rawValue,
                rejected: o.rejected)
        }

        return EvalRun.Column(formatter: formatter, modelKey: modelKey, modelSha256: modelSha256,
                              promptSha256: promptSha256, level: level, config: config, runKey: runKey,
                              scores: scores, micro: micro, gate: gate, verdicts: verdicts,
                              fallbacks: fallbacks, latencyMs: latency, byTag: byTag, rows: rows)
    }
}

// MARK: - Leaderboard row

extension EvalRun {
    /// One append-only JSONL line (§5): the column minus its rows, with the
    /// run's identity beside it. `zero_edit_rate` is the share of SHIP he
    /// gave this column (§7.4's north star) and `calibrated` is true only
    /// when a `calibration.json` marked valid exists for this exact
    /// `fixtures.sha256` — both come from the rating loop, and both are
    /// false / nil without it.
    public struct LeaderboardRow: Codable, Sendable, Equatable {
        public var date: String
        public var gitSha: String
        public var dirty: Bool
        public var label: String?
        public var formatter: String
        public var modelKey: String?
        public var modelSha256: String?
        public var promptSha256: String?
        public var level: String
        public var fixtures: FixturesRef
        public var scoringVersion: Int
        public var runKey: String
        public var scores: Scores
        public var verdicts: [String: Int]
        public var gate: Gate
        public var fallbacks: Fallbacks
        public var latencyMs: Latency?
        public var zeroEditRate: Double?
        public var calibrated: Bool
        public var machine: Machine
        /// `false` for a run without the self-repair rules
        /// (`Config.selfRepair`); absent otherwise, as on every older row.
        public var selfRepair: Bool?

        public struct FixturesRef: Codable, Sendable, Equatable {
            public var name: String
            public var sha256: String
            public var n: Int
            public var ratedN: Int
            public var draftN: Int

            enum CodingKeys: String, CodingKey {
                case name, sha256, n
                case ratedN = "rated_n"
                case draftN = "draft_n"
            }
        }

        enum CodingKeys: String, CodingKey {
            case date, dirty, label, formatter, level, fixtures, scores, verdicts, gate, fallbacks, calibrated, machine
            case gitSha = "git_sha"
            case modelKey = "model_key"
            case modelSha256 = "model_sha256"
            case promptSha256 = "prompt_sha256"
            case scoringVersion = "scoring_version"
            case runKey = "run_key"
            case latencyMs = "latency_ms"
            case zeroEditRate = "zero_edit_rate"
            case selfRepair = "self_repair"
        }

        /// The comparability tuple: two rows are Δ-comparable when these
        /// agree and only `git_sha` differs. A run without the self-repair
        /// rules is a different pipeline, so it compares only with its like.
        public var comparabilityKey: String {
            ([formatter, modelSha256 ?? "", promptSha256 ?? "", fixtures.sha256, level, String(scoringVersion)]
                + (selfRepair == false ? ["self_repair=false"] : []))
                .joined(separator: "\n")
        }

        /// Compact one-line JSON for the `.jsonl` file.
        public func canonicalJSON() throws -> Data {
            try EvalRun.encoder(pretty: false).encode(self)
        }
    }

    /// `calibration` is what the ratings on disk say (`.none` without
    /// `--ratings`): the row records the zero-edit rate of ITS column and
    /// never claims calibration the record does not support.
    public func leaderboardRow(_ column: Column, calibration: Calibration.Live = .none) -> LeaderboardRow {
        LeaderboardRow(date: date, gitSha: gitSha, dirty: dirty, label: column.config.label,
                       formatter: column.formatter, modelKey: column.modelKey,
                       modelSha256: column.modelSha256, promptSha256: column.promptSha256,
                       level: column.level,
                       fixtures: .init(name: fixtures.name, sha256: fixtures.sha256, n: fixtures.n,
                                       ratedN: fixtures.ratedN, draftN: fixtures.draftN),
                       scoringVersion: scoringVersion, runKey: column.runKey, scores: column.scores,
                       verdicts: column.verdicts, gate: column.gate, fallbacks: column.fallbacks,
                       latencyMs: column.latencyMs,
                       zeroEditRate: calibration.zeroEditRate(column.formatter),
                       calibrated: calibration.valid, machine: machine,
                       selfRepair: column.config.selfRepair)
    }
}

// MARK: - Identity and encoding

extension EvalRun {
    /// `run_key` (§5): the first 12 hex of SHA-256 over the identity tuple
    /// — git sha, formatter, model and prompt hashes, fixture-set hash,
    /// level, scoring version — newline-joined so no field can run into
    /// its neighbour. Stable across two runs of the same inputs.
    /// A run without the self-repair rules adds that to the tuple, and
    /// only then: every key minted before the switch existed is unchanged.
    public static func runKey(gitSha: String, formatter: String, modelSha256: String?,
                              promptSha256: String?, fixturesSha256: String, level: String,
                              selfRepair: Bool = true) -> String {
        let tuple = [gitSha, formatter, modelSha256 ?? "", promptSha256 ?? "", fixturesSha256, level,
                     String(scoringVersion)] + (selfRepair ? [] : ["self_repair=false"])
        return String(sha256Hex(tuple.joined(separator: "\n")).prefix(12))
    }

    /// SHA-256 hex of a string's UTF-8 — `prompt_sha256` over the exact
    /// prompt bytes, `model_sha256` stand-ins (`foundation@<os build>`).
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Sorted keys, slashes unescaped; `pretty` adds indentation for the
    /// run file (the leaderboard line is always compact).
    public func canonicalJSON(pretty: Bool = false) throws -> Data {
        try Self.encoder(pretty: pretty).encode(self)
    }

    public static func load(_ data: Data) throws -> EvalRun {
        try JSONDecoder().decode(EvalRun.self, from: data)
    }

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
                                          : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Scores are stored to a fixed number of places so the JSON reads
    /// like the report and two encodes of one run are byte-identical.
    static func round(_ x: Double, places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (x * scale).rounded() / scale
    }
}

// MARK: - Re-scoring stored outputs (`whispr-bench score`)

extension EvalRun {
    public enum RescoreError: Error, Equatable, CustomStringConvertible {
        /// The fixtures handed to `score` are not the set the run measured.
        case fixturesMismatch(stored: String, given: String)
        case unknownFixture(String)
        case unknownLevel(String)

        public var description: String {
            switch self {
            case .fixturesMismatch(let stored, let given):
                return "fixture set differs from the run's (stored \(stored.prefix(12)), given \(given.prefix(12))); pass the file the run measured"
            case .unknownFixture(let id): return "row '\(id)' has no fixture in the given set"
            case .unknownLevel(let level): return "column level '\(level)' is not fixture | fillers | standard"
            }
        }
    }

    /// The same run re-graded under the CURRENT `scoringVersion`: every
    /// stored output (and every rejected pre-gate text) is scored again
    /// against its fixture, the columns re-aggregated, `run_key`
    /// recomputed (the version is part of it); identity, provenance,
    /// latencies and `date` stay — the outputs were produced then. The
    /// fixture set must hash to the run's, so a rescore can never grade
    /// outputs against golds they were not measured on.
    public func rescored(with cases: [EvalCase],
                         verbatimCategories: [String] = AppConfig.Cleanup().verbatimCategories) throws -> EvalRun {
        let sha = try EvalCase.fixtureSetHash(cases)
        guard sha == fixtures.sha256 else {
            throw RescoreError.fixturesMismatch(stored: fixtures.sha256, given: sha)
        }
        let byId = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let columns = try self.columns.map { column -> Column in
            let level: AppConfig.Cleanup.Level?
            if column.level == "fixture" {
                level = nil
            } else if let parsed = AppConfig.Cleanup.Level(rawValue: column.level), parsed != .verbatim {
                level = parsed
            } else {
                throw RescoreError.unknownLevel(column.level)
            }
            let observations = try column.rows.map { row -> Observation in
                guard let fixture = byId[row.id] else { throw RescoreError.unknownFixture(row.id) }
                return Observation(
                    fixture: fixture, stripped: row.stripped, out: row.out,
                    source: FormatterSource(evalRowSource: row.source), ms: row.ms, reprime: row.reprime,
                    rejected: row.rejected,
                    score: QualityScore.score(fixture, out: row.out, level: level, verbatimCategories: verbatimCategories),
                    modelScore: row.rejected.map {
                        QualityScore.score(fixture, out: $0, level: level, verbatimCategories: verbatimCategories)
                    })
            }
            let runKey = EvalRun.runKey(gitSha: gitSha, formatter: column.formatter, modelSha256: column.modelSha256,
                                        promptSha256: column.promptSha256, fixturesSha256: sha, level: column.level,
                                        selfRepair: column.config.ranSelfRepair)
            return Column.make(formatter: column.formatter, modelKey: column.modelKey,
                               modelSha256: column.modelSha256, promptSha256: column.promptSha256,
                               level: column.level, config: column.config, runKey: runKey,
                               observations: observations)
        }
        return EvalRun(runId: runId, date: date, gitSha: gitSha, dirty: dirty, machine: machine,
                       fixtures: fixtures, columns: columns)
    }

    /// `prompt_sha256` for a column whose directive varies per fixture
    /// (register, level): SHA-256 over the DISTINCT prompt prefixes the
    /// run sent, sorted, separated by a record separator so no prefix
    /// can run into the next. One prefix hashes as itself plus nothing.
    public static func promptHash(_ prompts: [String]) -> String {
        sha256Hex(Set(prompts).sorted().joined(separator: "\u{1E}"))
    }
}

extension FormatterSource {
    /// Inverse of the row's `source` string: `model`, a fallback reason,
    /// or nil for a stage with no provenance (`rules`, `shipped`).
    public init?(evalRowSource: String) {
        if evalRowSource == "model" {
            self = .model
        } else if let reason = FormatterFallbackReason(rawValue: evalRowSource) {
            self = .fallback(reason)
        } else {
            return nil
        }
    }
}
