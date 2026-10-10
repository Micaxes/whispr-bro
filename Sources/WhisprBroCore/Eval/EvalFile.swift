import Foundation

/// Every file the eval surface writes, written owner-only (0600) with no
/// readable window — one helper so no writer can forget.
///
/// The rule exists because of what these files hold: a run JSON stores
/// every row's raw dictation and output verbatim, a report quotes them, a
/// ratings log carries his hand-edited golds, and even a leaderboard line
/// says what he measured and when. `Data.write(options: .atomic)` and
/// `FileManager.createFile(atPath:contents:)` both create 0644 (umask
/// 022) — world-readable on a shared Mac, and readable by anything running
/// as another user — so neither is called directly anywhere in the bench.
/// `write` stages the bytes in a sibling file **created empty** at 0600
/// and streams them into that descriptor — never a chmod after the bytes
/// land (it would leave a window where they are on disk at 0644), and
/// never `createFile(contents:)` with a payload either: on Darwin that
/// routes through `NSData`'s atomic write, which lands the WHOLE payload
/// in an auxiliary file at 0644 and only then applies the mode, the same
/// window by another name. `appendLine` creates the file 0600 and
/// re-asserts the mode on a file that already exists before it appends a
/// byte. The pattern is `history-export`'s, lifted here so `eval`,
/// `score`, `rate`, `gold` and `calibrate` share it.
public enum EvalFile {
    /// Owner read/write, nothing else.
    public static let mode = 0o600
    /// New directories this helper creates (a `runs/` under the private
    /// eval home) are owner-only too.
    public static let directoryMode = 0o700

    public enum WriteError: Error, Equatable, CustomStringConvertible {
        case failed(path: String, reason: String)

        public var description: String {
            switch self {
            case .failed(let path, let reason): return "could not write \(path): \(reason)"
            }
        }
    }

    /// Writes `data` to `path`, owner-only, atomically. The staging file
    /// sits beside the target (same volume, so the swap is a rename) and
    /// is removed on any failure — a failed write never costs him the file
    /// that was there.
    public static func write(_ data: Data, to path: String, fileManager: FileManager = .default) throws {
        let url = URL(fileURLWithPath: path)
        try createDirectory(for: url, fileManager: fileManager)
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
        // Empty first, at the mode; the bytes go into the descriptor after
        // — `contents: data` here would hand the payload to NSData's
        // atomic write, whose own auxiliary file is 0644 until the mode is
        // applied at the end (the window this helper exists to close).
        guard fileManager.createFile(atPath: staging.path, contents: nil,
                                     attributes: [.posixPermissions: mode]) else {
            throw WriteError.failed(path: path, reason: "could not create \(staging.lastPathComponent)")
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if fileManager.fileExists(atPath: url.path) {
                // `usingNewMetadataOnly` keeps the staging file's 0600
                // rather than inheriting the old file's mode.
                _ = try fileManager.replaceItemAt(url, withItemAt: staging, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: staging, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw WriteError.failed(path: path, reason: error.localizedDescription)
        }
    }

    /// Appends one line (the JSONL record plus its newline) to `path`,
    /// creating the file 0600 when it does not exist and re-asserting the
    /// mode when it does — a file that predates this helper (or one a
    /// hand-run `echo` created) is tightened before it grows.
    public static func appendLine(_ line: Data, to path: String, fileManager: FileManager = .default) throws {
        let url = URL(fileURLWithPath: path)
        try createDirectory(for: url, fileManager: fileManager)
        do {
            if fileManager.fileExists(atPath: path) {
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
            } else if !fileManager.createFile(atPath: path, contents: nil,
                                              attributes: [.posixPermissions: mode]) {
                throw WriteError.failed(path: path, reason: "could not create the file")
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data("\n".utf8))
        } catch let error as WriteError {
            throw error
        } catch {
            throw WriteError.failed(path: path, reason: error.localizedDescription)
        }
    }

    /// The POSIX permission bits of a path, nil when it does not exist —
    /// what the tests assert and what `rate` prints beside its output.
    public static func posixPermissions(of path: String, fileManager: FileManager = .default) -> Int? {
        (try? fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)??.intValue
    }

    /// A private output path that must never land in a source checkout:
    /// ratings, derived fixture files and calibration reports all carry
    /// (or name) his dictations. Same test `--append` and `history-export`
    /// apply — an ancestor holding `Package.swift` or `.git`.
    public static func refusesPrivatePath(_ path: String, fileManager: FileManager = .default) -> Bool {
        Leaderboard.isInsideRepoTree(path, fileManager: fileManager)
    }

    /// `$WHISPR_EVAL_HOME`, where the private set lives; nil when unset.
    /// The bench never defaults a write path into it — a file is written
    /// only where a flag says — but a READ (`--ratings`, the calibration
    /// record) falls back to it so the banner is live without a flag.
    public static func evalHome(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let raw = environment["WHISPR_EVAL_HOME"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        return NSString(string: raw).expandingTildeInPath
    }

    private static func createDirectory(for url: URL, fileManager: FileManager) throws {
        let directory = url.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: directoryMode])
        } catch {
            throw WriteError.failed(path: url.path, reason: error.localizedDescription)
        }
    }
}
