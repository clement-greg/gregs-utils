// Draws the app icon (a page with text lines and a red squiggle) into an .iconset folder.
import Cocoa

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let page = NSRect(x: s * 0.18, y: s * 0.10, width: s * 0.64, height: s * 0.80)
    NSColor(calibratedWhite: 0, alpha: 0.25).setFill()
    NSBezierPath(roundedRect: page.offsetBy(dx: 0, dy: -s * 0.015), xRadius: s * 0.06, yRadius: s * 0.06).fill()
    NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: page, xRadius: s * 0.06, yRadius: s * 0.06).fill()

    NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
    let lineH = s * 0.035
    for (i, w) in [0.48, 0.40, 0.46, 0.30].enumerated() {
        let y = page.maxY - s * 0.16 - CGFloat(i) * s * 0.12
        NSBezierPath(roundedRect: NSRect(x: page.minX + s * 0.08, y: y, width: s * CGFloat(w), height: lineH),
                     xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }

    // Red squiggle under the second line.
    let squiggle = NSBezierPath()
    let baseY = page.maxY - s * 0.16 - s * 0.12 - s * 0.03
    let startX = page.minX + s * 0.08
    let amp = s * 0.018, step = s * 0.035
    squiggle.move(to: NSPoint(x: startX, y: baseY))
    var x = startX
    var up = true
    while x < startX + s * 0.40 {
        squiggle.line(to: NSPoint(x: x + step / 2, y: baseY + (up ? amp : -amp)))
        x += step / 2
        up.toggle()
    }
    squiggle.lineWidth = max(1, s * 0.016)
    squiggle.lineJoinStyle = .round
    NSColor.systemRed.setStroke()
    squiggle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
