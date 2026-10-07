import AppKit

/// Edits a rendered table in place: every cell is a live field laid exactly over the
/// grid, so you work on the table, not its Markdown. Changes are written back to the
/// note as a normal pipe table.
///
/// Column widths hold still while you type; only a row grows when its text wraps.
/// Dragging across cells, shift-clicking, or shift-arrowing past a cell's edge selects
/// a block of cells to copy, cut, paste over, or clear.
final class TableEditorView: NSView, NSTextFieldDelegate, NSUserInterfaceValidations {
    typealias Cell = (row: Int, column: Int)

    /// Cell text as you see it while editing: Markdown, with pipes unescaped.
    var header: [String]
    var body: [[String]]
    var alignments: [Int]
    var dashes: [Int]?
    /// Called with new Markdown after any change, and the cell when it came from typing
    /// in it (a run of typing in one cell undoes as one step).
    var onChange: ((String, Cell?) -> Void)?
    var onExit: (() -> Void)?
    /// Arrowed past the first (false) or last (true) row.
    var onLeave: ((Bool) -> Void)?
    /// The cell whose text is being edited (nil while cells are selected as a block).
    var onFocusChange: ((Cell?) -> Void)?
    var onDeleteTable: (() -> Void)?

    private(set) var render: TableRender
    private var fields: [[CellField]] = []
    private(set) var focus: Cell = (0, 0)
    /// A block of selected cells, from where it started to where it reaches.
    private(set) var selection: (anchor: Cell, head: Cell)?
    /// One field editor for every cell, so paste and Select All can reach the table.
    /// Undo belongs to the note, which keeps a copy of the table from before each edit.
    let fieldEditor: CellTextView = {
        let editor = CellTextView(frame: .zero)
        editor.isFieldEditor = true
        return editor
    }()
    private var dragColumn: Int?
    private var dragStartX: CGFloat = 0
    private var dragStartOriginX: CGFloat = 0
    /// Floating on the right: the table grows from its left edge (toward the text),
    /// and inner dividers trade width between neighbours so the right edge holds.
    var anchoredRight = false
    var floating = false
    /// Whether the add strips fit outside the grid (see `TableEdgeStrip.frames`). Text
    /// wraps right up against a floating table, and a table can fill its column, so
    /// then they lie along the grid's inner edges instead.
    var stripRoom: (right: Bool, below: Bool) = (true, true) { didSet { layoutFields() } }
    private var dragStartWidths: [CGFloat] = []
    /// While a divider is dragged, the table as last rendered underneath; painted over
    /// so the old layout never shows through a narrower one.
    private var coverRect: NSRect?
    /// Room around the grid for the add strips. It overlaps the page rather than
    /// pushing the text below down; clicks there pass through to the note.
    static let margin: CGFloat = TableEdgeStrip.outset
    private let addColumnStrip = TableEdgeStrip(adds: .column)
    private let addRowStrip = TableEdgeStrip(adds: .row)
    private var tableRect: NSRect { NSRect(x: 0, y: 0, width: render.width, height: render.height) }

    init(render: TableRender) {
        self.render = render
        header = render.spec.header.map(Self.unescape)
        body = render.spec.body.map { $0.map(Self.unescape) }
        alignments = render.spec.alignments
        dashes = render.spec.widthFractions != nil ? render.spec.dashes : nil
        super.init(frame: NSRect(x: 0, y: 0, width: render.width + Self.margin, height: render.height + Self.margin))
        fieldEditor.table = self
        for strip in [addColumnStrip, addRowStrip] { addSubview(strip) }
        addColumnStrip.onClick = { [weak self] in self?.addColumnAtEnd() }
        addRowStrip.onClick = { [weak self] in self?.addRowAtEnd() }
        rebuildFields()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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

    /// `a \| b` in the file is `a | b` in the cell; pipes are escaped again on the way out.
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: #"\|"#, with: "|")
    }

