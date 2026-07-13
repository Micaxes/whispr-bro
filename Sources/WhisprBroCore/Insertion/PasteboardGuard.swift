#if os(macOS)
import AppKit

extension NSPasteboard.PasteboardType {
    /// nspasteboard.org convention: content is on the board only momentarily —
    /// clipboard managers should not record it.
    static let nsTransient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// nspasteboard.org convention: content is confidential — managers skip or
    /// conceal it (some treat it password-like).
    static let nsConcealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

/// Owns the write-then-restore clipboard dance for paste-based insertion
/// (spec §4 PasteboardGuard, §7 privacy). Guarantees:
///  - the user's ORIGINAL clipboard (all representations, not just strings) is
///    snapshotted and restored, surviving image/file content;
///  - back-to-back dictations carry the original snapshot forward, so
///    dictation N+1 never mistakes dictation N's transient text for the user's
///    clipboard;
///  - restore only happens if nobody else wrote the board meanwhile
///    (`changeCount` guard), so a user copy during the window wins;
///  - dictated text is marked transient + concealed so clipboard managers skip
///    it.
///
/// Known limitation: the transient/concealed markers are clipboard-manager
/// conventions; they do NOT suppress macOS Universal Clipboard, so dictated
/// text can briefly sync to other signed-in Apple devices during the restore
/// window. Promised/lazy pasteboard content (e.g. file promises) also can't be
/// snapshotted without fulfilling it, so it isn't restored — but such items
/// are detected and left untouched rather than clobbered with empties.
///
/// Main-queue only.
public final class PasteboardGuard {
    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval

    private var pendingOriginal: [[NSPasteboard.PasteboardType: Data]]?
    private var pendingRestore: DispatchWorkItem?

    public init(pasteboard: NSPasteboard = .general, restoreDelay: TimeInterval = 2.0) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
    }

    /// Write `text` (marked transient/concealed) and schedule restore of the
    /// user's clipboard after `restoreDelay`.
    public func writeTransient(_ text: String) {
        // A pending restore means the board currently holds OUR previous
        // transient text — keep the earlier (real) snapshot.
        if let pendingRestore {
            pendingRestore.cancel()
        } else {
            pendingOriginal = snapshot()
        }

        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .nsTransient, .nsConcealed], owner: nil)
        pasteboard.setString(text, forType: .string)
        // Presence of the marker type is the signal; empty value is convention.
        pasteboard.setString("", forType: .nsTransient)
        pasteboard.setString("", forType: .nsConcealed)
        let changeCountAfterWrite = pasteboard.changeCount

        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestore = nil
            let original = self.pendingOriginal
            self.pendingOriginal = nil
            guard self.pasteboard.changeCount == changeCountAfterWrite else { return }
            self.write(original ?? [])
        }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: restore)
    }

    private func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            // Drop items we captured nothing for (promised/lazy content): a
            // materialized-empty NSPasteboardItem would clobber the original
            // rather than restore it.
            return representations.isEmpty ? nil : representations
        }
    }

    private func write(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        // Nothing safely captured → leave the current board alone rather than
        // clearing it to empty (which would itself be data loss).
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let pasteboardItems = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}
#endif
