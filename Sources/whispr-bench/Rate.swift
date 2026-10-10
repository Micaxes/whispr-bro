import Foundation
import WhisprBroCore

/// `whispr-bench rate` (plan §7.1–7.2) — the thin half. The queue, the
/// screen, the key-to-record state machine and the record itself live in
/// `WhisprBroCore` (`Rating.swift`), where XCTest pins them; this file
/// only reads a key, prints what the session hands back, appends the
/// lines it emits (0600, through `EvalFile`), and opens `$EDITOR` on a
/// temp file for the `e` key — the one subprocess in the eval surface,
/// deliberately outside `WhisprBroCore`.
///
/// Two input modes:
/// - **raw stdin** on a TTY: one keystroke, no Enter — the 5-second-a-row
///   loop §7.1 budgets for. The terminal is restored on every exit path.
/// - **scripted** when stdin is not a TTY: one key or answer PER LINE, EOF
///   ends the session cleanly. This is how the tests and an agent drive
///   it; `e` then reads the replacement gold from the next line instead of
///   opening an editor (an editor with no terminal is not an editor).
extension WhisprBench {
    struct RateOptions {
        var runPath: String?
        var fixturesPath: String?
        var only: EvalPlan.Only = .all
        var column: String?
        var pairwisePath: String?
        var rerate = false
        var outPath: String?
        var session: String?
    }

