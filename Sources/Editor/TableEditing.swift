import AppKit

/// Editing tables in place: the table editor and its toolbar, formulas typed in cells,
/// recalculation, and the frontmatter variables formulas read.
extension EditorController {
    // MARK: Table editing

    /// A table's layout, where its grid sits, and the column it lives in (the page column,
    /// or its cell in a side-by-side layout), all in view coordinates.
    private func tableLayout(at location: Int) -> (TableRender, NSRect, column: NSRect)? {
        guard textView.textContainer != nil, location < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
        for block in layoutManager.blockRects(in: NSRange(location: location, length: 1), origin: textView.textContainerOrigin) {
            if case let .table(render) = block.decoration.content { return (render, block.content, tableColumn(of: block)) }
        }
        return nil
    }

    /// The page column, in view coordinates.
    var pageColumn: NSRect {
        let width = (textView.textContainer?.size.width ?? 0) - layoutManager.gutter * 2
        return NSRect(x: textView.textContainerOrigin.x + layoutManager.gutter, y: 0, width: max(width, 0), height: textView.bounds.height)
    }

    /// The column a table block belongs to. A floating table's area is the table itself;
    /// its column is the page's.
    func tableColumn(of block: (decoration: BlockDecoration, range: NSRange, area: NSRect, content: NSRect)) -> NSRect {
        if case .float = block.decoration.placement { return pageColumn }
        return block.area
    }

    /// Whether the add-column and add-row strips fit outside a table: there must be room
    /// right of it in its column (a full-width table may use some of the page margin),
    /// and text wraps right up against a floating table, so its strips stay inside.
    func tableStripRoom(table: NSRect, column: NSRect, floating: Bool) -> (right: Bool, below: Bool) {
        guard !floating else { return (false, false) }
        let page = pageColumn
        let limit = abs(column.maxX - page.maxX) < 1 ? page.maxX + layoutManager.gutter / 2 : column.maxX
        return (table.maxX + TableEdgeStrip.outset <= limit, true)
    }

    /// A caret that lands inside a table (arrow keys, clicks beside it) edits a cell
    /// rather than the table's Markdown.
    func openTableEditorIfCaretEntered(_ selection: [NSRange]) -> Bool {
        guard AppSettings.shared.syntax != .always, tableEditor == nil, let sel = selection.first, sel.length == 0,
              let i = styler.blockIndex(containing: sel.location), case let .table(spec) = styler.blocks[i].kind else { return false }
        let block = styler.blocks[i]
        let offset = sel.location - block.range.location
        guard offset > 0, offset < block.range.length - 1 else { return false }
        var row = 0, column = 0
        for (r, cells) in spec.rows.enumerated() {
            for (c, cell) in cells.enumerated() where cell.offset <= offset { row = r; column = c }
        }
        let comingFromBelow = (lastSelection.first?.location ?? 0) > NSMaxRange(block.range)
        DispatchQueue.main.async {
            self.beginTableEditing(at: block.range.location, row: comingFromBelow ? spec.rows.count - 1 : row, column: column)
        }
        return true
    }

