// Draws the app icon with plain Core Graphics (SF Symbols may not be used in
// app icons) and writes an .iconset. Run via `make icon`.
//
//   xcrun swift scripts/make-icon.swift Resources/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Everything is laid out on the 1024 macOS icon grid and scaled.
func draw(_ ctx: CGContext, size: CGFloat) {
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Body: standard macOS squircle-ish rounded rect (824pt, r≈185) with drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x1E3A8A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x312E81), rgb(0x2563EB), rgb(0x06B6D4)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])

    // Faint mesh lattice in the background.
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(6)
    let lattice: [CGPoint] = [CGPoint(x: 220, y: 780), CGPoint(x: 420, y: 860), CGPoint(x: 640, y: 800),
                              CGPoint(x: 820, y: 700), CGPoint(x: 300, y: 560)]
    for (i, a) in lattice.enumerated() {
        for b in lattice[(i + 1)...] where hypot(a.x - b.x, a.y - b.y) < 330 {
            ctx.move(to: a); ctx.addLine(to: b)
        }
    }
    ctx.strokePath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.12))
    for p in lattice { ctx.fillEllipse(in: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)) }
    ctx.restoreGState()

    let white = rgb(0xFFFFFF)
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: rgb(0x0B1030, 0.35))

    // Laptop (left): screen outline + base.
    ctx.setStrokeColor(white); ctx.setFillColor(white); ctx.setLineWidth(26)
    let screen = CGRect(x: 205, y: 330, width: 290, height: 200)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.strokePath()
    let base = CGMutablePath()
    base.addRoundedRect(in: CGRect(x: 170, y: 270, width: 360, height: 36), cornerWidth: 18, cornerHeight: 18)
    ctx.addPath(base); ctx.fillPath()

    // iPhone (right): body outline + island.
    let phone = CGRect(x: 640, y: 250, width: 170, height: 320)
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 697, y: 520, width: 56, height: 18),
                       cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.fillPath()

    // The bridge: a dashed arc over the gap, anchored by two nodes.
    let from = CGPoint(x: 350, y: 580), to = CGPoint(x: 725, y: 615)
    ctx.setLineWidth(22); ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [2, 44])
    ctx.move(to: from)
    ctx.addCurve(to: to, control1: CGPoint(x: 400, y: 800), control2: CGPoint(x: 680, y: 820))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    for p in [from, to] {
        ctx.fillEllipse(in: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52))
    }
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, size: CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(out.path)")
