// Draws the TodoNotch app icon as a 1024 x 1024 PNG.
// Run: swift scripts/make-icon.swift Resources/icon-1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 x 824 rounded square, centered, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Soft blue gradient, matching the section badge color.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let top = NSColor(srgbRed: 0.86, green: 0.92, blue: 1.0, alpha: 1).cgColor
let bottom = NSColor(srgbRed: 0.70, green: 0.81, blue: 0.98, alpha: 1).cgColor
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// The notch: a dark tab that hangs from the top edge.
let notch = CGRect(x: 512 - 170, y: tile.maxY - 92, width: 340, height: 130)
ctx.addPath(CGPath(roundedRect: notch, cornerWidth: 46, cornerHeight: 46, transform: nil))
ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Checklist: three rows. The first row is checked. The third row is nested.
let ink = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.22, alpha: 1).cgColor
let soft = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.22, alpha: 0.45).cgColor
let rows: [(x: CGFloat, y: CGFloat, length: CGFloat, checked: Bool)] = [
    (306, 600, 420, true),
    (306, 450, 360, false),
    (396, 300, 300, false),
]
for row in rows {
    let box = CGRect(x: row.x, y: row.y, width: 96, height: 96)
    let boxPath = CGPath(roundedRect: box, cornerWidth: 24, cornerHeight: 24, transform: nil)
    if row.checked {
        ctx.addPath(boxPath)
        ctx.setFillColor(ink)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(17)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: box.minX + 24, y: box.midY + 2))
        ctx.addLine(to: CGPoint(x: box.minX + 42, y: box.minY + 26))
        ctx.addLine(to: CGPoint(x: box.maxX - 22, y: box.maxY - 24))
        ctx.strokePath()
    } else {
        ctx.addPath(boxPath)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(14)
        ctx.strokePath()
    }
    let line = CGRect(x: row.x + 140, y: row.y + 32, width: row.length - 140, height: 32)
    ctx.addPath(CGPath(roundedRect: line, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.setFillColor(row.checked ? soft : ink)
    ctx.fillPath()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
