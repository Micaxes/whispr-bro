import AppKit
import SwiftUI
import WhisprBroCore

/// Pipeline phases the HUD can show.
enum HUDPhase: Equatable {
    case recording
    case locked // hands-free (double-tap lock)
    case transcribing
    case inserting
    case refused(String)
    case warning(String)
}

/// Observable backing the HUD SwiftUI view.
@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .recording
    /// Recent RMS levels (oldest→newest) for the waveform.
    @Published var levels: [Float] = Array(repeating: 0, count: HUDModel.barCount)

    static let barCount = 28

    func pushLevel(_ rms: Float) {
        // Normalize quiet speech into a visible range without clipping loud.
        let scaled = min(1, max(0, rms * 12))
        levels.removeFirst()
        levels.append(scaled)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// Borderless, click-through, non-activating panel. `canBecomeKey == false`
/// is the hard backstop that keeps keyboard focus in the app being dictated
/// into — the whole point of a HUD overlay.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows/updates/hides the HUD overlay near the bottom-center of the active
/// screen, and drives the waveform from a level provider while recording
/// (spec §4 HUD, §11.2). Never activates the app or steals focus.
@MainActor
final class HUDController {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var levelTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?

    /// Called ~30fps while recording to sample the current input level.
    var levelProvider: (() -> Float)?

    func show(_ phase: HUDPhase) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        model.phase = phase
        ensurePanel()
        positionPanel()
        panel?.orderFrontRegardless() // never makeKey — no focus theft
        updateLevelTimer(for: phase)
    }

    func update(_ phase: HUDPhase) {
        hideWorkItem?.cancel() // a fresh phase cancels any pending hide
        hideWorkItem = nil
        guard panel != nil else { show(phase); return }
        model.phase = phase
        updateLevelTimer(for: phase)
    }

    /// Hide after `delay` (lets a "refused"/"warning" message linger briefly).
    func hide(after delay: TimeInterval = 0) {
        levelTimer?.invalidate()
        levelTimer = nil
        hideWorkItem?.cancel() // supersede any earlier scheduled hide
        let work = DispatchWorkItem { [weak self] in
            self?.hideWorkItem = nil
            self?.panel?.orderOut(nil)
            self?.model.resetLevels()
        }
        hideWorkItem = work
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work.perform()
        }
    }

    // MARK: - Private

    private func updateLevelTimer(for phase: HUDPhase) {
        let live = (phase == .recording || phase == .locked)
        if live, levelTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.model.pushLevel(self.levelProvider?() ?? 0)
            }
            // .common so the waveform keeps animating while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            levelTimer = timer
        } else if !live {
            levelTimer?.invalidate()
            levelTimer = nil
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: 220, height: 64)
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel else { return }
        // The display the user is actually looking at — the one under the
        // pointer. NSScreen.main is the key-window's screen, wrong for an
        // LSUIElement app with no key window.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 120
        )
        panel.setFrameOrigin(origin)
    }
}

/// The HUD visuals: a pill with a status glyph, a live waveform, and a label.
private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)

            if showsWaveform {
                Waveform(levels: model.levels, tint: tint)
                    .frame(maxWidth: .infinity)
            } else {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 220, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(tint.opacity(0.5), lineWidth: 1)
                )
        )
    }

    private var showsWaveform: Bool {
        switch model.phase {
        case .recording, .locked: true
        default: false
        }
    }

    private var glyph: String {
        switch model.phase {
        case .recording: "mic.fill"
        case .locked: "lock.fill"
        case .transcribing: "waveform"
        case .inserting: "text.cursor"
        case .refused: "hand.raised.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch model.phase {
        case .recording: .green
        case .locked: .blue
        case .transcribing, .inserting: .cyan
        case .refused, .warning: .orange
        }
    }

    private var label: String {
        switch model.phase {
        case .recording: "Recording…"
        case .locked: "Hands-free…"
        case .transcribing: "Transcribing…"
        case .inserting: "Inserting…"
        case .refused(let message): message
        case .warning(let message): message
        }
    }
}

/// Simple symmetric bar waveform driven by recent RMS levels.
private struct Waveform: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 2
            let barWidth = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(tint)
                        .frame(
                            width: barWidth,
                            height: max(3, CGFloat(level) * geo.size.height)
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
