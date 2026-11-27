// Draws the app icon and writes Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    // Background: rounded square, deep green-slate.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.17, alpha: 1).setFill()
    bg.fill()
    // Monitor outline.
    let screen = NSBezierPath(roundedRect: NSRect(x: 230 * s, y: 430 * s, width: 564 * s, height: 330 * s), xRadius: 36 * s, yRadius: 36 * s)
    screen.lineWidth = 34 * s
    NSColor(calibratedWhite: 0.95, alpha: 1).setStroke()
    screen.stroke()
    // Signal bars inside the screen: amber, getting taller.
    let amber = NSColor(calibratedRed: 1.0, green: 0.71, blue: 0.20, alpha: 1)
    amber.setFill()
    for (i, h) in [70.0, 130.0, 190.0].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: (390 + Double(i) * 90) * s, y: 490 * s, width: 56 * s, height: h * s), xRadius: 12 * s, yRadius: 12 * s).fill()
    }
    // Cable down to a USB-C plug.
    let cable = NSBezierPath()
    cable.move(to: NSPoint(x: 512 * s, y: 413 * s))
    cable.line(to: NSPoint(x: 512 * s, y: 300 * s))
    cable.lineWidth = 30 * s
    cable.lineCapStyle = .round
    NSColor(calibratedWhite: 0.95, alpha: 1).setStroke()
    cable.stroke()
    let plug = NSBezierPath(roundedRect: NSRect(x: 432 * s, y: 190 * s, width: 160 * s, height: 110 * s), xRadius: 50 * s, yRadius: 50 * s)
    NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
    plug.fill()
    NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 470 * s, y: 232 * s, width: 84 * s, height: 26 * s), xRadius: 13 * s, yRadius: 13 * s).fill()
    img.unlockFocus()
    return img
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size: px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
