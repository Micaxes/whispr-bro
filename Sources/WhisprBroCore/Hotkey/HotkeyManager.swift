import AppKit
import CoreGraphics

/// Global push-to-talk via a listen-only `CGEventTap` on `flagsChanged`
/// (spec §4 HotkeyManager). Default key: Right Option (keycode 61).
///
/// Gestures:
///  - **Hold** to talk: `onKeyDown` on press, `onKeyUp` on release (instant, no
///    debounce delay — the primary path must not add latency).
///  - **Double-tap** to lock hands-free: `onDoubleTap` fires on the second
///    press within `doubleTapWindow`. (The first tap's press/release still
///    fire; the resulting sub-300ms recording is silently dropped downstream,
///    so hold-to-talk stays instant.)
///
/// A watchdog polls `CGEventTapIsEnabled` and re-enables (or recreates) a tap
/// the OS disabled — and reports health so the UI can warn when the tap is
/// dead (e.g. Input Monitoring revoked). `onHealthChange(false)` means the
/// hotkey is not working.
public final class HotkeyManager: @unchecked Sendable {
    /// kVK_RightOption
    public static let defaultKeyCode: Int64 = 61

    public var onKeyDown: (() -> Void)?
    public var onKeyUp: (() -> Void)?
    public var onDoubleTap: (() -> Void)?
    public var onHealthChange: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: Timer?
    private let keyCode: Int64
    private let deviceSpecificMask: UInt64?
    private let doubleTapWindow: TimeInterval
    private var keyIsDown = false
    private var lastReleaseTime: TimeInterval = 0
    private var lastHealthy = true

    public init(keyCode: Int64 = HotkeyManager.defaultKeyCode, doubleTapWindow: TimeInterval = 0.35) {
        self.keyCode = keyCode
        self.doubleTapWindow = doubleTapWindow
        // .maskAlternate is shared by BOTH option keys, so releasing Right
        // Option while Left Option is held would look like "still down".
        // The device-specific NX bits distinguish them.
        switch keyCode {
        case 61: deviceSpecificMask = 0x40 // NX_DEVICERALTKEYMASK
        case 58: deviceSpecificMask = 0x20 // NX_DEVICELALTKEYMASK
        case 62: deviceSpecificMask = 0x2000 // NX_DEVICERCTLKEYMASK
        case 59: deviceSpecificMask = 0x01 // NX_DEVICELCTLKEYMASK
        case 60: deviceSpecificMask = 0x04 // NX_DEVICERSHIFTKEYMASK
        case 56: deviceSpecificMask = 0x02 // NX_DEVICELSHIFTKEYMASK
        case 54: deviceSpecificMask = 0x10 // NX_DEVICERCMDKEYMASK
        case 55: deviceSpecificMask = 0x08 // NX_DEVICELCMDKEYMASK
        default: deviceSpecificMask = nil
        }
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
        keyIsDown = false
    }

    // MARK: - Tap lifecycle

    private func createTap() throws {
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
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

    /// Belt-and-suspenders: the OS silently disables slow/secure-input taps,
    /// and a revoked Input Monitoring grant kills the tap with no callback.
    private func startWatchdog() {
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkTapHealth()
        }
        // .common so the watchdog keeps firing while a menu/modal is open.
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func checkTapHealth() {
        guard let tap = eventTap else { return }
        if CGEvent.tapIsEnabled(tap: tap) {
            reportHealth(true)
            return
        }
        // Disabled: try to re-enable in place first.
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            reportHealth(true)
            return
        }
        // Still dead — recreate from scratch (grant may have lapsed). If the
        // key was held when the tap died, its release event was lost; reconcile
        // the stuck "down" as a release so the pipeline doesn't record forever.
        teardownTap()
        if keyIsDown {
            keyIsDown = false
            DispatchQueue.main.async { self.onKeyUp?() }
        }
        do {
            try createTap()
            reportHealth(true)
        } catch {
            reportHealth(false)
        }
    }

    private func reportHealth(_ healthy: Bool) {
        guard healthy != lastHealthy else { return }
        lastHealthy = healthy
        DispatchQueue.main.async { self.onHealthChange?(healthy) }
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // The OS disables taps that are slow or when secure input starts;
        // re-enable immediately. A key release delivered while the tap was
        // dead is lost, so reconcile a stuck "down" as released rather than
        // recording forever.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if keyIsDown {
                keyIsDown = false
                DispatchQueue.main.async { self.onKeyUp?() }
            }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == keyCode
        else { return }

        let modifierDown: Bool
        if let deviceSpecificMask {
            modifierDown = event.flags.rawValue & deviceSpecificMask != 0
        } else {
            modifierDown = event.flags.contains(.maskAlternate)
        }

        // Monotonic seconds. (CGEvent.timestamp is mach_absolute_time ticks,
        // NOT nanoseconds — dividing by 1e9 would be ~42x off on Apple
        // Silicon; systemUptime sidesteps the timebase conversion entirely.)
        let now = ProcessInfo.processInfo.systemUptime
        if modifierDown, !keyIsDown {
            keyIsDown = true
            let isDoubleTap = (now - lastReleaseTime) <= doubleTapWindow
            DispatchQueue.main.async {
                self.onKeyDown?()
                if isDoubleTap { self.onDoubleTap?() }
            }
        } else if !modifierDown, keyIsDown {
            keyIsDown = false
            lastReleaseTime = now
            DispatchQueue.main.async { self.onKeyUp?() }
        }
    }
}
