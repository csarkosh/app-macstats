// Composes the README's hero: the top of a Mac screen, with the real menu bar across the
// top, the real wallpaper below it (captured from macOS's wallpaper window, which sits
// behind every other window, so nothing covers it), and a real panel dropped down under
// its item, as it does when clicked. Without a wallpaper, a gradient in the bar's colours. A bare strip of the bar never reads as a menu bar; the screen's top
// edge, the system icons and the clock, and a panel beneath do.
//
//   swift scripts/compose-hero.swift <bar.png> <panel.png> <item x in points> <out.png> [<height in points> [<wallpaper.png> <bar x in points>]]
//   swift scripts/compose-hero.swift --finish <screenshot.png> <height in points> <out.png>
//
// --finish takes a screenshot someone took themselves (the top of the screen with a panel
// open) and gives it the hero's finish: cut to the height from the top, faded at the bottom.
//
// bar.png is a 2x capture of the bar from the notch's edge to the screen's right edge;
// item x is where the panel's item starts, in points from the bar's left edge; wallpaper.png
// is a 2x capture of the whole wallpaper window and bar x where the bar's capture starts in it. With a
// height, the image stops there and the panel fades out towards the bottom edge, a
// landscape hero that shows the bar and the top of a dropdown; the full panels follow
// in the README.

import Cocoa

let arguments = CommandLine.arguments

/// The bottom fifth fades to transparent, so a cut reads as a fade, not an edge.
func fadeBottom(of canvas: NSRect) {
    let fade = NSRect(x: 0, y: 0, width: canvas.width, height: canvas.height * 0.22)
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    NSGradient(colors: [NSColor.black, NSColor.black.withAlphaComponent(0)])!.draw(in: fade, angle: 90)
}

func canvasRep(width: Double, height: Double) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

if arguments.count == 5 && arguments[1] == "--finish" {
    guard let shot = NSImage(contentsOfFile: arguments[2]), let rep = shot.representations.first as? NSBitmapImageRep,
          let points = Double(arguments[3]) else {
        FileHandle.standardError.write("usage: compose-hero.swift --finish <screenshot.png> <height in points> <out.png>\n".data(using: .utf8)!)
        exit(2)
    }
    // A screenshot's pixels per point: 2 on a Retina display.
    let pixelsPerPoint = Double(rep.pixelsWide) / shot.size.width
    let width = Double(rep.pixelsWide), height = min(Double(rep.pixelsHigh), points * pixelsPerPoint)
    let out = canvasRep(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    // The top of the screenshot, as tall as asked.
    shot.draw(in: canvas, from: NSRect(x: 0, y: shot.size.height - height / pixelsPerPoint, width: shot.size.width, height: height / pixelsPerPoint),
              operation: .copy, fraction: 1)
    fadeBottom(of: canvas)
    NSGraphicsContext.restoreGraphicsState()
    try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[4]))
    print("Wrote \(arguments[4]) (\(Int(width))x\(Int(height)))")
    exit(0)
}

guard [5, 6, 8].contains(arguments.count), let itemX = Double(arguments[3]),
      let bar = NSImage(contentsOfFile: arguments[1]), let panel = NSImage(contentsOfFile: arguments[2]),
      let barRep = bar.representations.first as? NSBitmapImageRep, let panelRep = panel.representations.first as? NSBitmapImageRep
else {
    FileHandle.standardError.write("usage: compose-hero.swift <bar.png> <panel.png> <item x in points> <out.png>\n".data(using: .utf8)!)
    exit(2)
}

// Everything in pixels, at the captures' 2x.
let scale = 2.0
let barWidth = Double(barRep.pixelsWide), barHeight = Double(barRep.pixelsHigh)
let panelWidth = Double(panelRep.pixelsWide), panelHeight = Double(panelRep.pixelsHigh)
let gap = 3 * scale, margin = 28 * scale
let width = barWidth
let fullHeight = barHeight + gap + panelHeight + margin
let height = arguments.count >= 6 ? min(fullHeight, (Double(arguments[5]) ?? 0) * scale) : fullHeight
let fades = height < fullHeight
// The panel sits centred under its item (items are about 40 pt wide), kept inside the edge.
var panelX = itemX * scale + 20 * scale - panelWidth / 2
panelX = min(max(panelX, 8 * scale), width - panelWidth - 8 * scale)

// The wallpaper: the bar's average colour at its left and right thirds, darkened downwards.
func average(_ rep: NSBitmapImageRep, from: Int, to: Int) -> NSColor {
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for x in stride(from: from, to: to, by: 6) {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        }
    }
    return NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
}
let left = average(barRep, from: Int(barWidth * 0.1), to: Int(barWidth * 0.4))
let right = average(barRep, from: Int(barWidth * 0.6), to: Int(barWidth * 0.95))
func darker(_ c: NSColor, _ by: CGFloat) -> NSColor {
    NSColor(srgbRed: c.redComponent * by, green: c.greenComponent * by, blue: c.blueComponent * by, alpha: 1)
}

let out = canvasRep(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)
if arguments.count == 8, let wallpaper = NSImage(contentsOfFile: arguments[6]), let barX = Double(arguments[7]),
   let wallpaperRep = wallpaper.representations.first as? NSBitmapImageRep {
    // The wallpaper's top edge from where the bar starts, as wide and tall as the canvas.
    // NSImage measures `from` in its own points, not the capture's pixels.
    let pointScale = wallpaper.size.width / Double(wallpaperRep.pixelsWide)
    let from = NSRect(x: barX * scale * pointScale, y: wallpaper.size.height - height * pointScale,
                      width: width * pointScale, height: height * pointScale)
    wallpaper.draw(in: canvas, from: from, operation: .copy, fraction: 1)
} else {
    // Left to right follows the bar; top to bottom darkens, as a wallpaper does under a menu bar.
    NSGradient(colors: [left, right])!.draw(in: canvas, angle: 0)
    NSGradient(colors: [darker(left, 0.55).withAlphaComponent(0.55), NSColor.clear])!.draw(in: canvas, angle: 90)
}
// The bar at the top edge, as captured.
bar.draw(in: NSRect(x: 0, y: height - barHeight, width: barWidth, height: barHeight), from: .zero, operation: .sourceOver, fraction: 1)
// The panel under its item, with the shadow macOS gives a menu (the shadow follows the
// panel's own edge, so its rounded corners stay clean).
let panelRect = NSRect(x: panelX, y: height - barHeight - gap - panelHeight, width: panelWidth, height: panelHeight)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 18 * scale
shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
shadow.set()
panel.draw(in: panelRect, from: .zero, operation: .sourceOver, fraction: 1)
NSShadow().set()
if fades { fadeBottom(of: canvas) }
NSGraphicsContext.restoreGraphicsState()

try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[4]))
print("Wrote \(arguments[4]) (\(Int(width))x\(Int(height)))")
