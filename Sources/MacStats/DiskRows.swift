// The Disk panel's folder rows: the size column's cell, which shows a folder's size or note
// and, on the row the mouse is over, a Grant button over the note, which gives way to a
// spinner while the granted folder is measured. The panel decides which
// row is hovered and which rows can carry a button; nothing here opens a folder. Also the
// look shared by every folder list, the startup disk's and each external disk's, and the
// line above it with the time of the last measurement.

import Cocoa

/// The size column's cell: the size or note, and a Grant button shown over the note on hover.
final class SizeCell: NSTableCellView {
    let button: NSButton
    /// Whether this row can carry a button (set per row). Only such a row's button has a
    /// tooltip; the others stay hidden.
    var showsGrant = false {
        didSet {
            button.hoverTip = showsGrant
                ? twoLines("Opens this folder once; macOS asks you to allow it. MacStats remembers your answer.") : nil
        }
    }
    /// Whether the folder is being measured after a Grant click: a spinner shows in the
    /// button's place, over the note, and the button stays hidden.
    var measuring = false {
        didSet {
            spinner.isHidden = !measuring
            if measuring { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            setGrantVisible(false, animated: false)
        }
    }
    private let spinner = NSProgressIndicator()
    /// Whether the button is shown or fading in, so a fade out that ends after a new fade in
    /// began leaves the button alone.
    private var grantShown = false
    /// Holds the button 1 pt low before it fades in, so it settles up into place.
    private var settle: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        button = NSButton(title: "Grant", target: target, action: action)
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingMiddle
        text.alignment = .right
        text.font = .systemFont(ofSize: 12)
        // Layers, so the text and the button can fade.
        text.wantsLayer = true
        addSubview(text)
        textField = text

        // A blue pill: the push bezel (once called rounded) in the accent colour, which
        // titles itself in white. The inline bezel drew no pill at this size.
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.bezelColor = .controlAccentColor
        button.wantsLayer = true
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        settle = button.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.heightAnchor.constraint(equalToConstant: 18),
            settle,
        ])
        setGrantVisible(false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fades the button in over the note (150 ms, rising 1 pt) or out (75 ms), on Material's
    /// standard curve, the note fading the other way. With Reduce Motion on, or not
    /// animated, the swap is immediate. A hidden button takes no clicks. While measuring, the
    /// note stays hidden under the spinner.
    func setGrantVisible(_ visible: Bool, animated: Bool) {
        grantShown = visible
        if visible { button.isHidden = false }
        let noteHidden = visible || measuring
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            button.alphaValue = visible ? 1 : 0
            textField?.alphaValue = noteHidden ? 0 : 1
            settle.constant = 0
            button.isHidden = !visible
            return
        }
        if visible {
            settle.constant = 1  // 1 pt below its place: layout runs down the screen
            layoutSubtreeIfNeeded()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? 0.15 : 0.075
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            button.animator().alphaValue = visible ? 1 : 0
            textField?.animator().alphaValue = noteHidden ? 0 : 1
            if visible { settle.animator().constant = 0 }
        }, completionHandler: { [weak self] in
            guard let self, !self.grantShown else { return }
            self.button.isHidden = true
        })
    }
}

/// Sets up `outline` as a folder list like the startup disk's: a name column taking what the
/// fixed 72-pt size column leaves, 22-pt rows indented 10 pt a level, no header and no
/// selection, double-click sent to `target`. Returns the scroll view that holds it.
func folderList(
    _ outline: NSOutlineView, source: NSOutlineViewDataSource & NSOutlineViewDelegate, target: AnyObject, doubleAction: Selector
) -> NSScrollView {
    let name = NSTableColumn(identifier: .init("name"))
    name.width = Panel.width - 90
    name.resizingMask = .autoresizingMask
    let size = NSTableColumn(identifier: .init("size"))
    size.width = 72
    size.resizingMask = []
    outline.addTableColumn(name)
    outline.addTableColumn(size)
    outline.outlineTableColumn = name
    outline.style = .plain
    outline.headerView = nil
    outline.backgroundColor = .clear
    outline.rowSizeStyle = .custom
    outline.rowHeight = Panel.row
    outline.indentationPerLevel = 10
    outline.intercellSpacing = NSSize(width: 4, height: 0)
    outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    outline.selectionHighlightStyle = .none
    outline.dataSource = source
    outline.delegate = source
    outline.target = target
    outline.doubleAction = doubleAction
    let scroll = NSScrollView()
    scroll.documentView = outline
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return scroll
}

/// The 14-pt line above a folder list: `status` ("Last measured at 9:41 PM.") at its left and
/// `remeasuring` ("Remeasuring…", in italics) at its right, both in small faint type.
func statusLine(_ status: NSTextField, _ remeasuring: NSTextField) -> NSView {
    for text in [status, remeasuring] {
        text.font = .systemFont(ofSize: 10)
        text.textColor = .tertiaryLabelColor
    }
    remeasuring.font = NSFontManager.shared.convert(.systemFont(ofSize: 10), toHaveTrait: .italicFontMask)
    remeasuring.alignment = .right
    let line = NSView()
    line.translatesAutoresizingMaskIntoConstraints = false
    for text in [status, remeasuring] {
        text.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(text)
    }
    NSLayoutConstraint.activate([
        // Room for its line, kept while measuring, so the panel does not jump.
        line.widthAnchor.constraint(equalToConstant: Panel.width),
        line.heightAnchor.constraint(equalToConstant: 14),
        status.leadingAnchor.constraint(equalTo: line.leadingAnchor),
        status.centerYAnchor.constraint(equalTo: line.centerYAnchor),
        remeasuring.trailingAnchor.constraint(equalTo: line.trailingAnchor),
        remeasuring.centerYAnchor.constraint(equalTo: line.centerYAnchor),
        remeasuring.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 8),
    ])
    return line
}

/// "Last measured at 9:41 PM.", or nothing before the first measurement.
func lastMeasuredText(_ measuredAt: Date?) -> String {
    guard let measuredAt else { return "" }
    return "Last measured at \(DateFormatter.localizedString(from: measuredAt, dateStyle: .none, timeStyle: .short))."
}
