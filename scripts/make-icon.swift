// Renders Resources/AppIcon.icns (a stylised mouse on a red gradient).
import AppKit
let out = CommandLine.arguments[1]
let iconset = out.replacingOccurrences(of: ".icns", with: ".iconset")
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let bg = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8),
                          xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 0.85, green: 0.07, blue: 0.13, alpha: 1),
                        NSColor(red: 0.35, green: 0.02, blue: 0.06, alpha: 1)])!.draw(in: bg, angle: -90)
    let body = NSRect(x: s * 0.34, y: s * 0.2, width: s * 0.32, height: s * 0.56)
    let mouse = NSBezierPath(roundedRect: body, xRadius: s * 0.16, yRadius: s * 0.16)
    NSColor(white: 0.08, alpha: 1).setFill(); mouse.fill()
    NSColor(white: 1, alpha: 0.9).setStroke(); mouse.lineWidth = s * 0.018; mouse.stroke()
    let split = NSBezierPath(); split.move(to: NSPoint(x: s * 0.5, y: body.maxY)); split.line(to: NSPoint(x: s * 0.5, y: s * 0.56))
    split.lineWidth = s * 0.014; split.stroke()
    let wheel = NSBezierPath(roundedRect: NSRect(x: s * 0.48, y: s * 0.6, width: s * 0.04, height: s * 0.09), xRadius: s * 0.02, yRadius: s * 0.02)
    NSColor(red: 1, green: 0.25, blue: 0.3, alpha: 1).setFill(); wheel.fill()
    // honeycomb hint
    NSColor(white: 1, alpha: 0.18).setFill()
    for r in 0..<3 { for c in 0..<3 {
        let x = s * (0.405 + CGFloat(c) * 0.065 + (r % 2 == 1 ? 0.032 : 0)), y = s * (0.27 + CGFloat(r) * 0.07)
        if x < s * 0.6 { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: s * 0.04, height: s * 0.04)).fill() }
    } }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", out]; try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
