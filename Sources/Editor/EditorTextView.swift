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
        if let editor, editor.handleClick(at: point, clickCount: event.clickCount, event: event) { return }
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

    // Menu items are validated here, not in validateUserInterfaceItem.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performFindPanelAction(_:)) || item.action == #selector(performTextFinderAction(_:)),
           let editor {
            return editor.validateFind(item)
        }
        return super.validateMenuItem(item)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performFindPanelAction(_:)) || item.action == #selector(performTextFinderAction(_:)),
           let editor {
            return editor.validateFind(item)
        }
        if item.action == #selector(askIndium(_:)) { return isEditable && editor?.askRange() != nil }
        // A plain-text view disables Paste when the pasteboard only holds an image.
        if item.action == #selector(paste(_:)), isEditable, editor?.pasteboardHasImages(.general) == true { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    /// .csv and .tsv files dropped on the note come in as tables.
    private func dataFiles(_ pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["csv", "tsv"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if editor?.pasteboardHasImages(sender.draggingPasteboard) == true || !dataFiles(sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        if editor?.pasteboardHasImages(sender.draggingPasteboard) == true || !dataFiles(sender.draggingPasteboard).isEmpty { return .copy }
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
        let files = dataFiles(pb)
        if !files.isEmpty, let editor {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
            return files.map { editor.insertTable(fromFile: $0) }.contains(true)
        }
        return super.performDragOperation(sender)
    }

    // MARK: Drawing

    /// Soft suggestion drawn after the caret: a slash command or a quick answer.
    var ghost: String? { didSet { if ghost != oldValue { needsDisplay = true } } }

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
        guard let ghost, let layout = ghostLayout(), layout.fits else { return }
        (ghost as NSString).draw(at: layout.rect.origin, withAttributes: [.font: layout.font, .foregroundColor: Palette.tertiaryText])
    }

    /// The ghost is drawn and Tab or → take it only when it fits beside the text on its line.
    var showsGhost: Bool { ghostLayout()?.fits == true }

    /// Where the ghost goes: after the caret, or after the closing `$` when that's all that
    /// follows it. It fits when it ends on its line: short of the page's edge, a float beside
    /// the text, or the next column.
    func ghostLayout() -> (rect: NSRect, font: NSFont, fits: Bool)? {
        guard let ghost, let layoutManager, let container = textContainer,
              let storage = textStorage else { return nil }
        let caret = selectedRange().location
        guard caret > 0, caret <= storage.length else { return nil }
        let text = storage.string as NSString
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: caret, length: 0))
        var anchor = caret - 1
        for i in stride(from: ce - 1, through: caret, by: -1) where !(text.character(at: i) == 0x20 || text.character(at: i) == 0x09) {
            anchor = i
            break
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
        let frag = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let baseline = layoutManager.location(forGlyphAt: glyph).y
        let font = (storage.attribute(.font, at: anchor, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 15)
        let origin = textContainerOrigin
        let size = (ghost as NSString).size(withAttributes: [.font: font])
        let rect = NSRect(x: origin.x + box.maxX + 1, y: origin.y + frag.minY + baseline - font.ascender, width: size.width, height: size.height)
        return (rect, font, rect.maxX <= origin.x + frag.maxX)
    }

    // MARK: Keys

    override func moveUp(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(moveUp(_:))) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(moveDown(_:))) == true { return }
        super.moveDown(sender)
    }

    override func moveRight(_ sender: Any?) {
        if editor?.acceptSuggestionWithRightArrow() == true { return }
        if skipDelimiter(forward: true) { return }
        super.moveRight(sender)
    }

    override func moveLeft(_ sender: Any?) {
        if skipDelimiter(forward: false) { return }
        super.moveLeft(sender)
    }

    /// One arrow press steps over a whole `**`, `~~` or backtick run, shown or hidden, so
    /// leaving bold takes one press.
    private func skipDelimiter(forward: Bool) -> Bool {
        let caret = selectedRange()
        guard let editor, caret.length == 0, !hasMarkedText(),
              let to = MarkdownScanner.skippingDelimiter(in: editor.ns, line: editor.lineRange(at: caret.location).content,
                                                         caret: caret.location, forward: forward) else { return false }
        setSelectedRange(NSRange(location: to, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    #if DEBUG
    // What Siri and other assistive apps do through accessibility (see SiriLog).
    override func setAccessibilitySelectedText(_ text: String?) {
        SiriLog.write("ax setSelectedText selection=\(selectedRange()) text=\((text ?? "").prefix(200).debugDescription)")
        super.setAccessibilitySelectedText(text)
    }
    override func setAccessibilityValue(_ value: Any?) {
        SiriLog.write("ax setValue length=\(((value as? String) ?? "").count)")
        super.setAccessibilityValue(value)
    }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        SiriLog.write("ax setSelectedTextRange \(range)")
        super.setAccessibilitySelectedTextRange(range)
    }
    override func accessibilitySelectedText() -> String? {
        let text = super.accessibilitySelectedText()
        SiriLog.write("ax read selectedText (\(text?.count ?? 0) chars)")
        return text
    }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        SiriLog.write("services readSelection type=\(type.rawValue) selection=\(selectedRange())")
        return super.readSelection(from: pboard, type: type)
    }
    #endif

    // MARK: Ask Indium

    @objc func askIndium(_ sender: Any?) { editor?.showAsk() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        // First in the menu, where a request about the selection is easiest to reach.
        if let menu, isEditable, selectedRange().length > 0 {
            let item = NSMenuItem(title: "Ask Indium…", action: #selector(askIndium(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Typing with a chart selected writes on the line after it.
        editor?.leaveSelectedChart()
        // A key typed at the caret (not text put in by a command or an input method).
        if let s = string as? String, !hasMarkedText(),
           replacementRange.location == NSNotFound || replacementRange == selectedRange() {
            if editor?.math.handleInput(s) == true { return }
            let caret = selectedRange()
            if let editor, caret.length == 0,
               let (text, range) = MarkdownScanner.movingSpaceOutOfEmphasis(in: editor.ns, line: editor.lineRange(at: caret.location).content,
                                                                            caret: caret.location, typing: s) {
                super.insertText(text, replacementRange: range)
                return
            }
        }
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
        editor?.leaveSelectedChart()
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
        if editor?.deleteSelectedChart() == true { return }
        if editor?.math.handleBackspace() == true { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if editor?.deleteSelectedImage() == true { return }
        if editor?.deleteSelectedChart() == true { return }
        super.deleteForward(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(cancelOperation(_:))) == true { return }
        if editor?.deselectImage() == true { return }
        if editor?.deselectChart() == true { return }
        editor?.math.clearStops()
        super.cancelOperation(sender)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // A selected image is the selection; a caret the height of the image would be noise.
        if editor?.hasSelectedImage == true || editor?.styler.selectedChart != nil { return }
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
