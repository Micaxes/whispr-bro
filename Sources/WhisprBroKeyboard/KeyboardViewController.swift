import SwiftUI
import UIKit
import WhisprBroIPC

/// The whispr-bro keyboard appex (issue #13 P4, layout rev): a toolbar row —
/// [status strip][settings][mic at the far right] — above a standard
/// iOS-style typing grid (`KeyGrid`). A keyboard extension can never record
/// audio and lives under a ~48MB jetsam cap, so this target stays a thin IPC
/// client: audio + models live only in the main app; the keyboard posts
/// commands into the keyboard-owned mailbox, polls the app's status page at
/// ~20Hz while visible, and inserts transcripts from the result drop under
/// the keyboardInstanceNonce stale-target guard (see `KeyboardIPC`). No core,
/// no audio, no networking.
final class KeyboardViewController: UIInputViewController {
    private var session: KeyboardSession?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        // CLEAR, not cream: the system draws the native keyboard background
        // material behind this view, and letting it show through is what
        // blends the appex with iOS chrome in light AND dark mode. If a host
        // ever renders us without that material, switch to
        // `Palette.chromeFallback` here — never back to an opaque brand
        // color.
        view.backgroundColor = .clear

        // One session — and one keyboardInstanceNonce — per viewDidLoad, per
        // the `TranscriptResult` contract: a nonce match is what proves this
        // same instance (same host app, same text field) is still frontmost,
        // so a fresh instance must never inherit an older one's identity.
        let session = KeyboardSession()
        session.insertText = { [weak self] text in
            // The ONE insertion path (auto on nonce match, manual on the
            // pending-result key) — a single insertText per transcript.
            self?.textDocumentProxy.insertText(text)
        }
        session.openApp = { [weak self] in self?.openMainApp() }
        self.session = session

        // `controller: self` is the weak reference `GlobeKey` needs for the
        // one key that must stay UIKit (raw-UIEvent forwarding — see its doc).
        let host = UIHostingController(rootView: KeyboardBar(
            session: session,
            controller: self,
            insertCharacter: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            insertNewline: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            openSettings: { [weak self] in self?.openAppSettings() }))
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            host.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Toolbar (40pt) + four key rows ≈ the system keyboard's own height.
        // Must be added once the view is in the hierarchy; 999 avoids
        // fighting the system's own height constraint.
        if heightConstraint == nil {
            let constraint = view.heightAnchor.constraint(equalToConstant: 260)
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
            heightConstraint = constraint
        }
        // Full Access can change in Settings between appearances.
        session?.hasFullAccess = hasFullAccess
        session?.startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Off screen = no polling, no hint delivery, no auto-insert ever.
        session?.stopPolling()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // The grid's globe key follows the system's verdict (it can change
        // per host app). Guarded write: publishing on every layout pass would
        // re-render → re-layout, forever.
        if session?.needsInputModeSwitchKey != needsInputModeSwitchKey {
            session?.needsInputModeSwitchKey = needsInputModeSwitchKey
        }
    }

    /// Deep link out of the appex. The UIResponder-chain openURL trick is
    /// dead on iOS 18+; `extensionContext?.open` is the remaining route and
    /// is not guaranteed for keyboards — hence the status strip's "finishing
    /// in whispr bro" hint doubles as the manual fallback instruction.
    private func open(_ url: URL) {
        extensionContext?.open(url, completionHandler: nil)
    }

    /// How the mic key arms a session (and how the bounce key revives a dead
    /// one).
    private func openMainApp() {
        guard let url = URL(string: "whisprbro://session/start") else { return }
        open(url)
    }

    /// How the toolbar gear reaches the app's Settings sheet.
    private func openAppSettings() {
        guard let url = URL(string: "whisprbro://settings") else { return }
        open(url)
    }
}
