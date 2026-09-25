import AppKit

/// Edits a rendered table in place: every cell is a live field laid exactly over the
/// grid, so you work on the table, not its Markdown. Changes are written back to the
/// note as a normal pipe table.
final class TableEditorView: NSView, NSTextFieldDelegate {
    var header: [String]
    var body: [[String]]
    var alignments: [Int]
    var dashes: [Int]?
    /// Called with new Markdown after any change.
    var onChange: ((String) -> Void)?
    var onExit: (() -> Void)?
    /// Arrowed past the first (false) or last (true) row.
    var onLeave: ((Bool) -> Void)?

    private(set) var render: TableRender
    private var fields: [[CellField]] = []
    private var focus = (row: 0, column: 0)
    private var dragColumn: Int?
    private var dragStartX: CGFloat = 0
    private var dragStartOriginX: CGFloat = 0
    /// Floating on the right: the table grows from its left edge (toward the text),
    /// and inner dividers trade width between neighbours so the right edge holds.
    var anchoredRight = false
    private var dragStartWidths: [CGFloat] = []
    /// While a divider is dragged, the table as last rendered underneath; painted over
    /// so the old layout never shows through a narrower one.
    private var coverRect: NSRect?
    /// Room around the grid for the add-row / add-column buttons.
    static let margin: CGFloat = 34
    private let addColumnButton = HoverButton(symbol: "plus", label: "Add Column", pointSize: 11, target: nil, action: nil)
    private let addRowButton = HoverButton(symbol: "plus", label: "Add Row", pointSize: 11, target: nil, action: nil)
    private var tableRect: NSRect { NSRect(x: 0, y: 0, width: render.width, height: render.height) }

