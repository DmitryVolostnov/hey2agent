// Turns the square logo frame into app icon PNGs.
// Usage: swift make_icon.swift <src.png> <out.png> <size> [mac]
//   mac: Big Sur style — rounded square with transparent margin; otherwise full-bleed (iOS masks it).
import AppKit

let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!
let size = CGFloat(Double(a[3])!)
let mac = a.count > 4 && a[4] == "mac"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high
let inset = mac ? size * 0.1 : 0
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
if mac {
    // The artwork has its own rounded tile with black corners: mask them away.
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).addClip()
}
src.draw(in: tile, from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
