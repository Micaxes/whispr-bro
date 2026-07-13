import AVFoundation
#if os(macOS)
import ApplicationServices
import CoreGraphics
#endif

/// The TCC grants whispr-bro needs (spec §8): microphone everywhere, plus
/// Accessibility and Input Monitoring on macOS. No sandbox, no network
/// entitlements — offline is enforced by construction, not configuration.
public enum Permissions {
    /// Microphone — required for `AVAudioEngine` capture.
    public static var microphone: Bool {
        #if os(macOS)
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #else
        AVAudioApplication.shared.recordPermission == .granted
        #endif
    }

    public static func requestMicrophone() async -> Bool {
        #if os(macOS)
        await AVCaptureDevice.requestAccess(for: .audio)
        #else
        await AVAudioApplication.requestRecordPermission()
        #endif
    }

    #if os(macOS)
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
    #endif

    public static var allGranted: Bool {
        #if os(macOS)
        microphone && accessibility() && inputMonitoring
        #else
        microphone
        #endif
    }
}
