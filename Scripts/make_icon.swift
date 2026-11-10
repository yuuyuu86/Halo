#!/usr/bin/env swift
import AppKit

// Draws the Halo mark at every icon size and writes an .iconset directory.
// Run through Scripts/build.sh; `iconutil` turns the result into AppIcon.icns.

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func draw(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    // Rounded dark plate.
    let inset = s * 0.06
    let plate = NSBezierPath(roundedRect: NSRect(x: inset, y: inset,
                                                 width: s - inset * 2, height: s - inset * 2),
                             xRadius: s * 0.22, yRadius: s * 0.22)
    let bg = NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.13, alpha: 1),
                                 NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)])
    bg?.draw(in: plate, angle: -90)

    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = s * 0.27

    // Base ring.
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.20).cgColor)
    ctx.setLineWidth(max(s * 0.018, 1))
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Lit arc.
    let gold = NSColor(calibratedRed: 1.0, green: 0.77, blue: 0.42, alpha: 1)
    ctx.setStrokeColor(gold.cgColor)
    ctx.setLineWidth(max(s * 0.030, 1))
    ctx.setLineCap(.round)
    ctx.setShadow(offset: .zero, blur: s * 0.09, color: gold.withAlphaComponent(0.85).cgColor)
    ctx.addArc(center: center, radius: radius,
               startAngle: .pi * 0.34, endAngle: .pi * 0.66, clockwise: false)
    ctx.strokePath()

    // Node at the top of the ring.
    ctx.setShadow(offset: .zero, blur: s * 0.12, color: gold.withAlphaComponent(0.9).cgColor)
    ctx.setFillColor(gold.cgColor)
    let dot = s * 0.075
    ctx.fillEllipse(in: CGRect(x: center.x - dot / 2, y: center.y + radius - dot / 2,
                               width: dot, height: dot))

    // Core.
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.13).cgColor)
    let core = s * 0.12
    ctx.fillEllipse(in: CGRect(x: center.x - core / 2, y: center.y - core / 2,
                               width: core, height: core))

    image.unlockFocus()
    return image
}

func write(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

for (size, names) in [(16, ["icon_16x16.png"]), (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
                      (64, ["icon_32x32@2x.png"]), (128, ["icon_128x128.png"]),
                      (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
                      (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
                      (1024, ["icon_512x512@2x.png"])] {
    let image = draw(size: size)
    for name in names { write(image, to: output + "/" + name) }
}

print("icons written to \(output)")
