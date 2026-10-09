import AppKit

/// A thin bar along a table's right edge (adds a column) or bottom edge (adds a row),
/// as in Notion. Faint while the table is hovered or open; under the pointer it
/// darkens and shows a +. The whole strip is the target, not just the +.
final class TableEdgeStrip: NSView {
    enum Adds { case column, row }

    /// How thick the strip is, and its gap from the grid.
    static let thickness: CGFloat = 16
    static let gap: CGFloat = 4
    /// How far an outside strip reaches past the grid.
    static let outset: CGFloat = gap + thickness

    /// Where the strips go for a grid at `table`: just outside its right and bottom
    /// edges when there's room there, else along its inner edges, thinner.
    static func frames(table: NSRect, room: (right: Bool, below: Bool)) -> (column: NSRect, row: NSRect) {
        let inner: CGFloat = 10
        let column = room.right ? NSRect(x: table.maxX + gap, y: table.minY, width: thickness, height: table.height)
                                : NSRect(x: table.maxX - inner, y: table.minY, width: inner, height: table.height)
        let row = room.below ? NSRect(x: table.minX, y: table.maxY + gap, width: table.width, height: thickness)
                             : NSRect(x: table.minX, y: table.maxY - inner, width: table.width, height: inner)
        return (column, row)
    }

    let adds: Adds
    var onClick: (() -> Void)?
    /// Lying over the grid's edge cells: shown only under the pointer.
    var inside = false { didSet { if inside != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    init(adds: Adds) {
        self.adds = adds
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(adds == .column ? "Add Column" : "Add Row")
        toolTip = adds == .column ? "Add Column" : "Add Row"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        hovering = false
        onClick?()
    }

    // With keyboard navigation on, the strip is a stop in the key view loop: Space or
    // Return adds, and it shows the focus ring and its + while focused.
    private var focused = false { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled && !isHiddenOrHasHiddenAncestor }
    override func becomeFirstResponder() -> Bool { focused = true; return true }
    override func resignFirstResponder() -> Bool { focused = false; return true }
    override var focusRingMaskBounds: NSRect { bar }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill() }

    override func keyDown(with event: NSEvent) {
        if [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") { onClick?() } else { super.keyDown(with: event) }
    }

    private var bar: NSRect {
        adds == .column ? bounds.insetBy(dx: inside ? 1.5 : 3, dy: 1) : bounds.insetBy(dx: 1, dy: inside ? 1.5 : 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lit = hovering || focused
        guard lit || !inside else { return }
        (lit ? NSColor.quaternaryLabelColor : Palette.fill).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
        guard lit, let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: inside ? 8 : 10, weight: .semibold)) else { return }
        let tinted = NSImage(size: plus.size, flipped: false) { rect in
            plus.draw(in: rect)
            Palette.secondaryText.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: bar.midX - plus.size.width / 2, y: bar.midY - plus.size.height / 2,
                               width: plus.size.width, height: plus.size.height))
    }
}

