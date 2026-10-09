import AppKit

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

    @objc func undo(_ sender: Any?) {
        if table?.undoDraft() == true { return }
        noteUndo?.undo()
    }
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

    /// Text selected in a cell copies as just that text, as it's seen (a line break
    /// as a newline, not `<br>`).
    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        let pb = TableClipboard.board
        pb.clearContents()
        pb.setString((string as NSString).substring(with: sel), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copy(sender)
        delete(sender)
    }

    /// Cells pasted while typing fill the table from here; text goes in as typed (its
    /// line breaks kept, as `<br>`), without expanding math shortcuts.
    override func paste(_ sender: Any?) {
        let pb = TableClipboard.board
        if table?.pasteGrid(from: pb, intoText: true) == true { return }
        guard let text = TableClipboard.grid(from: pb, lines: false)?.first?.first ?? pb.string(forType: .string), !text.isEmpty else { return }
        insertTypedText(text.replacingOccurrences(of: "\r\n", with: "\n"))
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
        stringValue = table?.editingText(for: self) ?? source
        guard super.becomeFirstResponder() else { return false }
        restyleEditor()
        table?.beganEditing(self)
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
