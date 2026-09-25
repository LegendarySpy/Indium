import AppKit

/// Appears above a text selection with the layout moves that apply to it.
final class SelectionBarView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    enum Action { case left, right, fullWidth, swap, wrap }
    var onAction: ((Action) -> Void)?

    private let stack = NSStackView()
    private var glass: NSView!
    private let content = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        installArrowCursorArea()
        wantsLayer = true
        glass = Glass.make(cornerRadius: 17, content: content, interactive: true)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            // Soft, so the bar can sit at zero size while hidden without conflicts.
            glass.trailingAnchor.constraint(equalTo: trailingAnchor).withPriority(.init(999)),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor).withPriority(.init(999)),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Layout")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    func configure(inColumns: Bool, canWrap: Bool = false) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var items: [(String, String, Action)] = inColumns
            ? [("rectangle", "Full Width", .fullWidth), ("arrow.left.arrow.right", "Swap Sides", .swap)]
            : [("rectangle.lefthalf.inset.filled", "Place Left", .left), ("rectangle.righthalf.inset.filled", "Place Right", .right)]
        if canWrap { items.insert(("text.justify.left", "Wrap Text", .wrap), at: 0) }
        for (symbol, title, action) in items {
            let button = PillButton(symbol: symbol, title: title) { [weak self] in self?.onAction?(action) }
            stack.addArrangedSubview(button)
        }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        setFrameSize(NSSize(width: ceil(size.width), height: ceil(max(size.height, 34))))
    }

    /// Springs in from slightly below and smaller.
    func present(at origin: NSPoint) {
        setFrameOrigin(origin)
        window?.invalidateCursorRects(for: self)
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        alphaValue = 0
        layer?.setAffineTransform(centeredScale(0.96, dy: -4))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 1
            layer?.setAffineTransform(.identity)
        }
    }

    func dismiss() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.isHidden = true
        })
    }
}

/// Icon + label button with a hover wash and a small press-down response.
final class PillButton: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    var action: () -> Void
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = .labelColor
        label.stringValue = title
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        label.isHidden = title.isEmpty
        let row = NSStackView(views: [icon, label])
        row.spacing = 6
        row.edgeInsets = title.isEmpty ? NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
                                       : NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? symbol : title)
        toolTip = title.isEmpty ? nil : title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        press(true)
        guard let window else { return }
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        press(false)
        if inside { action() }
    }

    private func press(_ down: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = down ? 0.08 : 0.18
            ctx.allowsImplicitAnimation = true
            layer?.setAffineTransform(down ? centeredScale(0.95) : .identity)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
