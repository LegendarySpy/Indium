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

    /// Cell text as you see it while editing: Markdown, with `\|` as `|` and `<br>` as
    /// a line break (`TableSpec.escapeCell` writes them back).
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
    /// Fill Right (false) or Fill Down (true) in a cell's menu.
    var onFill: ((Bool) -> Void)?
    /// The formula a computed cell shows while it's edited, `=B2-B3` (the editor's numbering).
    var formulaOf: ((Cell) -> String?)?
    /// Text typed in a cell that isn't written to the note as it's typed: a formula, or
    /// anything typed over a computed cell. It goes in when the cell is left, with the
    /// table's results, as one step; the answer is what's wrong when it can't, and then
    /// the cell stays open. A value is already in `markdown` by then.
    var onEnter: ((Cell, String) -> String?)?
    /// The text being held back as it changes, for its preview; nil once it's gone in or
    /// was put back.
    var onDraft: (((cell: Cell, text: String)?) -> Void)?
    /// Called before `onChange` when values were typed, pasted or cleared over a block of
    /// cells: any formula there gives way to them.
    var onValuesReplaced: ((Cell, Cell) -> Void)?
    /// Called instead of `onChange` when rows or columns were inserted or deleted, with
    /// what was done, so formulas can keep pointing at the same rows and columns.
    var onStructureChange: ((String, TableFormulas.ShapeChange) -> Void)?

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
    /// Column letters and row numbers around the grid while a formula is typed.
    private let ruler = TableReferenceRuler()
    private var tableRect: NSRect { NSRect(x: 0, y: 0, width: render.width, height: render.height) }

    init(render: TableRender) {
        self.render = render
        header = render.spec.header.map(TableSpec.unescapeCell)
        body = render.spec.body.map { $0.map(TableSpec.unescapeCell) }
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
    /// Not while a formula is typed: a click on another cell then names it in the
    /// formula, and the window mustn't take the keys from the cell first.
    override var acceptsFirstResponder: Bool { !(pointing && cellEditor != nil) }

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
        TableSpec.markdown(header: header.map(TableSpec.escapeCell), body: body.map { $0.map(TableSpec.escapeCell) },
                           alignments: alignments, dashes: dashes)
    }

    /// Adopts a fresh layout after the note re-rendered the table.
    func update(render: TableRender) {
        self.render = render
        adopt(render.spec)
        setFrameSize(NSSize(width: render.width + Self.margin, height: render.height + Self.margin))
        layoutFields()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        syncFocusedFormula()
    }

    /// Takes on the note's version of the table when it changed underneath (undo, redo,
    /// another app). Text that only differs by spaces at its ends is left as typed.
    private func adopt(_ spec: TableSpec) {
        let newHeader = spec.header.map(TableSpec.unescapeCell)
        let newBody = spec.body.map { $0.map(TableSpec.unescapeCell) }
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
                if draft.map({ $0.cell == (r, c) }) ?? false { continue }
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
                // A computed cell says what it's calculated from, as in the rendered table.
                let tip = render.mark(row: r, column: c)?.tip
                if field.toolTip != tip { field.toolTip = tip }
            }
        }
        layoutRuler()
    }

    /// Cell text styled like the rendered table, equations fitted to the column the
    /// same way; `reveal` keeps the Markdown markers. A formula being typed is plain text.
    private func styled(_ text: String, row: Int, column: Int, reveal: Bool) -> NSAttributedString {
        let draw = { (t: String) in
            TableRender.render(t, header: row == 0, alignment: column < self.alignments.count ? self.alignments[column] : 0,
                               typography: self.render.typography, size: round(self.render.typography.size * 0.9), revealMarkers: reveal)
        }
        if reveal, text.hasPrefix("=") { return NSAttributedString(string: text, attributes: draw("x").attributes(at: 0, effectiveRange: nil)) }
        let styled = draw(text)
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
        render.drawMarks(in: tableRect)
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
        // The cells a formula being typed names, outlined as a spreadsheet does.
        for (a, b) in referencedAreas where b.row < render.rowHeights.count && b.column < render.columnWidths.count {
            let box = render.cellRect(row: a.row, column: a.column, in: tableRect).union(render.cellRect(row: b.row, column: b.column, in: tableRect))
                .insetBy(dx: 2, dy: 2)
            NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.25
            path.setLineDash([3, 2], count: 2, phase: 0)
            path.stroke()
        }
    }

    // MARK: Focus

    /// Edits a cell's text, with the caret at its end (or everything selected).
    func focusCell(row: Int, column: Int, selectAll: Bool = false, caretAtStart: Bool = false) {
        let r = min(max(row, 0), rowCount - 1), c = min(max(column, 0), columns - 1)
        // Leaving a cell with a formula typed in it puts the formula in, or stays when it can't.
        if let d = draft, d.cell != (r, c) { guard commitDraft() else { return } }
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
        pointRange = nil
        if draft.map({ $0.cell == (field.row, field.column) }) ?? false || field.stringValue.hasPrefix("=") {
            if draft == nil { draft = ((field.row, field.column), field.source) }
            field.restyleEditor()
            draftChanged()
            return
        }
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
        guard let field = obj.object as? CellField else { return }
        // A cell left some other way than through the table (the window closing) drops what it held.
        if let d = draft, d.cell == (field.row, field.column) { endDraft() }
        field.showRendered()
    }

    // MARK: Formulas

    /// The cell whose typing is held back from the note (see `onEnter`), and what it
    /// showed when editing began: its formula, or its value when a formula was started.
    private(set) var draft: (cell: Cell, original: String)?
    /// The reference the last click on another cell put in the formula; another click
    /// replaces it, as in a spreadsheet.
    private var pointRange: NSRange?

    /// A formula is being typed: clicks on other cells name them.
    private var pointing: Bool { draft != nil && (cellEditor?.string.hasPrefix("=") ?? false) }

    private var draftField: CellField? {
        guard let d = draft, d.cell.row < fields.count, d.cell.column < fields[d.cell.row].count else { return nil }
        return fields[d.cell.row][d.cell.column]
    }

    private var draftText: String? {
        (draftField?.currentEditor() as? NSTextView)?.string
    }

    private func draftChanged() {
        needsDisplay = true
        layoutRuler()
        onDraft?(draft.flatMap { d in draftText.map { (d.cell, $0) } })
    }

    /// Puts the held text in (see `onEnter`). False, with the cell still open, when it can't go in.
    @discardableResult
    func commitDraft() -> Bool {
        guard let d = draft else { return true }
        guard let field = draftField, let text = draftText else { endDraft(); return true }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed == d.original { endDraft(); return true }
        endDraft()
        if !typed.hasPrefix("=") {
            field.source = text
            setText(text, row: d.cell.row, column: d.cell.column)
        }
        if let problem = onEnter?(d.cell, typed) {
            draft = d
            if let editor = field.currentEditor() as? NSTextView, editor.string != text { editor.string = text }
            draftChanged()
            onProblem?(d.cell, problem)
            NSSound.beep()
            return false
        }
        return true
    }

    /// Undo while a formula is being typed puts the cell back first, as Escape does.
    func undoDraft() -> Bool {
        guard let d = draft, let text = draftText, text != d.original else { return false }
        discardDraft()
        return true
    }

    /// The cell's text as it was before the held typing.
    func discardDraft() {
        guard let d = draft else { return }
        let field = draftField
        endDraft()
        if let field, let editor = field.currentEditor() as? NSTextView {
            let original = formulaOf?(d.cell) ?? field.source
            editor.string = original
            editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
            field.restyleEditor()
            if formulaOf?(d.cell) != nil { draft = (d.cell, original) }
        }
        draftChanged()
    }

    /// Commits the held text, or, when it can't go in, puts the cell back as it was:
    /// before the table changes shape or loses the keys.
    func finishDraft() {
        if !commitDraft() { discardDraft() }
    }

    private func endDraft() {
        draft = nil
        pointRange = nil
        draftChanged()
    }

    /// A problem with the held text, for the hint under the cell.
    var onProblem: ((Cell, String) -> Void)?

    /// The focused cell starts a formula: `=` replaces its text (its formula shows if it has one).
    func startFormula() {
        let cell = selection?.anchor ?? focus
        if cellEditor == nil || draft.map({ $0.cell != cell }) ?? true { focusCell(row: cell.row, column: cell.column) }
        guard formulaOf?(cell) == nil, let editor = cellEditor as? CellTextView else { return }
        editor.selectAll(nil)
        editor.insertTypedText("=")
    }

    /// The focused cell, being edited, shows its formula when it has one: after the
    /// note changed underneath (undo, a fill), unless it's being typed in.
    private func syncFocusedFormula() {
        guard focus.row < fields.count, focus.column < fields[focus.row].count else { return }
        let field = fields[focus.row][focus.column]
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let shown = formulaOf?(focus)
        if let d = draft, d.cell == focus {
            guard editor.string == d.original, shown != d.original else { return }
        } else if shown == nil || draft != nil {
            return
        }
        let text = shown ?? field.source
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        field.restyleEditor()
        draft = shown.map { (focus, $0) }
        draftChanged()
    }

    /// Called by the cell as it starts being edited: a computed cell shows its formula.
    func editingText(for field: CellField) -> String {
        formulaOf?((field.row, field.column)) ?? field.source
    }

    func beganEditing(_ field: CellField) {
        if let formula = formulaOf?((field.row, field.column)) {
            draft = ((field.row, field.column), formula)
            draftChanged()
        }
    }

    /// True when a click on another cell should name it at the caret: right after `=`,
    /// an operator, `(`, `,` or `:`, or over the reference the last click put in.
    private func expectsReference(_ editor: NSTextView) -> Bool {
        let sel = editor.selectedRange()
        if let p = pointRange, p == sel || NSMaxRange(p) == sel.location { return true }
        let before = (editor.string as NSString).substring(to: sel.location).trimmingCharacters(in: .whitespaces)
        guard let last = before.last else { return false }
        return "=+-*/^(,:;×÷−·".contains(last)
    }

    /// Names cells `a` to `b` in the formula at the caret, over the last clicked one.
    private func insertReference(from a: Cell, to b: Cell, in editor: CellTextView) {
        let name = ExcelFormulas.name(from: TableFormulas.Cell(row: min(a.row, b.row) + 1, column: min(a.column, b.column) + 1),
                                      to: TableFormulas.Cell(row: max(a.row, b.row) + 1, column: max(a.column, b.column) + 1))
        let range = pointRange ?? editor.selectedRange()
        editor.setSelectedRange(range)
        editor.insertTypedText(name)
        pointRange = NSRange(location: range.location, length: (name as NSString).length)
    }

    /// The cells the formula being typed names, in the editor's numbering.
    var referencedAreas: [(Cell, Cell)] {
        guard pointing, let text = draftText else { return [] }
        let ns = text as NSString
        return Self.referencePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            func cell(_ i: Int) -> Cell? {
                guard m.range(at: i).location != NSNotFound else { return nil }
                let t = ns.substring(with: m.range(at: i)).replacingOccurrences(of: "$", with: "").uppercased()
                let letters = t.prefix { $0.isLetter }
                guard let row = Int(t.dropFirst(letters.count)), row >= 1 else { return nil }
                let column = letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
                return (row - 1, column - 1)
            }
            guard let a = cell(1) else { return nil }
            let b = cell(2) ?? a
            return ((min(a.row, b.row), min(a.column, b.column)), (max(a.row, b.row), max(a.column, b.column)))
        }
    }
    private static let referencePattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_$])(\$?[A-Za-z]{1,3}\$?\d+)(?::(\$?[A-Za-z]{1,3}\$?\d+))?(?![A-Za-z0-9_(])"#)

    private func layoutRuler() {
        guard pointing, let parent = superview else {
            if ruler.superview != nil { ruler.removeFromSuperview() }
            return
        }
        if ruler.superview !== parent { parent.addSubview(ruler, positioned: .above, relativeTo: self) }
        ruler.update(render: render, origin: frame.origin, focus: draft?.cell ?? focus)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        layoutRuler()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { ruler.removeFromSuperview() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? CellField else { return false }
        let (r, c) = (field.row, field.column)
        // A formula being typed: Return and Tab put it in before moving (or stay, saying
        // what's wrong), Escape puts the cell back, and the arrows move the caret only.
        if let d = draft, d.cell == (r, c), textView.string != d.original {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                guard commitDraft() else { return true }
            case #selector(NSResponder.cancelOperation(_:)):
                discardDraft()
                return true
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
                pointRange = nil
                return false
            default: break
            }
        }
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
        finishDraft()
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
        // `=` starts a formula in the cell, held back like any formula being typed.
        if typed.hasPrefix("=") {
            focusCell(row: cell.row, column: cell.column)
            guard let editor = cellEditor as? CellTextView else { return }
            editor.selectAll(nil)
            editor.insertTypedText(typed)
            return
        }
        setText(typed, row: cell.row, column: cell.column)
        fields[cell.row][cell.column].source = typed
        onValuesReplaced?(cell, cell)
        onChange?(markdown, nil)
        focusCell(row: cell.row, column: cell.column)
    }

    override func doCommand(by selector: Selector) {
        if responds(to: selector) { perform(selector, with: nil) }
    }

    func clearCells() {
        finishDraft()
        let b = targetBounds
        for r in b.rows { for c in b.columns where !text(row: r, column: c).isEmpty {
            setText("", row: r, column: c)
            fields[r][c].source = ""
            fields[r][c].showRendered()
        } }
        onValuesReplaced?((b.rows.lowerBound, b.columns.lowerBound), (b.rows.upperBound - 1, b.columns.upperBound - 1))
        onChange?(markdown, nil)
    }

    // MARK: Clipboard

    /// The table's Markdown in the note with its formula lines, for Copy Table.
    var noteSource: (() -> String?)?

    /// Selected cells only, never the formulas: Markdown for Indium, plain text and
    /// HTML for other apps. All of them selected also go out as a Markdown table.
    @objc func copy(_ sender: Any?) {
        let b = targetBounds
        let rows = b.rows.map { r in b.columns.map { c in text(row: r, column: c) } }
        let whole = b.rows == 0..<rowCount && b.columns == 0..<columns
        TableClipboard.write(rows, header: b.rows.lowerBound == 0, markdown: whole ? markdown : nil, to: TableClipboard.board)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        clearCells()
    }

    @objc func paste(_ sender: Any?) {
        _ = pasteGrid(from: TableClipboard.board, intoText: false)
    }

    /// The whole table as it is in the note, formula lines included.
    func copyTable() {
        TableClipboard.write([header + Array(repeating: "", count: max(0, columns - header.count))]
                             + body.map { $0 + Array(repeating: "", count: max(0, columns - $0.count)) },
                             header: true, markdown: noteSource?() ?? markdown, to: TableClipboard.board)
    }

    /// Pastes cells copied from a spreadsheet, a web page or another table, starting at
    /// the focused cell and growing the table to fit. One value pasted over a block of
    /// cells fills them all. While typing in a cell, a single value pastes as text.
    func pasteGrid(from pb: NSPasteboard, intoText: Bool) -> Bool {
        guard let grid = TableClipboard.grid(from: pb, lines: !intoText), !grid.isEmpty else { return false }
        let width = grid.map(\.count).max() ?? 0
        guard width > 0 else { return false }
        if intoText, grid.count == 1, width == 1 { return false }
        finishDraft()
        let b = targetBounds
        let origin: Cell = (b.rows.lowerBound, b.columns.lowerBound)
        if grid.count == 1, width == 1 {
            for r in b.rows { for c in b.columns { setText(grid[0][0], row: r, column: c) } }
        } else {
            while rowCount < origin.row + grid.count { body.append(Array(repeating: "", count: columns)) }
            while columns < origin.column + width { insertColumn(at: columns) }
            for (i, row) in grid.enumerated() {
                // Line breaks stay (written as `<br>`).
                for (j, value) in row.enumerated() { setText(value, row: origin.row + i, column: origin.column + j) }
            }
        }
        let reach: Cell = grid.count == 1 && width == 1 ? (b.rows.upperBound - 1, b.columns.upperBound - 1)
                                                        : (origin.row + grid.count - 1, origin.column + width - 1)
        onValuesReplaced?(origin, reach)
        commitStructure()
        if reach == origin { focusCell(row: origin.row, column: origin.column) } else { select(from: origin, to: reach) }
        return true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(selectAll(_:)): return true
        case #selector(paste(_:)): return TableClipboard.canPaste(TableClipboard.board)
        default: return responds(to: item.action)
        }
    }

    // MARK: Structure

    func addColumnAtEnd() {
        finishDraft()
        addColumn(right: columns - 1)
        focusCell(row: 0, column: columns - 1)
    }

    func addRowAtEnd() {
        finishDraft()
        body.append(Array(repeating: "", count: columns))
        commitStructure(.insertRows(at: rowCount, count: 1))
        focusCell(row: rowCount - 1, column: 0)
    }

    /// Adds a row under `row` (the focused row by default) and keeps the cursor where it was.
    func addRow(below row: Int? = nil) {
        finishDraft()
        let index = min(row ?? targetBounds.rows.upperBound - 1, rowCount - 1)
        body.insert(Array(repeating: "", count: columns), at: index)
        commitStructure(.insertRows(at: index + 2, count: 1))
    }

    /// A row above the header would take its place; it goes under it instead.
    func addRow(above row: Int? = nil) {
        finishDraft()
        let index = max((row ?? targetBounds.rows.lowerBound) - 1, 0)
        body.insert(Array(repeating: "", count: columns), at: index)
        commitStructure(.insertRows(at: index + 2, count: 1))
        if (row ?? targetBounds.rows.lowerBound) > 0 { focusCell(row: index + 1, column: focus.column) }
    }

    func addColumn(right column: Int? = nil) {
        finishDraft()
        let index = min((column ?? targetBounds.columns.upperBound - 1) + 1, columns)
        insertColumn(at: index)
        commitStructure(.insertColumns(at: index + 1, count: 1))
        focusCell(row: focus.row, column: index)
    }

    func addColumn(left column: Int? = nil) {
        finishDraft()
        let index = column ?? targetBounds.columns.lowerBound
        insertColumn(at: index)
        commitStructure(.insertColumns(at: index + 1, count: 1))
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
        finishDraft()
        let rows = targetBounds.rows.filter { $0 > 0 }
        guard !rows.isEmpty else { NSSound.beep(); return }
        for r in rows.reversed() { body.remove(at: r - 1) }
        commitStructure(.deleteRows(at: rows.first! + 1, count: rows.count))
        focusCell(row: min(rows.first!, rowCount - 1), column: focus.column)
    }

    func deleteColumn() {
        finishDraft()
        let cols = targetBounds.columns
        guard cols.count < columns else { NSSound.beep(); return }
        for c in cols.reversed() {
            if c < header.count { header.remove(at: c) }
            for i in body.indices where c < body[i].count { body[i].remove(at: c) }
            if c < alignments.count { alignments.remove(at: c) }
            if var d = dashes, c < d.count { d.remove(at: c); dashes = d }
        }
        commitStructure(.deleteColumns(at: cols.lowerBound + 1, count: cols.count))
        focusCell(row: focus.row, column: min(cols.lowerBound, columns - 1))
    }

    func align(_ alignment: Int) {
        finishDraft()
        while alignments.count < columns { alignments.append(0) }
        for c in targetBounds.columns { alignments[c] = alignment }
        let kept = selection
        commitStructure()
        if let kept { select(from: kept.anchor, to: kept.head) } else { focusCell(row: focus.row, column: focus.column) }
    }

    /// `change` in TBLFM numbering (row 1 the header, column 1 the leftmost).
    private func commitStructure(_ change: TableFormulas.ShapeChange? = nil) {
        selection = nil
        if let change, let onStructureChange { onStructureChange(markdown, change) } else { onChange?(markdown, nil) }
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
        // Typing a formula, a click on another cell names it (a drag, a range of cells).
        if let d = draft, start != d.cell, let editor = cellEditor as? CellTextView, pointing, expectsReference(editor) {
            insertReference(from: start, to: start, in: editor)
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
                autoscroll(with: next)
                insertReference(from: start, to: nearestCell(to: next) ?? start, in: editor)
            }
            return
        }
        if event.modifierFlags.contains(.shift) {
            select(from: selection?.anchor ?? focus, to: start)
            return
        }
        focusCell(row: start.row, column: start.column)
        guard focus == start, let editor = cellEditor else { return }
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
            let over = nearestCell(to: next) ?? start
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

    /// The cell under a drag, or the edge cell nearest to it once it leaves the grid.
    private func nearestCell(to event: NSEvent) -> Cell? {
        let p = convert(event.locationInWindow, from: nil)
        return render.cell(at: NSPoint(x: min(max(p.x, 0), max(render.width - 1, 0)), y: min(max(p.y, 0), max(render.height - 1, 0))))
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
        let computed = formulaOf?(selection?.anchor ?? focus) != nil
        menu.addItem(ClosureMenuItem(computed ? "Edit Formula" : "Add Formula") { [weak self] in self?.startFormula() })
        let right = ClosureMenuItem("Fill Formula Right") { [weak self] in self?.onFill?(false) }
        right.isEnabled = computed
        menu.addItem(right)
        let down = ClosureMenuItem("Fill Formula Down") { [weak self] in self?.onFill?(true) }
        down.isEnabled = computed
        menu.addItem(down)
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

    // Only our own area is replaced: the view's other tracking areas belong to its tooltips.
    private var cursorArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        cursorArea = area
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
