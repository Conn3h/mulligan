// Renders Resources/AppIcon.iconset from code, so the icon is regenerable and reviewable.
// Run: swift Tools/makeicon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// The mark: the tee shot. A coral ball (the app's recording lamp) sits on an off-white tee,
// with two sound arcs coming off it, on the app's charcoal ink. A mulligan is a free second
// shot; this is the shot. Flat fills and one hairline highlight; the palette is the app's own
// design tokens. Geometry is in a 100-unit box, the plate spanning 10...90, y down, as in the
// design canvas; `point` maps it onto the bitmap.
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

    // Canvas units (100 wide, y down) to bitmap points (y up).
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x / 100 * s, y: s - y / 100 * s)
    }
    func length(_ units: CGFloat) -> CGFloat {
        units / 100 * s
    }
    let small = pixels < 64

    // The ground: a faint line under the tee. Lost below 64 px, so left out there.
    if !small {
        let ground = NSBezierPath()
        ground.move(to: point(26, 78))
        ground.line(to: point(74, 78))
        ground.lineWidth = length(1.5)
        ground.lineCapStyle = .round
        paper.withAlphaComponent(0.3).setStroke()
        ground.stroke()
    }

    // The tee: a cup under the ball and a stem.
    paper.setFill()
    let cup = NSBezierPath()
    cup.move(to: point(34, 58))
    cup.line(to: point(54, 58))
    cup.line(to: point(47.5, 63))
    cup.line(to: point(40.5, 63))
    cup.close()
    cup.fill()
    let stemWidth = length(3.6)
    let stemTop = point(42.2, 62)
    let stem = NSRect(x: stemTop.x, y: stemTop.y - length(16), width: stemWidth, height: length(16))
    NSBezierPath(roundedRect: stem, xRadius: stemWidth / 2, yRadius: stemWidth / 2).fill()

    // The sound arcs, centred on the ball, 40 degrees either side of horizontal. Small sizes
    // keep only the inner arc, drawn heavier so it survives the downscale.
    let centre = point(44, 46)
    let arcs: [(radius: CGFloat, alpha: CGFloat)] = small ? [(17, 1)] : [(17, 1), (24, 0.55)]
    for arc in arcs {
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: length(arc.radius), startAngle: -40, endAngle: 40)
        path.lineWidth = length(small ? 5 : 3)
        path.lineCapStyle = .round
        paper.withAlphaComponent(arc.alpha).setStroke()
        path.stroke()
    }

    // The ball: the recording lamp.
    let ballRadius = length(11)
    coral.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - ballRadius, y: centre.y - ballRadius, width: 2 * ballRadius, height: 2 * ballRadius)).fill()
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
