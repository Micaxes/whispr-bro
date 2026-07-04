import AppKit
import CoreGraphics

/// Global push-to-talk via a listen-only `CGEventTap` on `flagsChanged`
/// (spec §4 HotkeyManager). Default key: Right Option (keycode 61), hold to
/// talk. Listen-only taps require the Input Monitoring permission.
///
/// The tap callback does minimal work and dispatches to the main queue.
/// `kCGEventTapDisabledByTimeout` is handled by re-enabling inline.
public final class HotkeyManager: @unchecked Sendable {
    /// kVK_RightOption
    public static let defaultKeyCode: Int64 = 61

    public var onKeyDown: (() -> Void)?
    public var onKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let keyCode: Int64
    private let deviceSpecificMask: UInt64?
    private var keyIsDown = false

    public init(keyCode: Int64 = HotkeyManager.defaultKeyCode) {
        self.keyCode = keyCode
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

    public func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        keyIsDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The OS disables taps that are slow or when secure input starts;
        // re-enable immediately (full watchdog arrives in task-008). A key
        // release delivered while the tap was dead is lost, so reconcile:
        // treat a stuck "down" as released rather than recording forever.
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
        if modifierDown, !keyIsDown {
            keyIsDown = true
            DispatchQueue.main.async { self.onKeyDown?() }
        } else if !modifierDown, keyIsDown {
            keyIsDown = false
            DispatchQueue.main.async { self.onKeyUp?() }
        }
    }
}
