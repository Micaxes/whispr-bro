import AppKit
import SwiftUI
import WhisprBroCore

/// A key/modifier recorder button for the Shortcuts settings (task: hotkeys).
/// While recording it installs a local NSEvent monitor and captures the next
/// press: a bare modifier (for modifier-only actions like Dictate) or a
/// key+chord (for tap actions like Cancel / Paste last). The action's gesture is
/// preserved — the recorder only changes the key.
struct HotkeyRecorderButton: View {
    let action: HotkeyAction
    let binding: HotkeyBinding?
    let onCapture: (HotkeyBinding) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    private var wantsModifierOnly: Bool {
        binding?.isModifierOnly
            ?? HotkeyConfig.defaults.bindings(for: action).first?.isModifierOnly
            ?? false
    }
    private var gesture: HotkeyGesture {
        binding?.gesture ?? HotkeyConfig.defaults.bindings(for: action).first?.gesture ?? .tap
    }

    var body: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            BrandKeycap(
                text: recording ? "press \(wantsModifierOnly ? "a modifier" : "a key")…"
                                : (binding?.displayString ?? "Set…"),
                active: recording)
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if let b = capture(event) { onCapture(b); stopRecording() }
            return nil   // swallow while recording so keys don't leak into the UI
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func capture(_ event: NSEvent) -> HotkeyBinding? {
        if wantsModifierOnly {
            guard event.type == .flagsChanged else { return nil }
            let kc = Int64(event.keyCode)
            guard Self.modifierKeycodes.contains(kc),
                  Self.isModifierActive(kc, event.modifierFlags) else { return nil }  // capture on press
            return HotkeyBinding(keyCode: kc, modifiers: 0, gesture: gesture, isModifierOnly: true)
        }
        guard event.type == .keyDown else { return nil }
        return HotkeyBinding(
            keyCode: Int64(event.keyCode), modifiers: Self.cgFlags(event.modifierFlags),
            gesture: gesture, isModifierOnly: false)
    }

    static let modifierKeycodes: Set<Int64> = [61, 58, 62, 59, 54, 55, 60, 56, 63]
    static func isModifierActive(_ kc: Int64, _ flags: NSEvent.ModifierFlags) -> Bool {
        switch kc {
        case 61, 58: return flags.contains(.option)
        case 62, 59: return flags.contains(.control)
        case 54, 55: return flags.contains(.command)
        case 60, 56: return flags.contains(.shift)
        case 63: return flags.contains(.function)
        default: return false
        }
    }
    static func cgFlags(_ flags: NSEvent.ModifierFlags) -> UInt64 {
        var m: UInt64 = 0
        if flags.contains(.command) { m |= CGEventFlags.maskCommand.rawValue }
        if flags.contains(.control) { m |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.option) { m |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.shift) { m |= CGEventFlags.maskShift.rawValue }
        if flags.contains(.function) { m |= CGEventFlags.maskSecondaryFn.rawValue }
        return m
    }
}

/// The "Shortcuts" settings tab content (branded), embedded in SettingsView:
/// one row per action with a recorder keycap.
struct ShortcutsSettingsView: View {
    @ObservedObject var pipeline: PipelineController
    @State private var config = HotkeyConfig.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                BrandSectionLabel("Keyboard shortcuts")
                BrandCard(padding: 6) {
                    ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { i, action in
                        if i > 0 { Rectangle().fill(Brand.ink.opacity(0.06)).frame(height: 1) }
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.displayName).font(Brand.sans(14, .medium)).foregroundStyle(Brand.ink)
                                Text(action.subtitle).font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
                            }
                            Spacer(minLength: 12)
                            HotkeyRecorderButton(
                                action: action,
                                binding: config.bindings(for: action).first
                            ) { update(action, $0) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 8)
                    }
                }
            }
            HStack {
                Button("Reset to defaults") { reset() }
                    .buttonStyle(.plain).font(Brand.sans(12, .medium)).foregroundStyle(Brand.ink)
                Spacer()
            }
            BrandCaption("Dictate / Hands-free / Command use bare modifiers; Cancel / Paste / Copy use a key chord. Command mode edits the selected text and needs the formatting model. Bound keys still reach the focused app (listen-only tap), so avoid productive keys.")
        }
    }

    private func update(_ action: HotkeyAction, _ binding: HotkeyBinding) {
        var entries = config.entries.filter { $0.action != action }
        entries.append(.init(action, binding))
        config = HotkeyConfig(entries: entries)
        config.save()
        pipeline.reloadHotkeys(config)
    }

    private func reset() {
        config = .defaults
        config.save()
        pipeline.reloadHotkeys(config)
    }
}
