import Foundation

/// `whispr-bench eval`'s flags as data (plan §6.1): parsing, the column list
/// `--formatter` expands to (dispatcher decision D2: comma lists and `all`),
/// the fixture-set name a filtered run reports, and the two flag lists
/// `scripts/bench-eval.sh` walks when it looks for a fixtures path. Lives in
/// Core so XCTest pins every branch — the bench target is invisible to it —
/// and so the value-taking flags the script must skip over are exactly the
/// ones the parser consumes: `whispr-bench eval --value-flags` prints
/// `valueFlags`, and the script asks the binary instead of keeping a copy
/// that drifts.
public struct EvalOptions: Sendable, Equatable {
    public var fixturePaths: [String] = []
    /// `--formatter` as given: names, comma lists, or `all`.
    public var formatters: [String] = ["all"]
    public var modelKey: String?
    public var systemPromptPath: String?
    public var level = "fixture"
    public var tags: [String] = []
    public var only: EvalPlan.Only = .all
    public var confirmedOnly = false
    public var budgetMs = EvalThresholds.defaultBudgetMs
    public var timeoutMs = EvalThresholds.defaultTimeoutMs
    public var strictLatency = false
    public var jsonPath: String?
    public var reportPath: String?
    public var appendPath: String?
    /// `ratings.jsonl` (§7.2), for the calibration banner and the
    /// leaderboard row's `zero_edit_rate` / `calibrated`. nil falls back to
    /// `$WHISPR_EVAL_HOME/ratings.jsonl` when that env var is set.
    public var ratingsPath: String?
    public var gitSha: String?
    public var dirty = false
    public var label: String?
    public var quiet = false
    /// `--no-self-repair`: the pre-pass without the self-repair rules —
    /// the strip alone, as the app runs with `[cleanup] self_repair =
    /// false`. Recorded in the run (`EvalRun.Config.selfRepair`) and its
    /// `run_key`, so such a row never passes for one with the rules.
    public var selfRepair = true

    public init() {}

    public static let formatterNames = ["rules", "llama", "foundation", "shipped", "all"]
    public static let levelNames = ["fixture", "fillers", "standard"]

    /// Flags that consume the next argument. `parse` accepts exactly these
    /// with a value (a listed flag the switch below does not handle is a
    /// test failure, not a silent default), and the script skips their
    /// values when it decides whether a fixtures path was given.
    public static let valueFlags = [
        "--formatter", "--model", "--system-prompt", "--level", "--tag", "--only",
        "--budget-ms", "--timeout-ms", "--json", "--report", "--append", "--ratings", "--git-sha", "--label",
    ]
    /// Flags that stand alone.
    public static let booleanFlags = ["--confirmed-only", "--strict-latency", "--dirty", "--quiet", "--no-self-repair"]

    /// Parses `eval`'s arguments; the failure is the usage line to print.
    public static func parse(_ args: [String]) -> Result<EvalOptions, EvalUsageError> {
        var o = EvalOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            if valueFlags.contains(arg) {
                guard i + 1 < args.count else { return .failure(EvalUsageError("\(arg) needs a value")) }
                if let error = o.apply(arg, value: args[i + 1]) { return .failure(error) }
                i += 2
            } else if booleanFlags.contains(arg) {
                o.apply(arg)
                i += 1
            } else if arg.hasPrefix("--") {
                return .failure(EvalUsageError("unknown flag '\(arg)'"))
            } else {
                o.fixturePaths.append(arg)
                i += 1
            }
        }
        for name in o.formatters where !formatterNames.contains(name) {
            return .failure(EvalUsageError("unknown --formatter '\(name)' (rules | llama | foundation | shipped | all, or a comma list)"))
        }
        return .success(o)
    }

    private mutating func apply(_ flag: String, value: String) -> EvalUsageError? {
        switch flag {
        case "--formatter":
            formatters = Self.list(value)
        case "--model":
            modelKey = value
        case "--system-prompt":
            systemPromptPath = value
        case "--level":
            guard Self.levelNames.contains(value) else {
                return EvalUsageError("--level must be fixture | fillers | standard, not '\(value)'")
            }
            level = value
        case "--tag":
            tags += Self.list(value)
        case "--only":
            guard let only = EvalPlan.Only(rawValue: value) else {
                return EvalUsageError("--only must be gated | flagged | unrated | all, not '\(value)'")
            }
            self.only = only
        case "--budget-ms":
            guard let n = Int(value), n > 0 else { return EvalUsageError("--budget-ms needs a positive integer") }
            budgetMs = n
        case "--timeout-ms":
            guard let n = Int(value), n > 0 else { return EvalUsageError("--timeout-ms needs a positive integer") }
            timeoutMs = n
        case "--json":
            jsonPath = value
        case "--report":
            reportPath = value
        case "--append":
            appendPath = value
        case "--ratings":
            ratingsPath = value
        case "--git-sha":
            // scripts/bench-eval.sh folds git's dirty check into the token.
            if value.hasSuffix("-dirty") {
                gitSha = String(value.dropLast("-dirty".count))
                dirty = true
            } else {
                gitSha = value
            }
        case "--label":
            label = value
        default:
            return EvalUsageError("unknown flag '\(flag)'")   // a `valueFlags` entry the switch forgot
        }
        return nil
    }

    private mutating func apply(_ flag: String) {
        switch flag {
        case "--confirmed-only": confirmedOnly = true
        case "--strict-latency": strictLatency = true
        case "--dirty": dirty = true
        case "--quiet": quiet = true
        case "--no-self-repair": selfRepair = false
        default: break
        }
    }

    /// A comma list, items trimmed, empties dropped.
    static func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var levelOverride: AppConfig.Cleanup.Level? {
        level == "fixture" ? nil : AppConfig.Cleanup.Level(rawValue: level)
    }

    /// The columns to run, in the order given (D2). `all` expands in place
    /// to rules, llama, foundation — plus shipped when a fixture carries
    /// an observed output (a column with nothing to score is noise).
    public func columns(hasObserved: Bool) -> [String] {
        var out: [String] = []
        for name in formatters {
            let expanded = name == "all"
                ? ["rules", "llama", "foundation"] + (hasObserved ? ["shipped"] : [])
                : [name]
            for e in expanded where !out.contains(e) { out.append(e) }
        }
        return out
    }

    /// The fixture-set name a filtered run reports: the base name plus the
    /// active filters, so a `--tag hedge` row on the leaderboard never
    /// reads as the whole set.
    public func fixturesName(base: String) -> String {
        var suffix: [String] = []
        if !tags.isEmpty { suffix.append("--tag " + tags.joined(separator: ",")) }
        if only != .all { suffix.append("--only \(only.rawValue)") }
        if confirmedOnly { suffix.append("--confirmed-only") }
        return suffix.isEmpty ? base : base + "[" + suffix.joined(separator: " ") + "]"
    }
}

/// A bench usage error: the message IS the line to print.
public struct EvalUsageError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
