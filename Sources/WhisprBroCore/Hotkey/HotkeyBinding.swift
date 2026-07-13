#if os(macOS)
import CoreGraphics
import Foundation

/// A first-class hotkey model (Wispr Flow-style: action → binding → gesture).
/// Replaces the single hardcoded key. Persisted as one JSON blob in
/// UserDefaults (like `cleanupLevel`/`historyEnabled`), NOT config.toml — a
/// recorder widget must round-trip keycodes/flags losslessly.

/// A thing the user can trigger. Each has one or more bindings.
public enum HotkeyAction: String, CaseIterable, Codable, Sendable {
    case dictate       // push-to-talk (hold): the primary path
    case handsFree     // hands-free lock (double-tap the dictate key)
    case commandMode   // hold: voice-edit the selected text via the LLM
    case cancel        // tap Esc: abort the in-flight dictation/command
    case pasteLast     // tap: re-paste the last transcript
    case copyLast      // tap: copy the last transcript to the clipboard

    public var displayName: String {
        switch self {
        case .dictate: return "Dictate (push-to-talk)"
        case .handsFree: return "Hands-free lock"
        case .commandMode: return "Command mode (voice edit)"
        case .cancel: return "Cancel"
        case .pasteLast: return "Paste last transcript"
        case .copyLast: return "Copy last transcript"
        }
    }

    public var subtitle: String {
        switch self {
        case .dictate: return "Hold to talk, release to insert."
        case .handsFree: return "Double-tap the dictate key; VAD auto-stops."
        case .commandMode: return "Select text, hold, and speak an edit (\"make it formal\")."
        case .cancel: return "Aborts without inserting (still saved to history)."
        case .pasteLast: return "Re-insert the most recent dictation."
        case .copyLast: return "Copy the most recent dictation to the clipboard."
        }
    }
}

/// How a binding is triggered.
public enum HotkeyGesture: String, Codable, Sendable {
    case hold        // .began on press, .ended on release (zero-debounce primary path)
    case doubleTap   // .fired on a second press within the window
    case tap         // .fired once on key-down
}

/// The phase reported to the consumer for an action.
public enum HotkeyPhase: Sendable { case began, ended, fired }

/// One physical trigger. A **modifier-only** binding (`isModifierOnly == true`,
/// e.g. Right-Option) is matched on `flagsChanged` via a device-specific mask —
/// the latency-free primary path. A **key** binding (a letter/Esc, optionally
/// with a modifier chord in `modifiers`) is matched on `keyDown`/`keyUp`.
public struct HotkeyBinding: Codable, Equatable, Sendable {
    public var keyCode: Int64
    /// Required modifier chord as `CGEventFlags` raw bits (0 = none). For a
    /// modifier-only binding this is any *additional* modifiers beyond the key
    /// itself (usually 0). For a key binding it's the chord that must be held.
    public var modifiers: UInt64
    public var gesture: HotkeyGesture
    public var isModifierOnly: Bool

    public init(keyCode: Int64, modifiers: UInt64 = 0, gesture: HotkeyGesture, isModifierOnly: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.gesture = gesture
        self.isModifierOnly = isModifierOnly
    }

    /// Modifier bits we compare on (ignore caps-lock / numeric-pad noise).
    public static let careMask: UInt64 =
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    /// Device-specific NX bit that distinguishes the left/right instance of a
    /// modifier key (so releasing Right-Option while Left-Option is held reads
    /// correctly). nil for non-modifier or unlisted keys.
    public var deviceSpecificMask: UInt64? {
        switch keyCode {
        case 61: return 0x40    // Right Option  (NX_DEVICERALTKEYMASK)
        case 58: return 0x20    // Left Option
        case 62: return 0x2000  // Right Control
        case 59: return 0x01    // Left Control
        case 54: return 0x10    // Right Command
        case 55: return 0x08    // Left Command
        case 60: return 0x04    // Right Shift
        case 56: return 0x02    // Left Shift
        default: return nil
        }
    }

    /// Whether the required modifier chord is satisfied by `flags`. Superset
    /// match — all required modifiers must be present, but extras are allowed. A
    /// no-modifier binding (Esc/cancel) always matches, so it fires even while
    /// another modifier (e.g. the held dictate key) is down.
    public func chordSatisfied(by flags: UInt64) -> Bool {
        let req = modifiers & Self.careMask
        return (flags & Self.careMask & req) == req
    }

    /// Human-readable label for the Settings recorder (e.g. "Right ⌥", "⌃⌥⌘V").
    public var displayString: String {
        if isModifierOnly, let name = Self.modifierKeyName[keyCode] {
            return name
        }
        var s = ""
        let m = modifiers
        if m & CGEventFlags.maskSecondaryFn.rawValue != 0 { s += "fn " }
        if m & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if m & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if m & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if m & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        return s + (Self.keyName[keyCode] ?? "key\(keyCode)")
    }

    static let modifierKeyName: [Int64: String] = [
        61: "Right ⌥", 58: "Left ⌥", 62: "Right ⌃", 59: "Left ⌃",
        54: "Right ⌘", 55: "Left ⌘", 60: "Right ⇧", 56: "Left ⇧", 63: "fn",
    ]
    static let keyName: [Int64: String] = [
        53: "esc", 49: "Space", 8: "C", 9: "V", 36: "Return",
    ]
}

/// The full, persisted set of bindings.
public struct HotkeyConfig: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var action: HotkeyAction
        public var binding: HotkeyBinding
        public init(_ action: HotkeyAction, _ binding: HotkeyBinding) {
            self.action = action; self.binding = binding
        }
    }
    public var entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    public func bindings(for action: HotkeyAction) -> [HotkeyBinding] {
        entries.filter { $0.action == action }.map { $0.binding }
    }

    /// Defaults mirror Wispr Flow's STRUCTURE but keep whispr-bro's Right-Option
    /// (no system tweak, unlike Fn) and add Right-Command for command mode.
    public static let defaults = HotkeyConfig(entries: [
        .init(.dictate, HotkeyBinding(keyCode: 61, gesture: .hold, isModifierOnly: true)),        // Right Option
        .init(.handsFree, HotkeyBinding(keyCode: 61, gesture: .doubleTap, isModifierOnly: true)), // double-tap Right Option
        .init(.commandMode, HotkeyBinding(keyCode: 54, gesture: .hold, isModifierOnly: true)),    // Right Command
        .init(.cancel, HotkeyBinding(keyCode: 53, gesture: .tap, isModifierOnly: false)),         // Esc
        .init(.pasteLast, HotkeyBinding(                                                          // ⌃⌘V
            keyCode: 9, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue,
            gesture: .tap, isModifierOnly: false)),
        .init(.copyLast, HotkeyBinding(                                                           // ⌃⌘C
            keyCode: 8, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue,
            gesture: .tap, isModifierOnly: false)),
    ])

    public static let storageKey = "hotkeys"

    /// The persisted config, or the defaults. A decode failure (schema drift)
    /// falls back to defaults rather than leaving the app with no hotkeys.
    public static func load() -> HotkeyConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let cfg = try? JSONDecoder().decode(HotkeyConfig.self, from: data),
              !cfg.entries.isEmpty
        else { return defaults }
        return cfg
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
#endif
