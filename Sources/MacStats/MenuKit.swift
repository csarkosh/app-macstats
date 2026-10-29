// The pieces every MacStats menu bar item shares: the item itself, drawn like the
// Stats app's "mini" widget (a 7pt label over a 12pt value), and a drop-down panel
// styled like Stats' popups (a header, captions between two lines, label and value
// rows). Disk.swift and Temp.swift build their items from these.

import Cocoa

// MARK: - The menu bar item

/// A small label over a value, at the positions of Stats' Mini widget.
final class MiniView: NSView {
    var label = ""
    var value = ""
    /// The widest value the item can show ("100%"): the item keeps that width whatever
    /// it shows, so items beside it do not shift as values change.
    var widest: String?
    /// Tints the value a soft red, for a reading in the red.
    var alert = false
    /// A fixed-width item draws digits of one width, so "11%" is as wide as "88%"; the
    /// others keep the narrower proportional digits, which save menu bar room.
    var valueFont: NSFont {
        widest == nil ? .systemFont(ofSize: 12, weight: .regular) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let left = NSMutableParagraphStyle()
        left.alignment = .left

        // Positions copied from Stats' Mini widget: label at y 12, value at y 1.
        NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .light),
            .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor,
            .paragraphStyle: left,
        ]).draw(with: CGRect(x: 0, y: 12, width: bounds.width, height: 7))

        let plain: NSColor = isDarkMode ? .white : .black
        // Soft red: red mixed with the plain text colour, so it reads as a hint, not an alarm.
        let tint = NSColor.systemRed.blended(withFraction: isDarkMode ? 0.35 : 0.15, of: plain) ?? .systemRed
        NSAttributedString(string: value, attributes: [
            .font: valueFont,
            .foregroundColor: alert ? tint : plain,
            .paragraphStyle: left,
        ]).draw(with: CGRect(x: 0, y: 1, width: bounds.width, height: 13))
    }

    // Clicks go to the status item's button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func contentWidth() -> CGFloat {
        let valueWidth = { (text: String) in NSAttributedString(string: text, attributes: [.font: self.valueFont]).size().width }
        return ceil(max(
            valueWidth(value),
            widest.map(valueWidth) ?? 0,
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 7, weight: .light)]).size().width))
    }
}

/// One status item: a MiniView in the menu bar, a click that opens its panel, and
/// a right-click menu with Quit.
final class MenuBarItem: NSObject {
    private let item: NSStatusItem
    private let view = MiniView()
    private let menu = NSMenu()
    private let onClick: (NSStatusBarButton) -> Void

