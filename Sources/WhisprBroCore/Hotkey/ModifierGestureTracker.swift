#if os(macOS)
import Foundation

/// The modifier-key gesture state machine — press, release, double-tap — as a
/// pure value type: in go key events, out come `(action, phase)` pairs. No
/// CGEvent, no run loop, no clock of its own.
///
/// It is split out of `HotkeyManager` because both bugs that made hands-free
/// unusable lived in exactly these twenty lines and neither was reachable by a
/// test: dispatch followed the entries array (so re-recording the Dictate
/// shortcut, which moves it to the end, delivered the double-tap BEFORE the
/// hold it latches, and hands-free silently stopped working), and every release
/// armed the double-tap window (so a press moments after an ordinary dictation
/// opened a latched mic he never asked for). Both rules are now here, where a
/// sequence of taps and holds can be played through them.
///
/// The invariants, stated once:
///  - bindings that share a key are delivered in `HotkeyGesture.emitPriority`
///    order, never entry order — a `doubleTap` acts on the recording its `hold`
///    has already started;
///  - only a TAP arms the double-tap window (`DictationGesture.armsDoubleTap`);
///  - the window is measured PRESS to PRESS, not release to press, so how long
///    he happens to rest on the first tap does not eat the gap he has left for
///    the second;
///  - a press the app consumed as a deliberate action (the hands-free stop),
///    or one that completed a double-tap, arms nothing at all: ending a session
///    is not the first half of starting one.
public struct ModifierGestureTracker: Sendable {
    public struct Event: Equatable, Sendable {
        public let action: HotkeyAction
        public let phase: HotkeyPhase
        public init(_ action: HotkeyAction, _ phase: HotkeyPhase) {
            self.action = action; self.phase = phase
        }
    }

    /// What the last transition measured — timings only (which key, how long it
    /// was down, how far it was from the press before it, and what the rules
    /// made of that). `HotkeyManager` logs it, so a gesture that did not fire
    /// says why in the log instead of being guessed at. No key content, ever:
    /// the tracker only ever sees modifier keys.
    public struct Trace: Equatable, Sendable {
        public let keyCode: Int64
        public let pressed: Bool
        /// Release only: how long the key was physically down.
        public let heldFor: TimeInterval?
        /// Press only: since the previous press of this key, nil for the first.
        public let sincePreviousPress: TimeInterval?
        /// Press: a window was open. Release: this release opened one.
        public let armed: Bool
        /// Press only: the double-tap fired.
        public let latched: Bool
    }

    /// The last transition's measurements. Diagnostics only — nothing reads it
    /// to make a decision.
    public private(set) var lastTrace: Trace?

    private let doubleTapWindow: TimeInterval
    /// Bindings per key, precomputed in emit order for fast per-event lookup.
    private var bindings: [Int64: [HotkeyConfig.Entry]] = [:]

    private var isDown: [Int64: Bool] = [:]
    private var pressTime: [Int64: TimeInterval] = [:]
    /// When a key was last pressed, tap or not — diagnostics only, so a gesture
    /// that missed can report the gap that missed it.
    private var lastPressTime: [Int64: TimeInterval] = [:]
    /// The PRESS time of the last press that turned out to be a tap — the only
    /// thing that arms a double-tap, and the instant the window is measured
    /// from.
    private var armedPress: [Int64: TimeInterval] = [:]
    /// Keys whose current press is spent — the app consumed it (see
    /// `suppressDoubleTap`), or it completed a double-tap. Either way its
    /// release arms nothing.
    private var consumed: Set<Int64> = []
    /// Hold actions currently in `.began`, so a lost key-up can be reconciled.
    public private(set) var heldActions: Set<HotkeyAction> = []

    public init(
        config: HotkeyConfig,
        doubleTapWindow: TimeInterval = DictationGesture.doubleTapWindow
    ) {
        self.doubleTapWindow = doubleTapWindow
        index(config)
    }

    public mutating func reload(_ config: HotkeyConfig) -> [Event] {
        let released = clear()
        index(config)
        return released
    }

    private mutating func index(_ config: HotkeyConfig) {
        bindings = [:]
        for keyCode in Set(config.entries.map(\.binding.keyCode)) {
            let ordered = config.entriesInEmitOrder(keyCode: keyCode)
                .filter { $0.binding.isModifierOnly }
            if !ordered.isEmpty { bindings[keyCode] = ordered }
        }
    }

