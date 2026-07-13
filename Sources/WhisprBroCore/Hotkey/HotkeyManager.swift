#if os(macOS)
import AppKit
import CoreGraphics

/// Global hotkeys via a listen-only `CGEventTap` (spec §4). Dispatches a
/// configurable set of `HotkeyAction`s (see `HotkeyConfig`) rather than a single
/// hardcoded key.
///
/// Two matching paths, both off one tap:
///  - **Modifier-only** bindings (Right-Option/Right-Command, the primary
///    dictation + command-mode keys) are matched on `flagsChanged` via
///    device-specific NX masks — zero-debounce, no latency added.
///  - **Key** bindings (Esc, ⌃⌘V, …) are matched on `keyDown`/`keyUp` with an
///    optional modifier chord.
///
/// Gestures: `hold` → `.began`/`.ended`; `doubleTap` → `.fired` on a second
/// press within `doubleTapWindow`; `tap` → `.fired` once per key-down.
///
/// A watchdog polls `CGEventTapIsEnabled` and re-enables/recreates a tap the OS
/// disabled, reporting health so the UI can warn when it's dead (Input
/// Monitoring revoked). A lost key-up (tap died mid-hold) is reconciled by
/// releasing every currently-held action so the pipeline never records forever.
public final class HotkeyManager: @unchecked Sendable {
    /// kVK_RightOption — the default dictation key (see `HotkeyConfig.defaults`).
    public static let defaultKeyCode: Int64 = 61

    /// Fired for every matched action. `phase`: .began/.ended (hold) or .fired.
    public var onAction: ((HotkeyAction, HotkeyPhase) -> Void)?
    public var onHealthChange: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: Timer?
    private let doubleTapWindow: TimeInterval

    // Precomputed from the config for fast per-event lookup.
    private var modifierBindings: [Int64: [(action: HotkeyAction, binding: HotkeyBinding)]] = [:]
    private var keyBindings: [Int64: [(action: HotkeyAction, binding: HotkeyBinding)]] = [:]

    // Transient runtime state.
    private var modifierDown: [Int64: Bool] = [:]
    private var modifierLastRelease: [Int64: TimeInterval] = [:]
    private var regularKeyDown: Set<Int64> = []
    /// Hold actions currently in the `.began` state — released on stuck-key
    /// reconcile so a lost key-up can't record forever.
    private var heldActions: Set<HotkeyAction> = []
    private var lastHealthy = true

    public init(config: HotkeyConfig = .load(), doubleTapWindow: TimeInterval = 0.35) {
        self.doubleTapWindow = doubleTapWindow
        indexBindings(config)
    }

    private func indexBindings(_ config: HotkeyConfig) {
        modifierBindings = [:]; keyBindings = [:]
        for e in config.entries {
            if e.binding.isModifierOnly {
                modifierBindings[e.binding.keyCode, default: []].append((e.action, e.binding))
            } else {
                keyBindings[e.binding.keyCode, default: []].append((e.action, e.binding))
            }
        }
    }

    /// Apply a new config live (Settings rebind). Releases any held action so a
    /// key that's no longer bound can't stay stuck "down".
    public func reload(_ config: HotkeyConfig) {
        for action in heldActions { emit(action, .ended) }
        heldActions.removeAll(); modifierDown.removeAll(); regularKeyDown.removeAll()
        indexBindings(config)
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
        modifierDown.removeAll(); regularKeyDown.removeAll(); heldActions.removeAll()
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
        for action in heldActions { emit(action, .ended) }
        heldActions.removeAll(); modifierDown.removeAll(); regularKeyDown.removeAll()
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            reconcileStuck()
            return
        }
        // Monotonic seconds (CGEvent.timestamp is mach ticks, ~42x off).
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .flagsChanged: handleFlags(event, now: now)
        case .keyDown: handleKeyDown(event)
        case .keyUp: handleKeyUp(event)
        default: break
        }
    }

    private func handleFlags(_ event: CGEvent, now: TimeInterval) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard let bindings = modifierBindings[kc], let first = bindings.first?.binding else { return }
        let flags = event.flags.rawValue
        let pressed: Bool
        if let dm = first.deviceSpecificMask { pressed = flags & dm != 0 }
        else { pressed = event.flags.contains(.maskAlternate) }

        let prev = modifierDown[kc] ?? false
        if pressed, !prev {
            modifierDown[kc] = true
            let isDouble = (now - (modifierLastRelease[kc] ?? -1000)) <= doubleTapWindow
            for (action, binding) in bindings {
                // Any *extra* required modifiers beyond the key itself.
                if binding.modifiers != 0, !binding.chordSatisfied(by: flags) { continue }
                switch binding.gesture {
                case .hold: heldActions.insert(action); emit(action, .began)
                case .doubleTap: if isDouble { emit(action, .fired) }
                case .tap: emit(action, .fired)
                }
            }
        } else if !pressed, prev {
            modifierDown[kc] = false
            modifierLastRelease[kc] = now
            for (action, binding) in bindings where binding.gesture == .hold {
                if heldActions.remove(action) != nil { emit(action, .ended) }
            }
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
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
            case .tap: emit(action, .fired)
            case .hold: heldActions.insert(action); emit(action, .began)
            case .doubleTap: break   // regular-key double-tap unsupported (unused)
            }
        }
    }

    private func handleKeyUp(_ event: CGEvent) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        regularKeyDown.remove(kc)
        guard let bindings = keyBindings[kc] else { return }
        for (action, binding) in bindings where binding.gesture == .hold {
            if heldActions.remove(action) != nil { emit(action, .ended) }
        }
    }

    private func emit(_ action: HotkeyAction, _ phase: HotkeyPhase) {
        DispatchQueue.main.async { self.onAction?(action, phase) }
    }
}
#endif