    /// `autosaveName` is what macOS stores the item's place under, as
    /// "NSStatusItem Preferred Position <name>" in the app's defaults. `widest` is the
    /// widest value it can show, which fixes its width (see MiniView).
    init(autosaveName: String, label: String, widest: String? = nil, onClick: @escaping (NSStatusBarButton) -> Void) {
        self.onClick = onClick
        item = NSStatusBar.system.statusItem(withLength: 40)
        super.init()
        item.autosaveName = autosaveName
        view.label = label
        view.widest = widest
        let menuBarHeight = NSApplication.shared.mainMenu?.menuBarHeight ?? 0
        let height = (menuBarHeight == 0 ? 22 : menuBarHeight) - 4
        view.frame = CGRect(x: 0, y: 2, width: 40, height: height)
        item.button?.addSubview(view)
        item.button?.image = NSImage()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.addItem(NSMenuItem(title: "Quit MacStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    var button: NSStatusBarButton? { item.button }

    func show(_ value: String, tooltip: String, alert: Bool = false) {
        // AppKit's tooltip, set only when its text changes and not while the pointer is on
        // the item: setting one again hides and shows it, so one set every second blinks.
        if let button = item.button, button.toolTip != twoLines(tooltip), !button.isUnderMouse {
            button.toolTip = twoLines(tooltip)
        }
        guard value != view.value || alert != view.alert else { return }
        view.value = value
        view.alert = alert
        let width = view.contentWidth()
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        item.length = width
        view.needsDisplay = true
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            onClick(button)
        }
    }
}

/// Draws a menu bar item, at 4x, on a dark menu bar, so its look can be checked
/// without Screen Recording permission.
func renderMiniView(label: String, value: String, widest: String? = nil, alert: Bool = false, to path: String) -> Int32 {
    let view = MiniView()
    view.label = label
    view.value = value
    view.widest = widest
    view.alert = alert
    view.appearance = NSAppearance(named: .darkAqua)
    let width = view.contentWidth()
    let size = NSSize(width: width + 20, height: 22)
    let scale: CGFloat = 4
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.12, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    view.frame = CGRect(x: 10, y: 2, width: width, height: 18)
    NSGraphicsContext.current!.cgContext.translateBy(x: 10, y: 2)
    view.appearance!.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
    NSGraphicsContext.restoreGraphicsState()
    do {
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write("Could not write \(path): \(error.localizedDescription)\n".data(using: .utf8)!)
        return 1
    }
    print(value)
    return 0
}

/// Runs a command-line tool and returns what it printed.
func runTool(_ path: String, _ arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}

// MARK: - The panel, styled like Stats' popups

/// Stats' popup sizes: 264 wide inside 8 of margin, a 42-high header, 22-high rows.
enum Panel {
    static let width: CGFloat = 264
    static let margin: CGFloat = 8
    static let header: CGFloat = 42
    static let row: CGFloat = 22
}

/// A section caption like Stats': small spaced capitals between two lines.
func separatorView(_ title: String) -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.tertiaryLabelColor,
        .kern: 1.0,
    ])
    let left = NSBox(), right = NSBox()
    for line in [left, right] {
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)
    }
    view.addSubview(label)
    NSLayoutConstraint.activate([
        view.heightAnchor.constraint(equalToConstant: 30),
        view.widthAnchor.constraint(equalToConstant: Panel.width),
        label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        left.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
        left.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        right.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
        right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        right.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    return view
}

/// A label on the left in secondary text and a value on the right, like Stats' rows;
/// with a colour, a 10-point rounded square before the label, as in its RAM panel.
final class PanelRow: NSView {
    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "")
    private let block = NSView()
    /// A row with a coloured square is a legend key: it names a colour in a chart or bar
    /// (or, in Temp, a heat), and its tooltip says what that is.
    let isKey: Bool

    init(_ title: String, color: NSColor? = nil) {
        isKey = color != nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        value.font = .systemFont(ofSize: 13)
        value.alignment = .right
        for field in [label, value] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        if let color {
            block.wantsLayer = true
            block.layer?.backgroundColor = color.cgColor
            block.layer?.cornerRadius = 3
            block.translatesAutoresizingMaskIntoConstraints = false
            addSubview(block)
            NSLayoutConstraint.activate([
                block.widthAnchor.constraint(equalToConstant: 10),
                block.heightAnchor.constraint(equalToConstant: 10),
                block.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
                block.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Panel.row),
            widthAnchor.constraint(equalToConstant: Panel.width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: color == nil ? 0 : 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Changes the square's colour, for a row made with one.
    func setColor(_ color: NSColor) {
        block.layer?.backgroundColor = color.cgColor
    }
}

/// One line of a small chart's legend, as wide as the chart above it: a coloured dot, a
/// name and a value, in small type.
final class LegendLine: NSView {
    let title: String
    let value = NSTextField(labelWithString: "")

    init(_ title: String, color: NSColor, width: CGFloat) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 2
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9)
        label.textColor = .secondaryLabelColor
        value.font = .systemFont(ofSize: 9)
        value.alignment = .right
        for view in [dot, label, value] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 13),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Tooltips stay at most two lines. macOS wraps a tooltip only past a width wider than
/// this, so text longer than one line here breaks at the space that best balances two
/// lines, and neither runs past it; text with its own line break is left as it is.
let tooltipLineWidth: CGFloat = 240

func tooltipWidth(_ line: String) -> CGFloat {
    NSAttributedString(string: line, attributes: [.font: NSFont.toolTipsFont(ofSize: 0)]).size().width
}

extension NSView {
    /// Whether the mouse is over the view now.
    var isUnderMouse: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

}

func twoLines(_ text: String) -> String {
    guard !text.contains("\n"), tooltipWidth(text) > tooltipLineWidth else { return text }
    let longer = { (space: String.Index) -> CGFloat in
        max(tooltipWidth(String(text[..<space])), tooltipWidth(String(text[text.index(after: space)...])))
    }
    guard let best = text.indices.filter({ text[$0] == " " }).min(by: { longer($0) < longer($1) }) else { return text }
    return String(text[..<best]) + "\n" + String(text[text.index(after: best)...])
}

/// A line bar split into coloured parts, drawn like Stats' horizontal bar chart: 10
/// points high with corners rounded at 3, the rest of the line in faint grey.
final class SpaceBar: NSView {
    var parts: [(fraction: Double, color: NSColor)] = [] { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 14),
            widthAnchor.constraint(equalToConstant: Panel.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: (bounds.height - 10) / 2, width: bounds.width, height: 10)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).addClip()
        NSColor.lightGray.withAlphaComponent(0.25).setFill()
        bar.fill()
        var x = bar.minX
        for part in parts {
            let width = bar.width * CGFloat(max(0, part.fraction))
            part.color.setFill()
            NSRect(x: x, y: bar.minY, width: width, height: bar.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A row's history as a small filled area before its value (50 by 12 points, newest at
/// the right, a sample a second), each sample a fraction of what a full bar stands for.
final class Sparkline: NSView {
    var fractions: [Double] = [] { didSet { needsDisplay = true } }
    var capacity = 180
    let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Puts the sparkline in `row`, just before its value; with `valueColumn`, that far
    /// from the row's right edge whatever the value's width, so a column of rows' graphs
    /// line up.
    func place(in row: PanelRow, valueColumn: CGFloat? = nil) {
        row.addSubview(self)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 50),
            heightAnchor.constraint(equalToConstant: 12),
            centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueColumn.map { trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -$0 - 8) }
                ?? trailingAnchor.constraint(equalTo: row.value.leadingAnchor, constant: -8),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor.lightGray.withAlphaComponent(0.15).setFill()
        frame.fill()
        guard fractions.count > 1 else { return }
        let step = bounds.width / CGFloat(capacity - 1)
        let x = { (index: Int) in self.bounds.maxX - CGFloat(self.fractions.count - 1 - index) * step }
        let area = NSBezierPath()
        area.move(to: CGPoint(x: x(0), y: bounds.minY))
        for (index, fraction) in fractions.enumerated() {
            area.line(to: CGPoint(x: x(index), y: bounds.minY + CGFloat(min(1, max(0, fraction))) * bounds.height))
        }
        area.line(to: CGPoint(x: x(fractions.count - 1), y: bounds.minY))
        area.close()
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        color.setFill()
        area.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A gauge like Stats' RAM pressure gauge: a half circle in three equal green, yellow
/// and red arcs and a blue needle, with a title and a second line under it. Unlike
/// Stats', whose needle points at the middle of a band, the needle moves along it:
/// `fraction` 0 is the start of green, 1/3 the start of yellow, 2/3 of red, 1 the end.
final class GaugeView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    /// What the gauge measures, above the arc.
    var heading = "" { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingTail
        let labels: CGFloat = 26
        let headingHeight: CGFloat = heading.isEmpty ? 0 : 16
        let arcWidth: CGFloat = 6
        let center = CGPoint(x: bounds.midX, y: labels + 4)
        let radius = min(bounds.width / 2 - 10, bounds.height - headingHeight - labels - 8) - arcWidth / 2

        NSAttributedString(string: heading, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]).draw(with: CGRect(x: 0, y: bounds.height - 13, width: bounds.width, height: 13))

        // Three equal arcs from the left (π) to the right (0), with small gaps, as in Stats.
        let gap = 0.025 * CGFloat.pi
        let span = (CGFloat.pi - 2 * gap) / 3
        let colors: [NSColor] = [.systemGreen, .systemYellow, .systemRed]
        context.setLineWidth(arcWidth)
        context.setLineCap(.round)
        for (index, color) in colors.enumerated() {
            let start = CGFloat.pi - CGFloat(index) * (span + gap)
            context.setStrokeColor(color.cgColor)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: start - span, clockwise: true)
            context.strokePath()
        }

        // The needle: a thin blue triangle from the centre, as in Stats.
        let clamped = min(max(fraction, 0), 1)
        let band = min(Int(clamped * 3), 2)
        let within = CGFloat(clamped * 3 - Double(band))
        let angle = CGFloat.pi - CGFloat(band) * (span + gap) - within * span
        let length = radius - arcWidth / 2 - 1
        let tip = CGPoint(x: center.x + length * cos(angle), y: center.y + length * sin(angle))
        let side = CGPoint(x: 2 * cos(angle + .pi / 2), y: 2 * sin(angle + .pi / 2))
        let needle = NSBezierPath()
        needle.move(to: tip)
        needle.line(to: CGPoint(x: center.x + side.x, y: center.y + side.y))
        needle.line(to: CGPoint(x: center.x - side.x, y: center.y - side.y))
        needle.close()
        NSColor.systemBlue.setFill()
        needle.fill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()

        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]).draw(with: CGRect(x: 0, y: 13, width: bounds.width, height: 13))
        NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]).draw(with: CGRect(x: 0, y: 1, width: bounds.width, height: 12))
    }
}

