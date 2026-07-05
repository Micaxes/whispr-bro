import ApplicationServices
import Carbon.HIToolbox

/// Detects when dictation must be refused because a password/secure field is
/// involved (spec §4 secure-field refusal, §7 privacy).
///
/// Two signals with very different costs:
///  - `isSystemSecureInputActive`: `IsSecureEventInputEnabled()` — a cheap,
///    non-IPC read of window-server state. Safe to call on the capture hot
///    path. True when a native password field / loginwindow / Terminal secure
///    keyboard entry is active. (It is *system-wide*, so it can over-refuse
///    when e.g. Terminal's Secure Keyboard Entry is globally on — but in that
///    state our synthetic events may not land anyway, so refusing is safe.)
///  - `isFocusedFieldSecure`: an AX round-trip that inspects the focused
///    element's subrole. Catches browser/Electron password fields that never
///    toggle system secure input. This is synchronous cross-process IPC, so it
///    must only run OFF the capture hot path (before insertion).
public enum SecureInput {
    /// Cheap, non-blocking — safe on the key-down hot path.
    public static var isSystemSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// AX round-trip — do NOT call on the capture hot path. Needs Accessibility
    /// permission; without it returns false (the system-wide check still guards).
    public static var isFocusedFieldSecure: Bool {
        guard let element = AXFocus.focusedElement() else { return false }
        return elementIsSecure(element)
    }

    /// True if `element` or one of its (bounded) ancestors is a secure field —
    /// some toolkits put the secure subrole on a wrapper.
    public static func elementIsSecure(_ element: AXUIElement, maxHops: Int = 3) -> Bool {
        var current: AXUIElement? = element
        var hops = 0
        while let el = current, hops <= maxHops {
            if AXFocus.stringAttribute(el, kAXSubroleAttribute as String)
                == (kAXSecureTextFieldSubrole as String) {
                return true
            }
            current = AXFocus.parent(el)
            hops += 1
        }
        return false
    }

    /// Full authoritative check for the insertion path (off the hot path).
    /// Re-evaluate here rather than trusting a key-down snapshot — focus moves.
    public static var shouldRefuse: Bool {
        isSystemSecureInputActive || isFocusedFieldSecure
    }
}
