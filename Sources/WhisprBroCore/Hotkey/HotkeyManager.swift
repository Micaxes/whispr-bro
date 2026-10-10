#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import os.log

/// Global hotkeys via a listen-only `CGEventTap` (spec §4). Dispatches a
/// configurable set of `HotkeyAction`s (see `HotkeyConfig`) rather than a single
/// hardcoded key.
///
/// Two matching paths, both off one tap:
///  - **Modifier-only** bindings (Right-Option/Right-Command, the primary
///    dictation + command-mode keys) are matched on `flagsChanged` via
///    device-specific NX masks — zero-debounce, no latency added. The rules
///    themselves live in `ModifierGestureTracker`, a pure value type, so the
///    press/release/double-tap sequences are unit-tested.
///  - **Key** bindings (Esc, ⌃⌘V, …) are matched on `keyDown`/`keyUp` with an
///    optional modifier chord.
///
/// Gestures: `hold` → `.began`/`.ended`; `doubleTap` → `.fired` on a second
/// press within `doubleTapWindow` **of the first press**, and only when the
/// FIRST press was a tap (`DictationGesture.armsDoubleTap`) — the release of a
/// real dictation must never let the next press latch hands-free. Bindings that
/// share a key are dispatched in `HotkeyGesture.emitPriority` order, so a
/// double-tap always lands after the hold it latches.
///
/// Every action carries the **event's** timestamp, not the handler's. Delivery
/// is an async hop to the main thread, and the main thread can be busy for tens
/// of milliseconds opening a microphone; a consumer that timed a hold with its
/// own clock would measure that delay instead of the key, and read a tap as a
/// dictation. One clock, taken at the tap, from press to release.
///
/// A watchdog polls `CGEventTapIsEnabled` and re-enables/recreates a tap the OS
/// disabled, reporting health so the UI can warn when it's dead (Input
/// Monitoring revoked). A lost key-up (tap died mid-hold) is reconciled by
/// releasing every currently-held action so the pipeline never records forever.
public final class HotkeyManager: @unchecked Sendable {
    /// kVK_RightOption — the default dictation key (see `HotkeyConfig.defaults`).
    public static let defaultKeyCode: Int64 = 61

    /// Fired for every matched action. `phase`: .began/.ended (hold) or .fired.
    /// The `TimeInterval` is when the KEY EVENT happened
    /// (`ProcessInfo.systemUptime`), not when this closure runs — see the note
    /// on clocks above.
    public var onAction: ((HotkeyAction, HotkeyPhase, TimeInterval) -> Void)?
    public var onHealthChange: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: Timer?

    /// The modifier-gesture rules (press/release/double-tap), unit-tested.
    private var modifiers: ModifierGestureTracker
    // Precomputed from the config for fast per-event lookup.
    private var keyBindings: [Int64: [(action: HotkeyAction, binding: HotkeyBinding)]] = [:]