    static func runRate(_ rest: [String]) {
        var o = RateOptions()
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--fixtures" where i + 1 < rest.count: o.fixturesPath = rest[i + 1]; i += 2
            case "--only" where i + 1 < rest.count:
                guard let only = EvalPlan.Only(rawValue: rest[i + 1]) else {
                    print("rate: --only must be gated | flagged | unrated | all, not '\(rest[i + 1])'"); exit(64)
                }
                o.only = only; i += 2
            case "--column" where i + 1 < rest.count: o.column = rest[i + 1]; i += 2
            case "--pairwise" where i + 1 < rest.count: o.pairwisePath = rest[i + 1]; i += 2
            case "--out" where i + 1 < rest.count: o.outPath = rest[i + 1]; i += 2
            case "--session" where i + 1 < rest.count: o.session = rest[i + 1]; i += 2
            case "--rerate": o.rerate = true; i += 1
            default:
                if rest[i].hasPrefix("--") { print("rate: unknown or incomplete flag '\(rest[i])'"); exit(64) }
                o.runPath = rest[i]; i += 1
            }
        }
        guard let runPath = o.runPath else { print("rate: needs runs/<id>.json"); exit(64) }
        guard let outPath = o.outPath else {
            print("rate: --out is required (the ratings log is $WHISPR_EVAL_HOME/ratings.jsonl, "
                  + "default ~/OS/dev/whispr-bro-eval/; nothing is written anywhere but the path given)")
            exit(64)
        }
        // His golds and his dictations' diffs end up in this file: never
        // inside a checkout, whatever the fixture set.
        if EvalFile.refusesPrivatePath(outPath) {
            print("--out \(outPath) is inside a source checkout; a ratings log carries his hand-edited golds "
                  + "— write it under $WHISPR_EVAL_HOME (default ~/OS/dev/whispr-bro-eval/)")
            exit(64)
        }

        let run = loadRun(runPath)
        let fixtures = loadRateFixtures(o.fixturesPath, run: run)
        let pairwise = o.pairwisePath.map { loadRun($0) }
        if let column = o.column, !run.columns.contains(where: { $0.formatter == column }) {
            print("rate: no column '\(column)' in \(runPath) (\(run.columns.map(\.formatter).joined(separator: ", ")))")
            exit(64)
        }
        var ratings: [Rating] = []
        if FileManager.default.fileExists(atPath: outPath) {
            do {
                ratings = try RatingLog.load(try Data(contentsOf: URL(fileURLWithPath: outPath)))
            } catch {
                print("could not read the existing \(outPath): \(error)"); exit(1)
            }
        }
        let session = o.session ?? sessionId(date: isoNow())
        let items = RatingQueue.build(run: run, fixtures: fixtures, only: o.only, column: o.column,
                                      pairwise: pairwise, ratings: ratings, rerate: o.rerate, session: session)
        guard !items.isEmpty else {
            print("nothing to rate in \(run.runId): \(run.columns.map { "\($0.formatter) \($0.rows.count) row(s)" }.joined(separator: ", "))"
                  + " · --only \(o.only.rawValue)" + (o.column.map { " · --column \($0)" } ?? "")
                  + (o.rerate ? " · --rerate" : " · \(ratings.filter(\.isTriage).count) already rated"))
            exit(0)
        }

        let scripted = isatty(FileHandle.standardInput.fileDescriptor) == 0
        print("rate \(run.runId) · \(items.count) row(s)"
              + (pairwise != nil ? " · pairwise vs \(pairwise!.runId)" : "")
              + " · session \(session)" + (scripted ? " · scripted (one key per line)" : ""))
        print("→ \(outPath)\n")

        var loop = RatingSession(items: items, session: session)
        let reader = KeyReader(scripted: scripted)
        defer { reader.restore() }
        var written = 0
        func apply(_ effects: [RatingSession.Effect]) -> Bool {
            for effect in effects {
                switch effect {
                case .write(let rating):
                    do {
                        try EvalFile.appendLine(try RatingLog.encode(rating), to: outPath)
                        written += 1
                    } catch {
                        reader.restore()
                        print("\n\(error)")
                        exit(1)
                    }
                case .note(let text):
                    print("  " + text.replacingOccurrences(of: "\n", with: "\n  "))
                case .openEditor(let text, let fixtureId):
                    let edited = scripted ? reader.line() : editGold(text, fixtureId: fixtureId, reader: reader)
                    if apply(loop.applyEdit(edited)) { return true }
                case .finished(let summary):
                    reader.restore()
                    print("\n" + summary.render())
                    print("→ \(outPath) (\(written) record(s) appended, "
                          + "\(EvalFile.posixPermissions(of: outPath).map { String(format: "%04o", $0) } ?? "?"))")
                    if summary.rated > 0 {
                        print("next: whispr-bench gold <fixtures.json> --ratings \(outPath)")
                    }
                    return true
                }
            }
            return false
        }

        while !loop.isFinished {
            print(loop.prompt)
            guard let key = reader.key() else {
                _ = apply(loop.endOfInput())
                break
            }
            if apply(loop.handle(key)) { break }
            print("")
        }
        exit(0)
    }

    /// `2026-09-13T110500Z` — printed at the top of the session because
    /// the pairwise slot layout is replayable from it and nothing else.
    static func sessionId(date: String) -> String {
        date.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
    }

    static func loadRun(_ path: String) -> EvalRun {
        do {
            return try EvalRun.load(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("could not load the run from \(path): \(error)"); exit(64)
        }
    }

    /// `--fixtures`, else the run's own `fixtures.path` (the seeds when it
    /// says so) — the same resolution `score` uses.
    static func loadRateFixtures(_ path: String?, run: EvalRun) -> [EvalCase] {
        let paths = path.map { [$0] }
            ?? (run.fixtures.path == "seeds" ? [] : run.fixtures.path.split(separator: ",").map(String.init))
        switch loadFixtures(paths) {
        case .success(let loaded): return loaded.cases
        case .failure(let e): print(e); exit(64)
        }
    }

    /// The `e` key on a TTY: the gold goes into a 0600 temp file, `$EDITOR`
    /// (or `vi`) opens it, the file is removed whatever happens. The text
    /// never leaves this Mac and never lands anywhere it could be read.
    private static func editGold(_ text: String, fixtureId: String, reader: KeyReader) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-rate-\(fixtureId)-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try EvalFile.write(Data((text + "\n").utf8), to: url.path)
        } catch {
            print("  \(error)")
            return nil
        }
        let editor = ProcessInfo.processInfo.environment["EDITOR"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // The terminal belongs to the editor while it runs.
        reader.restore()
        defer { reader.raw() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "\(editor.isEmpty ? "vi" : editor) \"$1\"", "sh", url.path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("  could not launch \(editor.isEmpty ? "vi" : editor): \(error.localizedDescription)")
            return nil
        }
        guard task.terminationStatus == 0,
              let edited = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return edited.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One keystroke at a time on a TTY (termios raw mode — no Enter, no echo
/// of the key itself), one line at a time otherwise. Restoring the
/// terminal is idempotent and runs on every exit path; a session that
/// left a terminal in raw mode would be a bug he feels immediately.
final class KeyReader {
    let scripted: Bool
    private var original = termios()
    private var isRaw = false

    init(scripted: Bool) {
        self.scripted = scripted
        if !scripted { raw() }
    }

    func raw() {
        guard !scripted, !isRaw else { return }
        tcgetattr(FileHandle.standardInput.fileDescriptor, &original)
        var mode = original
        mode.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        withUnsafeMutablePointer(to: &mode.c_cc) { cc in
            cc.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { bytes in
                bytes[Int(VMIN)] = 1
                bytes[Int(VTIME)] = 0
            }
        }
        tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &mode)
        isRaw = true
    }

    func restore() {
        guard isRaw else { return }
        tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &original)
        isRaw = false
    }

    /// The next key, nil at end of input. Enter reads as the empty string
    /// (the state machine's "commit / go back"); Ctrl-C and Ctrl-D read as
    /// `q` so the session closes through the normal path and the records
    /// already written stay.
    func key() -> String? {
        if scripted { return line() }
        var byte: UInt8 = 0
        let n = read(FileHandle.standardInput.fileDescriptor, &byte, 1)
        guard n == 1 else { return nil }
        switch byte {
        case 0x03, 0x04: return "q"
        case 0x0A, 0x0D: print(""); return ""
        default:
            let key = String(UnicodeScalar(byte))
            print(key)
            return key
        }
    }

    /// One line of standard input (scripted mode, and the `e` key's
    /// replacement gold), nil at EOF.
    func line() -> String? {
        readLine(strippingNewline: true)
    }
}