/// Where a value sits on a gauge whose three bands run from `low` to `warm` (green),
/// `warm` to `hot` (yellow) and `hot` to `high` (red): each band is a third of the arc.
func gaugeFraction(_ value: Double, low: Double, warm: Double, hot: Double, high: Double) -> Double {
    if value < warm { return max(0, (value - low) / (warm - low)) / 3 }
    if value < hot { return (1 + (value - warm) / (hot - warm)) / 3 }
    return min(1, (2 + (value - hot) / (high - hot)) / 3)
}

/// A drop-down panel like Stats' popups: a translucent window under its menu bar
/// item, a header with a title and up to two buttons, and `body` for the content.
/// It closes when it stops being the key window, as Stats' do.
class StatsPanel: NSWindow, NSWindowDelegate {
    let body = NSStackView()
    /// Shows the panel's tooltips (see HoverTip.swift).
    private lazy var hoverTracker = HoverTracker(panel: self)
    private let header = NSStackView()
    private let titleField = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Panel.width + Panel.margin * 2, height: 400),
                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // Menu level: above every ordinary window, whichever app is in front, as menus are.
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = true
        delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        contentView = background
        hoverTracker.install(on: background)

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 16)
        titleField.alignment = .center
        header.setViews([placeholder(), titleField, placeholder()], in: .leading)
        header.distribution = .equalCentering
        header.translatesAutoresizingMaskIntoConstraints = false
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(header)
        background.addSubview(body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Panel.header),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Panel.margin),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Panel.margin),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Panel.margin),
            body.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Panel.margin),
            body.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Panel.margin),
        ])
    }

    /// Puts buttons either side of the title, as Stats' headers have.
    func setHeaderButtons(leading: NSButton?, trailing: NSButton?) {
        header.setViews([leading ?? placeholder(), titleField, trailing ?? placeholder()], in: .leading)
    }

    func headerButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.hoverTip = tip
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func placeholder() -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }

    /// The MacStats panel that is open, if any: opening one closes the other.
    private static weak var openPanel: StatsPanel?
    /// Watches clicks in other apps while the panel is open, to close it on one. Mouse
    /// clicks need no permission to watch (only keystrokes would).
    private var outsideClicks: Any?
    /// The screen the panel is about to open on, known before it moves there.
    private(set) var openingScreen: NSScreen?
    private var dismissedAt = Date.distantPast

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    /// Closes the panel, as a click outside it or on its item does.
    func dismiss() {
        guard isVisible else { return }
        HoverTips.shared.reset()
        orderOut(nil)
        dismissedAt = Date()
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        if StatsPanel.openPanel === self { StatsPanel.openPanel = nil }
    }

    /// Called before the panel opens; a subclass refreshes what it shows.
    func willOpen() {}

    /// Opens under `button`, centred on it, kept on its screen: where Stats opens its panels.
    func toggle(under button: NSStatusBarButton) {
        // A click on the item first takes focus from the open panel, which closes it;
        // that same click must not open it again.
        if isVisible || Date().timeIntervalSince(dismissedAt) < 0.3 {
            dismiss()
            return
        }
        StatsPanel.openPanel?.dismiss()
        let screen = button.window?.screen ?? NSScreen.main
        // The fit happens before the move, so it must know which screen the panel will be on.
        openingScreen = screen
        willOpen()
        fitToContents()
        if let anchor = button.window?.frame {
            var x = anchor.midX - frame.width / 2
            if let screen {
                x = min(max(x, screen.frame.minX + 3), screen.frame.maxX - frame.width - 3)
            }
            setFrameOrigin(NSPoint(x: x, y: anchor.minY - frame.height - 3))
        }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        makeKeyAndOrderFront(nil)
        // If macOS declines to bring MacStats forward (another app has focus), show the
        // panel on top anyway.
        orderFrontRegardless()
        StatsPanel.openPanel = self
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in self?.dismiss()
        }
    }

    /// The tallest the panel may be: its screen's usable height (below the menu bar, above the
    /// Dock) less a margin. Before the panel has a screen it is the main screen's.
    func maximumHeight() -> CGFloat {
        guard let screen = openingScreen ?? screen ?? NSScreen.main else { return 800 }
        return screen.visibleFrame.height - 6
    }

    /// The height the contents want as they are laid out now.
    func heightNeeded() -> CGFloat {
        guard let content = contentView else { return 0 }
        content.layoutSubtreeIfNeeded()
        return content.fittingSize.height
    }

    /// Fits the panel to its contents, keeping its top edge where it is.
    func fitToContents() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

}