/// The glass bar shown above a table while editing it.
final class TableToolbarView: NSView {
    var onAddRow: (() -> Void)?
    var onAddColumn: (() -> Void)?
    var onAlign: ((Int) -> Void)?
    var onDeleteRow: (() -> Void)?
    var onDeleteColumn: (() -> Void)?
    var onDeleteTable: (() -> Void)?
    var onCopyTable: (() -> Void)?
    /// Starts a formula in the focused cell.
    var onFormula: (() -> Void)?
    /// Fill Right (false) or Fill Down (true) from the focused cell.
    var onFill: ((Bool) -> Void)?
    /// Whether the focused cell has a formula to fill.
    var canFill: (() -> Bool)?
    var onDone: (() -> Void)?
    /// nil: full width; true/false: text wraps beside it on the right/left.
    var onPlace: ((Bool?) -> Void)?
    var placement: Bool?
    /// How much of the bar shows. Narrower columns get less: `compact` folds alignment
    /// into one menu and drops Done's label; `minimal` is just a menu of everything and
    /// Done (the edge strips still add rows and columns).
    enum Size: CaseIterable { case full, compact, minimal }
    var size: Size = .full { didSet { if size != oldValue { build() } } }
    /// The bar's width at each size, largest first, to pick the one that fits.
    private(set) var widths: [Size: CGFloat] = [:]

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        installArrowCursorArea()
        wantsLayer = true
        let content = NSView()
        let glass = Glass.make(cornerRadius: 17, content: content, interactive: true)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // Observers don't run in init, so each size is built here by hand.
        for s in Size.allCases.reversed() {
            size = s
            build()
            widths[s] = self.frame.width
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The largest size no wider than `width` (the smallest if none is).
    func fit(width: CGFloat) {
        size = Size.allCases.first { (widths[$0] ?? 0) <= width } ?? .minimal
    }

    private func build() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let aligns = [("text.alignleft", "Align Left"), ("text.aligncenter", "Align Center"), ("text.alignright", "Align Right")]
        let places: [(String, Bool?)] = [("Full Width", nil), ("Right, Text Wraps Beside", true), ("Left, Text Wraps Beside", false)]
        func menuButton(_ symbol: String, _ title: String, _ fill: @escaping (NSMenu) -> Void) -> PillButton {
            let button = PillButton(symbol: symbol, title: "") { }
            labelIcon(button, title)
            button.action = { [weak button] in
                guard let button else { return }
                let menu = NSMenu()
                menu.autoenablesItems = false
                fill(menu)
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
            return button
        }
        let addAlign = { [weak self] (menu: NSMenu) in
            for (i, (symbol, title)) in aligns.enumerated() {
                let item = ClosureMenuItem(title) { self?.onAlign?(i + 1) }
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        let addPlaces = { [weak self] (menu: NSMenu) in
            for (title, side) in places {
                let item = ClosureMenuItem(title) { self?.onPlace?(side) }
                item.state = self?.placement == side ? .on : .off
                menu.addItem(item)
            }
        }
        let addMore = { [weak self] (menu: NSMenu) in
            let fills = self?.canFill?() ?? false
            for (title, down) in [("Fill Formula Right", false), ("Fill Formula Down", true)] {
                let item = ClosureMenuItem(title) { self?.onFill?(down) }
                item.isEnabled = fills
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete Row") { self?.onDeleteRow?() })
            menu.addItem(ClosureMenuItem("Delete Column") { self?.onDeleteColumn?() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Copy Table") { self?.onCopyTable?() })
            menu.addItem(ClosureMenuItem("Delete Table") { self?.onDeleteTable?() })
        }
        if size == .minimal {
            stack.addArrangedSubview(menuButton("ellipsis", "Table") { [weak self] menu in
                menu.addItem(ClosureMenuItem("Add Row") { self?.onAddRow?() })
                menu.addItem(ClosureMenuItem("Add Column") { self?.onAddColumn?() })
                menu.addItem(ClosureMenuItem("Formula") { self?.onFormula?() })
                menu.addItem(.separator())
                addAlign(menu)
                menu.addItem(.separator())
                addPlaces(menu)
                menu.addItem(.separator())
                addMore(menu)
            })
        } else {
            stack.addArrangedSubview(PillButton(symbol: "plus", title: "Row") { [weak self] in self?.onAddRow?() })
            stack.addArrangedSubview(PillButton(symbol: "plus", title: "Column") { [weak self] in self?.onAddColumn?() })
            let formula = PillButton(symbol: "function", title: size == .full ? "Formula" : "") { [weak self] in self?.onFormula?() }
            labelIcon(formula, "Formula: type = and a formula in a cell, like =B2-B3")
            stack.addArrangedSubview(formula)
            stack.addArrangedSubview(divider())
            if size == .compact {
                stack.addArrangedSubview(menuButton("text.alignleft", "Alignment", addAlign))
            } else {
                for (i, (symbol, title)) in aligns.enumerated() {
                    let button = PillButton(symbol: symbol, title: "") { [weak self] in self?.onAlign?(i + 1) }
                    labelIcon(button, title)
                    stack.addArrangedSubview(button)
                }
            }
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(menuButton("rectangle.righthalf.inset.filled", "Layout", addPlaces))
            stack.addArrangedSubview(menuButton("ellipsis", "More", addMore))
        }
        let done = PillButton(symbol: "checkmark", title: size == .full ? "Done" : "") { [weak self] in self?.onDone?() }
        if size != .full { labelIcon(done, "Done") }
        stack.addArrangedSubview(done)
        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        setFrameSize(NSSize(width: ceil(fitting.width), height: ceil(max(fitting.height, 34))))
    }

    private func labelIcon(_ button: PillButton, _ title: String) {
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    private func divider() -> NSView {
        let v = NSBox()
        v.boxType = .custom
        v.borderWidth = 0
        v.fillColor = .separatorColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
