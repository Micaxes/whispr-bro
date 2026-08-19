import Foundation

/// Resolves the App Group container all three IPC artifacts live in.
///
/// GRACEFUL DEGRADATION, load-bearing: the three ios/*.entitlements currently
/// have the App Group REMOVED (free-personal-team device-signing workaround),
/// so `containerURL(forSecurityApplicationGroupIdentifier:)` returning nil is
/// an expected configuration, not an error. Callers treat nil as "IPC
/// disabled": the keyboard stays on the deep-link-only stub behavior and the
/// app runs sessions without a status page. One log line (not one per poll
/// tick) records why.
public enum SharedContainer {
    /// Test hook: when set, `url()` returns this directory instead of asking
    /// the entitlement system, so every IPC type is exercisable from plain
    /// `swift test` with a temp directory.
    public static var directoryOverride: URL?

    private static var didLogMissing = false

    public static func url() -> URL? {
        if let directoryOverride { return directoryOverride }
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardIPC.appGroupID) else {
            if !didLogMissing {
                didLogMissing = true
                NSLog(
                    "[WhisprBroIPC] App Group container %@ unavailable (entitlement absent?) — session IPC disabled",
                    KeyboardIPC.appGroupID)
            }
            return nil
        }
        return url
    }
}
