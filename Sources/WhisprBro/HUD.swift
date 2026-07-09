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
        let size = NSSize(width: 248, height: 92)
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

/// The HUD visuals: **the Pebble** — a dark ink capsule with the echo-w mark,
/// a live center-tapered waveform, and mono status text (brand doc §6a).
private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        pebble.frame(maxWidth: .infinity, maxHeight: .infinity) // center in the panel
    }

    private var pebble: some View {
        HStack(spacing: 12) {
            EchoWMark(color: Brand.paper, listening: isLive)
                .frame(width: 30, height: 20)

            if isLive {
                Waveform(levels: model.levels)
                    .frame(maxWidth: .infinity)
            } else {
                Text(label)
                    .font(Brand.mono(12, .medium))
                    .foregroundStyle(labelColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 216, height: 56)
        .background(
            Capsule()
                .fill(Brand.ink)
                .overlay(Capsule().strokeBorder(Brand.pebbleBorder, lineWidth: 1))
        )
        .shadow(color: Brand.ink.opacity(0.55), radius: 18, x: 0, y: 12)
    }

    /// Recording or hands-free = "listening": show the live waveform + ripple.
    private var isLive: Bool {
        switch model.phase {
        case .recording, .locked: true
        default: false
        }
    }

    private var labelColor: Color {
        switch model.phase {
        case .refused: Brand.signal
        default: Brand.lightMono
        }
    }

    private var label: String {
        switch model.phase {
        case .recording: "recording…"
        case .locked: "hands-free…"
        case .transcribing: "transcribing…"
        case .inserting: "inserting…"
        case .refused(let message): message
        case .warning(let message): message
        }
    }
}

/// Center-tapered bar waveform (brand doc: "28 samples · 30fps · center-tapered")
/// driven by recent RMS levels. Cream bars on the ink pebble; a `sin(i·π)`
/// envelope tapers the ends to zero.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 2.5
            let barWidth = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    let taper = sin(Double(index) / Double(max(1, count - 1)) * .pi)
                    Capsule()
                        .fill(Brand.paper)
                        .frame(
                            width: barWidth,
                            height: max(2, CGFloat(level) * CGFloat(taper) * geo.size.height)
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