// MARK: - What a process is doing

// The Top processes rows of the CPU, RAM and GPU panels. A name like "node" says nothing
// about which work is running. The kernel tells any program, without a permission, a
// process's command line and environment (KERN_PROCARGS2), the folder it works in
// (proc_pidinfo) and its parent (KERN_PROC_PID), for processes of the same user; another
// user's (root's services) keep them private.

/// The process's arguments, `argv`, and its environment, or none when they cannot be read.
/// A process that renamed itself (npm's "npm run test") shows its title as the first
/// argument.
func processLaunch(_ pid: Int32) -> (arguments: [String], environment: [String: String]) {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], [:]) }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return ([], [:]) }
    // The count, the executable's path, padding, then that many arguments, then the
    // environment's NAME=value strings, each ending in NUL; an empty string ends them.
    let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    let next = { () -> String in
        let end = buffer[index..<size].firstIndex(of: 0) ?? size
        defer { index = end + 1 }
        return String(decoding: buffer[index..<end], as: UTF8.self)
    }
    var arguments: [String] = []
    while arguments.count < count, index < size { arguments.append(next()) }
    var environment: [String: String] = [:]
    while index < size {
        let entry = next()
        guard !entry.isEmpty, let equals = entry.firstIndex(of: "=") else { break }
        environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
    }
    return (arguments, environment)
}

