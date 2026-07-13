import SwiftUI
import UIKit

/// whispr·bro brand tokens (from "Whispr Bro Brand" design system), the iOS
/// port of `Sources/WhisprBro/Brand.swift`. Same hex/px values; font detection
/// goes through UIFont (Archivo + IBM Plex Mono ship via UIAppFonts in
/// App-Info.plist and fall back to system faces if not registered).
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
    static let lightMono = Color(hex: 0xC7BFAD)  // light mono on dark (timer, hints)

    // MARK: Type — Archivo (sans) + IBM Plex Mono, with graceful system fallbacks.
    // The registered PostScript/family name varies between the variable Archivo
    // TTF and the static Plex weights, so probe the known candidates once.
    private static let archivoName: String? =
        ["Archivo", "Archivo-Regular", "ArchivoRoman-Regular"]
            .first { UIFont(name: $0, size: 12) != nil }
    private static let monoName: String? =
        ["IBM Plex Mono", "IBMPlexMono", "IBMPlexMono-Regular"]
            .first { UIFont(name: $0, size: 12) != nil }

    /// Archivo (display/UI). Falls back to the system sans if the font isn't
    /// registered.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        archivoName.map { .custom($0, fixedSize: size).weight(weight) }
            ?? .system(size: size, weight: weight)
    }

    /// IBM Plex Mono (labels, latency, timers, keycaps). Falls back to the
    /// system MONOSPACED font so mono text stays monospaced either way.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        monoName.map { .custom($0, fixedSize: size).weight(weight) }
            ?? .system(size: size, weight: weight, design: .monospaced)
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
            // Fit the mark's CONTENT bounds (x 16–118 → 102 wide, y 26–65 → 39
            // tall), padded for the round caps, so the glyph fills its frame
            // instead of floating small inside the 150×100 viewBox.
            let s = min(geo.size.width / 111, geo.size.height / 48)
            let dx = (geo.size.width - 102 * s) / 2
            let dy = (geo.size.height - 39 * s) / 2

            ZStack {
                if strokes >= 3 {
                    stroke(Self.back, s, dx, dy, 8.5 * s)
                        .opacity(listening ? (pulse ? 0.5 : 0.1) : 0.16)
                        .animation(rippleAnim(delay: 0.28), value: pulse)
                }
                if strokes >= 2 {
                    stroke(Self.middle, s, dx, dy, 8.5 * s)
                        .opacity(listening ? (pulse ? 0.5 : 0.1) : 0.38)
                        .animation(rippleAnim(delay: 0), value: pulse)
                }
                stroke(Self.front, s, dx, dy, 9 * s).opacity(1)
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
                let m = CGPoint(x: dx + (pt.x - 16) * s, y: dy + (pt.y - 26) * s)
                if i == 0 { p.move(to: m) } else { p.addLine(to: m) }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
    }
}
