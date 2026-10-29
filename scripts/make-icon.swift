// Renders Resources/AppIcon.icns: a dark tile with three green equalizer bars.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let set = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    NSColor(white: 0.1, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22).fill()
    NSColor(red: 0.12, green: 0.84, blue: 0.38, alpha: 1).setFill()
    let barW = tile.width * 0.14, gap = tile.width * 0.08
    let total = barW * 3 + gap * 2
    for (i, h) in [0.38, 0.62, 0.48].enumerated() {
        let x = tile.midX - total / 2 + CGFloat(i) * (barW + gap)
        let r = NSRect(x: x, y: tile.minY + tile.height * 0.22, width: barW, height: tile.height * h)
        NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in sizes {
    if px <= 512 { try! render(px).write(to: set.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try! render(px).write(to: set.appendingPathComponent("icon_\(px / 2)x\(px / 2)@2x.png")) }
}
