import SwiftUI
import UIKit

/// The whispr-bro keyboard appex (issue #13 — this stub only proves the target
/// builds; phase P4 replaces it). A keyboard extension can never record audio
/// and lives under a ~48–80MB jetsam cap, so this target stays a thin client:
/// no models, no audio, no networking, no WhisprBroCore. For the stub the mic
/// key only deep-links to the main app; the real session IPC (status page +
/// command mailbox + Darwin hints, see `KeyboardIPC`) lands in phases P4/P5.
final class KeyboardViewController: UIInputViewController {
    private var globeKey: UIButton?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Palette.paper)

        let host = UIHostingController(rootView: StubRow { [weak self] in
            self?.openMainApp()
        })
        addChild(host)
        host.view.backgroundColor = .clear

        // Apple requires the next-keyboard affordance. It must be a UIButton
        // feeding handleInputModeList(from:with:) the raw UIEvent — a SwiftUI
        // Button has no event to forward, so this one key stays UIKit.
        let globe = UIButton(type: .system)
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.tintColor = UIColor(Palette.ink)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeKey = globe

        let row = UIStackView(arrangedSubviews: [globe, host.view])
        row.axis = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            globe.widthAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Single-row keyboard: override the system's default keyboard height.
        // Must be added once the view is in the hierarchy; 999 avoids fighting
        // the system's own height constraint.
        if heightConstraint == nil {
            let constraint = view.heightAnchor.constraint(equalToConstant: 72)
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeKey?.isHidden = !needsInputModeSwitchKey
    }

    /// Best-effort deep link into the main app. The UIResponder-chain openURL
    /// trick is dead on iOS 18+; `extensionContext?.open` is the remaining
    /// route and is not guaranteed for keyboards — hence the always-visible
    /// "open whispr bro" label as the manual fallback. Phase P4 replaces this
    /// with the real flow: mic tap → mailbox command + Darwin hint → deep link
    /// only to arm a session, bounce key only on the two-signal dead-session
    /// verdict (see `Liveness`).
    private func openMainApp() {
        guard let url = URL(string: "whisprbro://session/start") else { return }
        extensionContext?.open(url, completionHandler: nil)
    }
}

/// Brand palette subset. `Brand` in the macOS app is AppKit-bound and the appex
/// links neither the app nor core, so the three needed values are restated.
private enum Palette {
    static let ink = Color(red: 0x17 / 255.0, green: 0x13 / 255.0, blue: 0x0E / 255.0)
    static let paper = Color(red: 0xF4 / 255.0, green: 0xEF / 255.0, blue: 0xE4 / 255.0)
    static let raised = Color(red: 0xFB / 255.0, green: 0xF8 / 255.0, blue: 0xF1 / 255.0)
}

/// The stub's single row: mic key + fallback label, both deep-linking to the
/// app. Phase P4 adds the live mic key + waveform strip; P8 productizes the
/// full QWERTY.
private struct StubRow: View {
    var openApp: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openApp) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.paper)
                    .frame(width: 64, height: 44)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
            }
            Button(action: openApp) {
                Text("open whispr bro")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
        .frame(maxHeight: .infinity)
    }
}
