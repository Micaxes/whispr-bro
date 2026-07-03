import AVFoundation
import ApplicationServices
import CoreGraphics

/// The three TCC grants whispr-bro needs (spec §8). No sandbox, no network
/// entitlements — offline is enforced by construction, not configuration.
public enum Permissions {
    /// Microphone — required for `AVAudioEngine` capture.
    public static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Accessibility — required to post the synthetic Cmd+V `CGEvent`
    /// (and, later, AX context reads).
    public static func accessibility(prompt: Bool = false) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Input Monitoring — required for the listen-only `CGEventTap` hotkey
    /// (Accessibility alone does not cover listen taps on macOS 10.15+).
    public static var inputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    public static var allGranted: Bool {
        microphone && accessibility() && inputMonitoring
    }
}
