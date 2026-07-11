import Foundation

/// A minimal semantic version (major.minor.patch) with a `v`-prefix tolerance,
/// used only to compare the running app's `CFBundleShortVersionString` against a
/// GitHub release tag. Pre-release / build metadata (anything after `-` or `+`)
/// is ignored for ordering, so `v0.2.0-beta.1` compares equal to `0.2.0`.
///
/// Pure value type — no I/O, no networking — so the update-detection logic stays
/// unit-testable and lives comfortably inside the offline-audited core.
public struct SemVer: Comparable, Equatable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Parse `"0.2.0"`, `"v0.2.0"`, `"V1"`, `"1.2"` (missing components → 0).
    /// Returns nil if the leading numeric component isn't an integer, so a
    /// garbage tag never masquerades as a newer version.
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let maj = Int(first) else { return nil }
        let min = parts.count > 1 ? Int(parts[1]) : 0
        let pat = parts.count > 2 ? Int(parts[2]) : 0
        guard let min, let pat else { return nil }
        self.major = maj
        self.minor = min
        self.patch = pat
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
