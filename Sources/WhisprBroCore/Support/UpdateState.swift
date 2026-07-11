import Foundation

/// Where releases live. whispr-bro is distributed as a GitHub repo, so "is there
/// a newer version?" is answered by the latest release tag. These are plain
/// string constants — the app itself never opens a connection (see the module
/// note below); the out-of-process helper script does.
public enum UpdateEndpoint {
    public static let repo = "Micaxes/whispr-bro"
    /// The page a user lands on to download a new build. `/releases/latest`
    /// resolves to the newest non-prerelease tag, and GitHub renders the notes +
    /// assets there. Opened in the user's browser by the app; never fetched.
    public static let releasesLatestURL = "https://github.com/Micaxes/whispr-bro/releases/latest"
}

/// The result the out-of-process update helper writes to disk (`update-state.json`
/// under `Paths.home`). The app *reads* this file — ordinary disk I/O — and never
/// performs the network fetch itself, preserving the "zero networking code in the
/// binary" guarantee (audit-offline.sh Tier 0/1/2, net-tripwire, tcpdump).
public struct UpdateState: Codable, Equatable, Sendable {
    public let latestTag: String
    public let releaseURL: String
    public let checkedAt: Double

    public init(latestTag: String, releaseURL: String, checkedAt: Double) {
        self.latestTag = latestTag
        self.releaseURL = releaseURL
        self.checkedAt = checkedAt
    }

    /// Load + decode the helper's state file. Any error (missing / malformed /
    /// partial write) yields nil — the app simply shows no update.
    public static func load(from file: URL) -> UpdateState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(UpdateState.self, from: data)
    }
}

/// Whether a newer release exists, decided by comparing the running version
/// against the helper's recorded latest tag. Pure + testable.
public enum UpdateAvailability: Equatable, Sendable {
    /// No state on disk yet (never checked, or a check hasn't completed).
    case unknown
    case upToDate
    case available(tag: String, url: String)
}

public enum UpdateStatus {
    /// `current` is the running build's `CFBundleShortVersionString`; `state` is
    /// the helper's last recorded result. Unparseable versions → `.unknown` so a
    /// bad tag never nags the user with a phantom update.
    public static func evaluate(current: String, state: UpdateState?) -> UpdateAvailability {
        guard let state else { return .unknown }
        guard let cur = SemVer(current), let latest = SemVer(state.latestTag) else { return .unknown }
        return latest > cur ? .available(tag: state.latestTag, url: state.releaseURL) : .upToDate
    }
}
