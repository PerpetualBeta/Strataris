#!/usr/bin/env swift

import AppKit
import CoreGraphics

// Generates AppIcon.icns for Strataris — composed from the established Jorvik
// visual language (no source art file; the icon is drawn in code):
//   • the brand-blue rounded-square badge + wireframe globe backdrop used by
//     BrowserCommander / BrowserNotes, and
//   • the swept-fin rocket glyph (tilted 45° right) used as SpaceMan's
//     menu-bar icon.
// The rocket sits atop the globe: a craft over a world — Galactic Colony
// Defence. Replace by dropping your own AppIcon.icns next to this file.
//
// Run:  swift generate_icon.swift   (emits AppIcon.icns at project root;
// release.mk `build` copies it into Contents/Resources).

let brandBlue = NSColor(red: 0x00 / 255.0, green: 0x40 / 255.0, blue: 0x80 / 255.0, alpha: 1.0)

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        let pts = UnsafeMutablePointer<NSPoint>.allocate(capacity: 3)
        defer { pts.deallocate() }
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: pts) {
            case .moveTo:           path.move(to: pts[0])
            case .lineTo:           path.addLine(to: pts[0])
            case .curveTo:          path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .cubicCurveTo:     path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: path.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath:        path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

func drawIcon(size s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus(); return image
    }
    let cx = s / 2, cy = s / 2
    let gradSpace = CGColorSpaceCreateDeviceRGB()

    // ── Background: brand-blue rounded square ──
    let bgRect = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
    brandBlue.setFill()
    bgPath.fill()

    // Subtle radial depth gradient
    if let g = CGGradient(colorsSpace: gradSpace, colors: [
        NSColor(white: 1.0, alpha: 0.10).cgColor,
        NSColor(white: 0.0, alpha: 0.12).cgColor,
    ] as CFArray, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addPath(bgPath.cgPath); ctx.clip()
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy + s * 0.12), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: s * 0.55, options: [])
        ctx.restoreGState()
    }

    // ── Wireframe globe backdrop ──
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath); ctx.clip()

    let globeR = s * 0.34
    let globeCY = cy

    if let glow = CGGradient(colorsSpace: gradSpace, colors: [
        NSColor(white: 1.0, alpha: 0.06).cgColor,
        NSColor(white: 1.0, alpha: 0.0).cgColor,
    ] as CFArray, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: globeCY), startRadius: globeR * 0.9,
                               endCenter: CGPoint(x: cx, y: globeCY), endRadius: globeR * 1.35, options: [])
    }

    // Globe lines slightly dimmed so the rocket reads as the focal point.
    let lineColor = NSColor(white: 1.0, alpha: 0.55)
    let thinColor = NSColor(white: 1.0, alpha: 0.26)
    let thickW = s * 0.01, thinW = s * 0.006

    ctx.setStrokeColor(lineColor.cgColor)
    ctx.setLineWidth(thickW)
    ctx.strokeEllipse(in: CGRect(x: cx - globeR, y: globeCY - globeR, width: globeR * 2, height: globeR * 2))

    ctx.setStrokeColor(thinColor.cgColor)
    ctx.setLineWidth(thinW)
    for i in 1...3 {
        let eW = globeR * CGFloat(i) / 4.0
        ctx.strokeEllipse(in: CGRect(x: cx - eW, y: globeCY - globeR, width: eW * 2, height: globeR * 2))
    }
    for i in 1...3 {
        let frac = CGFloat(i) / 4.0
        let halfW = sqrt(max(0, globeR * globeR - (globeR * frac) * (globeR * frac)))
        for y in [globeCY + globeR * frac, globeCY - globeR * frac] {
            let lift: CGFloat = (y > globeCY) ? s * 0.006 : -s * 0.006
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx - halfW, y: y))
            ctx.addQuadCurve(to: CGPoint(x: cx + halfW, y: y), control: CGPoint(x: cx, y: y + lift))
            ctx.strokePath()
        }
    }
    ctx.setStrokeColor(lineColor.withAlphaComponent(0.4).cgColor)
    ctx.setLineWidth(thinW * 1.2)
    ctx.beginPath(); ctx.move(to: CGPoint(x: cx - globeR, y: globeCY)); ctx.addLine(to: CGPoint(x: cx + globeR, y: globeCY)); ctx.strokePath()
    ctx.beginPath(); ctx.move(to: CGPoint(x: cx, y: globeCY - globeR)); ctx.addLine(to: CGPoint(x: cx, y: globeCY + globeR)); ctx.strokePath()
    ctx.restoreGState()

    // ── Rocket atop the globe — SpaceMan's glyph, tilted 45° right ──
    // The glyph is authored in a 22×22 coordinate system; scale it up to
    // dominate the icon, rotate -π/4 (45° right), and centre it.
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath); ctx.clip()

    let unit = s / 22.0          // 22-unit glyph space → icon pixels
    let scale = unit * 0.62      // rocket occupies ~62% of the badge

    // Soft drop shadow for lift off the globe.
    ctx.saveGState()
    ctx.translateBy(x: cx + s * 0.012, y: cy - s * 0.018)
    ctx.rotate(by: -.pi / 4)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -11, y: -11)
    NSColor(white: 0.0, alpha: 0.28).setFill()
    rocketBody().fill(); rocketNose().fill(); rocketLeftFin().fill(); rocketRightFin().fill(); rocketFlame().fill()
    ctx.restoreGState()

    // Rocket proper.
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: -.pi / 4)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -11, y: -11)

    NSColor.white.setFill()
    rocketBody().fill()
    rocketNose().fill()
    rocketLeftFin().fill()
    rocketRightFin().fill()

    // Exhaust flame in a warm accent so the craft reads as "flying".
    NSColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 1.0).setFill()
    rocketFlame().fill()

    // Porthole — a brand-blue window in the white hull (filled, not cut out,
    // so the icon has no transparent hole).
    brandBlue.blended(withFraction: 0.25, of: .black)!.setFill()
    NSBezierPath(ovalIn: NSRect(x: 9.5, y: 11, width: 3, height: 3)).fill()
    NSColor(white: 1.0, alpha: 0.5).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 9.5, y: 11, width: 3, height: 3))
    ring.lineWidth = 0.3
    ring.stroke()

    ctx.restoreGState()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

