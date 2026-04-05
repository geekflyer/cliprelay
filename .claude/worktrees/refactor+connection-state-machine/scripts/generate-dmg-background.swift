#!/usr/bin/env swift
// Generates a simple DMG background for ClipRelay's drag-to-install layout.
// Usage: swift scripts/generate-dmg-background.swift
// Output: design/dmg-background.png, design/dmg-background@2x.png

import AppKit

let bgColor = NSColor(white: 0.85, alpha: 1)  // light gray

func generateBackground(width: Int, height: Int, scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

    let w = CGFloat(width) / scale
    let h = CGFloat(height) / scale

    bgColor.setFill()
    NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: h))

    // Icon positions (matching create-dmg coords)
    let leftX: CGFloat = 165
    let rightX: CGFloat = 495
    let iconY: CGFloat = h - 175  // flip y from top to bottom

    // Straight arrow between icon positions (shorter, clear of icons)
    let arrowColor = NSColor(white: 0.45, alpha: 1)
    let startX = leftX + 80   // clear of left icon
    let endX = rightX - 80     // clear of right icon/folder
    let arrowY = iconY

    let arrowPath = NSBezierPath()
    arrowPath.move(to: NSPoint(x: startX, y: arrowY))
    arrowPath.line(to: NSPoint(x: endX, y: arrowY))
    arrowColor.setStroke()
    arrowPath.lineWidth = 2.5
    arrowPath.lineCapStyle = .round
    arrowPath.stroke()

    // Arrowhead
    let arrowHead = NSBezierPath()
    arrowHead.move(to: NSPoint(x: endX, y: arrowY))
    arrowHead.line(to: NSPoint(x: endX - 14, y: arrowY + 8))
    arrowHead.line(to: NSPoint(x: endX - 14, y: arrowY - 8))
    arrowHead.close()
    arrowColor.setFill()
    arrowHead.fill()

    // "Drag to install" text
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(white: 0.45, alpha: 1)
    ]
    let text = "Drag to install" as NSString
    let textSize = text.size(withAttributes: textAttrs)
    text.draw(at: NSPoint(x: (w - textSize.width) / 2, y: iconY - 55),
              withAttributes: textAttrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0])
let rootDir = scriptPath.deletingLastPathComponent().deletingLastPathComponent()
let designDir = rootDir.appendingPathComponent("design")

let rep1x = generateBackground(width: 660, height: 400, scale: 1)
let rep2x = generateBackground(width: 1320, height: 800, scale: 2)

try rep1x.representation(using: .png, properties: [:])!
    .write(to: designDir.appendingPathComponent("dmg-background.png"))
try rep2x.representation(using: .png, properties: [:])!
    .write(to: designDir.appendingPathComponent("dmg-background@2x.png"))

print("Generated design/dmg-background.png (660x400)")
print("Generated design/dmg-background@2x.png (1320x800)")
