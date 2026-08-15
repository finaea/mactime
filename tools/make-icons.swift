#!/usr/bin/swift
// Generates all MacTime artwork programmatically (no design tool round-trips):
//   Resources/MacTime.icns        app + dmg volume icon
//   Resources/DmgBackground.png   + @2x — dmg window poster
// Run on the mac:  swift tools/make-icons.swift
//
// Icon design (per plan requirement 4): a screenshot frame — four curved corner
// brackets — with a stopwatch in the center.

import AppKit
import CoreGraphics

// ---------------------------------------------------------------- helpers

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ image: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed for \(path)")
    }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// ---------------------------------------------------------------- app icon

func drawIcon(size: Int) -> CGImage {
    let ctx = makeContext(size, size)
    let s = CGFloat(size) / 1024.0

    // Squircle-ish rounded rect on the standard macOS icon grid.
    let iconRect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = CGPath(roundedRect: iconRect, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil)

    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgba(0x5E5CE6), rgba(0x1B2350)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
                           end: CGPoint(x: iconRect.midX, y: iconRect.minY),
                           options: [])
    ctx.restoreGState()

    // Screenshot brackets: four curved corners of an inner frame.
    let frame = iconRect.insetBy(dx: 118 * s, dy: 118 * s)
    let r = 96 * s          // corner arc radius
    let arm = 74 * s        // straight run past each arc
    let strokeW = 40 * s

    ctx.setStrokeColor(rgba(0xFFFFFF, 0.92))
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)

    let corners: [(center: CGPoint, startAngle: CGFloat)] = [
        (CGPoint(x: frame.minX + r, y: frame.maxY - r), .pi / 2),      // top-left
        (CGPoint(x: frame.maxX - r, y: frame.maxY - r), 0),            // top-right
        (CGPoint(x: frame.maxX - r, y: frame.minY + r), -.pi / 2),     // bottom-right
        (CGPoint(x: frame.minX + r, y: frame.minY + r), .pi),          // bottom-left
    ]
    for (center, start) in corners {
        let path = CGMutablePath()
        // arc spans 90° from `start` going counterclockwise; arms extend tangentially
        let a0 = start
        let a1 = start + .pi / 2
        let p0 = CGPoint(x: center.x + r * cos(a0), y: center.y + r * sin(a0))
        let p1 = CGPoint(x: center.x + r * cos(a1), y: center.y + r * sin(a1))
        // tangent directions at the arc ends, pointing away from the corner
        let t0 = CGPoint(x: -sin(a0), y: cos(a0))
        let t1 = CGPoint(x: -sin(a1), y: cos(a1))
        path.move(to: CGPoint(x: p0.x - t0.x * arm, y: p0.y - t0.y * arm))
        path.addArc(center: center, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
        path.move(to: p1)
        path.addLine(to: CGPoint(x: p1.x + t1.x * arm, y: p1.y + t1.y * arm))
        ctx.addPath(path)
        ctx.strokePath()
    }

    // Stopwatch, centered (nudged down so the crown breathes).
    let c = CGPoint(x: iconRect.midX, y: iconRect.midY - 18 * s)
    let R = 196 * s
    let bodyW = 42 * s

    // crown stem + button
    ctx.setFillColor(rgba(0xFFFFFF, 0.92))
    let stem = CGRect(x: c.x - 20 * s, y: c.y + R - 4 * s, width: 40 * s, height: 52 * s)
    ctx.addPath(CGPath(roundedRect: stem, cornerWidth: 12 * s, cornerHeight: 12 * s, transform: nil))
    let button = CGRect(x: c.x - 44 * s, y: c.y + R + 40 * s, width: 88 * s, height: 34 * s)
    ctx.addPath(CGPath(roundedRect: button, cornerWidth: 17 * s, cornerHeight: 17 * s, transform: nil))
    ctx.fillPath()

    // body
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.92))
    ctx.setLineWidth(bodyW)
    ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))

    // face ticks at 12/3/6/9
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.65))
    ctx.setLineWidth(14 * s)
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2
        let outer = R - 44 * s, inner = R - 84 * s
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
        path.addLine(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
        ctx.addPath(path)
        ctx.strokePath()
    }

    // hand pointing at ~1 o'clock + hub
    let handAngle: CGFloat = .pi / 3
    ctx.setStrokeColor(rgba(0xFF9F0A))
    ctx.setLineWidth(20 * s)
    ctx.setLineCap(.round)
    let hand = CGMutablePath()
    hand.move(to: c)
    hand.addLine(to: CGPoint(x: c.x + (R - 96 * s) * cos(handAngle),
                             y: c.y + (R - 96 * s) * sin(handAngle)))
    ctx.addPath(hand)
    ctx.strokePath()
    ctx.setFillColor(rgba(0xFF9F0A))
    ctx.fillEllipse(in: CGRect(x: c.x - 22 * s, y: c.y - 22 * s, width: 44 * s, height: 44 * s))

    return ctx.makeImage()!
}

// ---------------------------------------------------------------- dmg poster

func drawDmgBackground(scale: Int) -> CGImage {
    let w = 600 * scale, h = 400 * scale
    let ctx = makeContext(w, h)
    let s = CGFloat(scale)

    // Light background: Finder renders icon labels in black regardless of the
    // poster, so a dark poster makes "MacTime" / "Applications" unreadable.
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgba(0xF5F6FA), rgba(0xE3E7F0)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: CGFloat(h)),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // Finder positions (make-dmg.sh): app icon at x=160, Applications at x=440, y=190
    // from the top → CG y = 400-190 = 210. Arrow between them.
    let arrowY = 210 * s
    ctx.setStrokeColor(rgba(0x6B7280, 0.7))
    ctx.setLineWidth(5 * s)
    ctx.setLineCap(.round)
    let shaft = CGMutablePath()
    shaft.move(to: CGPoint(x: 245 * s, y: arrowY))
    shaft.addLine(to: CGPoint(x: 345 * s, y: arrowY))
    shaft.move(to: CGPoint(x: 325 * s, y: arrowY + 16 * s))
    shaft.addLine(to: CGPoint(x: 349 * s, y: arrowY))
    shaft.addLine(to: CGPoint(x: 325 * s, y: arrowY - 16 * s))
    ctx.addPath(shaft)
    ctx.strokePath()

    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, y: CGFloat) {
        let font = NSFont.systemFont(ofSize: size * s, weight: weight)
        let attr = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: color)!,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (CGFloat(w) - bounds.width) / 2, y: y * s)
        CTLineDraw(line, ctx)
    }

    text("MacTime", size: 30, weight: .semibold, color: rgba(0x1D2233, 0.95), y: 330)
    text("Drag to Applications to install", size: 14, weight: .regular, color: rgba(0x1D2233, 0.5), y: 66)

    return ctx.makeImage()!
}

// ---------------------------------------------------------------- run

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()   // tools/
    .deletingLastPathComponent()   // repo root
let resources = root.appendingPathComponent("Resources")
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

// iconset → icns
let iconset = resources.appendingPathComponent("MacTime.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(size: size), iconset.appendingPathComponent("icon_\(size)x\(size).png").path)
    writePNG(drawIcon(size: size * 2), iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png").path)
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("MacTime.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(resources.appendingPathComponent("MacTime.icns").path)")
try? FileManager.default.removeItem(at: iconset)

writePNG(drawDmgBackground(scale: 1), resources.appendingPathComponent("DmgBackground.png").path)
writePNG(drawDmgBackground(scale: 2), resources.appendingPathComponent("DmgBackground@2x.png").path)
