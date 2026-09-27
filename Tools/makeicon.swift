// Renders Resources/AppIcon.iconset from code, so the icon is regenerable and reviewable.
// Run: swift Tools/makeicon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// The mark: Mulligan's level meter at rest, a calm five-bar waveform in off-white on the
// app's charcoal ink, with the single coral recording lamp in the top corner. Flat fills
// and one hairline highlight; the palette is the app's own design tokens.
import AppKit

let ink = NSColor(srgbRed: 0x1C / 255, green: 0x1B / 255, blue: 0x18 / 255, alpha: 1)
let paper = NSColor(srgbRed: 0xED / 255, green: 0xEA / 255, blue: 0xE3 / 255, alpha: 1)
let coral = NSColor(srgbRed: 0xE0 / 255, green: 0x6A / 255, blue: 0x5C / 255, alpha: 1)

// name -> pixel size, per Apple's iconset naming.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func draw(canvas s: CGFloat, pixels: Int) {
    // Apple's macOS icon grid: the squircle fills 824 of 1024 points, centred.
    let inset = s * 100 / 1024
    let plate = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = plate.width * 0.2237

    // Plate with a soft drop shadow, as the system's own icons carry.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    ink.setFill()
    NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()

    // One hairline of light along the top edge: material, not gloss.
    let bevel = NSBezierPath(roundedRect: plate.insetBy(dx: s * 0.005, dy: s * 0.005), xRadius: radius, yRadius: radius)
    bevel.lineWidth = max(1, s * 0.007)
    paper.withAlphaComponent(0.12).setStroke()
    bevel.stroke()

    // The waveform at rest, centred on the plate's horizontal axis, sitting a touch low
    // so the lamp has room above.
    let heights: [CGFloat] = pixels >= 64 ? [0.26, 0.46, 0.66, 0.42, 0.30] : [0.34, 0.66, 0.38]
    let barWidth = plate.width * (pixels >= 64 ? 0.082 : 0.13)
    let gap = plate.width * (pixels >= 64 ? 0.062 : 0.09)
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = plate.midX - total / 2
    let axis = plate.midY - plate.height * 0.05
    paper.setFill()
    for fraction in heights {
        let height = plate.height * fraction
        let bar = NSRect(x: x, y: axis - height / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    // The recording lamp.
    let lampRadius = plate.width * (pixels >= 64 ? 0.048 : 0.075)
    let lampCentre = NSPoint(x: plate.maxX - plate.width * 0.21, y: plate.maxY - plate.height * 0.21)
    coral.setFill()
    NSBezierPath(ovalIn: NSRect(x: lampCentre.x - lampRadius, y: lampCentre.y - lampRadius, width: 2 * lampRadius, height: 2 * lampRadius)).fill()
}

func render(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create a \(pixels)px bitmap")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(canvas: CGFloat(pixels), pixels: pixels)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(pixels)px PNG")
    }
    return png
}

let outputDirectory = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (name, pixels) in variants {
    try render(pixels: pixels).write(to: outputDirectory.appendingPathComponent("\(name).png"))
}
print("wrote \(variants.count) sizes to \(outputDirectory.path)")
