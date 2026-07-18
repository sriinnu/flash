import AppKit

// Renders build/icon-1024.png — the master for Flash.icns.
// Deep navy rounded tile + neon amber-gradient bolt-shield with glow.

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let fullRect = CGRect(x: 0, y: 0, width: size, height: size)

// Background tile.
let tileRect = fullRect.insetBy(dx: 28, dy: 28)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 230, yRadius: 230)
NSGradient(colors: [
    NSColor(red: 0.13, green: 0.14, blue: 0.24, alpha: 1),
    NSColor(red: 0.04, green: 0.05, blue: 0.13, alpha: 1)
])!.draw(in: tile, angle: -90)

// Faint radial warmth behind the symbol.
if let context = NSGraphicsContext.current?.cgContext {
    context.saveGState()
    tile.addClip()
    let glowCenter = CGPoint(x: size / 2, y: size / 2)
    let glowColors = [
        NSColor(red: 1.0, green: 0.62, blue: 0.05, alpha: 0.35).cgColor,
        NSColor.clear.cgColor
    ] as CFArray
    if let radial = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: glowColors, locations: [0, 1]) {
        context.drawRadialGradient(radial,
                                   startCenter: glowCenter, startRadius: 0,
                                   endCenter: glowCenter, endRadius: 480,
                                   options: [])
    }
    context.restoreGState()
}

// Bolt-shield symbol, gradient-tinted with an outer glow.
let config = NSImage.SymbolConfiguration(pointSize: 600, weight: .bold)
    .applying(NSImage.SymbolConfiguration.preferringMonochrome())
if let symbol = NSImage(systemSymbolName: "bolt.shield.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symRect = CGRect(
        x: (size - symbol.size.width) / 2,
        y: (size - symbol.size.height) / 2 + 10,
        width: symbol.size.width,
        height: symbol.size.height
    )
    let gradient = NSGradient(colors: [
        NSColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1),
        NSColor(red: 1.00, green: 0.55, blue: 0.02, alpha: 1)
    ])!

    // Build the gradient-symbol offscreen: paint the gradient, then cut it
    // down to the symbol's alpha with destinationIn. Doing this on the main
    // canvas won't work — the opaque tile behind defeats sourceIn.
    let local = CGRect(origin: .zero, size: symRect.size)
    let masked = NSImage(size: symRect.size)
    masked.lockFocus()
    gradient.draw(in: local, angle: -55)
    symbol.draw(in: local, from: .zero, operation: .destinationIn, fraction: 1)
    masked.unlockFocus()

    // Composite onto the tile twice with a neon shadow — glow + bright core.
    if let context = NSGraphicsContext.current?.cgContext {
        context.saveGState()
        tile.addClip()
        context.setShadow(offset: .zero, blur: 55,
                          color: NSColor(red: 1.0, green: 0.62, blue: 0.05, alpha: 0.9).cgColor)
        masked.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1)
        masked.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1)
        context.restoreGState()
    }
}

image.unlockFocus()

try! FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon PNG")
}
try png.write(to: URL(fileURLWithPath: "build/icon-1024.png"))
print("wrote build/icon-1024.png")
