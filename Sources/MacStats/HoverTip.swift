// The panels' tooltips, drawn by MacStats instead of AppKit. When the mouse rests on a
// view with a `hoverTip` for the tooltip delay, a small tooltip window shows its text and
// stays for as long as the mouse stays on that view, clicks included; moving straight on
// to another view with one swaps the text at once, and text that follows the readings
// updates in place. AppKit's own tooltips hide on any click, blink whenever they are
// set again, and are registered over the part of a view visible when set, which missed
// views nested in stack views. These find the view under the mouse when it moves.
//
// The menu bar items keep AppKit's tooltips: a click on one opens its panel anyway.

import Cocoa

private var hoverTipKey: UInt8 = 0

extension NSView {
    /// What the panel's tooltip says while the mouse rests on this view: at most two short
    /// lines (see twoLines). Setting the same text again does nothing; new text shows at
    /// once if this view's tooltip is up.
    var hoverTip: String? {
        get { objc_getAssociatedObject(self, &hoverTipKey) as? String }
        set {
            guard newValue != hoverTip else { return }
            objc_setAssociatedObject(self, &hoverTipKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            HoverTips.shared.textChanged(for: self)
        }
    }

    /// The nearest view, this one or one it sits in, that has a hoverTip.
    var hoverTipOwner: NSView? {
        var view: NSView? = self
        while let current = view, current.hoverTip == nil { view = current.superview }
        return view
    }
}

/// The one tooltip window, shared by the panels (only one is open at a time).
final class HoverTips {
    static let shared = HoverTips()

    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private weak var target: NSView?
    private var timer: Timer?
    /// When a tooltip last went away: moving on to the next view soon after shows its
    /// tooltip at once, as AppKit's do.
    private var hiddenAt = Date.distantPast
    private let margin = NSSize(width: 7, height: 4)

    /// AppKit's tooltip delay, NSInitialToolTipDelay in ms: MacStats registers 750 (half
    /// AppKit's 1.5 s), and a delay the user set wins.
    private var delay: TimeInterval {
        let ms = UserDefaults.standard.double(forKey: "NSInitialToolTipDelay")
        return ms > 0 ? ms / 1000 : 1.5
    }

    private init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 320
        background.addSubview(label)
        window.contentView = background
    }

    /// The mouse is now over `view` (nil when over nothing with a tooltip, or out of the
    /// panel). A new view starts the delay, or shows at once just after another tooltip.
    func track(_ view: NSView?) {
        let owner = view?.hoverTipOwner
        guard owner !== target else { return }
        let wasShowing = window.isVisible
        hide()
        target = owner
        guard owner != nil else { return }
        if wasShowing || Date().timeIntervalSince(hiddenAt) < 0.5 {
            show()
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.show() }
        }
    }

    /// Hides the tooltip and forgets the view, as when the panel closes.
    func reset() {
        hide()
        target = nil
    }

    func textChanged(for view: NSView) {
        guard view === target, window.isVisible else { return }
        if view.hoverTip == nil { hide() } else { show() }
    }

    /// Whether the tooltip is up, and what it says (for the self-check).
    var shown: String? { window.isVisible ? label.stringValue : nil }

    private func show() {
        timer?.invalidate()
        guard let target, let text = target.hoverTip, target.window?.isVisible == true else { return }
        label.stringValue = text
        let size = label.fittingSize
        label.frame = NSRect(x: margin.width, y: margin.height, width: size.width, height: size.height)
        let frameSize = NSSize(width: size.width + margin.width * 2, height: size.height + margin.height * 2)
        // Under the pointer, as AppKit puts them, kept on the screen.
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 2, y: mouse.y - 22 - frameSize.height)
        if let screen = (target.window?.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 2), screen.maxX - frameSize.width - 2)
            if origin.y < screen.minY + 2 { origin.y = mouse.y + 16 }
        }
        window.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        window.orderFrontRegardless()
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        if window.isVisible {
            window.orderOut(nil)
            hiddenAt = Date()
        }
    }
}

/// Follows the mouse over a panel and tells HoverTips what it is over.
final class HoverTracker: NSResponder {
    private weak var panel: NSWindow?

    init(panel: NSWindow) {
        self.panel = panel
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Watches the panel's whole content, whichever app is in front.
    func install(on view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { HoverTips.shared.track(nil) }

    private func follow(_ event: NSEvent) {
        guard let content = panel?.contentView else { return }
        HoverTips.shared.track(content.hitTest(content.convert(event.locationInWindow, from: nil)))
    }
}
