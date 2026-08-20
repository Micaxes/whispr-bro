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

    /// Deep link out of the appex — the DTS-sanctioned route (thread 812091):
    /// walk the responder chain up from this controller to the first responder
    /// that implements `openURL:options:completionHandler:` (UIApplication, or
    /// on newer iOS a UIScene — the selector matches both, KeyboardKit-style)
    /// and invoke it through its IMP. `UIApplication.shared`/`open` don't
    /// compile in an appex; the IMP cast is the sanctioned escape. Options and
    /// completion are passed nil on purpose: UIScene's options parameter is a
    /// `UISceneOpenExternalURLOptions` OBJECT, not a dictionary, so an empty
    /// NSDictionary would be wrongly typed there. On iOS 26+ this requires
    /// Full Access (sandbox error -54 without it) — acceptable: the mic key is
    /// already hidden without Full Access (`KeyboardBar`). `extensionContext?
    /// .open` is a NO-OP from keyboard extensions on every iOS version, kept
    /// only as a can't-hurt last resort behind the walk.
    private func open(_ url: URL) {
        let selector = sel_registerName("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                typealias OpenURLMethod = @convention(c) (
                    AnyObject, Selector, NSURL, AnyObject?, AnyObject?) -> Void
                let method = unsafeBitCast(current.method(for: selector), to: OpenURLMethod.self)
                method(current, selector, url as NSURL, nil, nil)
                return
            }
            responder = current.next
        }
        extensionContext?.open(url, completionHandler: nil) // last resort, historically a no-op
    }

    /// How the mic key arms a session (and how the bounce key revives a dead
    /// one). `source=keyboard` tells the app's router this arm came from the
    /// keyboard: it preserves the tap's pre-posted `startDictation` across the
    /// bring-up mailbox flush (`KeyboardSession.micTapped` posts it before
    /// this deep link fires) and enables the session card's return-to-app
    /// switchback — neither of which an intent / Control Center arm may
    /// trigger, so those keep the plain URL.
    private func openMainApp() {
        guard let url = URL(string: "whisprbro://session/start?source=keyboard") else { return }
        open(url)
    }

    /// How the toolbar gear reaches the app's Settings sheet.
    private func openAppSettings() {
        guard let url = URL(string: "whisprbro://settings") else { return }
        open(url)
    }
}
