import AppKit

/// Small borderless control: a symbol (or short label) with no chrome until hovered,
/// then a faint rounded background.
final class HoverButton: NSButton {
    private var hovering = false {
        didSet {
            contentTintColor = hovering ? Palette.text : restingTint
            needsDisplay = true
        }
    }
    var restingTint: NSColor = Palette.secondaryText {
        didSet { if !hovering { contentTintColor = restingTint } }
    }
    var isOn = false { didSet { needsDisplay = true } }
    var popUpMenu: NSMenu?

    convenience init(symbol: String, label: String, pointSize: CGFloat = 13, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        commonInit(label: label, target: target, action: action)
        widthAnchor.constraint(equalToConstant: 28).withPriority(.init(999)).isActive = true
        heightAnchor.constraint(equalToConstant: 24).withPriority(.init(999)).isActive = true
    }

    convenience init(text: String, label: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        imagePosition = .noImage
        commonInit(label: label, target: target, action: action)
        heightAnchor.constraint(equalToConstant: 24).withPriority(.init(999)).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 30).withPriority(.init(999)).isActive = true
    }

    private func commonInit(label: String, target: AnyObject?, action: Selector?) {
        isBordered = false
        setButtonType(.momentaryChange)
        bezelStyle = .regularSquare
        focusRingType = .none
        contentTintColor = restingTint
        toolTip = label
        setAccessibilityLabel(label)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
    }

    func setText(_ text: String) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: hovering ? Palette.text : restingTint,
        ])
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Brief press-down scale, like system controls.
    private func pressAnimation(_ down: Bool) {
        wantsLayer = true
        guard let layer else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = down ? 0.07 : 0.22
            ctx.timingFunction = down ? CAMediaTimingFunction(name: .easeOut) : CAMediaTimingFunction(controlPoints: 0.2, 1.4, 0.4, 1)
            ctx.allowsImplicitAnimation = true
            layer.setAffineTransform(down ? centeredScale(0.9) : .identity)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressAnimation(true)
        defer { pressAnimation(false) }
        if let popUpMenu {
            hovering = true
            popUpMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 6), in: self)
            hovering = false
            return
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted || isOn {
            (isHighlighted ? Palette.separator : Palette.hoverFill).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A flat surface with a hairline border and soft shadow, for transient panels.
class PopoverSurface: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    var cornerRadius: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 18
            s.shadowOffset = NSSize(width: 0, height: -6)
            s.shadowColor = Palette.shadow
            return s
        }()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        Palette.surface.setFill()
        path.fill()
        Palette.separator.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shadow?.shadowColor = Palette.shadow
        needsDisplay = true
    }
}

extension NSView {
    /// Overlays sitting on top of the page claim the arrow cursor so the text view's
    /// I-beam underneath doesn't leak through.
    func installArrowCursorArea() {
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["indium.arrow": true]))
    }
}

extension NSView {
    /// Scale about the view's center without touching the layer's anchor point,
    /// which AppKit owns for layer-backed views.
    func centeredScale(_ s: CGFloat, dy: CGFloat = 0) -> CGAffineTransform {
        let w = bounds.width / 2, h = bounds.height / 2
        return CGAffineTransform(translationX: w, y: h + dy).scaledBy(x: s, y: s).translatedBy(x: -w, y: -h)
    }
}
