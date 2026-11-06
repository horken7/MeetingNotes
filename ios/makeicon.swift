import AppKit

// Renders the iPhone app icon (1024 px, full bleed; iOS rounds the corners): the Mac app's white waveform
// on a green gradient. Run: swift ios/makeicon.swift ios/MeetingNotes/Assets.xcassets/AppIcon.appiconset/AppIcon.png
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let gradient = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.20, green: 0.55, blue: 0.42, alpha: 1), CGColor(red: 0.07, green: 0.27, blue: 0.24, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: .zero, options: [])
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 480, weight: .semibold).applying(.init(paletteColors: [.white]))) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2, width: s.width, height: s.height))
}
NSGraphicsContext.current = nil
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
