#!/usr/bin/env swift
// Renders the app icons and the menu bar glyph from plain vector shapes (no SF Symbols — their licence
// doesn't allow use in app icons, and no third-party logo artwork).
//
// The mark: a speech-bubble ring (nod to Alexa) around a beamed music note (nod to Apple Music),
// on an Apple Music–style red gradient.
//
// Usage:
//   swift scripts/make-icon.swift <output.png>            iOS icon (1024, full bleed, opaque)
//   swift scripts/make-icon.swift <output.png> --mac      macOS icon (1024, rounded tile + shadow)
//   add --small for the 16–64 px variants (bigger, outlined mark)
//   swift scripts/make-icon.swift <output.png> --glyph N  menu bar template glyph (N×N px, black on clear)
//   add --ring-white for a white ring instead of Alexa-cyan
import AppKit

let args = CommandLine.arguments
let output = args.dropFirst().first ?? "AppIcon.png"
let mac = args.contains("--mac")
/// Small sizes (16–64 px): bigger mark, dark outline, no soft shadow — readable in menus and lists.
let small = args.contains("--small")
let glyphSize = args.firstIndex(of: "--glyph").flatMap { Int(args[$0 + 1]) }
let cyanRing = !args.contains("--ring-white")

// MARK: - The mark, in a 1024×1024 design space (origin bottom-left)

/// Ring with a speech-bubble tail at the bottom-left (ring and tail are separate shapes so they don't cancel out).
let markCenter = NSPoint(x: 512, y: 528)
let outerRadius: CGFloat = 352, innerRadius: CGFloat = 252

func ringPath() -> NSBezierPath {
    let path = NSBezierPath()
    path.appendOval(in: NSRect(x: markCenter.x - outerRadius, y: markCenter.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
    path.appendOval(in: NSRect(x: markCenter.x - innerRadius, y: markCenter.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
    path.windingRule = .evenOdd
    return path
}

func tailPath() -> NSBezierPath {
    func point(_ degrees: CGFloat, _ radius: CGFloat) -> NSPoint {
        let r = degrees * .pi / 180
        return NSPoint(x: markCenter.x + cos(r) * radius, y: markCenter.y + sin(r) * radius)
    }
    // Starts inside the ring band (so it merges cleanly) and points down-left.
    let mid = (outerRadius + innerRadius) / 2
    let tail = NSBezierPath()
    tail.move(to: point(214, mid))
    tail.curve(to: point(238, outerRadius + 118), controlPoint1: point(222, outerRadius + 20), controlPoint2: point(232, outerRadius + 80))
    tail.curve(to: point(256, mid), controlPoint1: point(244, outerRadius + 70), controlPoint2: point(252, outerRadius + 10))
    tail.close()
    return tail
}

/// Two beamed eighth notes (♫).
func notePath() -> NSBezierPath {
    let path = NSBezierPath()
    func head(_ cx: CGFloat, _ cy: CGFloat) {
        let oval = NSBezierPath(ovalIn: NSRect(x: -62, y: -44, width: 124, height: 88))
        var t = AffineTransform(translationByX: cx, byY: cy)
        t.rotate(byDegrees: 22)
        oval.transform(using: t)
        path.append(oval)
    }
    // Heads (left lower, right slightly higher), stems on the heads' right side, slanted beam on top.
    let left = (x: CGFloat(432), y: CGFloat(410)), right = (x: CGFloat(612), y: CGFloat(446))
    head(left.x, left.y)
    head(right.x, right.y)
    let stem: CGFloat = 30
    let leftStemX = left.x + 46, rightStemX = right.x + 46
    let leftTop: CGFloat = 700, rightTop: CGFloat = 736
    // Stems stop under the slanted beam so they never poke out above it.
    path.appendRect(NSRect(x: leftStemX, y: left.y + 8, width: stem, height: leftTop - 30 - left.y - 8))
    path.appendRect(NSRect(x: rightStemX, y: right.y + 8, width: stem, height: rightTop - 30 - right.y - 8))
    let beam = NSBezierPath()
    let thickness: CGFloat = 62
    beam.move(to: NSPoint(x: leftStemX, y: leftTop - thickness))
    beam.line(to: NSPoint(x: rightStemX + stem, y: rightTop - thickness))
    beam.line(to: NSPoint(x: rightStemX + stem, y: rightTop))
    beam.line(to: NSPoint(x: leftStemX, y: leftTop))
    beam.close()
    path.append(beam)
    path.windingRule = .nonZero
    return path
}

// MARK: - Rendering

func makeContext(_ pixels: Int, opaque: Bool) -> CGContext {
    CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
}

func save(_ context: CGContext, to path: String) {
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

if let glyphSize {
    // Menu bar template: black mark on transparent, scaled so ring + tail (≈750 units tall) fill the square.
    let context = makeContext(glyphSize, opaque: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let scale = CGFloat(glyphSize) / 1024 * 1.28
    let transform = NSAffineTransform()
    transform.translateX(by: CGFloat(glyphSize) / 2 - 512 * scale, yBy: CGFloat(glyphSize) / 2 - 505 * scale)
    transform.scale(by: scale)
    transform.concat()
    NSColor.black.setFill()
    ringPath().fill()
    tailPath().fill()
    notePath().fill()
    NSGraphicsContext.restoreGraphicsState()
    save(context, to: output)
    exit(0)
}

let context = makeContext(1024, opaque: !mac)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

if mac {
    // macOS icon grid: 824pt rounded square centred on a 1024 canvas, with a soft shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    let transform = NSAffineTransform()
    transform.translateX(by: 100, yBy: 100)
    transform.scale(by: 824.0 / 1024.0)
    transform.concat()
}

let alexaCyan = NSGradient(colors: [
    NSColor(srgbRed: 0.35, green: 0.88, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.00, green: 0.62, blue: 0.95, alpha: 1),
])!

// Apple Music–style red: #FB5C74 (top) → #FA233B (bottom).
NSGradient(colors: [
    NSColor(srgbRed: 251 / 255, green: 92 / 255, blue: 116 / 255, alpha: 1),
    NSColor(srgbRed: 250 / 255, green: 35 / 255, blue: 59 / 255, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: -90)

if small {
    // Enlarge the mark around its centre so it survives being shrunk to 16–32 px.
    let t = NSAffineTransform()
    t.translateX(by: 512, yBy: 505)
    t.scale(by: 1.1)
    t.translateX(by: -512, yBy: -505)
    t.concat()
}

// Dark outline around ring + tail and note: separates cyan/white from the red, especially when small.
let outline = NSColor(srgbRed: 0.30, green: 0.02, blue: 0.08, alpha: small ? 0.75 : 0.45)
for shape in [ringPath(), tailPath(), notePath()] {
    outline.setStroke()
    shape.lineWidth = small ? 32 : 22
    shape.lineJoinStyle = .round
    shape.stroke()
}

// Soft shadow under the mark for depth.
let markShadow = NSShadow()
markShadow.shadowColor = NSColor(srgbRed: 0.45, green: 0, blue: 0.08, alpha: 0.35)
markShadow.shadowBlurRadius = 30
markShadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
if !small { markShadow.set() }

// Ring and tail are painted with one canvas-wide gradient (clipped to each), so the colour flows through both.
if cyanRing {
    for shape in [ringPath(), tailPath()] {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        alexaCyan.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
} else {
    NSColor.white.setFill()
    ringPath().fill()
    tailPath().fill()
}
NSColor.white.setFill()
notePath().fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
save(context, to: output)