/// The process's arguments alone (see processLaunch).
func processArguments(_ pid: Int32) -> [String] { processLaunch(pid).arguments }

/// The folder the process works in, or nil when it cannot be read.
func processFolder(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return path.isEmpty ? nil : path
}

/// The process's parent and its short name from the kernel's table, or nil when it is gone.
func processParent(_ pid: Int32) -> (parent: Int32, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
    return (info.kp_eproc.e_ppid, name)
}

/// A process's name from its first argument: the title it gave itself ("npm run test"),
/// the app whose bundle holds its executable ("Arkos IDE" for arkosd), or the
/// executable's name.
func commandName(_ first: String) -> String {
    if !first.contains("/") { return first }
    let parts = first.split(separator: "/").map(String.init)
    if let app = parts.last(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
    return (first as NSString).lastPathComponent
}

/// A process's name as the panel shows it: the app's, the title it gave itself, its
/// executable's name, or the kernel's short name.
func processName(_ pid: Int32) -> String? {
    if let app = NSRunningApplication(processIdentifier: pid)?.localizedName { return app }
    if let first = processArguments(pid).first, !first.isEmpty { return commandName(first) }
    return processParent(pid)?.name
}

private let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "tcsh", "csh", "ksh", "login"]

/// What a process runs, from its arguments: the package under `node_modules` it runs
/// ("vitest"), else the first argument that is not an option: a script's name, a
/// subcommand ("build") or a shell's command. Nil when the arguments say nothing.
func processWork(_ arguments: [String], name: String) -> String? {
    guard let first = arguments.first else { return nil }
    if first.contains(" "), !first.contains("/") { return first == name ? nil : first }  // a title the process set
    let rest = arguments.dropFirst().filter { !$0.isEmpty }
    for argument in rest {
        let parts = argument.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let modules = parts.lastIndex(of: "node_modules"), modules + 1 < parts.count else { continue }
        var package = parts[modules + 1]
        if package == ".bin", modules + 2 < parts.count { package = parts[modules + 2] }
        if package.hasPrefix("@"), modules + 2 < parts.count { package += "/" + parts[modules + 2] }
        return package
    }
    for argument in rest where !argument.hasPrefix("-") {
        if argument.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil { continue }  // VAR=value
        // A path's last part; a shell's command ("sleep 30; true") whole.
        let base = argument.contains("/") && !argument.contains(" ") ? (argument as NSString).lastPathComponent : argument
        if base.isEmpty || base == name { continue }
        return base.count > 60 ? String(base.prefix(59)) + "…" : base
    }
    return nil
}

