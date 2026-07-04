import ApplicationServices

/// Shared access to the system-wide focused UI element (spec §4). Used by
/// secure-field detection today; the AX direct-set insertion path (deferred)
/// will reuse it. Every call is synchronous cross-process IPC — callers must
/// keep it OFF the capture hot path (see PipelineController).
public enum AXFocus {
    /// The currently focused element, with a bounded messaging timeout so a
    /// hung target app can't freeze the caller for the AX default (~6s).
    public static func focusedElement(timeout: Float = 0.25) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
            let ref, CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    /// Read a string attribute off an element, or nil.
    public static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let value = ref as? String
        else { return nil }
        return value
    }
}
