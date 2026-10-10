import Foundation
import WhisprBroCore

/// The thin glue around the Core eval types for `whispr-bench eval` /
/// `score` / `lint` / `leaderboard`: fixture-file loading, the run's
/// identity (git sha, machine, model digest), and the file writers.
/// Nothing here computes a score, parses a flag or renders a line of
/// report text — that lives in WhisprBroCore (`EvalOptions`, `EvalReport`,
/// `Leaderboard`, `EvalPlan`, `EvalLint`) where XCTest can pin it; this
/// file only reads files and prints. It never opens a network connection and never spawns a
/// subprocess: the git sha comes from `.git/HEAD` on disk (or the
/// `--git-sha` flag scripts/bench-eval.sh passes), the machine from sysctl.
extension WhisprBench {
    /// The flag parser lives in Core (`EvalOptions`), where XCTest pins it.
    typealias UsageError = EvalUsageError

    // MARK: - Fixtures

    /// Loads every path (JSON arrays of `EvalCase`) or the seeds when none
    /// is given; the name is the file stems joined by `+`, the path the
    /// paths joined by `,`.
    static func loadFixtures(_ paths: [String]) -> Result<(cases: [EvalCase], name: String, path: String), UsageError> {
        guard !paths.isEmpty else { return .success((EvalCase.seeds, "seeds", "seeds")) }
        var cases: [EvalCase] = []
        for path in paths {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                cases += try JSONDecoder().decode([EvalCase].self, from: data)
            } catch {
                return .failure(UsageError("could not load fixtures from \(path): \(error.localizedDescription)"))
            }
        }
        guard !cases.isEmpty else { return .failure(UsageError("no fixtures in \(paths.joined(separator: ", "))")) }
        let name = paths.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.joined(separator: "+")
        return .success((cases, name, paths.joined(separator: ",")))
    }

    /// Loads one `whispr-bench format` fixtures file (a JSON array of
    /// `FormatFixture`) — the one reader `format` and `lint` share.
    static func loadFormatFixtures(_ path: String) -> Result<[FormatFixture], UsageError> {
        do {
            return .success(try FormatFixture.decode(try Data(contentsOf: URL(fileURLWithPath: path))))
        } catch {
            // `\(error)`, not its localizedDescription: a `DecodingError`
            // describes the key and the row ("Index 52"), which is how a
            // bad row among fifty is found; the localized text is only
            // "The data couldn't be read because it is missing."
            return .failure(UsageError("could not load format fixtures from \(path): \(error)"))
        }
    }

    // MARK: - Identity

    /// `<sha>` from `.git/HEAD` walking up from the working directory —
    /// no subprocess. A detached HEAD is the sha itself; a symbolic ref is
    /// resolved through `refs/heads/…` or `packed-refs`. nil outside a
    /// checkout (the run then records `unknown`; scripts/bench-eval.sh
    /// passes `--git-sha` with the dirty flag git alone can compute).
    static func gitHeadSha() -> String? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var gitDir = dotGit
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if !isDir.boolValue,
                   let text = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
                    // A worktree: `.git` is a file pointing at the real dir.
                    let target = String(line.dropFirst("gitdir: ".count))
                    gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                        : dir.appendingPathComponent(target).standardizedFileURL
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if head.hasPrefix("ref: ") {
                    let ref = String(head.dropFirst("ref: ".count))
                    // A worktree's refs live in the common dir.
                    var common = gitDir
                    if let c = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                        let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                        common = t.hasPrefix("/") ? URL(fileURLWithPath: t) : gitDir.appendingPathComponent(t).standardizedFileURL
                    }
                    if let sha = try? String(contentsOf: common.appendingPathComponent(ref), encoding: .utf8) {
                        return String(sha.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
                    }
                    if let packed = try? String(contentsOf: common.appendingPathComponent("packed-refs"), encoding: .utf8) {
                        for line in packed.split(separator: "\n") {
                            let parts = line.split(separator: " ")
                            if parts.count == 2, parts[1] == Substring(ref) { return String(parts[0].prefix(7)) }
                        }
                    }
                    return nil
                }
                return String(head.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func machine() -> EvalRun.Machine {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return EvalRun.Machine(model: sysctlString("hw.model") ?? "unknown",
                               os: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    /// `foundation@<os build>` — the system model changes with the OS.
    static func foundationModelIdentity() -> String {
        "foundation@" + (sysctlString("kern.osversion") ?? "unknown")
    }

    /// The GGUF's digest from `scripts/models-llm.sha256` (found walking
    /// up from the working directory), so two runs on the same weights
    /// share a `model_sha256` whatever the file's local path.
    static func llamaModelSha256(_ spec: LlmModelSpec) -> String? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        while true {
            let manifest = dir.appendingPathComponent("scripts/models-llm.sha256")
            if let text = try? String(contentsOf: manifest, encoding: .utf8) {
                return Leaderboard.modelSha256(manifest: text, relativePath: spec.relativePath)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    /// `<date>-<sha>-<name>` with the time's colons dropped and the name
    /// reduced to path-safe characters.
    static func runId(date: String, gitSha: String, name: String) -> String {
        let stamp = date.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "Z", with: "")
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+" ? $0 : Character("_") }
        return "\(stamp)-\(gitSha)-\(String(safe))"
    }

    // MARK: - Files

    /// Every file the bench writes goes through `EvalFile` — created 0600,
    /// never chmod-ed after the bytes land. A run JSON and a report hold
    /// his raw dictations and outputs verbatim, a ratings log holds his
    /// hand-edited golds, and even a leaderboard line says what he
    /// measured and when: none of them may be world-readable, and neither
    /// `Data.write(options: .atomic)` nor `FileManager.createFile` without
    /// attributes can promise that (both land 0644 under umask 022). The
    /// failure is printed here and reported as false so the caller still
    /// exits non-zero.
    static func write(_ data: Data, to path: String) -> Bool {
        do {
            try EvalFile.write(data, to: path)
            return true
        } catch {
            print("\(error)")
            return false
        }
    }

    static func appendLine(_ line: Data, to path: String) -> Bool {
        do {
            try EvalFile.appendLine(line, to: path)
            return true
        } catch {
            print("\(error)")
            return false
        }
    }

    /// Existing leaderboard rows (empty when the file does not exist yet).
    static func loadLeaderboard(_ path: String) -> Result<[EvalRun.LeaderboardRow], UsageError> {
        guard FileManager.default.fileExists(atPath: path) else { return .success([]) }
        do {
            return .success(try Leaderboard.load(try Data(contentsOf: URL(fileURLWithPath: path))))
        } catch {
            return .failure(UsageError("could not read \(path): \(error)"))
        }
    }

    // MARK: - Live ratings

    /// What the ratings on disk say about THIS fixture set (§7.4): the
    /// rated count in the banner, the zero-edit rate per column, and
    /// whether a `calibration.json` calls the set valid. `--ratings`, else
    /// `$WHISPR_EVAL_HOME/ratings.jsonl` when that env var is set — never
    /// a guess at a path nobody named. The calibration record is the
    /// `calibration.json` beside the ratings file, else the one in
    /// `$WHISPR_EVAL_HOME`; a record hashed against another fixture set
    /// calibrates nothing.
    static func liveCalibration(ratingsPath: String?, cases: [EvalCase], fixturesSha256: String,
                                quiet: Bool = false) -> Calibration.Live {
        guard let path = ratingsPath ?? defaultRatingsPath() else { return .none }
        let ratings: [Rating]
        do {
            ratings = try RatingLog.load(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            // Inside the guard: `--quiet` and `quiet: true` mean no
            // chatter, and this line was leaking into both.
            if !quiet {
                print("note: could not read the ratings at \(path) (\(error)); "
                      + "the calibration banner stays at n=0\n")
            }
            return .none
        }
        let record = calibrationRecord(besides: path)
        let live = Calibration.Live(ratings: ratings, cases: cases, record: record,
                                    fixturesSha256: fixturesSha256)
        if !quiet {
            // A record for THIS set that simply has not reached VALID yet
            // is not the same thing as a record for another set.
            let covers = record?.fixturesSha256 == fixturesSha256
            print("ratings: \(live.rated ?? 0) judgement(s) over "
                  + "\(RatingLog.ratedCount(ratings, in: cases))/\(cases.count) fixture(s) from \(path)"
                  + (record == nil ? " · no calibration.json"
                     : live.valid ? " · calibration VALID"
                     : covers ? " · calibration PENDING on this fixture set"
                     : " · the calibration record is for another fixture set") + "\n")
        }
        return live
    }

    /// The calibration record beside the ratings log, else the one in
    /// `$WHISPR_EVAL_HOME` — nil when neither is readable.
    static func calibrationRecord(besides ratingsPath: String?) -> Calibration.Record? {
        for candidate in calibrationPaths(besides: ratingsPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate)),
                  let loaded = try? Calibration.Record.load(data) else { continue }
            return loaded
        }
        return nil
    }

    /// Where a calibration record may live: beside the ratings log (when a
    /// log was named at all), then `$WHISPR_EVAL_HOME`.
    static func calibrationPaths(besides ratingsPath: String?) -> [String] {
        var paths = (ratingsPath ?? defaultRatingsPath()).map {
            [URL(fileURLWithPath: $0).deletingLastPathComponent()
                .appendingPathComponent("calibration.json").path]
        } ?? []
        if let home = EvalFile.evalHome() {
            paths.append(URL(fileURLWithPath: home).appendingPathComponent("calibration.json").path)
        }
        return paths
    }

    /// Writes `--json` / `--report` / `--append` for a run; returns false
    /// on any write failure. `cases` feed the report's raw / gold text.
    static func emit(_ run: EvalRun, cases: [EvalCase], jsonPath: String?, reportPath: String?,
                     appendPath: String?, previous: [String: EvalRun.LeaderboardRow],
                     calibration: Calibration.Live = .none) -> Bool {
        var ok = true
        if let jsonPath {
            do {
                ok = write(try run.canonicalJSON(pretty: true), to: jsonPath) && ok
                if ok { print("run JSON → \(jsonPath)") }
            } catch {
                print("could not encode the run: \(error)"); ok = false
            }
        }
        if let reportPath {
            ok = write(Data(EvalReport.markdown(run, cases: cases, previous: previous,
                                                calibration: calibration).utf8), to: reportPath) && ok
            if ok { print("report → \(reportPath)") }
        }
        if let appendPath {
            for column in run.columns {
                do {
                    ok = appendLine(try run.leaderboardRow(column, calibration: calibration).canonicalJSON(),
                                    to: appendPath) && ok
                } catch {
                    print("could not encode a leaderboard row: \(error)"); ok = false
                }
            }
            if ok { print("leaderboard +\(run.columns.count) row(s) → \(appendPath)") }
        }
        return ok
    }

    /// The previous comparable leaderboard row per formatter, for the Δ.
    static func previousRows(_ run: EvalRun, in rows: [EvalRun.LeaderboardRow]) -> [String: EvalRun.LeaderboardRow] {
        var previous: [String: EvalRun.LeaderboardRow] = [:]
        for column in run.columns {
            if let prev = Leaderboard.previousComparable(to: run.leaderboardRow(column), in: rows) {
                previous[column.formatter] = prev
            }
        }
        return previous
    }

    static func deltas(_ run: EvalRun, previous: [String: EvalRun.LeaderboardRow]) -> [String: Leaderboard.Delta] {
        var deltas: [String: Leaderboard.Delta] = [:]
        for column in run.columns {
            if let prev = previous[column.formatter], let delta = try? Leaderboard.diff(prev, run.leaderboardRow(column)) {
                deltas[column.formatter] = delta
            }
        }
        return deltas
    }

    static func printIssues(_ issues: [EvalLint.Issue], prefix: String = "  ") {
        for issue in issues { print(prefix + issue.description) }
    }
}
