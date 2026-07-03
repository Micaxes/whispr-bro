import AppKit
import CoreGraphics

/// Inserts text at the cursor of the frontmost app via clipboard + synthetic
/// Cmd+V (spec §4 TextInserter) — the proven macOS path; per-character
/// keystroke injection is not viable. Requires the Accessibility permission
/// to post the CGEvent.
///
/// Clipboard etiquette: the previous pasteboard contents are snapshotted with
/// ALL representations (not just strings — images/files survive), restored
/// after `restoreDelay` behind a `changeCount` guard so a user copy in the
/// window wins. Back-to-back dictations carry the ORIGINAL snapshot forward:
/// dictation N+1 must never mistake dictation N's transient text for the
/// user's clipboard.
///
/// The AX direct-set fast path and `org.nspasteboard.ConcealedType` marking
/// arrive with task-008's PasteboardGuard. Must be used from the main queue.
public final class TextInserter {
    /// kVK_ANSI_V
    private static let vKeyCode: CGKeyCode = 9

    private let restoreDelay: TimeInterval
    /// Small settle delay so the released hotkey modifier is not merged into
    /// the synthetic Cmd+V. Deliberately inside the measured insert window:
    /// the user is really waiting through it.
    private let pasteDelay: TimeInterval

    /// Snapshot of the user's real clipboard while one or more dictation
    /// writes are in flight; nil when no restore is pending.
    private var pendingOriginal: [[NSPasteboard.PasteboardType: Data]]?
    private var pendingRestore: DispatchWorkItem?

    public init(restoreDelay: TimeInterval = 2.0, pasteDelay: TimeInterval = 0.05) {
        self.restoreDelay = restoreDelay
        self.pasteDelay = pasteDelay
    }

    /// Insert `text` at the cursor. Calls `completion` on the main queue after
    /// the paste event has been posted (before clipboard restore).
    public func insert(_ text: String, completion: (() -> Void)? = nil) {
        let pasteboard = NSPasteboard.general

        // Chained dictation: a pending restore means the board currently
        // holds OUR previous transient text — keep the earlier snapshot.
        if let pendingRestore {
            pendingRestore.cancel()
        } else {
            pendingOriginal = Self.snapshot(pasteboard)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestore = nil
            let original = self.pendingOriginal
            self.pendingOriginal = nil
            // Only restore if nobody else wrote the pasteboard meanwhile.
            guard pasteboard.changeCount == changeCountAfterWrite else { return }
            Self.write(original ?? [], to: pasteboard)
        }
        pendingRestore = restore

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [self] in
            postCmdV()
            completion?()
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: restore)
        }
    }

    // MARK: - Pasteboard snapshot/restore (all representations)

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            return representations
        }
    }

    private static func write(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pasteboardItems = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }

    private func postCmdV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
