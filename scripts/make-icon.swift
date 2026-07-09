// make-icon.swift — render a whispr·bro app-icon variant (brand doc §4) into a
// macOS .iconset. Two variants: dark (default) and cream.
//
//   swift scripts/make-icon.swift <output.iconset-dir> [dark|cream]
//
// scripts/make-icon.sh wraps this + iconutil to produce Assets/AppIcon-*.icns.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <iconset-dir> [dark|cream]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = CommandLine.arguments[1]
let variant = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "dark"

func rgb(_ hex: UInt, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Per-variant colors (brand doc §4).
struct Style {
    let gradTop: UInt, gradBottom: UInt      // 155° gradient
    let glyph: UInt                          // echo-w stroke color
    let highlight: CGFloat                   // white top highlight alpha
    let border: CGColor?                     // hairline border (cream only)
}
let style: Style = variant == "cream"
    ? Style(gradTop: 0xFBF8F1, gradBottom: 0xEADFC9, glyph: 0x17130E, highlight: 0.55, border: rgb(0x17130E, 0.08))
    : Style(gradTop: 0x221D16, gradBottom: 0x100D09, glyph: 0xF4EFE4, highlight: 0.10, border: nil)

// The echo-w polylines (back faintest → front solid), in the doc's 150×100 box.
let echo: [(pts: [(CGFloat, CGFloat)], width: CGFloat, opacity: CGFloat)] = [
    ([(42, 33), (60, 61), (78, 39), (98, 65), (118, 26)], 8.5, 0.22),
    ([(29, 33), (47, 61), (65, 39), (85, 65), (105, 26)], 8.5, 0.45),
    ([(16, 33), (34, 61), (52, 39), (72, 65), (92, 26)], 9.0, 1.0),
]

func drawIcon(_ side: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: side); ctx.scaleBy(x: 1, y: -1) // top-left origin
    ctx.setAllowsAntialiasing(true); ctx.interpolationQuality = .high

    let inset = side * 0.098
    let s = side - 2 * inset
    let radius = s * 0.2237
    let rect = CGRect(x: inset, y: inset, width: s, height: s)
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let base = CGGradient(colorsSpace: cs, colors: [rgb(style.gradTop), rgb(style.gradBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: inset, y: inset),
                           end: CGPoint(x: side - inset, y: side - inset), options: [])
    let hl = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, style.highlight), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: inset, y: inset),
                           end: CGPoint(x: inset, y: inset + s * 0.4), options: [])
    ctx.restoreGState()

    if let border = style.border {
        ctx.addPath(squircle)
        ctx.setStrokeColor(border); ctx.setLineWidth(max(1, side * 0.004)); ctx.strokePath()
    }

    // echo-w, content-fitted (x 16–118 → 102 wide, y 26–65 → 39 tall) to ~62%
    // of the squircle width — bigger + centred, not floating in the 150×100 box.
    let markW = s * 0.62
    let ms = markW / 102
    let markH = 39 * ms
    let gx = inset + (s - markW) / 2, gy = inset + (s - markH) / 2
    func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: gx + (x - 16) * ms, y: gy + (y - 26) * ms) }
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for stroke in echo {
        let p = CGMutablePath()
        for (i, c) in stroke.pts.enumerated() {
            let q = map(c.0, c.1); if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        ctx.setStrokeColor(rgb(style.glyph, stroke.opacity))
        ctx.setLineWidth(stroke.width * ms)
        ctx.addPath(p); ctx.strokePath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("failed to write \(path)\n".data(using: .utf8)!); exit(1)
    }
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, s) in variants { writePNG(drawIcon(s), "\(outDir)/\(name).png") }
print("rendered \(variant) icon (\(variants.count) sizes) into \(outDir)")
