// The opening clip for MacStats' page on apps.csarko.sh, drawn frame by frame with MacStats' own
// views: the five menu bar items (MiniView) and the CPU panel (CPUPanel), fed a scripted minute of
// readings, over an original deep-water backdrop with a menu bar across the top. Nothing is read
// from this Mac but its core types and the CPU temperature the panel's gauge reads, and no screen
// is recorded. scripts/hero-video.sh compiles this with every file in Sources/MacStats/ except
// main.swift and runs it:
//
//   hero-scene <out.mp4> [--poster out.jpg] [--fps 30] [--preview]
//
// The camera opens tight on the CPU item as its value ticks, the panel drops open under it, the
// camera drifts down over its gauges and its chart, then pulls back into the whole bar and panel,
// and holds. Every frame is drawn in Core Graphics at the camera's zoom, so the close-ups are as
// sharp as the wide shot; frames go to ffmpeg as raw RGBA.
import AppKit
import CoreImage

// What main.swift defines for the app, which this harness replaces.
let percentWidest = "100%"
let temperatureWidest = degrees(100)
let diskWidest = "888 GB"

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let preview = args.contains("--preview")
args.removeAll { $0 == "--preview" }
let posterPath = option("--poster")
let fps = Int(option("--fps") ?? "") ?? (preview ? 15 : 30)
guard let outPath = args.first else {
    FileHandle.standardError.write("usage: hero-scene <out.mp4> [--poster out.jpg] [--fps 30] [--preview]\n".data(using: .utf8)!)
    exit(2)
}

_ = NSApplication.shared
NSApp.appearance = NSAppearance(named: .darkAqua)

// MARK: - The scene, in points, top-left origin (converted when drawn)

let W: CGFloat = 1440, H: CGFloat = 800
let pixelScale: CGFloat = preview ? 0.5 : 2
let duration = 7.6
let barHeight: CGFloat = 24

/// The items, right to left from the system icons, as the bar lays them out.
struct Item { let label: String; let widest: String?; var value: String }
let itemGap: CGFloat = 14
let itemsRight: CGFloat = 1040
let probe = MiniView()
func itemWidth(_ label: String, _ widest: String?) -> CGFloat {
    probe.label = label; probe.widest = widest; probe.value = widest ?? "88 GB"
    return probe.contentWidth()
}
let labels: [(String, String?)] = [("CPU", percentWidest), ("GPU", percentWidest), ("RAM", percentWidest), ("Temp", temperatureWidest), ("Disk free", diskWidest)]
let widths = labels.map { itemWidth($0.0, $0.1) }
let itemXs: [CGFloat] = {
    var x = itemsRight - widths.reduce(0, +) - itemGap * CGFloat(widths.count - 1)
    var xs: [CGFloat] = []
    for w in widths { xs.append(x); x += w + itemGap }
    return xs
}()
let cpuItemCentre = CGPoint(x: itemXs[0] + widths[0] / 2, y: barHeight / 2)

// MARK: - The scripted minute

/// A smooth, lively value: a few sines, no randomness, so every run is the same.
func wave(_ s: Double, _ base: Double, _ amp: Double, _ f: [Double]) -> Double {
    base + amp * f.enumerated().reduce(0) { acc, e in acc + sin(s * e.element + Double(e.offset) * 1.7) / Double(f.count) }
}
/// The data clock runs four seconds of readings to each second of film, so the chart moves.
func dataSeconds(_ t: Double) -> Double { 120 + t * 4 }
func cpuUsage(_ s: Double) -> Double { min(0.92, max(0.06, wave(s, 0.30, 0.34, [0.21, 0.53, 1.31]) + (sin(s * 0.09) > 0.7 ? 0.25 : 0))) }
func sample(at s: Double) -> CPUSample {
    let usage = cpuUsage(s)
    let system = usage * 0.34, user = usage * 0.66
    let speeds = coreTypes.enumerated().map { i, type -> Double in
        let top = type.steps.max() ?? 3000
        return top * min(1, max(0.25, wave(s + Double(i) * 3, 0.55 + usage * 0.4, 0.25, [0.7, 1.9])))
    }
    let cores = Double(ProcessInfo.processInfo.processorCount)
    return CPUSample(system: system, user: user, idle: 1 - usage, coreUsage: coreTypes.map { _ in usage },
                     frequencies: speeds, load: cores * (0.18 + usage * 0.5))
}

