import AppKit

// Renders a 1024px app icon: a white waveform on a green rounded square.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let rect = NSRect(x: 100, y: 100, width: size - 200, height: size - 200)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.42, alpha: 1),
        ending: NSColor(calibratedRed: 0.07, green: 0.27, blue: 0.24, alpha: 1)
    )?.draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        let tinted = NSImage(size: s, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
