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
        if pointerIsOverChrome(event) {
            NSCursor.arrow.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if pointerIsOverChrome(event) {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let editor, editor.handleClick(at: point, clickCount: event.clickCount) { return }
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        editor?.mouseTrackingEnded()
    }

    // MARK: Pasteboard

    override func paste(_ sender: Any?) {
        if editor?.insertImages(from: .general, at: nil) == true { return }
        pasteAsPlainText(sender)
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (layoutManager as? MarkdownLayoutManager)?.drawFloats(in: dirtyRect, origin: textContainerOrigin)
        drawGhost()
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

    override func insertNewline(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(insertNewline(_:))) == true { return }
        if editor?.handleNewline() == true { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(insertTab(_:))) == true { return }
        if editor?.indentListItem(outdent: false) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if editor?.indentListItem(outdent: true) == true { return }
        super.insertBacktab(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if editor?.deleteSelectedImage() == true { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if editor?.deleteSelectedImage() == true { return }
        super.deleteForward(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if editor?.handleSlashKey(#selector(cancelOperation(_:))) == true { return }
        if editor?.deselectImage() == true { return }
        super.cancelOperation(sender)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // A selected image is the selection; a caret the height of the image would be noise.
        if editor?.hasSelectedImage == true { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
