import Foundation

/// `whispr-bench lint` for a format-bench fixtures file: what `whispr-bench
/// format` itself relies on in a row, as data — one `EvalLint.Issue` per
/// finding, so the CLI prints, and CI's repo guard reads, the same list
/// for both kinds of fixtures file.
///
/// Why not `EvalLint`: its invariant scores the gold with `QualityScore`,
/// whose L1 gate refuses added lines and markdown — the layout these golds
/// exist to pin (docs/formatting-benchmark.md §2) — so no bulleted gold can
/// ever score 100 against itself, and its numeral rule refuses the "1." an
/// inferred list adds. The format bench compares its output to the gold
/// exactly instead, and the rules below are the ones that comparison and
/// its report take for granted: a fixture is named by id, its raw is run
/// through the shipping path, its gold is a hand-written string, its
/// register and policy are read by name, and the report is per tag. Every
/// rule is a fact about one row; nothing here models the pipeline.
///
/// The repo guard is `EvalLint`'s own (`guardExportFields`), not a copy:
/// the privacy rail refuses a `history:` source or a shipped output in
/// this file by the same test it applies to an eval file.
public enum FormatLint {
    /// Lints `fixtures`; `repoGuard` adds the export-field refusal, as
    /// `EvalLint.lint` does.
    public static func lint(_ fixtures: [FormatFixture], repoGuard: Bool = false) -> [EvalLint.Issue] {
        var issues: [EvalLint.Issue] = []
        var seen: Set<String> = []
        for f in fixtures {
            if !seen.insert(f.id).inserted {
                issues.append(EvalLint.Issue(.error, id: f.id, "duplicate id"))
            }
            issues += row(f)
            if repoGuard {
                issues += EvalLint.guardExportFields(id: f.id, source: f.source, observed: f.observed,
                                                     observedMs: f.observedMs)
            }
        }
        return issues
    }

    /// One fixture's structural errors. There are no warnings: every rule
    /// here is a row the bench could not run or could not report.
    public static func row(_ f: FormatFixture) -> [EvalLint.Issue] {
        var issues: [EvalLint.Issue] = []
        func error(_ message: String) { issues.append(EvalLint.Issue(.error, id: f.id, message)) }

        // Nothing to run through the pipeline.
        if f.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("empty raw")
        }
        // The scorer is exact match against a hand-written string; this
        // bench has no gold-free mode, so an empty gold is an unfinished row.
        if f.gold.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("empty gold")
        }
        // The per-tag table is how a regression names the feature it broke,
        // and the control check reads `control` / `known-fail` /
        // `unsupported-phrase` off the same list; an untagged fixture is
        // invisible to both.
        if f.tags.isEmpty {
            error("no tags")
        }
        // The bench maps an unknown register to `.unknown` silently — the
        // typo EvalCase's decoder refuses out loud.
        if let register = f.register, AppCategory(rawValue: register) == nil {
            error("register '\(register)' is not an app category (expected one of: "
                  + AppCategory.allCases.map(\.rawValue).joined(separator: ", ") + ")")
        }
        // Likewise a policy name the bench does not read runs the
        // register's own policy as if nothing had been declared.
        if let policy = f.policy, policy != FormatFixture.inferringPolicy {
            error("policy '\(policy)' is not one the format bench reads (only '\(FormatFixture.inferringPolicy)')")
        }
        return issues
    }
}
