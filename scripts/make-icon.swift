// make-icon.swift — render the whispr·bro app icon (brand doc §4: 22.5% squircle,
// dark #221D16→#100D09 gradient, cream echo-w glyph) into a macOS .iconset.
//
//   swift scripts/make-icon.swift <output.iconset-dir>
//
// scripts/make-icon.sh wraps this + iconutil to produce Assets/AppIcon.icns.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = CommandLine.arguments[1]

func rgb(_ hex: UInt, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// The echo-w polylines (front solid → back faintest), in the doc's 150×100 box.
let echo: [(pts: [(CGFloat, CGFloat)], width: CGFloat, opacity: CGFloat)] = [
    ([(42, 33), (60, 61), (78, 39), (98, 65), (118, 26)], 8.5, 0.22),   // back
    ([(29, 33), (47, 61), (65, 39), (85, 65), (105, 26)], 8.5, 0.45),   // middle
    ([(16, 33), (34, 61), (52, 39), (72, 65), (92, 26)], 9.0, 1.0),     // front
]

func drawIcon(_ side: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin so the doc's top-down coordinates draw directly.
    ctx.translateBy(x: 0, y: side); ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true); ctx.interpolationQuality = .high

    // macOS icon grid: rounded square ≈80% of the canvas with a transparent margin.
    let inset = side * 0.098
    let s = side - 2 * inset
    let radius = s * 0.2237
    let rect = CGRect(x: inset, y: inset, width: s, height: s)
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    // Dark diagonal gradient (#221D16 → #100D09).
    let base = CGGradient(colorsSpace: cs, colors: [rgb(0x221D16), rgb(0x100D09)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: inset, y: inset),
                           end: CGPoint(x: side - inset, y: side - inset), options: [])
    // Subtle inset top highlight (glossy edge).
    let hl = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: inset, y: inset),
                           end: CGPoint(x: inset, y: inset + s * 0.4), options: [])
    ctx.restoreGState()

    // Cream echo-w, centered, ~62% of the shape width.
    let gw = s * 0.62, gh = gw * (100.0 / 150.0)
    let gx = inset + (s - gw) / 2, gy = inset + (s - gh) / 2
    func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: gx + x / 150 * gw, y: gy + y / 100 * gh)
    }
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for stroke in echo {
        let p = CGMutablePath()
        for (i, c) in stroke.pts.enumerated() {
            let q = map(c.0, c.1)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        ctx.setStrokeColor(rgb(0xF4EFE4, stroke.opacity))
        ctx.setLineWidth(stroke.width / 150 * gw)
        ctx.addPath(p); ctx.strokePath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("failed to write \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}

// The sizes iconutil expects in an .iconset.
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, s) in variants {
    writePNG(drawIcon(s), "\(outDir)/\(name).png")
}
print("rendered \(variants.count) icon sizes into \(outDir)")