    /// The flag bit that is set while this bound key is down (see
    /// `HotkeyBinding.pressedMask`). nil when the key isn't bound, or when we
    /// have no way to tell it apart from its neighbours.
    public func pressedMask(for keyCode: Int64) -> UInt64? {
        bindings[keyCode]?.first?.binding.pressedMask
    }

    public func isBound(_ keyCode: Int64) -> Bool { bindings[keyCode] != nil }

    /// Feed one flags-changed transition. `flags` is the raw `CGEventFlags`
    /// bitfield, `now` a monotonic clock in seconds.
    public mutating func flagsChanged(
        keyCode: Int64, pressed: Bool, flags: UInt64, now: TimeInterval
    ) -> [Event] {
        guard let entries = bindings[keyCode] else { return [] }
        let wasDown = isDown[keyCode] ?? false
        var events: [Event] = []

        if pressed, !wasDown {
            isDown[keyCode] = true
            let gap = lastPressTime[keyCode].map { now - $0 }
            pressTime[keyCode] = now
            lastPressTime[keyCode] = now
            // Press to press, from the arming tap's own press — never from its
            // release, which charged the window for the length of the tap.
            let armedAt = armedPress[keyCode]
            let isDouble = armedAt.map { now - $0 <= doubleTapWindow } ?? false
            // A window is spent by the press that closes it, so a third press
            // cannot latch again off the same tap. And the press that COMPLETED
            // a double-tap is the second half of a gesture, never the first
            // half of the next one — its own release must arm nothing, exactly
            // like a press the app consumed (see `suppressDoubleTap`).
            // Otherwise tap-tap, let go, press to stop would read as another
            // double-tap and re-latch the mic he just closed.
            armedPress.removeValue(forKey: keyCode)
            if isDouble { consumed.insert(keyCode) }
            for e in entries {
                // Any *extra* required modifiers beyond the key itself.
                if e.binding.modifiers != 0, !e.binding.chordSatisfied(by: flags) { continue }
                switch e.binding.gesture {
                case .hold: heldActions.insert(e.action); events.append(.init(e.action, .began))
                case .doubleTap: if isDouble { events.append(.init(e.action, .fired)) }
                case .tap: events.append(.init(e.action, .fired))
                }
            }
            lastTrace = Trace(
                keyCode: keyCode, pressed: true, heldFor: nil, sincePreviousPress: gap,
                armed: armedAt != nil, latched: isDouble)
        } else if !pressed, wasDown {
            isDown[keyCode] = false
            // No recorded press means we never saw this key go down (the tap
            // was created mid-hold, or `clear()` ran): its duration is unknown,
            // and an unknown duration arms nothing.
            let pressedAt = pressTime.removeValue(forKey: keyCode)
            let held = pressedAt.map { now - $0 }
            // Arm the window only for a tap the app did not consume.
            let arms = consumed.remove(keyCode) == nil
                && held.map(DictationGesture.armsDoubleTap) == true
            if arms, let pressedAt {
                armedPress[keyCode] = pressedAt
            } else {
                armedPress.removeValue(forKey: keyCode)
            }
            for e in entries where e.binding.gesture == .hold {
                if heldActions.remove(e.action) != nil { events.append(.init(e.action, .ended)) }
            }
            lastTrace = Trace(
                keyCode: keyCode, pressed: false, heldFor: held, sincePreviousPress: nil,
                armed: arms, latched: false)
        }
        return events
    }

    /// The app consumed the press that is happening right now as a deliberate
    /// action (it stopped a hands-free session). Nothing about it may arm a
    /// double-tap — neither this press's release, nor a window a previous tap
    /// left open.
    public mutating func suppressDoubleTap() {
        for (keyCode, down) in isDown where down { consumed.insert(keyCode) }
        armedPress.removeAll()
    }

    /// Drop all transient state and report the holds that must be released
    /// (a lost key-up, a rebind, teardown). A hold whose real duration is
    /// unknown must not arm anything either.
    public mutating func clear() -> [Event] {
        let released = heldActions.map { Event($0, .ended) }
        heldActions.removeAll()
        isDown.removeAll(); pressTime.removeAll(); consumed.removeAll()
        armedPress.removeAll(); lastPressTime.removeAll()
        lastTrace = nil
        return released
    }
}
#endif
