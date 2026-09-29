// swift scripts/icon.swift  ->  Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.set()
    NSGradient(colors: [NSColor(red: 1.0, green: 0.42, blue: 0.32, alpha: 1), NSColor(red: 0.86, green: 0.13, blue: 0.24, alpha: 1)])!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    // glass sheen across the top half
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: r.minX - r.width * 0.2, y: r.midY - r.height * 0.05, width: r.width * 1.4, height: r.height * 0.9)), angle: -90)
    // inner rim
    NSColor.white.withAlphaComponent(0.28).setStroke()
    let rim = NSBezierPath(roundedRect: r.insetBy(dx: s * 0.004, dy: s * 0.004), xRadius: r.width * 0.22, yRadius: r.width * 0.22)
    rim.lineWidth = s * 0.006; rim.stroke()
    // padlock
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .semibold).applying(.init(paletteColors: [.white]))
    let sym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let sz = sym.size
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(red: 0.45, green: 0.02, blue: 0.08, alpha: 0.45); sh.shadowBlurRadius = s * 0.025; sh.shadowOffset = NSSize(width: 0, height: -s * 0.012); sh.set()
    let symRect = NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 - s * 0.01, width: sz.width, height: sz.height)
    sym.draw(in: symRect)
    NSGraphicsContext.restoreGraphicsState()
    // ":" keyhole - the port colon
    NSColor(red: 0.90, green: 0.22, blue: 0.28, alpha: 1).setFill()
    let d = s * 0.044, cx = s / 2, cy = symRect.minY + sz.height * 0.31
    for dy in [-d * 0.9, d * 0.9] { NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy + dy - d / 2, width: d, height: d)).fill() }
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
