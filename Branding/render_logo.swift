// Renders the voice-loop logo (yellow ribbon «S» on deep purple) to PNGs.
// Usage: swift render_logo.swift <out.png> <size> [mac]
//   mac = macOS icon shape (rounded square with margin), otherwise full-bleed square (iOS).
import AppKit

let args = CommandLine.arguments
let out = args[1]
let size = CGFloat(Double(args[2])!)
let mac = args.count > 3 && args[3] == "mac"

let bg = NSColor(srgbRed: 0x23 / 255, green: 0x00 / 255, blue: 0x21 / 255, alpha: 1)
let fg = NSColor(srgbRed: 0xDF / 255, green: 0xFF / 255, blue: 0x14 / 255, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Artwork canvas: 1254 × 1254, y down (drawn from the reference image).
let inset: CGFloat = mac ? size * 0.1 : 0
let art = size - inset * 2
let tile = CGRect(x: inset, y: inset, width: art, height: art)
let clip = mac ? CGPath(roundedRect: tile, cornerWidth: art * 0.225, cornerHeight: art * 0.225, transform: nil)
               : CGPath(rect: tile, transform: nil)
ctx.addPath(clip)
ctx.clip()
ctx.setFillColor(bg.cgColor)
ctx.fill(tile)

let k = art / 1254
ctx.translateBy(x: inset, y: inset + art)
ctx.scaleBy(x: k, y: -k)

let p = CGMutablePath()
p.move(to: CGPoint(x: 1082, y: 610))
p.addCurve(to: CGPoint(x: 1000, y: 268), control1: CGPoint(x: 1092, y: 480), control2: CGPoint(x: 1068, y: 350))
p.addCurve(to: CGPoint(x: 660, y: 120), control1: CGPoint(x: 905, y: 158), control2: CGPoint(x: 785, y: 120))
p.addCurve(to: CGPoint(x: 228, y: 292), control1: CGPoint(x: 480, y: 120), control2: CGPoint(x: 300, y: 172))
p.addCurve(to: CGPoint(x: 232, y: 602), control1: CGPoint(x: 168, y: 385), control2: CGPoint(x: 185, y: 520))
p.addCurve(to: CGPoint(x: 620, y: 780), control1: CGPoint(x: 305, y: 738), control2: CGPoint(x: 462, y: 768))
p.addCurve(to: CGPoint(x: 1078, y: 900), control1: CGPoint(x: 820, y: 795), control2: CGPoint(x: 995, y: 822))
p.addCurve(to: CGPoint(x: 978, y: 1112), control1: CGPoint(x: 1150, y: 972), control2: CGPoint(x: 1108, y: 1062))
p.addCurve(to: CGPoint(x: 320, y: 1345), control1: CGPoint(x: 800, y: 1180), control2: CGPoint(x: 500, y: 1205))

ctx.addPath(p)
ctx.setStrokeColor(fg.cgColor)
ctx.setLineWidth(215)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
