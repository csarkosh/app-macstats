// MacStats' app icon: the CS logo of csarko.sh (public/favicon.svg in csarkosh/csarko.sh),
// "cs" in bold monospace, teal on near-black, drawn here so the build needs no image file.
// scripts/bundle.sh writes it with `MacStats --write-icon <dir>.iconset` and packs it with iconutil.

import Cocoa

/// The logo's colours and proportions, from its SVG: a 64-unit square with corners of 14,
/// and "cs" 28 units high, centred, its middle 54% of the way down.
private let logoBackground = NSColor(srgbRed: 0x0a / 255, green: 0x0b / 255, blue: 0x0e / 255, alpha: 1)
private let logoTeal = NSColor(srgbRed: 0x7d / 255, green: 0xd3 / 255, blue: 0xc0 / 255, alpha: 1)

/// Draws the icon into the current context, `size` points square. The logo sits on macOS's
/// icon grid, 824 of 1024 centred, as other apps' icons do.
func drawAppIcon(size: CGFloat) {
    let side = size * 824 / 1024
    let square = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
    let unit = side / 64
    logoBackground.setFill()
    NSBezierPath(roundedRect: square, xRadius: 14 * unit, yRadius: 14 * unit).fill()

    let font = NSFont.monospacedSystemFont(ofSize: 28 * unit, weight: .bold)
    let text = NSAttributedString(string: "cs", attributes: [.font: font, .foregroundColor: logoTeal])
    // The SVG's "middle" baseline is half the x-height above the text's baseline.
    let middleFromTop = square.height * 0.54
    let baseline = square.maxY - middleFromTop - font.xHeight / 2
    text.draw(at: CGPoint(x: square.midX - text.size().width / 2, y: baseline + font.descender))
}

/// Writes the sizes macOS's iconutil wants into `directory` (an `.iconset`).
func writeIconSet(to directory: String) -> Int32 {
    let url = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 1 }
            rep.size = NSSize(width: pixels, height: pixels)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            drawAppIcon(size: CGFloat(pixels))
            NSGraphicsContext.restoreGraphicsState()
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: url.appendingPathComponent(name))) != nil else { return 1 }
        }
    }
    return 0
}