    /// Adopts a fresh layout after the note re-rendered the table.
    func update(render: TableRender) {
        self.render = render
        adopt(render.spec)
        setFrameSize(NSSize(width: render.width + Self.margin, height: render.height + Self.margin))
        layoutFields()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Takes on the note's version of the table when it changed underneath (undo, redo,
    /// another app). Text that only differs by spaces at its ends is left as typed.
    private func adopt(_ spec: TableSpec) {
        let newHeader = spec.header.map(Self.unescape)
        let newBody = spec.body.map { $0.map(Self.unescape) }
        let newColumns = max(spec.alignments.count, spec.rows.map(\.count).max() ?? 0, 1)
        func cell(_ r: Int, _ c: Int) -> String {
            let row = r == 0 ? newHeader : newBody[r - 1]
            return c < row.count ? row[c] : ""
        }
        if newBody.count + 1 != rowCount || newColumns != columns {
            header = newHeader
            body = newBody
            alignments = spec.alignments
            dashes = spec.widthFractions != nil ? spec.dashes : nil
            selection = nil
            // Keep the keys in the table, never the hidden Markdown behind it.
            let active = fields.joined().contains { $0.currentEditor() != nil } || window?.firstResponder === self
            rebuildFields()
            if active { focusCell(row: focus.row, column: focus.column) }
            return
        }
        if spec.alignments != alignments { alignments = spec.alignments }
        for r in 0..<rowCount {
            for c in 0..<columns {
                let theirs = cell(r, c)
                guard theirs.trimmingCharacters(in: .whitespaces) != text(row: r, column: c).trimmingCharacters(in: .whitespaces),
                      r < fields.count, c < fields[r].count else { continue }
                setText(theirs, row: r, column: c)
                let field = fields[r][c]
                field.source = theirs
                if let editor = field.currentEditor() as? NSTextView {
                    editor.string = theirs
                    editor.setSelectedRange(NSRange(location: (theirs as NSString).length, length: 0))
                }
            }
        }
    }

    private func rebuildFields() {
        fields.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        fields = (0..<rowCount).map { r in
            (0..<columns).map { c in
                let field = CellField()
                field.table = self
                field.source = text(row: r, column: c)
                field.style = { [weak self] text, reveal in self?.styled(text, row: r, column: c, reveal: reveal) ?? NSAttributedString(string: text) }
                field.delegate = self
                field.row = r
                field.column = c
                addSubview(field, positioned: .below, relativeTo: addColumnStrip)
                return field
            }
        }
        // Keyboard navigation runs from the cells on to the add strips.
        fields.last?.last?.nextKeyView = addColumnStrip
        addColumnStrip.nextKeyView = addRowStrip
        focus = (min(focus.row, rowCount - 1), min(focus.column, columns - 1))
        layoutFields()
    }

    private func layoutFields() {
        let rect = tableRect
        // The strips run along the edges where the next column and row would appear.
        let strips = TableEdgeStrip.frames(table: rect, room: stripRoom)
        addColumnStrip.frame = strips.column
        addColumnStrip.inside = !stripRoom.right
        addRowStrip.frame = strips.row
        addRowStrip.inside = !stripRoom.below
        for (r, row) in fields.enumerated() {
            for (c, field) in row.enumerated() {
                guard r < render.rowHeights.count, c < render.columnWidths.count else {
                    field.isHidden = true
                    continue
                }
                field.isHidden = false
                let attrs = styled("x", row: r, column: c, reveal: false).attributes(at: 0, effectiveRange: nil)
                field.font = attrs[.font] as? NSFont
                field.textColor = Palette.text
                field.alignment = (attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
                if field.currentEditor() == nil { field.showRendered() } else { field.restyleEditor() }
                let box = render.cellRect(row: r, column: c, in: rect)
                    .insetBy(dx: TableRender.padX - 2, dy: TableRender.padY - 2)
                field.frame = box
            }
        }
    }

    /// Cell text styled like the rendered table, equations fitted to the column the
    /// same way; `reveal` keeps the Markdown markers.
    private func styled(_ text: String, row: Int, column: Int, reveal: Bool) -> NSAttributedString {
        let styled = TableRender.render(text, header: row == 0, alignment: column < alignments.count ? alignments[column] : 0,
                                        typography: render.typography, size: round(render.typography.size * 0.9), revealMarkers: reveal)
        guard column < render.columnWidths.count else { return styled }
        return TableRender.fit(styled, width: render.columnWidths[column] - TableRender.padX * 2)
    }

    /// The text view editing the focused cell, if any. Formatting commands act on it
    /// so they never reach the note around the table.
    var cellEditor: NSTextView? {
        fields.joined().first { $0.currentEditor() != nil }?.currentEditor() as? NSTextView
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        tableRect.union(coverRect ?? tableRect).fill()
        render.drawChrome(in: tableRect)
        // Highlights on edge cells follow the table's rounded corners.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        TableRender.outline(of: tableRect).addClip()
        if let bounds = selectedBounds, bounds.rows.upperBound <= render.rowHeights.count, bounds.columns.upperBound <= render.columnWidths.count {
            // Selected cells: tinted, with one outline around the block.
            let first = render.cellRect(row: bounds.rows.lowerBound, column: bounds.columns.lowerBound, in: tableRect)
            let last = render.cellRect(row: bounds.rows.upperBound - 1, column: bounds.columns.upperBound - 1, in: tableRect)
            let block = first.union(last).insetBy(dx: 1, dy: 1)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: block, xRadius: 5, yRadius: 5).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let outline = NSBezierPath(roundedRect: block.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
            outline.lineWidth = 1.5
            outline.stroke()
        } else if focus.row < render.rowHeights.count, focus.column < render.columnWidths.count {
            // A quiet highlight on the cell being edited.
            let r = render.cellRect(row: focus.row, column: focus.column, in: tableRect).insetBy(dx: 1.5, dy: 1.5)
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
    }

    // MARK: Focus

    /// Edits a cell's text, with the caret at its end (or everything selected).
    func focusCell(row: Int, column: Int, selectAll: Bool = false, caretAtStart: Bool = false) {
        let r = min(max(row, 0), rowCount - 1), c = min(max(column, 0), columns - 1)
        focus = (r, c)
        if selection != nil { selection = nil }
        needsDisplay = true
        guard r < fields.count, c < fields[r].count else { return }
        let field = fields[r][c]
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let length = (field.stringValue as NSString).length
            editor.selectedRange = selectAll ? NSRange(location: 0, length: length) : NSRange(location: caretAtStart ? 0 : length, length: 0)
        }
        onFocusChange?(focus)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? CellField else { return }
        focus = (field.row, field.column)
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? CellField else { return }
        cellChanged(field)
    }

    private func cellChanged(_ field: CellField) {
        field.source = field.stringValue
        setText(field.source, row: field.row, column: field.column)
        field.restyleEditor()
        let typing = separatesNextChange ? nil : (field.row, field.column)
        separatesNextChange = false
        onChange?(markdown, typing)
    }

    /// The next change in a cell is its own Undo step rather than more of the typing
    /// before it (a math shortcut expanding: Undo brings back what was typed).
    private var separatesNextChange = false
    func separateNextChange() { separatesNextChange = true }

    func controlTextDidEndEditing(_ obj: Notification) {
        (obj.object as? CellField)?.showRendered()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? CellField else { return false }
        let (r, c) = (field.row, field.column)
        let range = textView.selectedRange()
        let length = (textView.string as NSString).length
        // Math comes first: a shortcut's blanks, then out of the equation; only then the
        // keys move between cells. Return and Escape always leave (dropping any blanks).
        let math = (textView as? CellTextView)?.math
        if let math {
            let handled: Bool
            switch selector {
            case #selector(NSResponder.insertTab(_:)): handled = math.handleTab()
            case #selector(NSResponder.insertBacktab(_:)): handled = math.handleBacktab()
            case #selector(NSResponder.deleteBackward(_:)): handled = math.handleBackspace()
            case #selector(NSResponder.insertNewline(_:)):
                handled = math.handleNewline(shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            default: handled = false
            }
            if handled { return true }
        }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if c + 1 < columns { focusCell(row: r, column: c + 1, selectAll: true) }
            else if r + 1 < rowCount { focusCell(row: r + 1, column: 0, selectAll: true) }
            else { addRow(below: r); focusCell(row: r + 1, column: 0) }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if c > 0 { focusCell(row: r, column: c - 1, selectAll: true) }
            else if r > 0 { focusCell(row: r - 1, column: columns - 1, selectAll: true) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if r + 1 < rowCount { focusCell(row: r + 1, column: c) } else { addRow(below: r); focusCell(row: r + 1, column: c) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            // A wrapped cell moves within its own lines first.
            guard caretOnEdgeLine(textView, top: true) else { return false }
            if r > 0 { focusCell(row: r - 1, column: c) } else { onLeave?(false) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard caretOnEdgeLine(textView, top: false) else { return false }
            if r + 1 < rowCount { focusCell(row: r + 1, column: c) } else { onLeave?(true) }
            return true
        case #selector(NSResponder.moveLeft(_:)):
            guard range == NSRange(location: 0, length: 0) else { return false }
            if c > 0 { focusCell(row: r, column: c - 1) } else if r > 0 { focusCell(row: r - 1, column: columns - 1) }
            return true
        case #selector(NSResponder.moveRight(_:)):
            guard range == NSRange(location: length, length: 0) else { return false }
            if c + 1 < columns { focusCell(row: r, column: c + 1, caretAtStart: true) }
            else if r + 1 < rowCount { focusCell(row: r + 1, column: 0, caretAtStart: true) }
            return true
        // Shift-arrowing past the edge of the text starts selecting cells.
        case #selector(NSResponder.moveLeftAndModifySelection(_:)) where range.location == 0:
            select(from: (r, c), to: (r, c - 1))
            return true
        case #selector(NSResponder.moveRightAndModifySelection(_:)) where NSMaxRange(range) == length:
            select(from: (r, c), to: (r, c + 1))
            return true
        case #selector(NSResponder.moveUpAndModifySelection(_:)) where range.location == 0:
            select(from: (r, c), to: (r - 1, c))
            return true
        case #selector(NSResponder.moveDownAndModifySelection(_:)) where NSMaxRange(range) == length:
            select(from: (r, c), to: (r + 1, c))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            math?.clearStops()
            onExit?()
            return true
        default:
            return false
        }
    }

    private func caretOnEdgeLine(_ textView: NSTextView, top: Bool) -> Bool {
        let length = (textView.string as NSString).length
        guard length > 0 else { return true }
        let caret = textView.selectedRange()
        let here = textView.firstRect(forCharacterRange: NSRange(location: top ? caret.location : NSMaxRange(caret), length: 0), actualRange: nil)
        let edge = textView.firstRect(forCharacterRange: NSRange(location: top ? 0 : length, length: 0), actualRange: nil)
        return abs(here.midY - edge.midY) < 2
    }

    // MARK: Selecting cells

    private var selectedBounds: (rows: Range<Int>, columns: Range<Int>)? {
        guard let s = selection else { return nil }
        return (min(s.anchor.row, s.head.row)..<(max(s.anchor.row, s.head.row) + 1),
                min(s.anchor.column, s.head.column)..<(max(s.anchor.column, s.head.column) + 1))
    }

    /// Cells the next command applies to: the selected block, or the focused cell.
    private var targetBounds: (rows: Range<Int>, columns: Range<Int>) {
        selectedBounds ?? (focus.row..<(focus.row + 1), focus.column..<(focus.column + 1))
    }

    private func clamp(_ cell: Cell) -> Cell {
        (min(max(cell.row, 0), rowCount - 1), min(max(cell.column, 0), columns - 1))
    }

    /// Selects a block of cells. The table itself takes the keys, so arrows, Delete,
    /// and copy and paste act on the whole block.
    func select(from anchor: Cell, to head: Cell) {
        let anchor = clamp(anchor), head = clamp(head)
        let wasSelecting = selection != nil
        selection = (anchor, head)
        focus = anchor
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if !wasSelecting { onFocusChange?(nil) }
        needsDisplay = true
    }

    func selectAllCells() {
        select(from: (0, 0), to: (rowCount - 1, columns - 1))
    }

    override func selectAll(_ sender: Any?) { selectAllCells() }

    private func moveSelection(dRow: Int, dColumn: Int, extend: Bool) {
        guard let s = selection else { return }
        let head = (s.head.row + dRow, s.head.column + dColumn)
        if extend { select(from: s.anchor, to: head) } else { select(from: head, to: head) }
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveUp(_ sender: Any?) { moveSelection(dRow: -1, dColumn: 0, extend: false) }
    override func moveDown(_ sender: Any?) { moveSelection(dRow: 1, dColumn: 0, extend: false) }
    override func moveLeft(_ sender: Any?) { moveSelection(dRow: 0, dColumn: -1, extend: false) }
    override func moveRight(_ sender: Any?) { moveSelection(dRow: 0, dColumn: 1, extend: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { moveSelection(dRow: -1, dColumn: 0, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { moveSelection(dRow: 1, dColumn: 0, extend: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { moveSelection(dRow: 0, dColumn: -1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { moveSelection(dRow: 0, dColumn: 1, extend: true) }
    override func insertTab(_ sender: Any?) { moveSelection(dRow: 0, dColumn: 1, extend: false) }
    override func insertBacktab(_ sender: Any?) { moveSelection(dRow: 0, dColumn: -1, extend: false) }
    override func insertNewline(_ sender: Any?) { focusCell(row: focus.row, column: focus.column) }
    override func cancelOperation(_ sender: Any?) { focusCell(row: focus.row, column: focus.column) }
    override func deleteBackward(_ sender: Any?) { clearCells() }
    override func deleteForward(_ sender: Any?) { clearCells() }
    @objc func delete(_ sender: Any?) { clearCells() }

    /// Typing over selected cells starts the first one afresh, as in a spreadsheet.
    override func insertText(_ insertString: Any) {
        let typed = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        guard !typed.isEmpty else { return }
        let cell = selection?.anchor ?? focus
        setText(typed, row: cell.row, column: cell.column)
        fields[cell.row][cell.column].source = typed
        onChange?(markdown, nil)
        focusCell(row: cell.row, column: cell.column)
    }

    override func doCommand(by selector: Selector) {
        if responds(to: selector) { perform(selector, with: nil) }
    }

    func clearCells() {
        let b = targetBounds
        for r in b.rows { for c in b.columns where !text(row: r, column: c).isEmpty {
            setText("", row: r, column: c)
            fields[r][c].source = ""
            fields[r][c].showRendered()
        } }
        onChange?(markdown, nil)
    }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        let b = targetBounds
        let rows = b.rows.map { r in b.columns.map { c in text(row: r, column: c) } }
        let whole = b.rows == 0..<rowCount && b.columns == 0..<columns
        TableClipboard.write(rows, header: b.rows.lowerBound == 0, markdown: whole ? markdown : nil, to: .general)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        clearCells()
    }

    @objc func paste(_ sender: Any?) {
        _ = pasteGrid(from: .general, intoText: false)
    }

    func copyTable() {
        TableClipboard.write([header + Array(repeating: "", count: max(0, columns - header.count))]
                             + body.map { $0 + Array(repeating: "", count: max(0, columns - $0.count)) },
                             header: true, markdown: markdown, to: .general)
    }

    /// Pastes cells copied from a spreadsheet, a web page or another table, starting at
    /// the focused cell and growing the table to fit. One value pasted over a block of
    /// cells fills them all. While typing in a cell, a single value pastes as text.
    func pasteGrid(from pb: NSPasteboard, intoText: Bool) -> Bool {
        guard let grid = TableClipboard.grid(from: pb, lines: !intoText), !grid.isEmpty else { return false }
        let width = grid.map(\.count).max() ?? 0
        guard width > 0 else { return false }
        if intoText, grid.count == 1, width == 1 { return false }
        let b = targetBounds
        let origin: Cell = (b.rows.lowerBound, b.columns.lowerBound)
        if grid.count == 1, width == 1 {
            for r in b.rows { for c in b.columns { setText(grid[0][0], row: r, column: c) } }
        } else {
            while rowCount < origin.row + grid.count { body.append(Array(repeating: "", count: columns)) }
            while columns < origin.column + width { insertColumn(at: columns) }
            for (i, row) in grid.enumerated() {
                for (j, value) in row.enumerated() { setText(value.replacingOccurrences(of: "\n", with: " "), row: origin.row + i, column: origin.column + j) }
            }
        }
        commitStructure()
        let reach: Cell = grid.count == 1 && width == 1 ? (b.rows.upperBound - 1, b.columns.upperBound - 1)
                                                        : (origin.row + grid.count - 1, origin.column + width - 1)
        if reach == origin { focusCell(row: origin.row, column: origin.column) } else { select(from: origin, to: reach) }
        return true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(selectAll(_:)): return true
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        default: return responds(to: item.action)
        }
    }

    // MARK: Structure

    func addColumnAtEnd() {
        addColumn(right: columns - 1)
        focusCell(row: 0, column: columns - 1)
    }

    func addRowAtEnd() {
        body.append(Array(repeating: "", count: columns))
        commitStructure()
        focusCell(row: rowCount - 1, column: 0)
    }

    /// Adds a row under `row` (the focused row by default) and keeps the cursor where it was.
    func addRow(below row: Int? = nil) {
        let index = min(row ?? targetBounds.rows.upperBound - 1, rowCount - 1)
        body.insert(Array(repeating: "", count: columns), at: index)
        commitStructure()
    }

    /// A row above the header would take its place; it goes under it instead.
    func addRow(above row: Int? = nil) {
        let index = max((row ?? targetBounds.rows.lowerBound) - 1, 0)
        body.insert(Array(repeating: "", count: columns), at: index)
        commitStructure()
        if (row ?? targetBounds.rows.lowerBound) > 0 { focusCell(row: index + 1, column: focus.column) }
    }

    func addColumn(right column: Int? = nil) {
        let index = min((column ?? targetBounds.columns.upperBound - 1) + 1, columns)
        insertColumn(at: index)
        commitStructure()
        focusCell(row: focus.row, column: index)
    }

    func addColumn(left column: Int? = nil) {
        let index = column ?? targetBounds.columns.lowerBound
        insertColumn(at: index)
        commitStructure()
        focusCell(row: focus.row, column: index)
    }

    private func insertColumn(at index: Int) {
        let columns = self.columns
        header += Array(repeating: "", count: max(0, columns - header.count))
        header.insert("", at: index)
        for i in body.indices {
            body[i] += Array(repeating: "", count: max(0, columns - body[i].count))
            body[i].insert("", at: index)
        }
        alignments += Array(repeating: 0, count: max(0, columns - alignments.count))
        alignments.insert(0, at: index)
        if var d = dashes {
            d += Array(repeating: 3, count: max(0, columns - d.count))
            d.insert(d.min() ?? 3, at: index)
            dashes = d
        }
    }

    /// Deletes the selected rows (or the focused one). The header row stays.
    func deleteRow() {
        let rows = targetBounds.rows.filter { $0 > 0 }
        guard !rows.isEmpty else { NSSound.beep(); return }
        for r in rows.reversed() { body.remove(at: r - 1) }
        commitStructure()
        focusCell(row: min(rows.first!, rowCount - 1), column: focus.column)
    }

    func deleteColumn() {
        let cols = targetBounds.columns
        guard cols.count < columns else { NSSound.beep(); return }
        for c in cols.reversed() {
            if c < header.count { header.remove(at: c) }
            for i in body.indices where c < body[i].count { body[i].remove(at: c) }
            if c < alignments.count { alignments.remove(at: c) }
            if var d = dashes, c < d.count { d.remove(at: c); dashes = d }
        }
        commitStructure()
        focusCell(row: focus.row, column: min(cols.lowerBound, columns - 1))
    }

    func align(_ alignment: Int) {
        while alignments.count < columns { alignments.append(0) }
        for c in targetBounds.columns { alignments[c] = alignment }
        let kept = selection
        commitStructure()
        if let kept { select(from: kept.anchor, to: kept.head) } else { focusCell(row: focus.row, column: focus.column) }
    }

    private func commitStructure() {
        selection = nil
        onChange?(markdown, nil)
        rebuildFields()
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        // Dividers win over the cells next to them; the table handles its own clicks
        // so a drag can run from one cell into the next.
        if divider(at: local) != nil { return self }
        for strip in [addColumnStrip, addRowStrip] where !strip.isHidden && strip.frame.contains(local) { return strip }
        return tableRect.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let column = divider(at: p) {
            beginResizing(column, event: event)
            return
        }
        guard let start = render.cell(at: p) else { return }
        if event.modifierFlags.contains(.shift) {
            select(from: selection?.anchor ?? focus, to: start)
            return
        }
        focusCell(row: start.row, column: start.column)
        guard let editor = cellEditor else { return }
        let index = characterIndex(in: editor, at: event.locationInWindow)
        switch event.clickCount {
        case 1: editor.setSelectedRange(NSRange(location: index, length: 0))
        case 2: editor.setSelectedRange(editor.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord))
        default: editor.selectAll(nil)
        }
        let anchor = editor.selectedRange()
        var selecting = false
        // Dragging selects text inside the cell; leaving it selects cells instead.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            let q = convert(next.locationInWindow, from: nil)
            let inside = NSPoint(x: min(max(q.x, 0), max(render.width - 1, 0)), y: min(max(q.y, 0), max(render.height - 1, 0)))
            let over = render.cell(at: inside) ?? start
            if selecting || over != start {
                selecting = true
                select(from: start, to: over)
            } else if let editor = cellEditor {
                let i = characterIndex(in: editor, at: next.locationInWindow)
                let lo = min(i, anchor.location), hi = max(i, NSMaxRange(anchor))
                editor.setSelectedRange(NSRange(location: lo, length: hi - lo))
            }
        }
    }

    private func characterIndex(in editor: NSTextView, at windowPoint: NSPoint) -> Int {
        min(editor.characterIndexForInsertion(at: editor.convert(windowPoint, from: nil)), (editor.string as NSString).length)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let cell = render.cell(at: p), !(selectedBounds.map { $0.rows.contains(cell.row) && $0.columns.contains(cell.column) } ?? false) {
            focusCell(row: cell.row, column: cell.column)
        }
        let b = targetBounds
        let rows = b.rows.count, cols = b.columns.count
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Cut") { [weak self] in self?.cut(nil) })
        menu.addItem(ClosureMenuItem("Copy") { [weak self] in self?.copy(nil) })
        menu.addItem(ClosureMenuItem("Paste") { [weak self] in self?.paste(nil) })
        menu.addItem(.separator())
        let above = ClosureMenuItem("Insert Row Above") { [weak self] in self?.addRow(above: nil) }
        above.isEnabled = b.rows.lowerBound > 0
        menu.addItem(above)
        menu.addItem(ClosureMenuItem("Insert Row Below") { [weak self] in
            guard let self else { return }
            let row = self.targetBounds.rows.upperBound - 1
            self.addRow(below: row)
            self.focusCell(row: row + 1, column: self.focus.column)
        })
        menu.addItem(ClosureMenuItem("Insert Column Left") { [weak self] in self?.addColumn(left: nil) })
        menu.addItem(ClosureMenuItem("Insert Column Right") { [weak self] in self?.addColumn(right: nil) })
        menu.addItem(.separator())
        let deleteRows = ClosureMenuItem(rows > 1 ? "Delete \(rows) Rows" : "Delete Row") { [weak self] in self?.deleteRow() }
        deleteRows.isEnabled = b.rows.contains { $0 > 0 }
        menu.addItem(deleteRows)
        let deleteColumns = ClosureMenuItem(cols > 1 ? "Delete \(cols) Columns" : "Delete Column") { [weak self] in self?.deleteColumn() }
        deleteColumns.isEnabled = cols < columns
        menu.addItem(deleteColumns)
        menu.addItem(ClosureMenuItem(rows * cols > 1 ? "Clear Cells" : "Clear Cell") { [weak self] in self?.clearCells() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy Table") { [weak self] in self?.copyTable() })
        menu.addItem(ClosureMenuItem("Delete Table") { [weak self] in self?.onDeleteTable?() })
        return menu
    }

    // MARK: Column resizing

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        addCursorRect(tableRect, cursor: .iBeam)
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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func updateCursor(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (divider(at: p) != nil ? NSCursor.columnResize : tableRect.contains(p) ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    private func beginResizing(_ column: Int, event: NSEvent) {
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
        onChange?(markdown, nil)
    }
}

/// The field editor shared by a table's cells. Paste and Select All reach past the
/// cell: a copied grid fills cells, and a second Select All takes the whole table.
final class CellTextView: NSTextView, MathEditingHost {
    weak var table: TableEditorView?

    /// Math is written in a cell just as in the note: shortcuts, `/` fractions, Tab
    /// through the blanks and out, and the preview card (floating over the page, so the
    /// table doesn't clip it). The keys reach it through `TableEditorView`'s commands.
    lazy var math = MathEditor(host: self)
    private var storageObserver: NSObjectProtocol?

    var mathTextView: NSTextView { self }
    var mathEnabled: Bool { table != nil }
    /// A cell is one line of a pipe table: no `$$` blocks or line breaks, no bare `|`.
    var mathSingleLine: Bool { true }
    func mathBlock(at location: Int) -> MathEditor.Block { .text }
    var mathUndoManager: UndoManager? { noteUndo }
    func mathSeparateUndo() { table?.separateNextChange() }
    var mathPreviewParent: NSView? { table?.superview }
    var mathPreviewColumn: NSRect {
        guard let page = table?.superview else { return .zero }
        guard let text = page as? NSTextView, let container = text.textContainer else { return page.bounds }
        return NSRect(origin: text.textContainerOrigin, size: container.size)
    }
    var mathFontSize: CGFloat { table.map { round($0.render.typography.size * 0.9) } ?? font?.pointSize ?? 13 }

    func insertTypedText(_ s: String) {
        super.insertText(s, replacementRange: selectedRange())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // A key typed at the caret (not text put in by a command or an input method).
        if let s = string as? String, !hasMarkedText(),
           replacementRange.location == NSNotFound || replacementRange == selectedRange(),
           math.handleInput(s) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: range, replacementString: replacementString) else { return false }
        observeStorage()
        math.pendingEdit = replacementString.map { (range, ($0 as NSString).length) }
        return true
    }

    /// Blanks move with the text as it changes around them.
    private func observeStorage() {
        guard storageObserver == nil, let storage = textStorage else { return }
        storageObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage,
                                                                 queue: nil) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.math.shiftStops(editedRange: storage.editedRange, delta: storage.changeInLength) }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        math.syncCopies()
        math.updatePreview()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        math.selectionChanged()
        math.updatePreview()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        math.drawMarks()
    }

    /// Leaving the cell leaves its equation: no blanks or preview linger.
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        math.clearStops()
        math.hidePreview()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            math.clearStops()
            math.hidePreview()
        }
    }

    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
    }

    /// Cells never record their own typing (with no undo manager there's nowhere to):
    /// the note keeps a copy of the table from before each run of typing instead, and
    /// Undo and Redo here walk the note's history like the page around the table.
    override var undoManager: UndoManager? { nil }
    private var noteUndo: UndoManager? { table?.superview?.undoManager }

    @objc func undo(_ sender: Any?) { noteUndo?.undo() }
    @objc func redo(_ sender: Any?) { noteUndo?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = noteUndo?.undoMenuItemTitle ?? "Undo"
            return noteUndo?.canUndo ?? false
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = noteUndo?.redoMenuItemTitle ?? "Redo"
            return noteUndo?.canRedo ?? false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func paste(_ sender: Any?) {
        if table?.pasteGrid(from: .general, intoText: true) == true { return }
        pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func selectAll(_ sender: Any?) {
        let length = (string as NSString).length
        if let table, selectedRange() == NSRange(location: 0, length: length) {
            table.selectAllCells()
            return
        }
        super.selectAll(sender)
    }
}

final class CellFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? CellField)?.table?.fieldEditor ?? super.fieldEditor(for: controlView)
    }
}

/// Borderless cell field that looks like the rendered cell text.
final class CellField: NSTextField {
    override class var cellClass: AnyClass? {
        get { CellFieldCell.self }
        set { super.cellClass = newValue }
    }

    weak var table: TableEditorView?
    var row = 0
    var column = 0
    /// The cell's Markdown. Shown rendered, with its markers only while being edited.
    var source = ""
    var style: ((String, Bool) -> NSAttributedString)?

    func showRendered() {
        attributedStringValue = style?(source, false) ?? NSAttributedString(string: source)
    }

    override func becomeFirstResponder() -> Bool {
        stringValue = source
        guard super.becomeFirstResponder() else { return false }
        restyleEditor()
        return true
    }

    /// Restyles the text being edited in place, so bold looks bold as it's typed.
    func restyleEditor() {
        guard let editor = currentEditor() as? NSTextView, let storage = editor.textStorage,
              let styled = style?(editor.string, true), styled.length == storage.length else { return }
        storage.beginEditing()
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
            storage.setAttributes(attrs, range: range)
        }
        storage.endEditing()
    }

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
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    var onAddRow: (() -> Void)?
    var onAddColumn: (() -> Void)?
    var onAlign: ((Int) -> Void)?
    var onDeleteRow: (() -> Void)?
    var onDeleteColumn: (() -> Void)?
    var onDeleteTable: (() -> Void)?
    var onCopyTable: (() -> Void)?
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