    func beginTableEditing(at location: Int, row: Int, column: Int) {
        endTableEditing()
        math.hidePreview()
        styler.editingTableLocation = location
        styler.restyleBlock(at: location, in: storage)
        updateFloats()
        guard let (render, rect, columnRect) = tableLayout(at: location) else {
            styler.editingTableLocation = nil
            return
        }
        hideTableStrips()
        // The columns hold these widths until editing ends, so typing never reshuffles them.
        styler.editingTableWidths = render.columnWidths
        let floatSide = styler.blockIndex(containing: location).flatMap { styler.floatOfBlock[$0] }
        let editor = TableEditorView(render: render)
        editor.anchoredRight = floatSide == true
        editor.floating = floatSide != nil
        layoutManager.hiddenFloat = floatSide != nil ? location : nil
        editor.frame.origin = rect.origin
        tableColumnRect = columnRect
        editor.stripRoom = tableStripRoom(table: rect, column: columnRect, floating: floatSide != nil)
        editor.onChange = { [weak self] markdown, cell in self?.commitTable(markdown, typingIn: cell) }
        editor.onStructureChange = { [weak self] markdown, shape in self?.commitTable(markdown, typingIn: nil, shape: shape) }
        editor.onExit = { [weak self] in self?.endTableEditing(caretAfter: true) }
        editor.onLeave = { [weak self] down in
            guard let self else { return }
            if down { self.endTableEditing(caretAfter: true) } else { self.endTableEditing(caretBefore: true) }
        }
        editor.onFocusChange = { [weak self] cell in self?.tableFocusChanged(cell) }
        editor.onDeleteTable = { [weak self] in self?.deleteEditedTable() }
        editor.formulaOf = { [weak self] cell in self?.formula(at: cell) }
        editor.onEnter = { [weak self] cell, text in self?.enterInTable(text, at: cell) }
        editor.onDraft = { [weak self] draft in self?.formulaDraftChanged(draft) }
        editor.onProblem = { [weak self] cell, problem in self?.showFormulaHint(problem, isError: true, help: "", at: cell) }
        editor.onValuesReplaced = { [weak self] a, b in self?.tableValuesReplaced = (a, b) }
        editor.onFill = { [weak self] down in self?.fillTableFormula(down: down) }
        editor.noteSource = { [weak self] in
            guard let self, let at = self.styler.editingTableLocation, let range = self.tableSource(at: at) else { return nil }
            return self.ns.substring(with: range)
        }
        textView.addSubview(editor)
        tableEditor = editor

        let bar = TableToolbarView(frame: .zero)
        bar.onAddRow = { [weak editor] in
            guard let editor else { return }
            editor.addRow(below: nil)
            editor.focusCell(row: editor.focus.row + 1, column: editor.focus.column)
        }
        bar.onAddColumn = { [weak editor] in editor?.addColumn(right: nil) }
        bar.onCopyTable = { [weak editor] in editor?.copyTable() }
        bar.onAlign = { [weak editor] a in editor?.align(a) }
        bar.onDeleteRow = { [weak editor] in editor?.deleteRow() }
        bar.onDeleteColumn = { [weak editor] in editor?.deleteColumn() }
        bar.onDeleteTable = { [weak self] in self?.deleteEditedTable() }
        bar.onDone = { [weak self] in self?.endTableEditing(caretAfter: true) }
        bar.placement = floatSide
        bar.onPlace = { [weak self] side in self?.placeEditedTable(float: side) }
        bar.onFormula = { [weak editor] in editor?.startFormula() }
        bar.onFill = { [weak self] down in self?.fillTableFormula(down: down) }
        bar.canFill = { [weak self, weak editor] in
            guard let self, let editor else { return false }
            return self.formula(at: editor.selection?.anchor ?? editor.focus) != nil
        }
        textView.addSubview(bar)
        tableToolbar = bar
        positionTableToolbar()
        // Scrolling through a tall table carries the bar along its visible part.
        scrollView.contentView.postsBoundsChangedNotifications = true
        tableScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionTableToolbar() }
        }
        bar.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; bar.animator().alphaValue = 1 }
        editor.focusCell(row: row, column: column)
    }

    /// Puts the toolbar right-aligned over its own table and inside the table's column:
    /// above the table where that space is empty, else below it, else along the top of
    /// the view over the table's visible part (scrolled into a tall table). It only
    /// covers neighbouring text when the table is hemmed in on both sides.
    private func positionTableToolbar() {
        guard let editor = tableEditor, let bar = tableToolbar, let location = styler.editingTableLocation else { return }
        let table = NSRect(origin: editor.frame.origin, size: NSSize(width: editor.render.width, height: editor.render.height))
        let column = tableColumnRect.width > 0 ? tableColumnRect : table
        bar.fit(width: column.width)
        let size = bar.frame.size
        let x = round(max(column.minX, min(table.maxX, column.maxX) - size.width))
        func at(_ y: CGFloat) -> NSRect { NSRect(x: x, y: round(y), width: size.width, height: size.height) }
        // The page fades out over its top 46 points (DocumentWindowController); the bar
        // stays clear of that.
        var visible = textView.visibleRect.insetBy(dx: 0, dy: 4)
        visible.origin.y += 40
        visible.size.height -= 40
        var range = NSRange(location: location, length: 0)
        // Below the table, the bar also clears its formulas' caption ("ƒ 3 formulas").
        var bottom = table.maxY + (editor.stripRoom.below ? TableEdgeStrip.outset : 0)
        if let i = styler.blockIndex(containing: location) {
            range = styler.blocks[i].range
            if i + 1 < styler.blocks.count, case .tableFormulas = styler.blocks[i + 1].kind {
                let formulas = styler.blocks[i + 1].range
                range = NSUnionRange(range, formulas)
                let glyphs = layoutManager.glyphRange(forCharacterRange: formulas, actualCharacterRange: nil)
                layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, _, _ in
                    bottom = max(bottom, line.maxY + self.textView.textContainerOrigin.y)
                }
            }
        }
        // Roomy spots first, then the same ones snug against the grid (below, it clears
        // the add-row strip and the caption).
        let spots = [(at(table.minY - size.height - 8), 6.0), (at(bottom + 6), 6.0),
                     (at(table.minY - size.height - 3), 1.0), (at(bottom + 2), 1.0)]
        if let spot = spots.first(where: { visible.contains($0.0) && tableToolbarRoomIsFree($0.0.insetBy(dx: 0, dy: -$0.1), table: range) }) {
            bar.frame = spot.0
        } else if table.minY < visible.minY + size.height + 8 {
            bar.frame = at(min(max(visible.minY, table.minY), table.maxY - size.height))
        } else {
            bar.frame = spots[2].0
        }
    }

    /// True when no text or rendered block other than the edited table lies under `rect`.
    private func tableToolbarRoomIsFree(_ rect: NSRect, table: NSRange) -> Bool {
        guard let container = textView.textContainer else { return true }
        let origin = textView.textContainerOrigin
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        for (location, frame) in layoutManager.floatFrames where !NSLocationInRange(location, table) && frame.intersects(local) { return false }
        let glyphs = layoutManager.glyphRange(forBoundingRect: local, in: container)
        var free = true
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { line, used, _, range, stop in
            guard line.height > 1 else { return }
            let chars = self.layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            guard NSIntersectionRange(chars, table).length == 0, chars.location < self.storage.length else { return }
            // Text takes the room it's set in; a rendered block (its source hidden) its whole line.
            var occupied = NSRect.zero
            self.storage.enumerateAttributes(in: chars) { attrs, run, _ in
                if attrs[.mdBlock] != nil { occupied = occupied.union(line) }
                let text = attrs[.mdHidden] != nil ? "" : self.ns.substring(with: run).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { occupied = occupied.union(used) }
            }
            if occupied.intersects(local) {
                free = false
                stop.pointee = true
            }
        }
        return free
    }

    /// A table editor cell (header row 0, first column 0) in TBLFM numbering (both from 1).
    private static func formulaCell(_ cell: TableEditorView.Cell) -> TableFormulas.Cell {
        TableFormulas.Cell(row: cell.row + 1, column: cell.column + 1)
    }

    /// Block `i`'s range, with the formula lines right under it when there are some.
    private func rangeWithFormulas(ofBlock i: Int) -> NSRange {
        let range = styler.blocks[i].range
        guard i + 1 < styler.blocks.count, case .tableFormulas = styler.blocks[i + 1].kind else { return range }
        return NSUnionRange(range, styler.blocks[i + 1].range)
    }

    /// A table's Markdown with its formula lines, without the line break after them.
    private func tableSource(at location: Int) -> NSRange? {
        guard let i = styler.blockIndex(containing: location), case .table = styler.blocks[i].kind else { return nil }
        var range = rangeWithFormulas(ofBlock: i)
        while range.length > 0, [0x0A, 0x0D].contains(ns.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        return range
    }

    /// `tableSource` split into the table and its formula lines.
    private func tableParts(at location: Int) -> (range: NSRange, table: String, formulas: [String])? {
        guard let range = tableSource(at: location) else { return nil }
        let lines = ns.substring(with: range).components(separatedBy: "\n")
        let split = lines.firstIndex { MarkdownScanner.isTableFormulaLine($0) } ?? lines.count
        return (range, lines[..<split].joined(separator: "\n"), Array(lines[split...]))
    }

    private static func joined(_ table: String, _ formulas: [String]) -> String {
        ([table] + formulas).joined(separator: "\n")
    }

    /// Writes the table editor's Markdown back. A change of shape (rows or columns
    /// inserted or deleted) moves the formulas' references along and recalculates;
    /// typing recalculates when the cell is left (`recalculateEditedTable`). Either way
    /// the results join the edit's undo step, which restores table and formulas whole.
    private func commitTable(_ markdown: String, typingIn cell: TableEditorView.Cell?, shape: TableFormulas.ShapeChange? = nil) {
        guard let location = styler.editingTableLocation, let parts = tableParts(at: location) else { return }
        let old = ns.substring(with: parts.range)
        var table = markdown, formulas = parts.formulas
        if let (a, b) = tableValuesReplaced, !formulas.isEmpty, let grid = TableFormulaUI.grid(of: parts.table)?.grid {
            formulas = ExcelFormulas.removing(from: Self.formulaCell(a), to: Self.formulaCell(b), in: formulas, grid: grid)
        }
        tableValuesReplaced = nil
        if cell == nil, !formulas.isEmpty {
            if let shape { formulas = TableFormulas.adjust(formulas, for: shape) }
            table = TableFormulaUI.recalculate(tableMarkdown: markdown, formulaLines: formulas, noteText: storage.string)
        }
        tableFormulasPending = cell != nil && !formulas.isEmpty
        let new = Self.joined(table, formulas)
        guard old != new else { return }
        // Widths the editor holds (or was just dragged to) carry into the new layout.
        if let widths = tableEditor?.render.columnWidths { styler.editingTableWidths = widths }
        let continuing = cell != nil && tableTypingCell?.row == cell?.row && tableTypingCell?.column == cell?.column
        tableTypingCell = cell
        if !continuing { registerTableUndo(at: parts.range.location, restoring: old) }
        replaceWithoutUndo(parts.range, with: new)
        refreshTableEditor()
    }

    // MARK: Frontmatter variables

    /// What one undo step puts back: the note's text up to `suffix` characters from its end.
    final class RegionRestore {
        var text: String
        var suffix: Int
        init(text: String, suffix: Int) { self.text = text; self.suffix = suffix }
    }

    /// A run of edits inside the frontmatter. Its first edit registers one undo step that
    /// restores the frontmatter as it started; the edits after it register nothing. When it
    /// ends, tables reading a changed variable are recalculated into that same step.
    struct FrontmatterSession {
        let before: String
        let restore: RegionRestore
    }

    var frontmatterRange: NSRange? {
        guard let first = styler.blocks.first, case .frontmatter = first.kind else { return nil }
        return first.range
    }

    var caretInFrontmatter: Bool {
        guard let range = frontmatterRange else { return false }
        return textView.selectedRanges.allSatisfy { NSLocationInRange($0.rangeValue.location, range) }
    }

    /// Called before every edit: one inside the frontmatter joins (or starts) the session,
    /// any other ends it, without recalculating (the caption then says the values are stale).
    func frontmatterWillChange(_ range: NSRange) {
        guard !isLoading, let undo = textView.undoManager, !undo.isUndoing, !undo.isRedoing, undo.isUndoRegistrationEnabled else { return }
        guard let fm = frontmatterRange, range.location < NSMaxRange(fm), NSMaxRange(range) <= NSMaxRange(fm) else {
            frontmatterSession = nil
            return
        }
        if frontmatterSession == nil {
            let restore = RegionRestore(text: ns.substring(with: fm), suffix: storage.length - NSMaxRange(fm))
            frontmatterSession = FrontmatterSession(before: restore.text, restore: restore)
            registerRegionUndo(restore)
        }
        undo.disableUndoRegistration()
        frontmatterEditUnrecorded = true
    }

    func recordEditsAgain() {
        guard frontmatterEditUnrecorded else { return }
        frontmatterEditUnrecorded = false
        textView.undoManager?.enableUndoRegistration()
    }

    /// Undo puts back the start of the note as `restore` holds it, and redo the other way round.
    private func registerRegionUndo(_ restore: RegionRestore) {
        guard let undo = textView.undoManager else { return }
        undo.registerUndo(withTarget: self) { controller in
            controller.frontmatterSession = nil
            controller.recordEditsAgain()
            let range = NSRange(location: 0, length: max(0, controller.storage.length - restore.suffix))
            controller.registerRegionUndo(RegionRestore(text: controller.ns.substring(with: range), suffix: restore.suffix))
            controller.replaceWithoutUndo(range, with: restore.text)
        }
        undo.setActionName("Typing")
    }

    /// The frontmatter edit is done (the caret left it, or the note is saved or closed):
    /// tables whose formulas read a variable that changed are recalculated, and the
    /// session's undo step grows to cover them.
    func endFrontmatterSession() {
        recordEditsAgain()
        guard let session = frontmatterSession else { return }
        frontmatterSession = nil
        guard let fm = frontmatterRange else { return }
        let old = NoteVariables.parse(noteText: session.before), new = NoteVariables.parse(noteText: ns.substring(with: fm))
        let changed = Set(old.values.keys).union(new.values.keys).filter { old.values[$0]?.formatted() != new.values[$0]?.formatted() }
        guard !changed.isEmpty else { return }
        var tables: [(range: NSRange, text: String)] = []   // last first
        for block in styler.blocks.reversed() {
            guard case .table = block.kind, let parts = tableParts(at: block.range.location),
                  parts.formulas.contains(where: { !TableFormulaUI.names(in: $0).isDisjoint(with: changed) }) else { continue }
            let table = TableFormulaUI.recalculate(tableMarkdown: parts.table, formulaLines: parts.formulas, noteText: storage.string)
            if table != parts.table { tables.append((parts.range, Self.joined(table, parts.formulas))) }
        }
        guard let last = tables.first else { return }
        let end = NSMaxRange(last.range)
        session.restore.text = session.before + ns.substring(with: NSRange(location: NSMaxRange(fm), length: end - NSMaxRange(fm)))
        session.restore.suffix = storage.length - end
        for t in tables { replaceWithoutUndo(t.range, with: t.text) }
    }

    /// The formula caption under `point`: where its formula lines start, the rect of its
    /// words (view coordinates), and whether the point is on its link (Recalculate).
    func caption(at point: NSPoint) -> (formulas: Int, rect: NSRect, onAction: Bool)? {
        guard let container = textView.textContainer, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textView.textContainerOrigin.x, y: point.y - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: container)
        var line = NSRange()
        let frag = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        guard frag.contains(local) else { return nil }
        // The caption sits on the line's hidden source, whose glyphs take no room: the line's first.
        let index = layoutManager.characterIndexForGlyph(at: line.location)
        guard index < storage.length, let caption = storage.attribute(.mdCaption, at: index, effectiveRange: nil) as? CaptionDecoration,
              let i = styler.blockIndex(containing: index) else { return nil }
        // Measured as MarkdownLayoutManager draws it: the text, then " · " and the link.
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        let x = layoutManager.contentColumn(glyph: line.location, container: container, origin: textView.textContainerOrigin).x
        let words = (caption.text as NSString).size(withAttributes: font).width
        let linkX = x + ((caption.text + " · ") as NSString).size(withAttributes: font).width
        let end = caption.action.map { linkX + ($0 as NSString).size(withAttributes: font).width } ?? x + words
        guard point.x >= x - 2, point.x <= end + 2 else { return nil }
        let rect = NSRect(x: x, y: frag.minY + textView.textContainerOrigin.y, width: words, height: frag.height)
        return (styler.blocks[i].range.location, rect, caption.action != nil && point.x >= linkX - 2)
    }

    /// The formulas under a table, one per row in plain words, each with Edit: the
    /// caption's popover.
    func showFormulaList(formulasAt location: Int, from rect: NSRect) {
        guard location > 0, let parts = tableParts(at: location - 1), let i = styler.blockIndex(containing: location - 1),
              let grid = TableFormulaUI.grid(of: parts.table)?.grid else { return }
        let table = styler.blocks[i].range.location
        let rows = TableFormulaUI.summaries(grid: grid, formulaLines: parts.formulas)
        let list = TableFormulaListPopover(rows: rows.map { ($0.text, $0.cell != nil) })
        let popover = NSPopover()
        list.presentingPopover = popover
        list.onEdit = { [weak self] n in
            guard let self else { return }
            if let cell = rows[n].cell {
                self.beginTableEditing(at: table, row: cell.row - 1, column: cell.column - 1)
            } else {
                self.revealFormulaLine(rows[n].line, formulasAt: location)
            }
        }
        list.onShowSource = { [weak self] in self?.revealFormulaLine(0, formulasAt: location) }
        popover.contentViewController = list
        popover.behavior = .transient
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        formulaListPopover = popover
    }

    /// The caret at the start of a formula line, which shows the lines as source.
    private func revealFormulaLine(_ n: Int, formulasAt location: Int) {
        guard let i = styler.blockIndex(containing: location) else { return }
        let block = styler.blocks[i].range
        var at = block.location
        for _ in 0..<n {
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: at, length: 0)))
            guard next < NSMaxRange(block) else { break }
            at = next
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: at, length: 0))
    }

    // MARK: Computed cells

    func updateCellTips() {
        var tips: [(NSRect, String)] = []
        for block in visibleBlocks() {
            guard case let .table(table) = block.decoration.content, block.decoration.placement != .below else { continue }
            for (cell, mark) in table.marks.sorted(by: { ($0.key.row, $0.key.column) < ($1.key.row, $1.key.column) })
            where cell.row < table.rowHeights.count && cell.column < table.columnWidths.count {
                tips.append((table.cellRect(row: cell.row, column: cell.column, in: block.content), mark.tip))
            }
        }
        let key = tips.map { "\(NSStringFromRect($0.0))\u{1}\($0.1)" }
        guard key != cellTipKey else { return }
        cellTipKey = key
        cellTips.forEach { textView.removeToolTip($0.tag) }
        cellTips = tips.map { rect, text in
            let owner = CellTip(text)
            return (textView.addToolTip(rect, owner: owner, userData: nil), owner)
        }
    }

    #if DEBUG
    var cellTipCount: Int { cellTips.count }

    /// The tooltip text of a computed cell under `point` on the rendered page.
    func cellTip(at point: NSPoint) -> String? {
        for block in visibleBlocks() {
            guard case let .table(table) = block.decoration.content else { continue }
            let local = NSPoint(x: point.x - block.content.minX, y: point.y - block.content.minY)
            if let cell = table.cell(at: local), let mark = table.mark(row: cell.row, column: cell.column) { return mark.tip }
        }
        return nil
    }
    #endif

    // MARK: Typing formulas

    /// The formula a cell of the edited table shows while it's edited (`=B2-B3`), from the note.
    private func formula(at cell: TableEditorView.Cell) -> String? {
        guard let location = styler.editingTableLocation, let parts = tableParts(at: location), !parts.formulas.isEmpty,
              let grid = TableFormulaUI.grid(of: parts.table)?.grid else { return nil }
        return ExcelFormulas.formula(at: Self.formulaCell(cell), grid: grid, formulaLines: parts.formulas)
    }

    /// A formula typed in a cell, or a value typed over a computed one, goes into the note
    /// with the table's results: one undo step. What's wrong instead, when it can't.
    private func enterInTable(_ text: String, at cell: TableEditorView.Cell) -> String? {
        recalculateEditedTable()
        guard let editor = tableEditor, let location = styler.editingTableLocation, let parts = tableParts(at: location),
              let grid = TableFormulaUI.grid(of: parts.table)?.grid else { return nil }
        let at = Self.formulaCell(cell)
        guard text.hasPrefix("=") else {
            let formulas = ExcelFormulas.removing(from: at, to: at, in: parts.formulas, grid: grid)
            setTableFormulas(formulas, table: editor.markdown, actionName: "Typing")
            return nil
        }
        switch ExcelFormulas.entering(text, in: at, grid: grid, formulaLines: parts.formulas, variables: NoteVariables.parse(noteText: storage.string)) {
        case .failure(let e): return ExcelFormulas.message(e)
        case .success(let formulas):
            setTableFormulas(formulas, table: editor.markdown, actionName: "Formula")
            return nil
        }
    }

    /// Fill Right or Fill Down from the focused cell, to the end of its row or column, or
    /// across the selected cells.
    func fillTableFormula(down: Bool) {
        guard let editor = tableEditor else { return }
        editor.finishDraft()
        recalculateEditedTable()
        guard let location = styler.editingTableLocation, let parts = tableParts(at: location),
              let grid = TableFormulaUI.grid(of: parts.table)?.grid else { return }
        let from: TableEditorView.Cell = editor.selection.map { s in (min(s.anchor.row, s.head.row), min(s.anchor.column, s.head.column)) } ?? editor.focus
        let to = editor.selection.map { s in down ? max(s.anchor.row, s.head.row) : max(s.anchor.column, s.head.column) }
        let through = to.flatMap { $0 > (down ? from.row : from.column) ? $0 + 1 : nil }
        switch ExcelFormulas.filling(from: Self.formulaCell(from), down: down, through: through,
                                     grid: grid, formulaLines: parts.formulas, variables: NoteVariables.parse(noteText: storage.string)) {
        case .failure(let e):
            NSSound.beep()
            showFormulaHint(ExcelFormulas.message(e), isError: true, help: "", at: from)
        case .success(let formulas):
            setTableFormulas(formulas, table: editor.markdown, actionName: down ? "Fill Down" : "Fill Right")
        }
    }

    /// The formula being typed changed: the hint follows it, and the cell's row is
    /// measured with the formula's text so none of it is cut off.
    private func formulaDraftChanged(_ draft: (cell: TableEditorView.Cell, text: String)?) {
        if styler.editingTableCellText != draft?.text, let location = styler.editingTableLocation, location < storage.length {
            styler.editingTableCellText = draft?.text
            styler.restyleBlock(at: location, in: storage)
            refreshTableEditor()
        }
        guard let draft, let location = styler.editingTableLocation, let parts = tableParts(at: location),
              let grid = TableFormulaUI.grid(of: parts.table)?.grid else { return hideFormulaHint() }
        let at = Self.formulaCell(draft.cell)
        let stored = ExcelFormulas.formula(at: at, grid: grid, formulaLines: parts.formulas)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("=") else {
            if stored != nil { showFormulaHint("Typing a value replaces the formula", isError: false, help: "Esc puts the formula back.", at: draft.cell) }
            else { hideFormulaHint() }
            return
        }
        let help = "Click a cell to put it in the formula. Return to finish, Esc to cancel."
        let variables = NoteVariables.parse(noteText: storage.string)
        switch ExcelFormulas.entering(text, in: at, grid: grid, formulaLines: parts.formulas, variables: variables) {
        case .failure(let e):
            showFormulaHint(ExcelFormulas.message(e), isError: false, help: help, at: draft.cell)
        case .success(let formulas):
            let outcome = TableFormulas.evaluate(grid: grid, formulaLines: formulas, variables: variables)
            let name = ExcelFormulas.name(at)
            let value: String
            var isError = false
            if let issue = outcome.issues.first(where: { $0.cell == at }) {
                value = ExcelFormulas.message(issue.error)
                isError = true
            } else if outcome.blanks.contains(at) { value = "\(name) stays blank until the cells it uses have values" }
            else if outcome.succeeded { value = "\(name) = \(outcome.grid[at.row - 1][at.column - 1])" }
            else { value = "\(name): another formula in this table has a problem, so its values aren't updated" }
            var about = help
            // Not changed yet: what the formula works out, in the table's words.
            if text == stored, let i = TableFormulas.targets(grid: grid, formulaLines: parts.formulas)[at] {
                about = TableFormulaUI.plainWords(TableFormulas.parse(formulaLines: parts.formulas)[i].text, grid: grid).map { "= " + $0.source } ?? ""
            }
            showFormulaHint(value, isError: isError, help: about, at: draft.cell)
        }
    }

    private func showFormulaHint(_ text: String, isError: Bool, help: String, at cell: TableEditorView.Cell) {
        let hint = formulaHint ?? TableFormulaHint()
        hint.show(text, isError: isError, help: help)
        if hint.superview == nil { textView.addSubview(hint) }
        formulaHint = hint
        formulaHintCell = cell
        positionFormulaHint()
    }

    private func hideFormulaHint() {
        formulaHint?.removeFromSuperview()
        formulaHint = nil
        formulaHintCell = nil
    }

    private func positionFormulaHint() {
        guard let hint = formulaHint, let cell = formulaHintCell, let editor = tableEditor,
              cell.row < editor.render.rowHeights.count, cell.column < editor.render.columnWidths.count else { return }
        let table = NSRect(origin: editor.frame.origin, size: NSSize(width: editor.render.width, height: editor.render.height))
        let box = editor.render.cellRect(row: cell.row, column: cell.column, in: table)
        hint.layoutSubtreeIfNeeded()
        let size = hint.fittingSize
        let x = min(max(box.minX, table.minX), max(table.maxX - size.width, table.minX))
        hint.frame = NSRect(x: round(x), y: round(box.maxY + 4), width: ceil(size.width), height: ceil(size.height))
    }

    /// Recalculate under a table whose stored results are out of date: one undo step.
    /// On any problem nothing changes (the caption says what).
    func recalculateFormulas(at formulasLocation: Int) {
        guard formulasLocation > 0, let parts = tableParts(at: formulasLocation - 1) else { return }
        let table = TableFormulaUI.recalculate(tableMarkdown: parts.table, formulaLines: parts.formulas, noteText: storage.string)
        guard table != parts.table else { return }
        registerTableUndo(at: parts.range.location, restoring: ns.substring(with: parts.range))
        textView.undoManager?.setActionName("Recalculate Formulas")
        replaceWithoutUndo(parts.range, with: Self.joined(table, parts.formulas))
    }

    /// After typing in a cell: the formulas' results, in the typing's undo step.
    func recalculateEditedTable() {
        guard tableFormulasPending else { return }
        tableFormulasPending = false
        guard let location = styler.editingTableLocation, let parts = tableParts(at: location), !parts.formulas.isEmpty else { return }
        let table = TableFormulaUI.recalculate(tableMarkdown: parts.table, formulaLines: parts.formulas, noteText: storage.string)
        guard table != parts.table else { return }
        replaceWithoutUndo(parts.range, with: Self.joined(table, parts.formulas))
        refreshTableEditor()
    }

    /// Undo puts back the whole table as it was, and redo the other way round.
    private func registerTableUndo(at location: Int, restoring markdown: String) {
        guard let undo = textView.undoManager else { return }
        undo.registerUndo(withTarget: self) { controller in
            guard let range = controller.tableSource(at: location) else { return }
            controller.registerTableUndo(at: range.location, restoring: controller.ns.substring(with: range))
            controller.tableTypingCell = nil
            controller.tableFormulasPending = false
            controller.replaceWithoutUndo(range, with: markdown)
            controller.refreshTableEditor()
        }
        undo.setActionName("Edit Table")
    }

    /// New formula lines for the edited table (and `table`, its Markdown, when given), with
    /// its values recalculated: one undo step.
    private func setTableFormulas(_ formulas: [String], table markdown: String? = nil, actionName: String) {
        guard let location = styler.editingTableLocation, let parts = tableParts(at: location) else { return }
        let old = ns.substring(with: parts.range)
        let table = TableFormulaUI.recalculate(tableMarkdown: markdown ?? parts.table, formulaLines: formulas, noteText: storage.string)
        let new = Self.joined(table, formulas)
        guard old != new else { return }
        tableTypingCell = nil
        tableFormulasPending = false
        registerTableUndo(at: parts.range.location, restoring: old)
        textView.undoManager?.setActionName(actionName)
        replaceWithoutUndo(parts.range, with: new)
        refreshTableEditor()
        if let i = styler.blockIndex(containing: location), i + 1 < styler.blocks.count {
            styler.restyleBlock(at: styler.blocks[i + 1].range.location, in: storage)
        }
    }

    private func replaceWithoutUndo(_ range: NSRange, with markdown: String) {
        textView.undoManager?.disableUndoRegistration()
        replace(range, with: markdown)
        textView.undoManager?.enableUndoRegistration()
    }

    /// The cell being typed in shows its Markdown markers; its row is measured with
    /// them so the text never runs past the cell.
    private func tableFocusChanged(_ cell: TableEditorView.Cell?) {
        guard let location = styler.editingTableLocation,
              styler.editingTableCell?.row != cell?.row || styler.editingTableCell?.column != cell?.column else { return }
        recalculateEditedTable()
        styler.editingTableCell = cell
        tableTypingCell = nil
        guard location < storage.length else { return }
        styler.restyleBlock(at: location, in: storage)
        refreshTableEditor()
        DispatchQueue.main.async { [weak self] in self?.revealFocusedCellUnderToolbar() }
    }

    /// A cell focused under the toolbar pinned over a tall table scrolls clear of it.
    /// Only on a change of cell: scrolling by hand is left alone.
    private func revealFocusedCellUnderToolbar() {
        guard let editor = tableEditor, let bar = tableToolbar,
              editor.focus.row < editor.render.rowHeights.count, editor.focus.column < editor.render.columnWidths.count else { return }
        let table = NSRect(origin: editor.frame.origin, size: NSSize(width: editor.render.width, height: editor.render.height))
        let cell = editor.render.cellRect(row: editor.focus.row, column: editor.focus.column, in: table)
        guard cell.intersects(bar.frame) else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, clip.bounds.minY - (bar.frame.maxY + 6 - cell.minY))))
        scrollView.reflectScrolledClipView(clip)
    }

    func refreshTableEditor() {
        if tableEditor != nil { updateFloats() }
        guard let editor = tableEditor, let location = styler.editingTableLocation,
              let (render, rect, columnRect) = tableLayout(at: location) else { return }
        // A change of shape (a column added or removed) lays out afresh; hold that too.
        styler.editingTableWidths = render.columnWidths
        tableColumnRect = columnRect
        editor.stripRoom = tableStripRoom(table: rect, column: columnRect, floating: editor.floating)
        editor.update(render: render)
        editor.frame.origin = rect.origin
        positionTableToolbar()
        positionFormulaHint()
    }

    private func deleteEditedTable() {
        guard let location = styler.editingTableLocation, let i = styler.blockIndex(containing: location) else { return }
        // Its formula lines go with it.
        let range = rangeWithFormulas(ofBlock: i)
        endTableEditing()
        replace(range, with: "", select: NSRange(location: range.location, length: 0), actionName: "Delete Table")
    }

    func endTableEditing(caretAfter: Bool = false, caretBefore: Bool = false) {
        guard let location = styler.editingTableLocation else { return }
        tableEditor?.finishDraft()
        recalculateEditedTable()
        styler.editingTableLocation = nil
        styler.editingTableWidths = nil
        styler.editingTableCell = nil
        styler.editingTableCellText = nil
        layoutManager.hiddenFloat = nil
        tableEditor?.removeFromSuperview()
        tableToolbar?.removeFromSuperview()
        hideFormulaHint()
        tableEditor = nil
        tableToolbar = nil
        tableColumnRect = .zero
        if let observer = tableScrollObserver { NotificationCenter.default.removeObserver(observer) }
        tableScrollObserver = nil
        textView.window?.makeFirstResponder(textView)
        if caretAfter, let i = styler.blockIndex(containing: location) {
            // Past the formula lines too, so leaving the table doesn't open their source.
            let end = NSMaxRange(rangeWithFormulas(ofBlock: i))
            textView.setSelectedRange(NSRange(location: min(end, storage.length), length: 0))
        } else if caretBefore {
            textView.setSelectedRange(NSRange(location: max(0, location - 1), length: 0))
        }
        if location < storage.length { styler.restyleBlock(at: location, in: storage) }
        updateFloats()
    }

    // MARK: Hovering over tables

    /// Where clicks count as aimed at a table: the grid, plus the space beside its rows
    /// (the page margin on the left, its column's empty space on the right) and the
    /// padding under it. A floating table has text right beside it, so only its grid.
    func tableClickArea(_ block: (decoration: BlockDecoration, range: NSRange, area: NSRect, content: NSRect)) -> NSRect {
        if case .float = block.decoration.placement { return block.content.insetBy(dx: -4, dy: -4) }
        let column = tableColumn(of: block)
        let minX = abs(column.minX - pageColumn.minX) < 1 ? textView.bounds.minX : column.minX - 8
        return NSRect(x: minX, y: block.content.minY - 4, width: column.maxX - minX, height: max(block.area.maxY, block.content.maxY + 4) - block.content.minY + 4)
    }

    /// Shows the add-column and add-row strips of the table under the pointer, so a
    /// table grows without opening it first. An open table shows its own.
    func hoverTables(at point: NSPoint) {
        guard tableEditor == nil, textView.isEditable, AppSettings.shared.syntax != .always else { return hideTableStrips() }
        for block in visibleBlocks() {
            guard case let .table(table) = block.decoration.content, block.decoration.placement != .below else { continue }
            var floating = false
            if case .float = block.decoration.placement { floating = true }
            let room = tableStripRoom(table: block.content, column: tableColumn(of: block), floating: floating)
            let frames = TableEdgeStrip.frames(table: block.content, room: room)
            guard block.content.union(frames.column).union(frames.row).contains(point) else { continue }
            if tableStrips.isEmpty {
                tableStrips = [TableEdgeStrip(adds: .column), TableEdgeStrip(adds: .row)]
                tableStrips.forEach { textView.addSubview($0) }
            }
            let location = lineRange(at: block.range.location).content.location
            let rows = table.rowHeights.count, columns = table.columnWidths.count
            tableStrips[0].frame = frames.column
            tableStrips[0].inside = !room.right
            tableStrips[0].onClick = { [weak self] in
                self?.beginTableEditing(at: location, row: 0, column: columns - 1)
                self?.tableEditor?.addColumnAtEnd()
            }
            tableStrips[1].frame = frames.row
            tableStrips[1].inside = !room.below
            tableStrips[1].onClick = { [weak self] in
                self?.beginTableEditing(at: location, row: rows - 1, column: 0)
                self?.tableEditor?.addRowAtEnd()
            }
            return
        }
        hideTableStrips()
    }

    func hideTableStrips() {
        tableStrips.forEach { $0.removeFromSuperview() }
        tableStrips = []
    }
}