/// The folder's name, or nil for the root or the home folder (every shell starts there).
func processFolderName(_ folder: String?) -> String? {
    guard let folder, folder != "/", folder != NSHomeDirectory() else { return nil }
    let name = (folder as NSString).lastPathComponent
    return name.isEmpty ? nil : name
}

/// What started a process: its ancestors' names, without the shells between them and
/// without its own name again, up to the app they run in ("npm run test", "npm run gate",
/// "claude", "Arkos IDE") or launchd. (A command-line tool can register as a running
/// application too, npm does; an app is one with a bundle.)
func processAncestors(_ pid: Int32, name: String) -> [String] {
    var names: [String] = []
    var current = pid
    for _ in 0..<16 {
        guard let (parent, _) = processParent(current), parent > 1 else { break }
        current = parent
        let app = NSRunningApplication(processIdentifier: parent)
        guard let parentName = app?.localizedName ?? processName(parent) else { break }
        if !shellNames.contains(parentName), parentName != name, parentName != names.last { names.append(parentName) }
        if app?.bundleIdentifier != nil { break }
    }
    return names
}

// MARK: Claude Code sessions

/// A Claude Code session: its title and whether it is working. Every session runs as
/// "claude" in a folder, often the same one, so its title is what tells them apart.
struct ClaudeSession {
    let title: String?
    let busy: Bool
}

