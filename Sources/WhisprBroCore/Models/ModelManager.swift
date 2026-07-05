import Foundation
import CryptoKit
import os.log

/// Integrity + presence view over the installed model sets (spec §11.7
/// "ModelManager pane with on-disk sha256 verify").
///
/// The same `*.sha256` manifests that `scripts/fetch-models.sh` verifies at
/// install time are shipped in the app bundle so the running app can re-verify
/// on disk — catching a truncated download, a corrupted file, or tampering,
/// and telling the user exactly which model to re-fetch. Reads only; never
/// downloads (that stays an explicit, offline-by-construction install step).
public enum ModelManager {

    public enum FileState: String, Sendable { case ok, mismatch, missing, unreadable }

    public struct FileStatus: Sendable, Identifiable {
        public let relativePath: String
        public let state: FileState
        public var id: String { relativePath }
    }

    public struct GroupStatus: Sendable, Identifiable {
        public let id: String            // stable key, e.g. "asr"
        public let displayName: String
        public let rootDir: URL
        public let files: [FileStatus]
        public let manifestFound: Bool
        /// True for a group whose manifest lists several INDEPENDENTLY optional
        /// files (the LLM presets: a user installs one, not all). A `.missing`
        /// file then means "that preset isn't installed", not "broken".
        public let partialOK: Bool

        private var present: [FileStatus] { files.filter { $0.state != .missing } }
        private var broken: [FileStatus] { files.filter { $0.state == .mismatch || $0.state == .unreadable } }

        /// At least the required files are on disk. `!files.isEmpty` guards
        /// against a vacuous allSatisfy over an empty manifest reading as OK.
        public var isInstalled: Bool {
            guard manifestFound, !files.isEmpty else { return false }
            return partialOK ? !present.isEmpty : files.allSatisfy { $0.state != .missing }
        }
        /// Everything that must be present is present and hash-verified. For a
        /// partial-OK group, only the installed presets must verify.
        public var isVerified: Bool {
            guard manifestFound, !files.isEmpty, isInstalled, broken.isEmpty else { return false }
            return partialOK ? !present.isEmpty : files.allSatisfy { $0.state == .ok }
        }

        public var summary: String {
            guard manifestFound else { return "manifest missing" }
            let missing = files.filter { $0.state == .missing }.count
            let bad = files.filter { $0.state == .mismatch }.count
            let unreadable = files.filter { $0.state == .unreadable }.count
            if partialOK {
                let installed = files.count - missing
                if installed == 0 { return "none of \(files.count) installed" }
                if bad > 0 || unreadable > 0 { return "\(installed) installed, \(bad + unreadable) failing" }
                return "\(installed) of \(files.count) installed, verified"
            }
            if missing == files.count { return "not installed" }
            if missing > 0 { return "\(missing) file(s) missing" }
            if unreadable > 0 { return "\(unreadable) file(s) unreadable" }
            if bad > 0 { return "\(bad) file(s) hash mismatch" }
            return "verified (\(files.count) files)"
        }
    }

    /// One installed model set: a manifest file paired with the on-disk root
    /// its relative paths resolve against. `partialOK` groups treat each file as
    /// an independently optional install (the selectable LLM presets).
    private struct Group {
        let id: String
        let displayName: String
        let manifest: String
        let root: URL
        var partialOK: Bool = false
    }

    private static let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "models")

    private static var groups: [Group] {
        [
            Group(id: "asr", displayName: "Parakeet ASR (CoreML)",
                  manifest: "models.sha256",
                  root: Paths.modelsDir.appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)),
            Group(id: "vad", displayName: "Silero VAD (CoreML)",
                  manifest: "models-vad.sha256",
                  root: Paths.modelsDir.appendingPathComponent("silero-vad", isDirectory: true)),
            Group(id: "llm", displayName: "Formatting LLMs (GGUF)",
                  manifest: "models-llm.sha256",
                  root: Paths.llmDir, partialOK: true),
        ]
    }

    /// Verify every model group. Runs sha256 over on-disk files, so call it off
    /// the main thread. `manifestsDir` defaults to the resolved bundle/dev dir.
    public static func verifyAll(manifestsDir: URL? = nil) -> [GroupStatus] {
        let dir = manifestsDir ?? defaultManifestsDir()
        return groups.map { verify($0, manifestsDir: dir) }
    }

    private static func verify(_ group: Group, manifestsDir: URL?) -> GroupStatus {
        guard let manifestsDir,
              let expected = parseManifest(manifestsDir.appendingPathComponent(group.manifest))
        else {
            return GroupStatus(id: group.id, displayName: group.displayName,
                               rootDir: group.root, files: [], manifestFound: false,
                               partialOK: group.partialOK)
        }
        let files: [FileStatus] = expected.map { (rel, hash) in
            let url = group.root.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return FileStatus(relativePath: rel, state: .missing)
            }
            // nil == a read error on an existing file (see sha256): report it as
            // .unreadable, NOT .mismatch — it isn't a tampering signal.
            guard let actual = sha256(of: url) else {
                return FileStatus(relativePath: rel, state: .unreadable)
            }
            return FileStatus(relativePath: rel, state: actual == hash ? .ok : .mismatch)
        }
        return GroupStatus(id: group.id, displayName: group.displayName,
                           rootDir: group.root, files: files, manifestFound: true,
                           partialOK: group.partialOK)
    }

    /// Parse a `shasum -a 256` manifest: `<hex>␠␠<relative/path>` per line.
    /// Returns [(relativePath, lowercaseHex)] preserving order; nil if unreadable
    /// OR if it parses to zero entries — an empty/truncated/comments-only
    /// manifest is as unusable as a missing one (and must not vacuously "verify").
    static func parseManifest(_ url: URL) -> [(String, String)]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [(String, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // hash is the first whitespace-delimited token; the path is the rest
            // (may contain spaces), with shasum's leading '*'/space marker stripped.
            guard let sp = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hash = String(trimmed[trimmed.startIndex..<sp]).lowercased()
            var path = String(trimmed[trimmed.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("*") { path.removeFirst() }
            if hash.count == 64, !path.isEmpty { out.append((path, hash)) }
        }
        return out.isEmpty ? nil : out
    }

    /// Streaming SHA-256 so multi-GB GGUFs don't load into memory at once.
    /// Returns nil on a genuine read error (distinct from clean EOF) so a mid-
    /// file I/O failure surfaces as unreadable, not as a bogus partial-content
    /// hash that would masquerade as a tampering mismatch.
    public static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) }
            catch { log.error("sha256 read failed for \(url.lastPathComponent): \(error.localizedDescription)"); return nil }
            guard let chunk, !chunk.isEmpty else { break }   // nil/empty == EOF
            autoreleasepool { hasher.update(data: chunk) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Where the shipped `*.sha256` manifests live: the app bundle's
    /// Resources/manifests (added by make-app.sh), or, for dev/bench runs, the
    /// repo `scripts/` dir found by walking up from the executable.
    public static func defaultManifestsDir() -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let m = res.appendingPathComponent("manifests", isDirectory: true)
            if fm.fileExists(atPath: m.appendingPathComponent("models.sha256").path) { return m }
        }
        // dev fallback: …/whispr-bro/scripts next to a source checkout
        var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        for _ in 0..<8 {
            let scripts = dir.appendingPathComponent("scripts", isDirectory: true)
            if fm.fileExists(atPath: scripts.appendingPathComponent("models.sha256").path) { return scripts }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}
