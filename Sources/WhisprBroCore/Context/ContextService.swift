import AppKit

/// Reads the app being dictated into, to drive per-app formatting style
/// (spec §4 ContextService). This is deliberately IPC-free: the category comes
/// from the frontmost app's bundle id via a map, so it is safe to call
/// synchronously on the capture hot path (0ms on the critical path).
///
/// Reading nearby-cursor text via AX is intentionally NOT included: for a
/// privacy-first app it's a liability — web/Electron password and 2FA fields
/// frequently don't expose the secure subrole, so bounded AX reads could pull
/// a password or a whole document into the LLM prompt. Deferred until it can be
/// made reliably safe.
public enum ContextService {
    /// The frontmost app's bundle id + display name (IPC-free). Sample AT
    /// key-press — frontmost moves during dictation. The pipeline resolves the
    /// category with the config's overrides applied, and stores both in history.
    @MainActor
    public static func frontmostApp() -> (bundleId: String?, appName: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.bundleIdentifier, app?.localizedName)
    }
}
