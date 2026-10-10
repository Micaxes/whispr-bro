import Foundation
import WhisprBroCore

/// `whispr-bench gold` (plan §7.3) — the thin half: load, print the
/// per-fixture before/after, and (with `--write`) put the merged file back
/// 0600. Every rule lives in `GoldDerivation`.
///
/// A derived annotation that fails `lint` is a scoring bug waiting to
/// happen, so `--write` refuses it — but a rating session is 70 rows, and
/// one retained filler refusing 22 good golds is the worse failure. So the
/// refusal names the row, the rule and `--skip-failing`, and
/// `--skip-failing` writes every change that lints clean and lists the ones
/// it held back with the errors that hold them (`GoldDerivation.writable`).
/// Only a change THIS pass derived refuses: an error the file already
/// carried is a row the pass never touched, so it is written and printed as
/// the warning it is (`GoldDerivation.writeDecision`).
///
/// A rating pins the output it judged by digest, not by value (§7.2), so
/// the text a SHIP turns into a gold has to come from somewhere: the
/// fixtures' own `observed` column (the shipped output, by construction)
/// and any run files passed with `--runs`. A record whose output cannot be
/// resolved is listed, never guessed at.
extension WhisprBench {
    static func runGold(_ rest: [String]) {
        var fixturesPath: String?
        var ratingsPath: String?
        var runPaths: [String] = []
        var write = false
        var skipFailing = false
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--ratings" where i + 1 < rest.count: ratingsPath = rest[i + 1]; i += 2
            case "--runs" where i + 1 < rest.count:
                runPaths += rest[i + 1].split(separator: ",").map(String.init); i += 2
            case "--write": write = true; i += 1
            case "--skip-failing": skipFailing = true; i += 1
            default:
                if rest[i].hasPrefix("--") { print("gold: unknown or incomplete flag '\(rest[i])'"); exit(64) }
                fixturesPath = rest[i]; i += 1
            }
        }
        guard let fixturesPath else { print("gold: needs a fixtures.json"); exit(64) }
        guard let ratingsPath = ratingsPath ?? defaultRatingsPath() else {
            print("gold: --ratings is required (or set $WHISPR_EVAL_HOME so ratings.jsonl is found)")
            exit(64)
        }
        let fixtures: [EvalCase]
        switch loadFixtures([fixturesPath]) {
        case .success(let loaded): fixtures = loaded.cases
        case .failure(let e): print(e); exit(64)
        }
        let ratings = loadRatings(ratingsPath)
        guard !ratings.isEmpty else { print("gold: no ratings in \(ratingsPath)"); exit(0) }

        let runs = runPaths.map { loadRun($0) }
        let outputs = GoldDerivation.Outputs(runs: runs, fixtures: fixtures)
        let result = GoldDerivation.derive(fixtures: fixtures, ratings: ratings, outputs: outputs)
        print("gold \(fixturesPath): \(fixtures.count) fixture(s), \(ratings.filter(\.isTriage).count) rating(s)"
              + (runs.isEmpty ? "" : ", \(runs.count) run(s)") + "\n")
        print(result.render())
        print("\n" + result.summary)

        guard write else {
            print("\ndry run — pass --write to put this back into \(fixturesPath)")
            exit(0)
        }
        guard !result.changes.isEmpty else { print("\nnothing to write"); exit(0) }
        // The file carries his dictations; it never lands in a checkout.
        if EvalFile.refusesPrivatePath(fixturesPath) {
            print("\n--write \(fixturesPath) is inside a source checkout; his fixtures live under "
                  + "$WHISPR_EVAL_HOME (default ~/OS/dev/whispr-bro-eval/)")
            exit(64)
        }
        // A derived annotation that fails lint is a scoring bug waiting to
        // happen: `--write` refuses that change and leaves the file alone.
        // One bad row must not cost him the others, though — neither a row
        // this pass derived (the refusal names it, the rule, and
        // `--skip-failing`, which writes the rest) nor a row that was
        // already failing before he rated anything, which holds nothing
        // back and is written with its errors printed as warnings.
        let set = GoldDerivation.writable(result)
        // `issues` is the file exactly as it would go back: a held change
        // is the ORIGINAL row again, so every error left here belongs to a
        // row this pass never touched.
        let issues = EvalLint.lint(set.cases)
        let errors = issues.filter { $0.severity == .error }.count
        let decision = GoldDerivation.writeDecision(set, issues: issues, changes: result.changes.count,
                                                    skipFailing: skipFailing, lintPath: fixturesPath)
        guard decision.writes else {
            print("\n" + decision.render())
            exit(1)
        }
        guard !set.written.isEmpty else {
            print("\n" + set.render())
            print("\nnothing left to write — every change is held back")
            exit(1)
        }
        do {
            try EvalFile.write(try HistoryExport.encode(set.cases), to: fixturesPath)
        } catch {
            print("\n\(error)"); exit(1)
        }
        let drafts = set.cases.filter { !$0.isGoldFree && $0.isDraft }.count
        let rated = set.cases.filter { !$0.isGoldFree && !$0.isDraft }.count
        print("\n→ \(fixturesPath) (\(EvalFile.posixPermissions(of: fixturesPath).map { String(format: "%04o", $0) } ?? "?"))"
              + " · \(set.written.count) fixture(s) written"
              + (set.held.isEmpty ? "" : ", \(set.held.count) held back")
              + " · \(rated) confirmed, \(drafts) draft, "
              + "\(set.cases.filter(\.isGoldFree).count) still unrated")
        if !set.held.isEmpty { print("\n" + set.render()) }
        // What is left was in the file before this pass: holding a change
        // back cannot fix it, and refusing would cost him the golds that
        // are fine.
        if !decision.lines.isEmpty { print("\n" + decision.render()) }
        let warnings = issues.count - errors
        if warnings > 0 { print("lint: \(warnings) warning(s) — run `whispr-bench lint \(fixturesPath)`") }
        exit(0)
    }

    /// `--ratings`, else `$WHISPR_EVAL_HOME/ratings.jsonl` when that env
    /// var is set and the file is there. Never a guess into a directory
    /// the flag did not name.
    static func defaultRatingsPath() -> String? {
        guard let home = EvalFile.evalHome() else { return nil }
        let path = URL(fileURLWithPath: home).appendingPathComponent("ratings.jsonl").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func loadRatings(_ path: String) -> [Rating] {
        guard FileManager.default.fileExists(atPath: path) else {
            print("no ratings at \(path)"); exit(1)
        }
        do {
            return try RatingLog.load(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("could not read \(path): \(error)"); exit(1)
        }
    }
}