    // Transient runtime state for the key (non-modifier) path.
    private var regularKeyDown: Set<Int64> = []
    /// Key-binding hold actions currently `.began` — released on stuck-key
    /// reconcile so a lost key-up can't record forever. (The modifier path
    /// tracks its own; see `ModifierGestureTracker.heldActions`.)
    private var heldActions: Set<HotkeyAction> = []
    private var lastHealthy = true
    private let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "hotkey")

    public init(
        config: HotkeyConfig = .load(),
        doubleTapWindow: TimeInterval = DictationGesture.doubleTapWindow
    ) {
        modifiers = ModifierGestureTracker(config: config, doubleTapWindow: doubleTapWindow)
        indexBindings(config)
    }

    private func indexBindings(_ config: HotkeyConfig) {
        keyBindings = [:]
        // Per physical key, in EMIT order — never entry order. A rebind moves
        // its action to the end of `entries`, so entry order must not decide
        // delivery order (see `HotkeyConfig.entriesInEmitOrder`).
        for keyCode in Set(config.entries.map(\.binding.keyCode)) {
            for e in config.entriesInEmitOrder(keyCode: keyCode) where !e.binding.isModifierOnly {
                keyBindings[keyCode, default: []].append((e.action, e.binding))
            }
        }
    }

    /// Apply a new config live (Settings rebind). Releases any held action so a
    /// key that's no longer bound can't stay stuck "down".
    public func reload(_ config: HotkeyConfig) {
        let now = ProcessInfo.processInfo.systemUptime
        for event in modifiers.reload(config) { emit(event.action, event.phase, at: now) }
        for action in heldActions { emit(action, .ended, at: now) }
        heldActions.removeAll(); regularKeyDown.removeAll()
        indexBindings(config)
    }

    /// Tell the gesture layer that the press happening right now was consumed
    /// as a deliberate action (the hands-free STOP), so nothing about it arms a
    /// double-tap. Main thread, like every other entry point.
    public func consumePressForDoubleTap() {
        modifiers.suppressDoubleTap()
    }

    public func start() throws {
        guard eventTap == nil else { return }
        try createTap()
        startWatchdog()
    }

    public func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        teardownTap()
        _ = modifiers.clear()
        regularKeyDown.removeAll(); heldActions.removeAll()
    }

    // MARK: - Tap lifecycle

    private func createTap() throws {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw WhisprError.eventTapCreationFailed
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func teardownTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkTapHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func checkTapHealth() {
        guard let tap = eventTap else { return }
        if CGEvent.tapIsEnabled(tap: tap) { reportHealth(true); return }
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) { reportHealth(true); return }
        // Still dead — recreate. Release any held action (its key-up was lost).
        teardownTap()
        reconcileStuck()
        do { try createTap(); reportHealth(true) }
        catch { reportHealth(false) }
    }

    private func reportHealth(_ healthy: Bool) {
        guard healthy != lastHealthy else { return }
        lastHealthy = healthy
        DispatchQueue.main.async { self.onHealthChange?(healthy) }
    }

    /// Release every held hold-action (a lost key-up must not record forever).
    private func reconcileStuck() {
        let now = ProcessInfo.processInfo.systemUptime
        for event in modifiers.clear() { emit(event.action, event.phase, at: now) }
        for action in heldActions { emit(action, .ended, at: now) }
        heldActions.removeAll(); regularKeyDown.removeAll()
    }

    // MARK: - Event clock

    /// mach ticks → seconds, on the same base as `ProcessInfo.systemUptime`.
    private static let machToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// A CGEvent's own timestamp in `systemUptime` seconds. Falls back to now
    /// for an event that carries no usable one, and never reports the future:
    /// an event we are holding has already happened.
    static func eventSeconds(_ timestamp: CGEventTimestamp) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let seconds = Double(timestamp) * machToSeconds
        return seconds > 0 ? min(seconds, now) : now
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            reconcileStuck()
            return
        }
        // WHEN THE KEY MOVED — not when this callback got to run.
        //
        // The tap source is on the MAIN run loop, so a press whose handler
        // opens the microphone (~150ms on a USB device) delays the callback for
        // the matching key-up by exactly that long. Reading the clock here
        // measured that stall as part of the hold: a real 150ms tap arrived as
        // 338ms, over the tap ceiling, so it armed nothing and the double-tap
        // could not fire. Hammering the key was the only way through, because a
        // warm mic opens faster.
        //
        // The event carries its own timestamp. It is mach absolute time (the
        // "~42x off" a previous pass saw and gave up on — that is the Apple
        // Silicon timebase, 125/3), so convert it and it lands on exactly the
        // same clock as `ProcessInfo.systemUptime`.
        let now = Self.eventSeconds(event.timestamp)
        switch type {
        case .flagsChanged: handleFlags(event, now: now)
        case .keyDown: handleKeyDown(event, now: now)
        case .keyUp: handleKeyUp(event, now: now)
        default: break
        }
    }

    private func handleFlags(_ event: CGEvent, now: TimeInterval) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard modifiers.isBound(kc) else { return }
        let flags = event.flags.rawValue
        // The bit that is set while THIS key is down, so releasing Right-Option
        // while Left-Option is held reads correctly. No mask = we cannot tell,
        // and "not pressed" is the only safe answer: reading an unrelated
        // modifier's bit (the old `.maskAlternate` fallback) both misses the
        // key-up — mic open until the cap — and fires a phantom press when any
        // Option key happens to be down.
        guard let mask = modifiers.pressedMask(for: kc) else { return }
        let pressed = flags & mask != 0

        let events = modifiers.flagsChanged(keyCode: kc, pressed: pressed, flags: flags, now: now)
        trace(events)
        for e in events { emit(e.action, e.phase, at: now) }
    }

    /// One line per modifier transition, so a gesture that did not fire says
    /// why. Timings only — no key content reaches this (modifier keys carry
    /// none), so the values are logged public and are actually readable in
    /// `log show`.
    private func trace(_ events: [ModifierGestureTracker.Event]) {
        guard let t = modifiers.lastTrace else { return }
        let ms = { (v: TimeInterval?) in v.map { String(Int($0 * 1000)) } ?? "–" }
        let fired = events.map { "\($0.action.rawValue).\($0.phase)" }.joined(separator: ",")
        if t.pressed {
            log.info("""
                key \(t.keyCode, privacy: .public) down                 gap=\(ms(t.sincePreviousPress), privacy: .public)ms                 armed=\(t.armed, privacy: .public)                 latched=\(t.latched, privacy: .public)                 window=\(Int(DictationGesture.doubleTapWindow * 1000), privacy: .public)ms                 → [\(fired, privacy: .public)]
                """)
        } else {
            log.info("""
                key \(t.keyCode, privacy: .public) up                 held=\(ms(t.heldFor), privacy: .public)ms                 arms=\(t.armed, privacy: .public)                 tapCeiling=\(Int(DictationGesture.minHoldToTranscribe * 1000), privacy: .public)ms                 → [\(fired, privacy: .public)]
                """)
        }
    }

    private func handleKeyDown(_ event: CGEvent, now: TimeInterval) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard let bindings = keyBindings[kc] else { return }
        if regularKeyDown.contains(kc) { return }   // ignore auto-repeat
        regularKeyDown.insert(kc)
        let flags = event.flags.rawValue
        for (action, binding) in bindings {
            // Superset match: required modifiers must all be present. A binding
            // with no modifiers (Esc/cancel) fires even while others are held.
            if !binding.chordSatisfied(by: flags) { continue }
            switch binding.gesture {
            case .tap: emit(action, .fired, at: now)
            case .hold: heldActions.insert(action); emit(action, .began, at: now)
            case .doubleTap: break   // regular-key double-tap unsupported (unused)
            }
        }
    }

    private func handleKeyUp(_ event: CGEvent, now: TimeInterval) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        regularKeyDown.remove(kc)
        guard let bindings = keyBindings[kc] else { return }
        for (action, binding) in bindings where binding.gesture == .hold {
            if heldActions.remove(action) != nil { emit(action, .ended, at: now) }
        }
    }

    private func emit(_ action: HotkeyAction, _ phase: HotkeyPhase, at eventTime: TimeInterval) {
        DispatchQueue.main.async { self.onAction?(action, phase, eventTime) }
    }
}
#endif
