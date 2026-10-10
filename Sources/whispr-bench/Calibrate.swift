import Foundation
import WhisprBroCore

/// `whispr-bench calibrate` (plan §7.4) — the thin half: load the
/// fixtures, the runs and the ratings, hand them to `Calibration`, print
/// the check table, and write `calibration.md` plus the machine-readable
/// `calibration.json` beside it (both 0600).
///
/// The JSON is what makes the banner honest everywhere else: `eval` and
/// `leaderboard` read it and mark a row `calibrated` only when it says
/// `valid` for that exact `fixtures_sha256`.
extension WhisprBench {
    static func runCalibrate(_ rest: [String]) {
        var fixturesPath: String?
        var runPaths: [String] = []
        var ratingsPath: String?
        var outPath: String?
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--fixtures" where i + 1 < rest.count: fixturesPath = rest[i + 1]; i += 2
            case "--runs" where i + 1 < rest.count:
                runPaths += rest[i + 1].split(separator: ",").map(String.init); i += 2
            case "--ratings" where i + 1 < rest.count: ratingsPath = rest[i + 1]; i += 2
            case "--out" where i + 1 < rest.count: outPath = rest[i + 1]; i += 2
            default:
                print("calibrate: unknown or incomplete flag '\(rest[i])'"); exit(64)
            }
        }
        guard let fixturesPath else { print("calibrate: --fixtures is required"); exit(64) }
        guard let ratingsPath = ratingsPath ?? defaultRatingsPath() else {
            print("calibrate: --ratings is required (or set $WHISPR_EVAL_HOME so ratings.jsonl is found)")
            exit(64)
        }
        guard let outPath else { print("calibrate: --out calibration.md is required"); exit(64) }
        if EvalFile.refusesPrivatePath(outPath) {
            print("--out \(outPath) is inside a source checkout; a calibration report names his fixtures — "
                  + "write it under $WHISPR_EVAL_HOME (default ~/OS/dev/whispr-bro-eval/)")
            exit(64)
        }
        // The record goes to the `.json` sibling of `--out`; an `--out`
        // that is already `.json` IS that sibling, and the report would be
        // silently overwritten by it.
        let jsonPath = URL(fileURLWithPath: outPath).deletingPathExtension()
            .appendingPathExtension("json").path
        guard jsonPath != outPath else {
            print("--out \(outPath) collides with the calibration record written beside it — "
                  + "name the report calibration.md (the record goes to calibration.json)")
            exit(64)
        }
        let loaded: (cases: [EvalCase], name: String, path: String)
        switch loadFixtures([fixturesPath]) {
        case .success(let l): loaded = l
        case .failure(let e): print(e); exit(64)
        }
        let ratings = loadRatings(ratingsPath)
        let runs = runPaths.map { loadRun($0) }
        if runs.isEmpty { print("note: no --runs given; only the ratings' own statistics can be computed\n") }
        let sha: String
        do { sha = try EvalCase.fixtureSetHash(loaded.cases) } catch {
            print("could not hash the fixtures: \(error)"); exit(64)
        }
        let report = Calibration.report(fixtures: loaded.cases, runs: runs, ratings: ratings,
                                        fixturesSha256: sha, fixturesName: loaded.name, date: isoNow())
        print("calibrate \(loaded.name): \(loaded.cases.count) fixture(s), \(ratings.count) rating(s), "
              + "\(runs.count) run(s)\n")
        // `padding(toLength:)` truncates when the text is longer, which
        // would cut a target in half — pad, never trim.
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
        }
        for check in report.checks {
            let value = check.value.map { String(format: "%.3f", $0) } ?? "—"
            print("  \(check.number). " + pad(check.name, 24) + pad(check.statistic, 27)
                  + pad(value, 8) + pad(check.target, 44) + check.status.rawValue)
        }
        print("\n" + report.banner)
        if !report.zeroEditRates.isEmpty {
            print("zero-edit  " + report.zeroEditRates.keys.sorted()
                .map { String(format: "%@ %.1f%%", $0, report.zeroEditRates[$0]!) }.joined(separator: " · "))
        }

        do {
            try EvalFile.write(Data(report.markdown().utf8), to: outPath)
            try EvalFile.write(try report.record.canonicalJSON(), to: jsonPath)
        } catch {
            print("\(error)"); exit(1)
        }
        print("\n→ \(outPath)\n→ \(jsonPath) (read by eval / leaderboard for the banner and `calibrated`)")
        exit(0)
    }
}
