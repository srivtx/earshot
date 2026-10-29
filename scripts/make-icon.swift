// Renders the Earshot app icon: a pixel earbud on the grain-green field with a hard ink shadow.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size = 1024
let bud = [
    "....+##.....",
    "..++####-...",
    ".+#######-x.",
    ".+######--xx",
    ".+######--xx",
    ".+#######-x.",
    "..+######-..",
    "...+####-...",
    "...+###-....",
    "...+###-....",
    "...+###-....",
    "...+###-....",
    "...+###-....",
    "...+#o#-....",
    "....---.....",
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.interpolationQuality = .none

// macOS icon grid: 824pt body centred in 1024.
let body = CGRect(x: 100, y: 116, width: 808, height: 808)
let radius: CGFloat = 180

// Hard shadow.
ctx.addPath(CGPath(roundedRect: body.offsetBy(dx: 18, dy: -18), cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.setFillColor(color(0x0A100C).cgColor)
ctx.fillPath()

// Field.
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.setFillColor(color(0x2E9A5D).cgColor)
ctx.fill(body)

// Grain.
var rng = SystemRandomNumberGenerator()
for _ in 0..<60000 {
    let x = CGFloat.random(in: body.minX...body.maxX, using: &rng)
    let y = CGFloat.random(in: body.minY...body.maxY, using: &rng)
    let light = Bool.random(using: &rng)
    ctx.setFillColor((light ? NSColor.white : NSColor.black).withAlphaComponent(.random(in: 0.03...0.11, using: &rng)).cgColor)
    ctx.fill(CGRect(x: x, y: y, width: 3, height: 3))
}

// Faint grid.
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
ctx.setLineWidth(2)
var g = body.minX
while g < body.maxX { ctx.move(to: CGPoint(x: g, y: body.minY)); ctx.addLine(to: CGPoint(x: g, y: body.maxY)); g += 64 }
g = body.minY
while g < body.maxY { ctx.move(to: CGPoint(x: body.minX, y: g)); ctx.addLine(to: CGPoint(x: body.maxX, y: g)); g += 64 }
ctx.strokePath()
ctx.restoreGState()

// Border.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: radius - 3, cornerHeight: radius - 3, transform: nil))
ctx.setStrokeColor(color(0x13221A).cgColor)
ctx.setLineWidth(6)
ctx.strokePath()

// The bud, 40px per pixel, centred, with a pixel drop shadow.
let px: CGFloat = 40
let spriteW = CGFloat(bud[0].count) * px, spriteH = CGFloat(bud.count) * px
let origin = CGPoint(x: body.midX - spriteW / 2 + 10, y: body.midY + spriteH / 2 - 6)
let palette: [Character: UInt32] = ["#": 0xF4FFF6, "+": 0xFFFFFF, "-": 0xA9C4B1, "o": 0x13221A, "x": 0xF7B9E4]
for pass in 0..<2 {
    for (row, line) in bud.enumerated() {
        for (col, ch) in line.enumerated() {
            guard let hex = palette[ch] else { continue }
            let shift: CGFloat = pass == 0 ? 20 : 0
            let rect = CGRect(x: origin.x + CGFloat(col) * px + shift, y: origin.y - CGFloat(row + 1) * px - shift, width: px, height: px)
            ctx.setFillColor(pass == 0 ? color(0x13221A).withAlphaComponent(0.9).cgColor : color(hex).cgColor)
            ctx.fill(rect)
        }
    }
}

// Pink pixel cluster in the corner, the Earshot mark.
for (dx, dy, hex) in [(0, 0, 0xF7B9E4), (1, 0, 0xF7B9E4), (0, 1, 0xF7B9E4), (2, 2, 0x13221A)] as [(Int, Int, UInt32)] {
    ctx.setFillColor(color(hex).cgColor)
    ctx.fill(CGRect(x: body.minX + 110 + CGFloat(dx) * 36, y: body.maxY - 146 - CGFloat(dy) * 36, width: 36, height: 36))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