    init(render: TableRender) {
        self.render = render
        header = render.spec.header
        body = render.spec.body
        alignments = render.spec.alignments
        dashes = render.spec.widthFractions != nil ? render.spec.dashes : nil
        super.init(frame: NSRect(x: 0, y: 0, width: render.width + Self.margin, height: render.height + Self.margin))
        installArrowCursorArea()
        for button in [addColumnButton, addRowButton] {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.target = self
            button.restingTint = Palette.tertiaryText
            addSubview(button)
        }
        addColumnButton.action = #selector(addColumnAtEnd)
        addRowButton.action = #selector(addRowAtEnd)
        rebuildFields()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var columns: Int { max(header.count, alignments.count, body.map(\.count).max() ?? 0, 1) }
    var rowCount: Int { body.count + 1 }

    func text(row: Int, column: Int) -> String {
        let r = row == 0 ? header : body[row - 1]
        return column < r.count ? r[column] : ""
    }

    private func setText(_ text: String, row: Int, column: Int) {
        if row == 0 {
            while header.count <= column { header.append("") }
            header[column] = text
        } else {
            while body[row - 1].count <= column { body[row - 1].append("") }
            body[row - 1][column] = text
        }
    }

    var markdown: String {
        TableSpec.markdown(header: header, body: body, alignments: alignments, dashes: dashes)
    }

    /// Adopts a fresh layout after the note re-rendered the table.
    func update(render: TableRender) {
        self.render = render
        setFrameSize(NSSize(width: render.width + Self.margin, height: render.height + Self.margin))
        layoutFields()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func rebuildFields() {
        fields.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        fields = (0..<rowCount).map { r in
            (0..<columns).map { c in
                let field = CellField()
                field.stringValue = text(row: r, column: c)
                field.delegate = self
                field.row = r
                field.column = c
                addSubview(field)
                return field
            }
        }
        layoutFields()
    }

    private func layoutFields() {
        let rect = tableRect
        // The + buttons sit where the next column and row would appear.
        let headerHeight = render.rowHeights.first ?? 30
        addColumnButton.frame = NSRect(x: rect.maxX + 4, y: (headerHeight - 24) / 2, width: 26, height: 24)
        addRowButton.frame = NSRect(x: 4, y: rect.maxY + 4, width: 26, height: 24)
        for (r, row) in fields.enumerated() {
            for (c, field) in row.enumerated() {
                guard r < render.rowHeights.count, c < render.columnWidths.count else {
                    field.isHidden = true
                    continue
                }
                field.isHidden = false
                let attrs = render.attributes(row: r, column: c)
                field.font = attrs[.font] as? NSFont
                field.textColor = Palette.text
                field.alignment = (attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
                let box = render.cellRect(row: r, column: c, in: rect)
                    .insetBy(dx: TableRender.padX - 2, dy: TableRender.padY - 2)
                field.frame = box
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        tableRect.union(coverRect ?? tableRect).fill()
        render.drawChrome(in: tableRect)
        // A quiet highlight on the cell being edited.
        if focus.row < render.rowHeights.count, focus.column < render.columnWidths.count {
            let r = render.cellRect(row: focus.row, column: focus.column, in: tableRect).insetBy(dx: 1.5, dy: 1.5)
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
    }

    // MARK: Focus

    func focusCell(row: Int, column: Int, selectAll: Bool = false) {
        let r = min(max(row, 0), rowCount - 1), c = min(max(column, 0), columns - 1)
        focus = (r, c)
        needsDisplay = true
        guard r < fields.count, c < fields[r].count else { return }
        let field = fields[r][c]
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            if selectAll { editor.selectAll(nil) }
            else { editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? CellField else { return }
        focus = (field.row, field.column)
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? CellField else { return }
        setText(field.stringValue, row: field.row, column: field.column)
        onChange?(markdown)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? CellField else { return false }
        let (r, c) = (field.row, field.column)
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if c + 1 < columns { focusCell(row: r, column: c + 1, selectAll: true) }
            else if r + 1 < rowCount { focusCell(row: r + 1, column: 0, selectAll: true) }
            else { addRow(after: r); focusCell(row: r + 1, column: 0) }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if c > 0 { focusCell(row: r, column: c - 1, selectAll: true) }
            else if r > 0 { focusCell(row: r - 1, column: columns - 1, selectAll: true) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if r + 1 < rowCount { focusCell(row: r + 1, column: c) } else { addRow(after: r); focusCell(row: r + 1, column: c) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if r > 0 { focusCell(row: r - 1, column: c) } else { onLeave?(false) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if r + 1 < rowCount { focusCell(row: r + 1, column: c) } else { onLeave?(true) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onExit?()
            return true
        default:
            return false
        }
    }

    // MARK: Structure

    @objc private func addColumnAtEnd() {
        addColumn(after: columns - 1)
        focusCell(row: 0, column: columns - 1)
    }

    @objc private func addRowAtEnd() {
        body.append(Array(repeating: "", count: columns))
        commitStructure()
        focusCell(row: rowCount - 1, column: 0)
    }

    func addRow(after row: Int? = nil) {
        let index = min((row ?? focus.row), rowCount - 1)
        body.insert(Array(repeating: "", count: columns), at: index)
        commitStructure()
    }

    func addColumn(after column: Int? = nil) {
        let index = min((column ?? focus.column) + 1, columns)
        header.insert("", at: min(index, header.count))
        for i in body.indices { body[i].insert("", at: min(index, body[i].count)) }
        alignments.insert(0, at: min(index, alignments.count))
        if var d = dashes { d.insert(d.min() ?? 3, at: min(index, d.count)); dashes = d }
        commitStructure()
        focusCell(row: focus.row, column: index)
    }

    func deleteRow() {
        guard focus.row > 0 else { NSSound.beep(); return }
        body.remove(at: focus.row - 1)
        commitStructure()
        focusCell(row: min(focus.row, rowCount - 1), column: focus.column)
    }

    func deleteColumn() {
        guard columns > 1 else { NSSound.beep(); return }
        let c = focus.column
        if c < header.count { header.remove(at: c) }
        for i in body.indices where c < body[i].count { body[i].remove(at: c) }
        if c < alignments.count { alignments.remove(at: c) }
        if var d = dashes, c < d.count { d.remove(at: c); dashes = d }
        commitStructure()
        focusCell(row: focus.row, column: min(c, columns - 1))
    }

    func align(_ alignment: Int) {
        while alignments.count < columns { alignments.append(0) }
        alignments[focus.column] = alignment
        commitStructure()
        focusCell(row: focus.row, column: focus.column)
    }

    private func commitStructure() {
        onChange?(markdown)
        rebuildFields()
    }

    // MARK: Column resizing

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        var x: CGFloat = 0
        for w in render.columnWidths {
            x += w
            addCursorRect(NSRect(x: x - 4, y: 0, width: 8, height: render.height), cursor: .columnResize)
        }
    }

    /// The column whose right edge is under the point (the last one is the table edge).
    private func divider(at point: NSPoint) -> Int? {
        guard point.y >= 0, point.y <= render.height else { return nil }
        if anchoredRight, point.x >= 0, point.x <= 5 { return -1 }
        var x: CGFloat = 0
        for (i, w) in render.columnWidths.enumerated() {
            x += w
            if anchoredRight, i == render.columnWidths.count - 1 { break }
            if abs(point.x - x) <= 4 { return i }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (divider(at: p) != nil ? NSCursor.columnResize : NSCursor.arrow).set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Dividers win over the fields next to them.
        let local = convert(point, from: superview)
        if bounds.contains(local), divider(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let column = divider(at: p) else { return }
        dragColumn = column
        dragStartX = event.locationInWindow.x
        dragStartOriginX = frame.minX
        dragStartWidths = render.columnWidths
        coverRect = anchoredRight ? nil : tableRect.insetBy(dx: -2, dy: -2)
        NSCursor.columnResize.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let column = dragColumn else { return }
        let dx = event.locationInWindow.x - dragStartX
        var widths = dragStartWidths
        let minimum: CGFloat = 48
        if anchoredRight {
            let total = dragStartWidths.reduce(0, +)
            if column == -1 {
                let others = total - dragStartWidths[0]
                widths[0] = min(max(dragStartWidths[0] - dx, minimum), render.maxWidth - others)
            } else {
                let pair = dragStartWidths[column] + dragStartWidths[column + 1]
                widths[column] = min(max(dragStartWidths[column] + dx, minimum), pair - minimum)
                widths[column + 1] = pair - widths[column]
            }
            render.setColumnWidths(widths)
            setFrameOrigin(NSPoint(x: dragStartOriginX + total - widths.reduce(0, +), y: frame.minY))
            setFrameSize(NSSize(width: render.width + Self.margin, height: render.height + Self.margin))
            layoutFields()
            needsDisplay = true
            return
        }
        // Only this column changes, so the table itself grows or shrinks.
        let others = widths.enumerated().filter { $0.offset != column }.reduce(0) { $0 + $1.element }
        widths[column] = min(max(dragStartWidths[column] + dx, minimum), render.maxWidth - others)
        render.setColumnWidths(widths)
        let cover = coverRect ?? .zero
        setFrameSize(NSSize(width: max(render.width + Self.margin, cover.maxX), height: max(render.height + Self.margin, cover.maxY)))
        layoutFields()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragColumn != nil else { return }
        dragColumn = nil
        coverRect = nil
        NSCursor.pop()
        // Save widths as dash counts: each column is dashes / 72 of the text width.
        let scale = CGFloat(TableSpec.widthScale)
        var counts = render.columnWidths.map { max(3, Int(round($0 / render.fractionBase * scale))) }
        // Equal counts would read as "no widths set"; nudge the last one.
        if Set(counts).count == 1, let last = counts.indices.last { counts[last] += 1 }
        dashes = counts
        onChange?(markdown)
    }
}

/// Borderless cell field that looks like the rendered cell text.
final class CellField: NSTextField {
    var row = 0
    var column = 0

    convenience init() {
        self.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        cell?.wraps = true
        cell?.isScrollable = false
        cell?.usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        setAccessibilityLabel("Table cell")
    }
}

/// The glass bar shown above a table while editing it.
final class TableToolbarView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    var onAddRow: (() -> Void)?
    var onAddColumn: (() -> Void)?
    var onAlign: ((Int) -> Void)?
    var onDeleteRow: (() -> Void)?
    var onDeleteColumn: (() -> Void)?
    var onDeleteTable: (() -> Void)?
    var onDone: (() -> Void)?
    /// nil: full width; true/false: text wraps beside it on the right/left.
    var onPlace: ((Bool?) -> Void)?
    var placement: Bool?

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
        stack.addArrangedSubview(PillButton(symbol: "plus", title: "Row") { [weak self] in self?.onAddRow?() })
        stack.addArrangedSubview(PillButton(symbol: "plus", title: "Column") { [weak self] in self?.onAddColumn?() })
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(PillButton(symbol: "text.alignleft", title: "") { [weak self] in self?.onAlign?(1) })
        stack.addArrangedSubview(PillButton(symbol: "text.aligncenter", title: "") { [weak self] in self?.onAlign?(2) })
        stack.addArrangedSubview(PillButton(symbol: "text.alignright", title: "") { [weak self] in self?.onAlign?(3) })
        stack.addArrangedSubview(divider())
        let place = PillButton(symbol: "rectangle.righthalf.inset.filled", title: "") { }
        place.toolTip = "Layout"
        place.action = { [weak self, weak place] in
            guard let self, let place else { return }
            let menu = NSMenu()
            let options: [(String, Bool?)] = [("Full Width", nil), ("Right, Text Wraps Beside", true), ("Left, Text Wraps Beside", false)]
            for (title, side) in options {
                let item = ClosureMenuItem(title) { self.onPlace?(side) }
                item.state = self.placement == side ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: place.bounds.height + 4), in: place)
        }
        stack.addArrangedSubview(place)
        let more = PillButton(symbol: "ellipsis", title: "") { }
        more.action = { [weak self, weak more] in
            guard let self, let more else { return }
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Delete Row") { self.onDeleteRow?() })
            menu.addItem(ClosureMenuItem("Delete Column") { self.onDeleteColumn?() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete Table") { self.onDeleteTable?() })
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        }
        stack.addArrangedSubview(more)
        stack.addArrangedSubview(PillButton(symbol: "checkmark", title: "Done") { [weak self] in self?.onDone?() })
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        setFrameSize(NSSize(width: ceil(size.width), height: ceil(max(size.height, 34))))
    }

    required init?(coder: NSCoder) { fatalError() }

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