/// The Claude Code session a process runs, or nil for any other process. Claude Code
/// keeps a record of each running session in its settings folder (`~/.claude`, or the
/// process's CLAUDE_CONFIG_DIR), `sessions/<pid>.json`, naming the session; the session's
/// transcript, `projects/<folder>/<session>.jsonl`, holds the title Claude Code gives it,
/// updated as the work goes on. A name set by hand wins over the given title.
func claudeSession(_ pid: Int32, environment: [String: String]) -> ClaudeSession? {
    let home = NSHomeDirectory()
    let settings = environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).standardizingPath } ?? home + "/.claude"
    // Only a hidden folder in the home folder (or the temporary folder, for the tests):
    // a settings folder in Documents or Desktop would make macOS ask for access.
    let temporary = (NSTemporaryDirectory() as NSString).standardizingPath
    guard settings.hasPrefix(home + "/.") || settings.hasPrefix(temporary + "/") else { return nil }
    guard let data = FileManager.default.contents(atPath: settings + "/sessions/\(pid).json"),
          let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (record["pid"] as? NSNumber)?.int32Value == pid, let session = record["sessionId"] as? String
    else { return nil }
    var title = ClaudeTitles.shared.title(session: session, settings: settings, folder: record["cwd"] as? String)
    if let name = record["name"] as? String, !name.isEmpty, let source = record["nameSource"] as? String, source != "derived" {
        title = name
    }
    return ClaudeSession(title: title, busy: record["status"] as? String == "busy")
}

/// Each session's latest title, read from its transcript. The transcript only grows (to
/// megabytes), so it is read once and then only from where the last read stopped.
final class ClaudeTitles {
    static let shared = ClaudeTitles()
    private struct Transcript { var path: String; var offset: UInt64 = 0; var given: String?; var custom: String? }
    private var transcripts: [String: Transcript] = [:]
    /// When a session's transcript was last looked for and not found (it is written at
    /// the first message): not looked for again for half a minute.
    private var missing: [String: Date] = [:]
    private let lock = NSLock()

    func title(session: String, settings: String, folder: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard var transcript = transcripts[session] ?? find(session, settings: settings, folder: folder) else { return nil }
        if let handle = FileHandle(forReadingAtPath: transcript.path) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: transcript.offset)
            if let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) {
                // Only whole lines; a line being written is read next time.
                transcript.offset += UInt64(end - data.startIndex + 1)
                for line in data[data.startIndex...end].split(separator: UInt8(ascii: "\n")) {
                    guard line.count < 4096, line.range(of: Data("-title\"".utf8)) != nil,
                          let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    if entry["type"] as? String == "ai-title", let title = entry["aiTitle"] as? String { transcript.given = title }
                    if entry["type"] as? String == "custom-title", let title = entry["customTitle"] as? String { transcript.custom = title }
                }
            }
        }
        transcripts[session] = transcript
        return (transcript.custom ?? transcript.given).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The transcript sits in a folder named after the session's folder, every character
    /// but letters and digits a dash; a session that moved keeps it under its first folder,
    /// so the other folders are looked in too.
    private func find(_ session: String, settings: String, folder: String?) -> Transcript? {
        if let since = missing[session], Date().timeIntervalSince(since) < 30 { return nil }
        let projects = settings + "/projects"
        let file = session + ".jsonl"
        var candidates: [String] = []
        if let folder {
            candidates.append(String(folder.map { $0.isLetter || $0.isNumber ? $0 : "-" }))
        }
        candidates += (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        for name in candidates where FileManager.default.fileExists(atPath: "\(projects)/\(name)/\(file)") {
            missing[session] = nil
            return Transcript(path: "\(projects)/\(name)/\(file)")
        }
        missing[session] = Date()
        return nil
    }
}

