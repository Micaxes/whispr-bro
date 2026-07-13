#if os(macOS)
import AppKit
import CoreGraphics

/// Inserts text at the cursor of the frontmost app via clipboard + synthetic
/// Cmd+V (spec §4 TextInserter) — the proven universal path; per-character
/// keystroke injection is not viable on macOS. Requires the Accessibility
/// permission to post the CGEvent. Must be used from the main queue.
///
/// The AX direct-set fast path (`AXUIElementSetAttributeValue` on
/// `kAXSelectedTextAttribute`) is intentionally NOT used yet: it acks-without-
/// inserting on Electron/Chromium, its read-back verification is ambiguous
/// (risking silent drops or double-insertion), and its four synchronous AX IPC
/// calls would block the main actor. It is deferred until it can be
/// per-app-gated and verified reliably (tracked for a later task).
public final class TextInserter {
    /// kVK_ANSI_V
    private static let vKeyCode: CGKeyCode = 9

    private let pasteboardGuard: PasteboardGuard
    /// Settle delay so the released hotkey modifier isn't merged into the
    /// synthetic Cmd+V.
    private let pasteDelay: TimeInterval

    public init(pasteboardGuard: PasteboardGuard = PasteboardGuard(), pasteDelay: TimeInterval = 0.05) {
        self.pasteboardGuard = pasteboardGuard
        self.pasteDelay = pasteDelay
    }

    /// Insert `text` at the cursor. `completion` runs on the main queue once
    /// the paste event has been posted.
    public func insert(_ text: String, completion: (() -> Void)? = nil) {
        pasteboardGuard.writeTransient(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [self] in
            postCmdV()
            completion?()
        }
    }

    private func postCmdV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        // Exactly the Command chord — posting to the session tap (not the HID
        // tap) so a physically-held hotkey modifier isn't merged into it.
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
#endif
