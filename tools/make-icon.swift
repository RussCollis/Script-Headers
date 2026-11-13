#!/usr/bin/env swift
//
// Renders the Info Headers app icon as a 1024×1024 PNG.
// Usage: swift tools/make-icon.swift <output.png>
//
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("Couldn't create bitmap")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(blur: CGFloat, offsetY: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offsetY)
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func bar(_ rect: NSRect, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
}

// MARK: Background squircle (macOS icon grid: 824pt body inset 100pt)

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

withShadow(blur: 28, offsetY: -14, alpha: 0.35) {
    color(0x1D4ED8).setFill()
    bodyPath.fill()
}
NSGradient(colors: [color(0x5CA8FA), color(0x2966DB), color(0x3D2E9E)])?.draw(in: bodyPath, angle: -90)

// Soft glassy highlight across the top half.
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
let highlight = NSBezierPath(ovalIn: NSRect(x: -60, y: 560, width: 1144, height: 620))
NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])?
    .draw(in: highlight, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// MARK: Script card

let card = NSRect(x: 250, y: 205, width: 500, height: 610)
let cardPath = NSBezierPath(roundedRect: card, xRadius: 52, yRadius: 52)
withShadow(blur: 30, offsetY: -16, alpha: 0.30) {
    NSColor.white.setFill()
    cardPath.fill()
}
NSGradient(colors: [NSColor.white, color(0xEEF2FF)])?.draw(in: cardPath, angle: -90)

// Shebang on the first line.
let shebang = NSAttributedString(string: "#!", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 92, weight: .heavy),
    .foregroundColor: color(0x2966DB),
])
shebang.draw(at: NSPoint(x: 292, y: 680))
bar(NSRect(x: 425, y: 712, width: 260, height: 34), color(0xC9D3F5))

// Highlighted header block with ruler lines and "Label : value" rows.
let block = NSRect(x: 286, y: 405, width: 428, height: 250)
color(0xDCE6FF).setFill()
NSBezierPath(roundedRect: block, xRadius: 26, yRadius: 26).fill()
bar(NSRect(x: 310, y: 620, width: 380, height: 12), color(0x2966DB))
bar(NSRect(x: 310, y: 428, width: 380, height: 12), color(0x2966DB))
for (index, width) in [190.0, 230.0, 160.0].enumerated() {
    let y = 568 - CGFloat(index) * 58
    bar(NSRect(x: 314, y: y, width: 92, height: 26), color(0x3D2E9E))
    bar(NSRect(x: 426, y: y, width: width, height: 26), color(0x8FA7E8))
}

// Code lines below the header.
for (index, width) in [260.0, 200.0].enumerated() {
    bar(NSRect(x: 300, y: 330 - CGFloat(index) * 62, width: width, height: 28), color(0xC9D3F5))
}

// MARK: Info badge

let badgeCenter = NSPoint(x: 735, y: 265)
let badgeRadius: CGFloat = 128
let badge = NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                                        width: badgeRadius * 2, height: badgeRadius * 2))
withShadow(blur: 24, offsetY: -10, alpha: 0.35) {
    color(0x16A34A).setFill()
    badge.fill()
}
NSGradient(colors: [color(0x4ADE80), color(0x15803D)])?.draw(in: badge, angle: -90)
NSColor.white.withAlphaComponent(0.9).setStroke()
badge.lineWidth = 10
badge.stroke()

// The "i": a dot above a rounded stem.
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 24, y: badgeCenter.y + 44, width: 48, height: 48)).fill()
NSBezierPath(roundedRect: NSRect(x: badgeCenter.x - 21, y: badgeCenter.y - 82, width: 42, height: 108),
             xRadius: 21, yRadius: 21).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
