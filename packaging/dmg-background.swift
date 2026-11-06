import AppKit

// Draws the disk image window background: an arrow from the app to Applications, and what to do the
// first time macOS blocks the (unsigned) app.
//   swift packaging/dmg-background.swift <out.png> <scale 1 or 2>
let width: CGFloat = 640, height: CGFloat = 420
let scale = CGFloat(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1") ?? 1)

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, in rect: NSRect) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = 3
    (s as NSString).draw(in: rect, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ])
}

let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let ink = NSColor(calibratedRed: 0.07, green: 0.27, blue: 0.24, alpha: 1)
    text("Drag Meeting Notes into Applications", 20, .semibold, ink, in: NSRect(x: 0, y: 28, width: width, height: 30))

    // Arrow between the icons (icons sit at x 170 and 470, y 190 in window points).
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 255, y: 190))
    arrow.line(to: NSPoint(x: 366, y: 190))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    ink.withAlphaComponent(0.55).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 390, y: 190))
    head.line(to: NSPoint(x: 368, y: 175))
    head.line(to: NSPoint(x: 368, y: 205))
    head.close()
    ink.withAlphaComponent(0.55).setFill()
    head.fill()

    let note = """
    Then open Meeting Notes from Applications. The first time, macOS says it can't check the app: \
    click Done, open System Settings > Privacy & Security, scroll down and click Open Anyway.
    """
    text(note, 13, .regular, NSColor(calibratedWhite: 0.3, alpha: 1), in: NSRect(x: 50, y: 318, width: width - 100, height: 70))
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