let history = CPUHistory()
let reader = SensorReader()
let panel = CPUPanel(history: history, reader: reader)
var fed = -1
/// The history up to the data second of `t`, one sample a data second.
func feed(_ t: Double) {
    let upTo = Int(dataSeconds(t))
    if fed < 0 { for s in (upTo - history.capacity)...upTo { history.add(sample(at: Double(s))) }; fed = upTo }
    while fed < upTo { fed += 1; history.add(sample(at: Double(fed))) }
    panel.update(history.samples.last!)
}

func itemValues(_ t: Double) -> [String] {
    // The items tick twice a second of film, as a second of readings would.
    let s = 120 + floor(t * 2) * 2
    let gpu = min(0.88, max(0.04, wave(s, 0.38, 0.4, [0.33, 0.8])))
    let ram = 0.63 + 0.02 * sin(s * 0.05)
    let celsius = 52 + 14 * cpuUsage(s)
    return [formatPercent(cpuUsage(s)), formatPercent(gpu), formatPercent(ram), degrees(celsius), "412 GB"]
}

// MARK: - Drawing helpers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
/// A rect given top-left in scene points, as Core Graphics' bottom-left one.
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: H - y - h, width: w, height: h) }

/// The backdrop: deep water, light from above, a few soft shafts and a warm glow far right.
func drawBackdrop(_ c: CGContext) {
    let base = CGGradient(colorsSpace: colorSpace, colors: [color(0x0e3a5c), color(0x08243d), color(0x04121f)] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(base, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    let glow = { (x: CGFloat, y: CGFloat, r: CGFloat, hex: UInt32, a: CGFloat) in
        let g = CGGradient(colorsSpace: colorSpace, colors: [color(hex, a), color(hex, 0)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: H - y), startRadius: 0, endCenter: CGPoint(x: x, y: H - y), endRadius: r, options: [])
    }
    glow(420, -40, 700, 0x3fb6d6, 0.42)
    glow(1250, 520, 520, 0x6a4bd1, 0.30)
    glow(980, 980, 620, 0x1fa38a, 0.28)
    // Shafts of light from the surface.
    c.saveGState()
    for (i, x) in [180.0, 330, 560, 760, 1010].enumerated() {
        c.saveGState()
        c.translateBy(x: CGFloat(x), y: H + 40)
        c.rotate(by: -0.28 + CGFloat(i) * 0.03)
        let shaft = CGGradient(colorsSpace: colorSpace, colors: [color(0x9fe6ff, 0.10), color(0x9fe6ff, 0)] as CFArray, locations: [0, 1])!
        c.addRect(CGRect(x: -26 - CGFloat(i % 2) * 18, y: -900, width: 52 + CGFloat(i % 2) * 36, height: 900))
        c.clip()
        c.drawLinearGradient(shaft, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: -900), options: [])
        c.restoreGState()
    }
    c.restoreGState()
}

/// The menu bar: translucent dark across the top, the five items, the system's own icons and
/// the clock at the right.
func drawBar(_ c: CGContext, values: [String], highlight: CGFloat) {
    c.setFillColor(color(0x05101c, 0.55))
    c.fill(rect(0, 0, W, barHeight))
    if highlight > 0 {
        let r = rect(itemXs[0] - 6, 2, widths[0] + 12, barHeight - 4)
        c.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
        c.setFillColor(color(0xffffff, 0.22 * highlight))
        c.fillPath()
    }
    let ns = NSGraphicsContext(cgContext: c, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    for (i, l) in labels.enumerated() {
        let view = MiniView()
        view.label = l.0; view.widest = l.1; view.value = values[i]
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(x: 0, y: 0, width: widths[i], height: 18)
        c.saveGState()
        c.translateBy(x: itemXs[i], y: H - 2 - 18 - 1)
        view.appearance!.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        c.restoreGState()
    }
    // The system's own items: Wi-Fi, the battery, the control centre, the clock.
    var x = itemsRight + 22
    for symbol in ["wifi", "battery.75percent", "switch.2"] {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            let tinted = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: CGRect(x: x, y: H - barHeight / 2 - image.size.height / 2, width: image.size.width, height: image.size.height))
            x += image.size.width + 16
        }
    }
    NSAttributedString(string: "Sun 9:41 AM", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        .draw(at: CGPoint(x: x + 2, y: H - barHeight / 2 - 8))
    NSGraphicsContext.restoreGraphicsState()
}

/// The panel: its content drawn by AppKit into a bitmap at the camera's pixel scale (so it is
/// sharp at any zoom), on a dark glass card with a shadow, faded out below the chart so the
/// clip shows the dashboard and the usage, not the processes.
let panelShown: CGFloat = 520
func drawPanel(_ c: CGContext, at origin: CGPoint, alpha: CGFloat, scale: CGFloat) {
    guard alpha > 0.001, let content = panel.contentView else { return }
    content.layoutSubtreeIfNeeded()
    let size = content.fittingSize
    content.setFrameSize(size)
    content.layoutSubtreeIfNeeded()
    let px = max(1, scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * px), pixelsHigh: Int(panelShown * px),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: size.width, height: panelShown)
    content.appearance = NSAppearance(named: .darkAqua)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The top `panelShown` points of the panel: shift the content up so its top is the bitmap's.
    NSGraphicsContext.current!.cgContext.translateBy(x: 0, y: panelShown - size.height)
    content.appearance!.performAsCurrentDrawingAppearance {
        content.displayIgnoringOpacity(content.bounds, in: NSGraphicsContext.current!)
    }
    NSGraphicsContext.restoreGraphicsState()
    let card = rect(origin.x, origin.y, size.width, panelShown)
    c.saveGState()
    c.setAlpha(alpha)
    // Fade the card out over its last 120 points.
    let mask = CGContext(data: nil, width: 1, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    for i in 0..<256 { let v = min(255, Int(Double(i) / 255 * Double(panelShown) / 120 * 255)); mask.setFillColor(gray: CGFloat(v) / 255, alpha: 1); mask.fill(CGRect(x: 0, y: i, width: 1, height: 1)) }
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.55))
    c.addPath(CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12, transform: nil))
    c.setFillColor(color(0x1c1f26, 0.93))
    c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(CGPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 12, cornerHeight: 12, transform: nil))
    c.setStrokeColor(color(0xffffff, 0.13))
    c.setLineWidth(1)
    c.strokePath()
    if let image = rep.cgImage { c.draw(image, in: card) }
    c.endTransparencyLayer()
    c.restoreGState()
    // The fade: the wallpaper back over the card's foot.
    c.saveGState()
    c.clip(to: card)
    let fade = CGGradient(colorsSpace: colorSpace, colors: [color(0x05162a, 0), color(0x05162a, 1)] as CFArray, locations: [0, 1])!
    c.setAlpha(alpha)
    c.drawLinearGradient(fade, start: CGPoint(x: 0, y: card.minY + 140), end: CGPoint(x: 0, y: card.minY), options: [])
    c.restoreGState()
    _ = mask
}

