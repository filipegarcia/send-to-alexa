#!/usr/bin/env swift
// Renders the 1024×1024 app icon (gradient + SF Symbols) so the repo has no opaque design files.
// Usage: swift scripts/make-icon.swift <output.png> [--mac]
//   --mac  draws the macOS shape (rounded square with margin and shadow on a transparent canvas)
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let mac = CommandLine.arguments.contains("--mac")
let size = 1024.0

// Draw straight into an opaque 1024px bitmap (App Store icons must not have alpha).
let cg = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: (mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)

if mac {
    // macOS icon grid: 824pt rounded square centred on a 1024 canvas, with a soft shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    path.addClip()
    // Scale the artwork into the tile.
    let transform = NSAffineTransform()
    transform.translateX(by: 100, yBy: 100)
    transform.scale(by: 824.0 / 1024.0)
    transform.concat()
}

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.0, green: 0.68, blue: 0.95, alpha: 1),
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -60)

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(.init(hierarchicalColor: .white))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

let speaker = symbol("hifispeaker.fill", pointSize: 430, weight: .regular)
let speakerRect = NSRect(
    x: (size - speaker.size.width) / 2 - 70,
    y: (size - speaker.size.height) / 2 - 40,
    width: speaker.size.width,
    height: speaker.size.height
)
speaker.draw(in: speakerRect)

let note = symbol("music.note", pointSize: 230, weight: .bold)
note.draw(in: NSRect(x: speakerRect.maxX - 40, y: speakerRect.maxY - note.size.height + 120,
                     width: note.size.width, height: note.size.height))

NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: cg.makeImage()!)
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