// Rocket sub-paths in the original 22-unit coordinate system (from SpaceMan).
func rocketBody() -> NSBezierPath { NSBezierPath(roundedRect: NSRect(x: 8, y: 4, width: 6, height: 12), xRadius: 3, yRadius: 3) }
func rocketNose() -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: NSPoint(x: 11, y: 20.5)); p.line(to: NSPoint(x: 7.5, y: 14)); p.line(to: NSPoint(x: 14.5, y: 14)); p.close(); return p
}
func rocketLeftFin() -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: NSPoint(x: 8, y: 9)); p.line(to: NSPoint(x: 2.5, y: 3)); p.line(to: NSPoint(x: 8, y: 5)); p.close(); return p
}
func rocketRightFin() -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: NSPoint(x: 14, y: 9)); p.line(to: NSPoint(x: 19.5, y: 3)); p.line(to: NSPoint(x: 14, y: 5)); p.close(); return p
}
func rocketFlame() -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: NSPoint(x: 9.5, y: 4)); p.line(to: NSPoint(x: 11, y: 1)); p.line(to: NSPoint(x: 12.5, y: 4)); p.close(); return p
}

// ── Emit the iconset and compile to AppIcon.icns at project root ──
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

let iconsetDir = "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: iconsetDir + "/" + name))
    print("  \(name) (\(size)x\(size))")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", "AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(atPath: iconsetDir)
print("Generated AppIcon.icns")
