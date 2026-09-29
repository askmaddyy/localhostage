// swift scripts/icon.swift  ->  Resources/AppIcon.icns + Resources/icon-1024.png
// Ransom-note ":3000": each glyph cut from a different "magazine".
import AppKit

func C(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

// Deterministic jitter so every build draws the same torn edges.
var seed: UInt64 = 0x5EED
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }

/// A scrap with slightly torn, uneven edges.
func scrap(_ r: NSRect, tear: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let corners = [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY)]
    for i in 0..<4 {
        let a = corners[i], b = corners[(i + 1) % 4]
        let steps = 5
        for k in 0..<steps {
            let t = CGFloat(k) / CGFloat(steps)
            let pt = NSPoint(x: a.x + (b.x - a.x) * t + (rnd() - 0.5) * tear, y: a.y + (b.y - a.y) * t + (rnd() - 0.5) * tear)
            if i == 0 && k == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
    }
    p.close()
    return p
}

func render(_ px: Int) -> Data {
    seed = 0x5EED
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow(); drop.shadowColor = .black.withAlphaComponent(0.35); drop.shadowBlurRadius = s * 0.03; drop.shadowOffset = NSSize(width: 0, height: -s * 0.012); drop.set()
    NSGradient(colors: [C(0x232326), C(0x0A0A0B)])!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // warm glow behind the note
    NSGradient(colors: [C(0xE63946, 0.28), C(0xE63946, 0)])!.draw(in: r, relativeCenterPosition: NSPoint(x: 0, y: -0.1))
    // top sheen
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), .clear])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: r.minX - r.width * 0.2, y: r.midY + r.height * 0.05, width: r.width * 1.4, height: r.height * 0.8)), angle: -90)

    // (glyph, font, paper, ink, rotation, y nudge, size scale)
    let glyphs: [(String, String, UInt32, UInt32, CGFloat, CGFloat, CGFloat)] = [
        (":", "HelveticaNeue-CondensedBlack", 0xF5F1E8, 0x111111, -7, 0.05, 0.92),
        ("3", "TimesNewRomanPS-BoldMT", 0xF4C430, 0x111111, 6, -0.04, 1.08),
        ("0", "Futura-CondensedExtraBold", 0xE63946, 0xFFFFFF, -4, 0.06, 1.12),
        ("0", "AmericanTypewriter-Bold", 0xF5F1E8, 0x1D3557, 7, -0.05, 1.0),
        ("0", "Didot-Bold", 0xFF8FA3, 0x111111, -9, 0.03, 1.06),
    ]
    let w = r.width * 0.2, overlap = r.width * 0.028
    var x = r.midX - (w * 5 - overlap * 4) / 2
    for g in glyphs {
        let h = w * 1.3 * g.6, ww = w * g.6
        let box = NSRect(x: x + (w - ww) / 2, y: r.midY - h / 2 + g.5 * r.height, width: ww, height: h)
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: box.midX, yBy: box.midY); t.rotate(byDegrees: g.4); t.translateX(by: -box.midX, yBy: -box.midY); t.concat()
        let paper = scrap(box, tear: s * 0.012)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.55); sh.shadowBlurRadius = s * 0.014; sh.shadowOffset = NSSize(width: s * 0.004, height: -s * 0.008); sh.set()
        C(g.2).setFill(); paper.fill()
        NSGraphicsContext.restoreGraphicsState()
        let f = NSFont(name: g.1, size: h * 0.86) ?? .systemFont(ofSize: h * 0.86, weight: .black)
        let str = NSAttributedString(string: g.0, attributes: [.font: f, .foregroundColor: C(g.3)])
        // center the actual ink, not the font's line box (fonts disagree wildly on ascent/leading)
        let line = CTLineCreateWithAttributedString(str)
        let cg = NSGraphicsContext.current!.cgContext
        cg.textMatrix = .identity
        cg.textPosition = .zero  // image bounds are relative to the current text position
        let ink = CTLineGetImageBounds(line, cg)
        cg.textPosition = CGPoint(x: box.midX - ink.midX, y: box.midY - ink.midY)
        CTLineDraw(line, cg)
        NSGraphicsContext.restoreGraphicsState()
        x += w - overlap
    }
    NSGraphicsContext.restoreGraphicsState()

    // hairline rim
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let rim = NSBezierPath(roundedRect: r.insetBy(dx: s * 0.002, dy: s * 0.002), xRadius: r.width * 0.223, yRadius: r.width * 0.223)
    rim.lineWidth = s * 0.004; rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! render(1024).write(to: URL(fileURLWithPath: "Resources/icon-1024.png"))
print("Resources/AppIcon.icns")