// MARK: - The camera and the timeline

func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
func smooth(_ v: Double) -> Double { let v = clamp(v); return v * v * (3 - 2 * v) }
func inOut(_ v: Double) -> Double { let v = clamp(v); return v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2 }
func outCubic(_ v: Double) -> Double { 1 - pow(1 - clamp(v), 3) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }

let panelOrigin = CGPoint(x: cpuItemCentre.x - (Panel.width + Panel.margin * 2) / 2, y: barHeight + 6)
let openAt = 2.0, openFor = 0.28
let gaugesAt = CGPoint(x: panelOrigin.x + (Panel.width + Panel.margin * 2) / 2, y: panelOrigin.y + 120)
let chartAt = CGPoint(x: gaugesAt.x, y: panelOrigin.y + 300)
/// The key art, a little closer than the whole scene: the bar along the top, the panel under it
/// a little right of centre, open water to its left for the page's title.
let restZoom: CGFloat = 1.3
let restCentre = CGPoint(x: panelOrigin.x + (Panel.width + Panel.margin * 2) / 2 - 0.12 * W / restZoom, y: H / (2 * restZoom))

/// Where the camera looks (scene points) and how close, at `t`.
func camera(_ t: Double) -> (centre: CGPoint, zoom: CGFloat, blur: CGFloat) {
    // 0 to 2.2: tight on the CPU item, pushing in a little as it ticks.
    var centre = cpuItemCentre
    var zoom = lerp(4.6, 5.0, smooth(t / 2.2))
    // 2.0 to 4.2: down with the panel as it opens, over the gauges to the chart.
    let down = inOut((t - 1.9) / 2.3)
    centre = CGPoint(x: lerp(centre.x, gaugesAt.x, min(1, down * 1.6)), y: lerp(centre.y, chartAt.y, down))
    zoom = lerp(zoom, 2.4, down)
    // 4.0 to 6.4: back into the whole bar and panel.
    let pull = inOut((t - 4.0) / 2.4)
    centre = CGPoint(x: lerp(centre.x, restCentre.x, pull), y: lerp(centre.y, restCentre.y, pull))
    zoom = lerp(zoom, restZoom, pull)
    let blur = lerp(10, 0, smooth(t / 0.7))
    return (centre, zoom, blur)
}

