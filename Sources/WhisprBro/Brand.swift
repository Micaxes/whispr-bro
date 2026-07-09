import AppKit
import SwiftUI

/// whispr·bro brand tokens (from "Whispr Bro Brand" design system). Voice:
/// calm · quiet · minimal · terminal-first · black/white/cream. Exact hex/px
/// values from the brand doc so the native UI matches the design.
enum Brand {
    // MARK: Palette
    static let ink = Color(hex: 0x17130E)        // primary text, dark surfaces, logo on light
    static let inkSoft = Color(hex: 0x4A4238)    // secondary dark
    static let mist = Color(hex: 0x8C8578)       // muted/label text, tertiary strokes
    static let paper = Color(hex: 0xF4EFE4)      // cream app background, text on ink
    static let raised = Color(hex: 0xFBF8F1)     // card/surface/window body
    static let creamAccent = Color(hex: 0xE7DCC6)
    static let signal = Color(hex: 0xB2452F)     // destructive / refused ONLY
    static let bodyMuted = Color(hex: 0x6B6558)  // body muted on light
    static let metaMuted = Color(hex: 0xA79E8C)  // faint mono meta
    static let lightMono = Color(hex: 0xC7BFAD)  // light mono on dark (HUD timer, hints)
    /// Pebble hairline border: cream at 14% (rgba(244,239,228,0.14)).
    static let pebbleBorder = Color(hex: 0xF4EFE4, alpha: 0.14)

    // MARK: Type — Archivo (sans) + IBM Plex Mono, with graceful system fallbacks.
    private static let hasArchivo = NSFont(name: "Archivo", size: 12) != nil
    private static let hasMono = NSFont(name: "IBM Plex Mono", size: 12) != nil

    /// Archivo (display/UI). Falls back to the system sans if the font isn't
    /// registered (dev `swift run`; the bundled .app ships Archivo).
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasArchivo ? .custom("Archivo", fixedSize: size).weight(weight)
                   : .system(size: size, weight: weight)
    }

    /// IBM Plex Mono (labels, latency, timers, keycaps). Falls back to the
    /// system MONOSPACED font so mono text stays monospaced either way.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasMono ? .custom("IBM Plex Mono", fixedSize: size).weight(weight)
                : .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    /// 0xRRGGBB literal → sRGB Color.
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha)
    }
}

// MARK: - The echo-w mark

/// The whispr·bro logo: three echoed "W" zigzag strokes ("reverb made visible").
/// The front stroke is solid; the back two are faint and — while `listening` —
/// pulse via the `wb-ripple` motion (opacity 0.1↔0.5, 1.7s, back stroke delayed
/// 0.28s). Drawn in the doc's 150×100 space, scaled uniformly into the frame.
struct EchoWMark: View {
    var color: Color = Brand.ink
    var listening: Bool = false
    /// 3 (default), 2, or 1 stroke — the doc collapses strokes at small sizes.
    var strokes: Int = 3

    @State private var pulse = false

    // Polylines in the 150×100 viewBox (front is leftmost/solid).
    private static let front: [CGPoint] =
        [.init(x: 16, y: 33), .init(x: 34, y: 61), .init(x: 52, y: 39), .init(x: 72, y: 65), .init(x: 92, y: 26)]
    private static let middle: [CGPoint] =
        [.init(x: 29, y: 33), .init(x: 47, y: 61), .init(x: 65, y: 39), .init(x: 85, y: 65), .init(x: 105, y: 26)]
    private static let back: [CGPoint] =
        [.init(x: 42, y: 33), .init(x: 60, y: 61), .init(x: 78, y: 39), .init(x: 98, y: 65), .init(x: 118, y: 26)]

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 150, geo.size.height / 100)
            let dx = (geo.size.width - 150 * scale) / 2
            let dy = (geo.size.height - 100 * scale) / 2
            let lw = 8.5 * scale

            ZStack {
                if strokes >= 3 {
                    stroke(Self.back, scale, dx, dy, lw)
                        .opacity(listening ? (pulse ? 0.5 : 0.1) : 0.16)
                        .animation(rippleAnim(delay: 0.28), value: pulse)
                }
                if strokes >= 2 {
                    stroke(Self.middle, scale, dx, dy, lw)
                        .opacity(listening ? (pulse ? 0.5 : 0.1) : 0.38)
                        .animation(rippleAnim(delay: 0), value: pulse)
                }
                stroke(Self.front, scale, dx, dy, lw).opacity(1)
            }
            .onAppear { pulse = listening }
            .onChange(of: listening) { _, newValue in pulse = newValue }
        }
    }

    private func rippleAnim(delay: Double) -> Animation? {
        listening ? .easeInOut(duration: 1.7).repeatForever(autoreverses: true).delay(delay) : nil
    }

    private func stroke(_ pts: [CGPoint], _ s: CGFloat, _ dx: CGFloat, _ dy: CGFloat, _ lw: CGFloat) -> some View {
        Path { p in
            for (i, pt) in pts.enumerated() {
                let m = CGPoint(x: dx + pt.x * s, y: dy + pt.y * s)
                if i == 0 { p.move(to: m) } else { p.addLine(to: m) }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
    }
}

/// A template NSImage of the echo-w for the menu bar (macOS tints template
/// images to the menu-bar color; the stroke opacities survive as alpha). Drawn
/// black with the doc's menu-bar opacities (0.18 / 0.4 / 1).
enum EchoWImage {
    static func menuBar(size: NSSize = NSSize(width: 20, height: 14)) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            let scale = min(rect.width / 150, rect.height / 100)
            let dx = (rect.width - 150 * scale) / 2
            let dy = (rect.height - 100 * scale) / 2
            func draw(_ pts: [(CGFloat, CGFloat)], width: CGFloat, opacity: CGFloat) {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.lineWidth = width * scale
                for (i, p) in pts.enumerated() {
                    // NSImage flipped:false has origin bottom-left; the doc's y is
                    // top-down, so flip y within the 100-unit box.
                    let pt = NSPoint(x: dx + p.0 * scale, y: dy + (100 - p.1) * scale)
                    if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
                }
                NSColor.black.withAlphaComponent(opacity).setStroke()
                path.stroke()
            }
            draw([(42, 33), (60, 61), (78, 39), (98, 65), (118, 26)], width: 9, opacity: 0.18)
            draw([(29, 33), (47, 61), (65, 39), (85, 65), (105, 26)], width: 9, opacity: 0.4)
            draw([(16, 33), (34, 61), (52, 39), (72, 65), (92, 26)], width: 9.5, opacity: 1)
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// The two app-icon variants (brand doc §4). The Finder / bundle icon is fixed
/// at build time (WHISPR_ICON in make-app.sh); this picker swaps the LIVE Dock
/// icon via `NSApplication.applicationIconImage`, visible while a window is open.
enum AppIconVariant: String, CaseIterable, Sendable {
    case dark, cream

    static let storageKey = "appIconVariant"
    var displayName: String { self == .dark ? "Dark" : "Cream" }
    var resourceName: String { "AppIcon-\(self == .dark ? "Dark" : "Cream")" }

    static var selected: AppIconVariant {
        AppIconVariant(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .dark
    }

    /// Set the running app's Dock icon from the bundled .icns. No-op under
    /// `swift run` (the resource bundle isn't present there).
    @MainActor func applyToDock() {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = image
    }
}
