#if os(macOS)
import ApplicationServices
import CoreGraphics

/// A process's menu-bar item as the accessibility tree reports it.
///
/// This is the only place the app can ask where its own icon sits (see
/// `StatusItemVisibility`): `AXExtrasMenuBar` lists the process's status items
/// with their frames, and keeps listing one that macOS has hidden.
///
/// Which thread to call it from depends on whose tree it is. Another process's
/// is synchronous IPC and needs the Accessibility permission (the app holds it,
/// to paste): call it OFF the main thread, where it can wait up to `timeout`.
/// This process's own, the default, is no IPC and needs no permission:
/// HIServices calls AppKit's accessibility code right on the calling thread
/// (measured on macOS 26.5: a process that was not trusted still read its own
/// item), and AppKit belongs to the main thread. So call it ON the main thread.
/// Nothing is waited for there (milliseconds), so the main thread is never left
/// waiting on itself.
public enum AXStatusItem {
    /// The frame of the first item in `pid`'s extras menu bar, global with the
    /// origin at the top-left of the primary display; nil when there is none or
    /// any part of it cannot be read. A zero-size frame is returned as is —
    /// the tree reports one for items that are not laid out.
    public static func frame(pid: pid_t = getpid(), timeout: Float = 0.5) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)

        guard let bar = element(app, "AXExtrasMenuBar"),
              let item = children(bar).first,
              let position = pointAttribute(item, kAXPositionAttribute),
              let size = sizeAttribute(item, kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, name as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    private static func children(_ parent: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &ref) == .success
        else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        return (ref as! AXValue)
    }

    private static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        var out = CGPoint.zero
        guard let value = axValue(element, name), AXValueGetValue(value, .cgPoint, &out) else { return nil }
        return out
    }

    private static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        var out = CGSize.zero
        guard let value = axValue(element, name), AXValueGetValue(value, .cgSize, &out) else { return nil }
        return out
    }
}
#endif
