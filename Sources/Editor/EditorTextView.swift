import AppKit

/// The writing surface. A plain NSTextView keeps every native behavior
/// (input methods, spelling, services, Find, dictation, accessibility); this
/// subclass only adds column layout, image handling and Markdown list editing.
final class EditorTextView: NSTextView {
    weak var editor: EditorController?

    var columnWidth: CGFloat = 700 { didSet { updateGeometry() } }
    var gutter: CGFloat = 56 { didSet { updateGeometry() } }
    var topPadding: CGFloat = 92 { didSet { updateGeometry() } }
    private(set) var effectiveColumn: CGFloat = 700
    private(set) var isTrackingMouse = false
    private var clickAnchor: (character: Int, offset: NSSize)?
    /// The view is being resized by an animation (the sidebar sliding in): treat it
    /// like a live resize and restyle once it settles.
    var isAnimatingFrame = false
    private var insetX: CGFloat = 0

    override var textContainerOrigin: NSPoint {
        NSPoint(x: insetX, y: topPadding)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            updateGeometry()
            editor?.geometryDidChange()
        }
    }

    func updateGeometry() {
        let available = bounds.width
        let column = max(200, min(columnWidth, available - gutter * 2 - 24))
        let newInset = max(0, floor((available - column) / 2 - gutter))
        let visibleHeight = enclosingScrollView?.contentSize.height ?? 800
        let bottom = max(160, visibleHeight * 0.35)
        let insetHeight = (topPadding + bottom) / 2
        if newInset != insetX || textContainerInset.height != insetHeight {
            insetX = newInset
            textContainerInset = NSSize(width: newInset, height: insetHeight)
        }
        // A fixed width for a given column: centering rounds the inset, and a width
        // that alternated by a point would re-wrap (and re-float) text on every step.
        let containerWidth = min(column + gutter * 2, max(available - newInset * 2, 0))
        if let container = textContainer, container.size.width != containerWidth {
            container.size = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        if column != effectiveColumn {
            effectiveColumn = column
            editor?.columnDidChange(column)
        }
    }

    // MARK: Mouse

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// True when the pointer is over something other than the page's text: the title
    /// bar (which sits above the page), or a floating bar or toolbar on the page.
    private func pointerIsOverChrome(_ event: NSEvent) -> Bool {
        guard let frame = window?.contentView?.superview else { return false }
        guard let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return true }
        if hit === self { return false }
        if hit.isDescendant(of: self) { return !(hit is NSTextView || hit is NSTextField) }
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        editor?.hoverTables(at: convert(event.locationInWindow, from: nil))
        editor?.hoverTableGrip(at: convert(event.locationInWindow, from: nil))
        editor?.updateCellTips()
        if pointerIsOverChrome(event) {
            NSCursor.arrow.set()
            return
        }
        // A table's formula caption is a button: its list, or Recalculate.
        if editor?.caption(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        editor?.hideTableStrips()
        editor?.hideTableGrip()
    }

    override func cursorUpdate(with event: NSEvent) {
        if pointerIsOverChrome(event) {
            NSCursor.arrow.set()
            return
        }
        if editor?.caption(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let editor, editor.handleClick(at: point, clickCount: event.clickCount) { return }
        var event = event
        if event.clickCount == 1 {
            clickAnchor = anchor(at: point)
        } else if let moved = clickAnchor.flatMap(location(of:)), moved != point,
                  let retargeted = NSEvent.mouseEvent(
                    with: event.type, location: convert(moved, to: nil), modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                    eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) {
            // The first click may have shown or hidden markers; keep aiming at the same text.
            event = retargeted
        }
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        editor?.mouseTrackingEnded()
    }

    private func anchor(at point: NSPoint) -> (character: Int, offset: NSSize)? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        return (layoutManager.characterIndexForGlyph(at: glyph),
                NSSize(width: inContainer.x - rect.minX, height: inContainer.y - rect.minY))
    }

    private func location(of anchor: (character: Int, offset: NSSize)) -> NSPoint? {
        guard let layoutManager, let textContainer, let storage = textStorage, anchor.character < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: anchor.character)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        return NSPoint(x: rect.minX + anchor.offset.width + textContainerOrigin.x,
                       y: rect.minY + anchor.offset.height + textContainerOrigin.y)
    }

    // MARK: Pasteboard

    override func paste(_ sender: Any?) {
        let pb = TableClipboard.board
        if editor?.insertImages(from: pb, at: nil) == true { return }
        if editor?.pasteTable(from: pb) == true { return }
        if let cell = TableClipboard.singleCell(from: pb) { return insertText(cell, replacementRange: selectedRange()) }
        if pb.name == .general { return pasteAsPlainText(sender) }
        // The debug harness's private board.
        if let text = pb.string(forType: .string) { insertText(text, replacementRange: selectedRange()) }
    }

    /// Copied text holding a table also goes out as HTML, so it pastes as a real table;
    /// a whole table takes its formula lines along (`EditorController.copySelection`).
    override func copy(_ sender: Any?) {
        guard let editor else { return super.copy(sender) }
        editor.copySelection(to: TableClipboard.board)
    }

    override func cut(_ sender: Any?) {
        guard let editor, let range = editor.copySelection(to: TableClipboard.board) else { return super.cut(sender) }
        setSelectedRange(range)
        delete(sender)
    }

    override func performFindPanelAction(_ sender: Any?) {
        if let editor { editor.performFind(sender) } else { super.performFindPanelAction(sender) }
    }

    override func performTextFinderAction(_ sender: Any?) {
        if let editor { editor.performFind(sender) } else { super.performTextFinderAction(sender) }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performFindPanelAction(_:)) || item.action == #selector(performTextFinderAction(_:)),
           let editor {
            return editor.validateFind(item)
        }
        // A plain-text view disables Paste when the pasteboard only holds an image.
        if item.action == #selector(paste(_:)), isEditable, editor?.pasteboardHasImages(.general) == true { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if editor?.pasteboardHasImages(sender.draggingPasteboard) == true { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        if editor?.pasteboardHasImages(sender.draggingPasteboard) == true { return .copy }
        return op
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if editor?.pasteboardHasImages(pb) == true {
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            window?.makeFirstResponder(self)
            return editor?.insertImages(from: pb, at: index) ?? false
        }
        return super.performDragOperation(sender)
    }

    // MARK: Keys

    /// Soft suggestion drawn after the caret (slash commands).
    var ghost: String? { didSet { if ghost != oldValue { needsDisplay = true } } }
    /// A computed answer (drawn like any other suggestion: soft gray after the caret).
    var ghostIsAnswer = false

    /// Where each exported page after the first begins (character offsets), shown as
    /// dashed lines when Show Page Lines is on.
    var pageStarts: [Int] = [] { didSet { if pageStarts != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (layoutManager as? MarkdownLayoutManager)?.drawFloats(in: dirtyRect, origin: textContainerOrigin)
        drawPageLines(in: dirtyRect)
        editor?.math.drawMarks()
        drawGhost()
    }

    private func drawPageLines(in dirtyRect: NSRect) {
        guard !pageStarts.isEmpty, let layoutManager, let storage = textStorage else { return }
        let origin = textContainerOrigin
        let text = storage.string as NSString
        for (i, start) in pageStarts.enumerated() where start < storage.length {
            // A page break written just above already marks this spot.
            var before = start - 1
            while before > 0, let u = UnicodeScalar(text.character(at: before)), CharacterSet.whitespacesAndNewlines.contains(u) { before -= 1 }
            if before >= 0, storage.attribute(.mdPageBreak, at: before, effectiveRange: nil) != nil { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            let y = origin.y + layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            guard y > dirtyRect.minY - 12, y < dirtyRect.maxY + 12 else { continue }
            MarkdownLayoutManager.drawPageLine(y: y, from: insetX, to: insetX + effectiveColumn + gutter * 2,
                                               label: "Page \(i + 2)", centered: false, color: Palette.separator)
        }
    }

    private func drawGhost() {
        guard let ghost, let layoutManager, let container = textContainer, let storage = textStorage else { return }
        let caret = selectedRange().location
        guard caret > 0, caret <= storage.length else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: caret - 1)
        let frag = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let baseline = layoutManager.location(forGlyphAt: glyph).y
        let font = (storage.attribute(.font, at: caret - 1, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 15)
        let origin = textContainerOrigin
        let point = NSPoint(x: origin.x + box.maxX + 1, y: origin.y + frag.minY + baseline - font.ascender)
        (ghost as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: Palette.tertiaryText])
    }

    override func moveUp(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(moveUp(_:))) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(moveDown(_:))) == true { return }
        super.moveDown(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // A key typed at the caret (not text put in by a command or an input method).
        if let s = string as? String, !hasMarkedText(),
           replacementRange.location == NSNotFound || replacementRange == selectedRange(),
           editor?.math.handleInput(s) == true { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Inserts at the selection as typing does, without the math shortcuts.
    func insertTypedText(_ s: String) {
        super.insertText(s, replacementRange: selectedRange())
    }

    /// The key press being handled, so Return can tell Shift-Return apart (math matrices).
    private var keyEvent: NSEvent?

    override func keyDown(with event: NSEvent) {
        // Typing hides the pointer; the table strips go with it (the text may move).
        editor?.hideTableStrips()
        editor?.hideTableGrip()
        keyEvent = event
        defer { keyEvent = nil }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(insertNewline(_:))) == true { return }
        let shift = (keyEvent ?? NSApp.currentEvent)?.modifierFlags.contains(.shift) == true
        if editor?.math.handleNewline(shift: shift) == true { return }
        if editor?.handleNewline() == true { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(insertTab(_:))) == true { return }
        if editor?.math.handleTab() == true { return }
        if editor?.indentListItem(outdent: false) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if editor?.math.handleBacktab() == true { return }
        if editor?.indentListItem(outdent: true) == true { return }
        super.insertBacktab(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if editor?.deleteSelectedImage() == true { return }
        if editor?.math.handleBackspace() == true { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if editor?.deleteSelectedImage() == true { return }
        super.deleteForward(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(cancelOperation(_:))) == true { return }
        if editor?.deselectImage() == true { return }
        editor?.math.clearStops()
        super.cancelOperation(sender)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // A selected image is the selection; a caret the height of the image would be noise.
        if editor?.hasSelectedImage == true { return }
        super.drawInsertionPoint(in: caretRect(clamping: rect), color: color, turnedOn: flag)
    }

    /// A caret beside a rendered block (a table, an equation) would take the height of
    /// the block's whole line; it's one line of text tall instead, level with the
    /// block's first line.
    func caretRect(clamping rect: NSRect) -> NSRect {
        let font = typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 15)
        let line = ceil(font.ascender - font.descender + font.leading)
        guard rect.height > line * 2 else { return rect }
        return NSRect(x: rect.minX, y: rect.minY + TableRender.padY + 2, width: rect.width, height: line)
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