private func shortenHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") || path == home ? "~" + path.dropFirst(home.count) : path
}

/// Cuts a line to just under the width at which the tooltip wraps, ending it in an ellipsis.
private func fitTooltipLine(_ text: String) -> String {
    let limit = tooltipWrapWidth - 4
    guard tooltipWidth(text) > limit else { return text }
    var line = String(text.prefix(200))
    while !line.isEmpty, tooltipWidth(line + "…") > limit { line.removeLast() }
    return line.trimmingCharacters(in: .whitespaces) + "…"
}

/// The panel's detail and tooltip for a process: "vitest · game-dayhike" beside its name,
/// and a tooltip of its command line (paths relative to its folder, the home folder as
/// ~), then "Started by npm run test, under claude and Arkos IDE, in ~/Projects/game-dayhike".
/// A Claude Code session shows its title instead ("Film handoff review · Projects"), and
/// whether it is working in place of its command line. An app, named well already and
/// rarely started in a folder that means anything, shows no folder beside its name.
func describeProcess(_ pid: Int32, name: String) -> (detail: String, tooltip: String) {
    let folder = processFolder(pid)
    let launch = processLaunch(pid)
    let isClaude = name == "claude" || launch.arguments.first.map(commandName) == "claude"
    let claude = isClaude ? claudeSession(pid, environment: launch.environment) : nil
    let isApp = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier != nil
    // Paths in the arguments relative to the folder, or with the home folder as ~; the
    // empty arguments a process that renamed itself leaves behind dropped.
    let shorten = { (argument: String) -> String in
        if let folder, folder != "/", argument.hasPrefix(folder + "/") { return String(argument.dropFirst(folder.count + 1)) }
        return shortenHome(argument)
    }
    var arguments = launch.arguments
    if !arguments.isEmpty { arguments = [arguments[0]] + arguments.dropFirst().filter { !$0.isEmpty }.map(shorten) }
    let work = claude?.title ?? processWork(arguments, name: name)
    let detail = [work, isApp ? nil : processFolderName(folder)].compactMap { $0 }.joined(separator: " · ")
    var command = arguments.first.map { ([commandName($0)] + arguments.dropFirst()).joined(separator: " ") }
        ?? "Runs as another user, so its command line is private."
    if let claude {
        command = "Claude Code, " + (claude.busy ? "working" : "idle") + (claude.title.map { ": " + $0 } ?? "")
    }
    // The nearest ancestor, then at most the two outermost: the app and what it ran.
    var ancestors = processAncestors(pid, name: name)
    if ancestors.count > 3 { ancestors = [ancestors[0]] + ancestors.suffix(2) }
    var started: String
    switch ancestors.count {
    case 0: started = "Started by macOS (launchd)"
    case 1: started = "Started by " + ancestors[0]
    case 2: started = "Started by \(ancestors[0]), under \(ancestors[1])"
    default: started = "Started by \(ancestors[0]), under \(ancestors[1]) and \(ancestors[2])"
    }
    // The folder, whole if the line has room for it, else by its name alone.
    if let folder, let name = processFolderName(folder) {
        let line = ["\(started), in \(shortenHome(folder))", "\(started), in \(name)"].first { tooltipWidth($0) <= tooltipWrapWidth - 4 }
        started = line ?? started
    }
    return (detail, fitTooltipLine(command) + "\n" + fitTooltipLine(started))
}

/// Prints what a Top processes row would say of one process: its name, the detail beside it and its
/// tooltip's lines. Exit 1 when there is no such process.
func processReport(_ pid: Int32) -> Int32 {
    guard let name = processName(pid) else { return 1 }
    let (detail, tooltip) = describeProcess(pid, name: name)
    print("Name\t" + name)
    print("Detail\t" + detail)
    for line in tooltip.split(separator: "\n") { print("Tooltip\t" + line) }
    return 0
}
