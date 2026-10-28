// The Disk panel's folder rows: the size column's cell, which shows a folder's size or note
// and, on the row the mouse is over, a Grant button over the note, which gives way to a
// spinner while the granted folder is measured. The panel decides which
// row is hovered and which rows can carry a button; nothing here opens a folder.

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