// MARK: - Rendering

let PW = Int(W * pixelScale) & ~1, PH = Int(H * pixelScale) & ~1
let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
ffmpeg.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(PW)x\(PH)", "-r", "\(fps)", "-i", "-",
                    "-vf", "setparams=color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709:range=tv,format=yuv420p",
                    "-c:v", "libx264", "-preset", preview ? "veryfast" : "slow", "-crf", "19", "-profile:v", "high", "-movflags", "+faststart", "-an", outPath]
let pipe = Pipe()
ffmpeg.standardInput = pipe
try ffmpeg.run()
let ci = CIContext(options: [.workingColorSpace: colorSpace])
let frames = Int((duration * Double(fps)).rounded())
var lastImage: CGImage?
for i in 0..<frames {
    let t = Double(i) / Double(fps)
    feed(t)
    let ctx = CGContext(data: nil, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let cam = camera(t)
    // Scene points to pixels: the camera's centre at the frame's centre, at its zoom.
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.translateBy(x: W / 2, y: H / 2)
    ctx.scaleBy(x: cam.zoom, y: cam.zoom)
    ctx.translateBy(x: -cam.centre.x, y: -(H - cam.centre.y))
    drawBackdrop(ctx)
    let open = outCubic((t - openAt) / openFor)
    drawPanel(ctx, at: CGPoint(x: panelOrigin.x, y: panelOrigin.y - 8 * (1 - open)), alpha: open, scale: pixelScale * cam.zoom)
    drawBar(ctx, values: itemValues(t), highlight: open)
    var image = ctx.makeImage()!
    if cam.blur > 0.2 {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(cam.blur * pixelScale / 2)).cropped(to: input.extent)
        image = ci.createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: colorSpace)!
    }
    lastImage = image
    // Raw RGBA, top row first, as ffmpeg reads it.
    let out = CGContext(data: nil, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.draw(image, in: CGRect(x: 0, y: 0, width: PW, height: PH))
    let bytes = Data(bytes: out.data!, count: PW * PH * 4)
    pipe.fileHandleForWriting.write(bytes)
    if i % 30 == 0 { FileHandle.standardError.write("hero: frame \(i) of \(frames)\n".data(using: .utf8)!) }
}
try pipe.fileHandleForWriting.close()
ffmpeg.waitUntilExit()
guard ffmpeg.terminationStatus == 0 else { FileHandle.standardError.write("hero: ffmpeg failed\n".data(using: .utf8)!); exit(1) }
if let posterPath, let lastImage {
    let rep = NSBitmapImageRep(cgImage: lastImage)
    try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: URL(fileURLWithPath: posterPath))
}
print("\(outPath): \(PW)x\(PH), \(frames) frames at \(fps) fps (\(duration) s)")
