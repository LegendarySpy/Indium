import AppKit
import Combine
import UniformTypeIdentifiers

/// Owns one text system and whichever note is currently shown in it.
final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate, ImageResolving {
    let scrollView = NSScrollView()
    let textView: EditorTextView
    let storage = NSTextStorage()
    let layoutManager = MarkdownLayoutManager()
    let styler: MarkdownStyler
    let finder = NSTextFinder()

    weak var workspace: Workspace?
    private(set) var note: Note?

    /// The user typed; the window fades its chrome.
    var onTyping: (() -> Void)?
    /// Open another note (wiki link, relative link).
    var onOpenNote: ((URL) -> Void)?
    /// The note's file disappeared and there were no unsaved edits.
    var onNoteMissing: (() -> Void)?
    /// Title (file name) changed.
    var onTitleChange: (() -> Void)?

    private var isLoading = false
    private(set) var hasUnsavedEdits = false
    private var saveTimer: Timer?
    private var restyleTimer: Timer?
    private var lastSelection: [NSRange] = [NSRange(location: 0, length: 0)]
    private var selectedImageLine: Int?
    private var changingImageSelection = false
    private var resolvingConflict = false
    private let imageControls = ImageControlsView()
    let selectionBar = SelectionBarView(frame: .zero)
    var textVersion = 0
    var cachedLayout: (version: Int, model: LayoutModel)?
    var slash: SlashState?
    var tableEditor: TableEditorView?
    var tableToolbar: TableToolbarView?
    var slashDismissedAt: Int?
    /// A computed answer offered after an `=` at the caret.
    var answer: (location: Int, result: MathAnswer.Result)?
    var answerDismissedAt: Int?
    private var captionPopover: NSPopover?
    private var observers: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    override init() {
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        // Sized by the text view to exactly the column (see updateGeometry), so it
        // never flickers by a point while the window resizes.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        styler = MarkdownStyler(config: .current)
        super.init()
        configureTextView()
        styler.imageResolver = self
        applySettings(restyle: false)

        AppSettings.shared.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.applySettings(restyle: true) } }
            .store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: Workspace.didMoveItem, object: nil, queue: .main) { [weak self] n in
            self?.itemMoved(from: n.userInfo?["from"] as? URL, to: n.userInfo?["to"] as? URL)
        })
        observers.append(NotificationCenter.default.addObserver(forName: Workspace.didChange, object: nil, queue: .main) { [weak self] n in
            self?.checkForExternalChanges()
            // Links and images resolve against the folder's files, known once it's scanned.
            if n.userInfo?["initial"] as? Bool == true { self?.restyleAll() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Workspace.filesTouched, object: nil, queue: .main) { [weak self] _ in
            self?.checkForExternalChanges()
        })
        observers.append(NotificationCenter.default.addObserver(forName: ImageCache.remoteImageLoaded, object: nil, queue: .main) { [weak self] _ in
            self?.restyleAll()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func configureTextView() {
        let tv = textView
        tv.editor = self
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = true
        tv.smartInsertDeleteEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.usesInspectorBar = false
        tv.usesRuler = false
        tv.allowsDocumentBackgroundColorChange = false
        tv.drawsBackground = true
        tv.backgroundColor = Palette.background
        tv.insertionPointColor = Palette.text
        tv.linkTextAttributes = [
            .foregroundColor: Palette.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: Palette.linkUnderline,
            .cursor: NSCursor.pointingHand,
        ]
        tv.delegate = self
        tv.setAccessibilityLabel("Note")
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        storage.delegate = self

        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero

        imageControls.isHidden = true
        imageControls.onWidth = { [weak self] f in self?.setSelectedImageWidth(fraction: f) }
        imageControls.onCaption = { [weak self] in self?.editSelectedImageCaption() }
        imageControls.onRemove = { [weak self] in _ = self?.deleteSelectedImage() }
        tv.addSubview(imageControls)
        selectionBar.isHidden = true
        selectionBar.onAction = { [weak self] action in self?.performSelectionAction(action) }
        tv.addSubview(selectionBar)
    }

    // MARK: Find

    func attachFindBar(_ host: FindBarHost) {
        host.textView = textView
        finder.client = (textView as NSObject) as? NSTextFinderClient
        finder.findBarContainer = host
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
    }

    func performFind(_ sender: Any?) {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        if let action = NSTextFinder.Action(rawValue: tag) { finder.performAction(action) }
    }

    func validateFind(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return finder.validateAction(action)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        finder.noteClientStringWillChange()
        return true
    }

    // MARK: Settings

    func applySettings(restyle: Bool) {
        let s = AppSettings.shared
        styler.config.typography = .current
        styler.config.syntax = s.syntax
        layoutManager.gutter = styler.config.gutter
        layoutManager.bodyLineSpacing = styler.config.typography.lineSpacing
        layoutManager.typoParagraphGap = styler.config.typography.paragraphSpacing
        layoutManager.captionFont = styler.config.typography.text(bold: false, italic: true, size: round(styler.config.typography.size * 0.8))
        textView.gutter = styler.config.gutter
        textView.columnWidth = s.lineWidth.points
        styler.config.columnWidth = textView.effectiveColumn
        if textView.isContinuousSpellCheckingEnabled != s.spellcheck {
            textView.isContinuousSpellCheckingEnabled = s.spellcheck
        }
        textView.typingAttributes = styler.baseAttributes()
        if restyle { restyleAll() }
    }

    func columnDidChange(_ column: CGFloat) {
        guard styler.config.columnWidth != column else { return }
        styler.config.columnWidth = column
        restyleTimer?.invalidate()
        let needsRestyle = !styler.regions.isEmpty
            || styler.blocks.contains {
                switch $0.kind { case .image, .math, .table: true; default: false }
            }
        guard needsRestyle else { return }
        restyleTimer = Timer.scheduledTimer(withTimeInterval: textView.inLiveResize ? 0.12 : 0, repeats: false) { [weak self] _ in
            self?.restyleAll()
        }
    }

    /// The page moved under floating editors (window resize, column change): keep the
    /// table editor and image controls on their blocks.
    func geometryDidChange() {
        // Floats move in the same pass as the text, so nothing draws a frame late.
        updateFloats()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshTableEditor()
            self.positionImageControls()
            self.completeLayoutSoon()
        }
    }

    /// Places floating tables and images: each sits at its source line's position, and
    /// an exclusion beside it makes the text that follows wrap around it.
    func updateFloats() {
        guard let container = textView.textContainer else { return }
        let hadFloats = !layoutManager.floatFrames.isEmpty
        guard let bottom = layoutManager.placeFloats(in: container, styler: styler) else {
            if hadFloats { textView.needsDisplay = true }
            return
        }
        // A float near the end still needs page below it.
        textView.minSize = NSSize(width: 0, height: bottom + textView.textContainerInset.height * 2 + 40)
        textView.needsDisplay = true
    }

    private var fullLayoutWork: DispatchWorkItem?

    /// Lays out the whole note shortly after changes, so the scroller reflects the real
    /// length instead of an estimate that shifts while scrolling.
    func completeLayoutSoon(delay: TimeInterval = 0.05) {
        fullLayoutWork?.cancel()
        guard storage.length < 400_000 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let container = self.textView.textContainer else { return }
            self.layoutManager.ensureLayout(for: container)
        }
        fullLayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func restyleAll() {
        styler.styleAll(storage, selection: textView.selectedRanges.map(\.rangeValue))
        textView.typingAttributes = styler.baseAttributes()
        updateFloats()
        positionImageControls()
        refreshTableEditor()
    }

    // MARK: Table editing

    private func tableLayout(at location: Int) -> (TableRender, NSRect)? {
        guard let container = textView.textContainer, location < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
        _ = container
        for block in layoutManager.blockRects(in: NSRange(location: location, length: 1), origin: textView.textContainerOrigin) {
            if case let .table(render) = block.decoration.content { return (render, block.content) }
        }
        return nil
    }

    /// A caret that lands inside a table (arrow keys, clicks beside it) edits a cell
    /// rather than the table's Markdown.
    private func openTableEditorIfCaretEntered(_ selection: [NSRange]) -> Bool {
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
        styler.editingTableLocation = location
        styler.restyleBlock(at: location, in: storage)
        updateFloats()
        guard let (render, rect) = tableLayout(at: location) else {
            styler.editingTableLocation = nil
            return
        }
        let floatSide = styler.blockIndex(containing: location).flatMap { styler.floatOfBlock[$0] }
        let editor = TableEditorView(render: render)
        editor.anchoredRight = floatSide == true
        layoutManager.hiddenFloat = floatSide != nil ? location : nil
        editor.frame.origin = rect.origin
        editor.onChange = { [weak self] markdown in self?.commitTable(markdown) }
        editor.onExit = { [weak self] in self?.endTableEditing(caretAfter: true) }
        editor.onLeave = { [weak self] down in
            guard let self else { return }
            if down { self.endTableEditing(caretAfter: true) } else { self.endTableEditing(caretBefore: true) }
        }
        textView.addSubview(editor)
        tableEditor = editor

        let bar = TableToolbarView(frame: .zero)
        bar.onAddRow = { [weak editor] in editor?.addRow() }
        bar.onAddColumn = { [weak editor] in editor?.addColumn() }
        bar.onAlign = { [weak editor] a in editor?.align(a) }
        bar.onDeleteRow = { [weak editor] in editor?.deleteRow() }
        bar.onDeleteColumn = { [weak editor] in editor?.deleteColumn() }
        bar.onDeleteTable = { [weak self] in self?.deleteEditedTable() }
        bar.onDone = { [weak self] in self?.endTableEditing(caretAfter: true) }
        bar.placement = floatSide
        bar.onPlace = { [weak self] side in self?.placeEditedTable(float: side) }
        textView.addSubview(bar)
        tableToolbar = bar
        positionTableToolbar()
        bar.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; bar.animator().alphaValue = 1 }
        editor.focusCell(row: row, column: column)
    }

    private func positionTableToolbar() {
        guard let editor = tableEditor, let bar = tableToolbar else { return }
        let size = bar.frame.size
        var y = editor.frame.minY - size.height - 8
        if y < textView.visibleRect.minY + 4 { y = editor.frame.maxY + 8 }
        let tableRight = editor.frame.minX + editor.render.width
        bar.setFrameOrigin(NSPoint(x: round(tableRight - size.width), y: round(y)))
    }

    private func commitTable(_ markdown: String) {
        guard let location = styler.editingTableLocation, let i = styler.blockIndex(containing: location),
              case .table = styler.blocks[i].kind else { return }
        var range = styler.blocks[i].range
        let ns = storage.string as NSString
        while range.length > 0, [0x0A, 0x0D].contains(ns.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        guard ns.substring(with: range) != markdown else { return }
        replace(range, with: markdown, actionName: "Edit Table")
        refreshTableEditor()
    }

    private func refreshTableEditor() {
        if tableEditor != nil { updateFloats() }
        guard let editor = tableEditor, let location = styler.editingTableLocation,
              let (render, rect) = tableLayout(at: location) else { return }
        editor.update(render: render)
        editor.frame.origin = rect.origin
        positionTableToolbar()
    }

    private func deleteEditedTable() {
        guard let location = styler.editingTableLocation, let i = styler.blockIndex(containing: location) else { return }
        let range = styler.blocks[i].range
        endTableEditing()
        replace(range, with: "", select: NSRange(location: range.location, length: 0), actionName: "Delete Table")
    }

    func endTableEditing(caretAfter: Bool = false, caretBefore: Bool = false) {
        guard let location = styler.editingTableLocation else { return }
        styler.editingTableLocation = nil
        layoutManager.hiddenFloat = nil
        tableEditor?.removeFromSuperview()
        tableToolbar?.removeFromSuperview()
        tableEditor = nil
        tableToolbar = nil
        textView.window?.makeFirstResponder(textView)
        if caretAfter, let i = styler.blockIndex(containing: location) {
            let end = NSMaxRange(styler.blocks[i].range)
            textView.setSelectedRange(NSRange(location: min(end, storage.length), length: 0))
        } else if caretBefore {
            textView.setSelectedRange(NSRange(location: max(0, location - 1), length: 0))
        }
        if location < storage.length { styler.restyleBlock(at: location, in: storage) }
        updateFloats()
    }

    // MARK: Loading

    func load(_ newNote: Note?) {
        saveNow()
        if let old = note {
            old.selection = textView.selectedRange()
            old.scrollOffset = scrollView.contentView.bounds.origin.y
        }
        clearImageSelection()
        endTableEditing()
        note = newNote
        setText(newNote?.savedText ?? "")
        hasUnsavedEdits = false
        let length = storage.length
        let sel = newNote.map { NSRange(location: min($0.selection.location, length), length: 0) } ?? NSRange(location: 0, length: 0)
        isLoading = true
        textView.setSelectedRange(sel)
        isLoading = false
        lastSelection = [sel]
        styler.styleAll(storage, selection: [sel])
        textView.isEditable = newNote != nil
        let offset = newNote?.scrollOffset ?? 0
        layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: 2000, height: offset + 2000), in: textView.textContainer!)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        onTitleChange?()
        updateFloats()
        completeLayoutSoon()
    }

    private func setText(_ text: String) {
        isLoading = true
        finder.noteClientStringWillChange()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        isLoading = false
    }

    var text: String { storage.string }

    var isEmpty: Bool {
        storage.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Saving

    private var firstUnsavedEdit: Date?

    /// Continuous saving: shortly after typing pauses, and never more than ~2 s behind
    /// during a long streak.
    private func scheduleSave() {
        saveTimer?.invalidate()
        let since = firstUnsavedEdit ?? Date()
        firstUnsavedEdit = since
        let overdue = Date().timeIntervalSince(since) > 2
        saveTimer = Timer.scheduledTimer(withTimeInterval: overdue ? 0 : 0.6, repeats: false) { [weak self] _ in self?.saveNow() }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let note, !note.isTemporary, hasUnsavedEdits, !resolvingConflict else { return }
        if case let .changed(disk) = note.checkDisk() {
            resolveConflict(disk: disk)
            return
        }
        do {
            try note.write(storage.string)
            hasUnsavedEdits = false
            firstUnsavedEdit = nil
            if let url = note.url, let workspace { NoteIcons.shared.suggest(for: url, text: storage.string, in: workspace) }
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        guard let window = textView.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    func checkForExternalChanges() {
        guard let note, !note.isTemporary, !resolvingConflict else { return }
        switch note.checkDisk() {
        case .unchanged:
            break
        case let .changed(disk):
            if !hasUnsavedEdits {
                applyExternal(disk)
            } else if !mergeExternal(disk) {
                resolveConflict(disk: disk)
            }
        case .missing:
            if !hasUnsavedEdits { onNoteMissing?() }
        }
    }

    /// The span that differs between two texts: common prefix and suffix trimmed.
    private static func changedSpan(_ a: NSString, _ b: NSString) -> (old: NSRange, new: NSRange) {
        let limit = min(a.length, b.length)
        var start = 0
        while start < limit, a.character(at: start) == b.character(at: start) { start += 1 }
        var end = 0
        while end < limit - start, a.character(at: a.length - 1 - end) == b.character(at: b.length - 1 - end) { end += 1 }
        return (NSRange(location: start, length: a.length - start - end), NSRange(location: start, length: b.length - start - end))
    }

    /// Another app (or an agent) changed the note: apply just the changed span, as one
    /// undoable step, keeping the caret and the text at the top of the window in place.
    private func applyExternal(_ disk: String) {
        guard let note else { return }
        let current = storage.string as NSString
        let span = Self.changedSpan(current, disk as NSString)
        let replacement = (disk as NSString).substring(with: span.new)
        replaceExternally(span.old, with: replacement)
        note.adopt(diskText: disk, keepUndo: true)
        hasUnsavedEdits = false
    }

    /// You have unsaved typing and the file changed too. When the two touch different
    /// parts of the note, keep both; otherwise the caller asks which to keep.
    private func mergeExternal(_ disk: String) -> Bool {
        guard let note else { return false }
        let base = note.savedText as NSString
        let ours = Self.changedSpan(base, storage.string as NSString)
        let theirs = Self.changedSpan(base, disk as NSString)
        let apart = NSMaxRange(theirs.old) < ours.old.location || theirs.old.location > NSMaxRange(ours.old)
        guard apart else { return false }
        var location = theirs.old.location
        if location > NSMaxRange(ours.old) { location += ours.new.length - ours.old.length }
        let replacement = (disk as NSString).substring(with: theirs.new)
        replaceExternally(NSRange(location: location, length: theirs.old.length), with: replacement)
        // The file now matches `disk`; your edits on top are saved shortly as usual.
        note.adopt(diskText: disk, keepUndo: true)
        scheduleSave()
        return true
    }

    private func replaceExternally(_ range: NSRange, with text: String) {
        guard range.length > 0 || !text.isEmpty else { return }
        if let location = styler.editingTableLocation, let i = styler.blockIndex(containing: location),
           NSIntersectionRange(styler.blocks[i].range, range).length > 0 || NSLocationInRange(range.location, styler.blocks[i].range) {
            endTableEditing()
        }
        // Anchor the reader: the line at the top of the window stays put.
        let visible = scrollView.contentView.bounds
        let origin = textView.textContainerOrigin
        let topGlyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: visible.minY - origin.y + 1), in: textView.textContainer!)
        var topChar = layoutManager.characterIndexForGlyph(at: topGlyph)
        let topY = layoutManager.lineFragmentRect(forGlyphAt: topGlyph, effectiveRange: nil).minY + origin.y - visible.minY
        let delta = (text as NSString).length - range.length
        func map(_ i: Int) -> Int { i < range.location ? i : i >= NSMaxRange(range) ? i + delta : range.location }
        let selection = textView.selectedRange()
        topChar = map(topChar)

        isLoading = true
        finder.noteClientStringWillChange()
        if textView.shouldChangeText(in: range, replacementString: text) {
            storage.replaceCharacters(in: range, with: text)
            textView.didChangeText()
            textView.undoManager?.setActionName("Change from Another App")
        }
        let caret = NSRange(location: min(map(selection.location), storage.length), length: 0)
        textView.setSelectedRange(caret)
        isLoading = false
        lastSelection = [caret]
        styler.styleAll(storage, selection: [caret])
        updateFloats()
        if topChar < storage.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: topChar)
            layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
            let y = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + origin.y - topY
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func reload(from disk: String) {
        guard let note else { return }
        let sel = textView.selectedRange()
        let offset = scrollView.contentView.bounds.origin.y
        note.adopt(diskText: disk)
        setText(disk)
        let clamped = NSRange(location: min(sel.location, storage.length), length: 0)
        isLoading = true
        textView.setSelectedRange(clamped)
        isLoading = false
        lastSelection = [clamped]
        styler.styleAll(storage, selection: [clamped])
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        hasUnsavedEdits = false
    }

    private func resolveConflict(disk: String) {
        guard let note, let window = textView.window else { return }
        resolvingConflict = true
        let alert = NSAlert()
        alert.messageText = "“\(note.title)” was changed by another app."
        alert.informativeText = "You have edits here that haven't been saved. Which version do you want to keep?"
        alert.addButton(withTitle: "Keep My Version")
        alert.addButton(withTitle: "Use Version on Disk")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.resolvingConflict = false
            if response == .alertFirstButtonReturn {
                do {
                    try note.write(self.storage.string)
                    self.hasUnsavedEdits = false
                } catch { self.showError(error) }
            } else {
                self.reload(from: disk)
            }
        }
    }

    private func itemMoved(from: URL?, to: URL?) {
        guard let from, let to, let url = note?.url else { return }
        let fromPath = from.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == fromPath {
            note?.relocate(to: to)
        } else if path.hasPrefix(fromPath + "/") {
            note?.relocate(to: URL(fileURLWithPath: to.standardizedFileURL.path + path.dropFirst(fromPath.count)))
        } else {
            return
        }
        onTitleChange?()
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        textVersion += 1
        guard !isLoading else { return }
        let caret = NSRange(location: NSMaxRange(editedRange), length: 0)
        styler.didEdit(textStorage, editedRange: editedRange, delta: delta, selection: [caret])
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        note?.undoManager
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        hasUnsavedEdits = true
        selectionBar.dismiss()
        onTyping?()
        updateFloats()
        completeLayoutSoon(delay: 0.4)
        if note?.isTemporary == false { scheduleSave() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        if selectedImageLine != nil, !changingImageSelection { clearImageSelection() }
        if textView.isTrackingMouse {
            selectionBar.dismiss()
            return
        }
        applySelectionStyling()
        updateSelectionBar()
        updateSlashSuggestion()
        updateAnswerSuggestion()
    }

    private func applySelectionStyling() {
        let new = textView.selectedRanges.map(\.rangeValue)
        guard new != lastSelection else { return }
        let touched = (lastSelection + new).filter { $0.length > 0 }
        layoutManager.selectedRanges = new
        if !touched.isEmpty || lastSelection.contains(where: { $0.length > 0 }) {
            let union = (lastSelection + new).reduce(NSRange(location: NSNotFound, length: 0)) {
                $0.location == NSNotFound ? $1 : NSUnionRange($0, $1)
            }
            layoutManager.invalidateDisplay(forCharacterRange: union)
        }
        if openTableEditorIfCaretEntered(new) { lastSelection = new; return }
        styler.selectionChanged(storage, from: lastSelection, to: new)
        if !layoutManager.floatFrames.isEmpty || styler.floatOfBlock.count > 0 { updateFloats() }
        lastSelection = new
    }

    func mouseTrackingEnded() {
        applySelectionStyling()
        updateSelectionBar()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        switch url.scheme {
        case "indium-wiki":
            let target = String(url.path.dropFirst())
            if let found = workspace?.resolveWiki(target, from: note?.url) {
                openLinked(found)
            } else if let workspace, !target.isEmpty {
                let name = target.components(separatedBy: "#")[0]
                let folder = note?.url?.deletingLastPathComponent()
                if let created = try? workspace.createNote(in: folder, name: (name as NSString).lastPathComponent) {
                    onOpenNote?(created)
                }
            }
        case "indium-file":
            let path = String(url.path.dropFirst())
            if let found = workspace?.resolveRelative(path, from: note?.url) ?? noteRelative(path) {
                openLinked(found)
            } else {
                NSSound.beep()
            }
        default:
            NSWorkspace.shared.open(url)
        }
        return true
    }

    private func noteRelative(_ path: String) -> URL? {
        guard let dir = note?.url?.deletingLastPathComponent() else { return nil }
        let u = dir.appendingPathComponent(path).standardizedFileURL
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func openLinked(_ url: URL) {
        if Workspace.markdownExtensions.contains(url.pathExtension.lowercased()) {
            onOpenNote?(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Editing helpers

    @discardableResult
    func replace(_ range: NSRange, with string: String, select: NSRange? = nil, actionName: String? = nil) -> Bool {
        guard textView.isEditable, textView.shouldChangeText(in: range, replacementString: string) else { return false }
        storage.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        if let actionName { note?.undoManager.setActionName(actionName) }
        if let select { textView.setSelectedRange(select) }
        return true
    }

    private var ns: NSString { storage.string as NSString }

    private func lineRange(at location: Int) -> (content: NSRange, full: NSRange) {
        var s = 0, e = 0, ce = 0
        ns.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: min(location, ns.length), length: 0))
        return (NSRange(location: s, length: ce - s), NSRange(location: s, length: e - s))
    }

    // MARK: Formatting commands

    func toggleWrap(_ marker: String, name: String) {
        let r = textView.selectedRange()
        let m = (marker as NSString).length
        let text = ns
        if r.location >= m, NSMaxRange(r) + m <= text.length,
           text.substring(with: NSRange(location: r.location - m, length: m)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(r), length: m)) == marker {
            let inner = text.substring(with: r)
            replace(NSRange(location: r.location - m, length: r.length + 2 * m), with: inner,
                    select: NSRange(location: r.location - m, length: r.length), actionName: name)
            return
        }
        let selected = text.substring(with: r)
        if r.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: r.length - 2 * m))
            replace(r, with: inner, select: NSRange(location: r.location, length: r.length - 2 * m), actionName: name)
            return
        }
        replace(r, with: marker + selected + marker, select: NSRange(location: r.location + m, length: r.length), actionName: name)
    }

    func setHeading(_ level: Int) {
        let sel = textView.selectedRange()
        let line = lineRange(at: sel.location).content
        let current = ns.substring(with: line)
        let stripped = current.replacingOccurrences(of: #"^ {0,3}#{1,6}(?:[ \t]+|$)"#, with: "", options: .regularExpression)
        let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""
        let newLine = prefix + stripped
        let delta = (newLine as NSString).length - line.length
        let caret = max(line.location, min(sel.location + delta, line.location + (newLine as NSString).length))
        replace(line, with: newLine, select: NSRange(location: caret, length: 0), actionName: level > 0 ? "Heading \(level)" : "Body Text")
    }

    func currentHeadingLevel() -> Int {
        let line = lineRange(at: textView.selectedRange().location).content
        if case let .heading(level, _) = MarkdownScanner.classify(line: ns.substring(with: line)) { return level }
        return 0
    }

    func insertLink() {
        let r = textView.selectedRange()
        let selected = ns.substring(with: r)
        var url = ""
        if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           s.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
            url = s
        }
        if selected.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
            replace(r, with: "[](\(selected))", select: NSRange(location: r.location + 1, length: 0), actionName: "Link")
        } else if url.isEmpty {
            let insert = "[\(selected)]()"
            let caret = r.location + (insert as NSString).length - 1
            replace(r, with: insert, select: NSRange(location: caret, length: 0), actionName: "Link")
        } else {
            let insert = "[\(selected)](\(url))"
            let caret = selected.isEmpty ? r.location + 1 : r.location + (insert as NSString).length
            replace(r, with: insert, select: NSRange(location: caret, length: 0), actionName: "Link")
        }
    }

    func insertMath(block: Bool) {
        let r = textView.selectedRange()
        let selected = ns.substring(with: r)
        if block {
            let line = lineRange(at: r.location).content
            let needsBreak = r.location > line.location
            let insert = (needsBreak ? "\n" : "") + "$$\n" + selected + "\n$$\n"
            let caret = r.location + (needsBreak ? 1 : 0) + 3 + (selected as NSString).length
            replace(r, with: insert, select: NSRange(location: caret, length: 0), actionName: "Equation")
        } else {
            toggleWrap("$", name: "Inline Math")
        }
    }

    // MARK: Lists

    private static let headingPrefix = try! NSRegularExpression(pattern: "^#{1,6}[ \t]+")

    func handleNewline() -> Bool {
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let line = lineRange(at: sel.location).content
        let text = ns.substring(with: line) as NSString
        let full = NSRange(location: 0, length: text.length)
        // Return at the visible start of a heading, list item or quote (the caret sits
        // just after its hidden prefix) moves the whole line down instead of splitting
        // "## " off from its text.
        let prefix = [Self.headingPrefix, MarkdownScanner.Regex.list, MarkdownScanner.Regex.quote].lazy
            .compactMap { $0.firstMatch(in: text as String, range: full)?.range.length }.first
        if let prefix, sel.location > line.location, sel.location <= line.location + prefix,
           !text.substring(from: prefix).trimmingCharacters(in: .whitespaces).isEmpty {
            textView.insertText("\n", replacementRange: NSRange(location: line.location, length: 0))
            textView.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return true
        }
        if let m = MarkdownScanner.Regex.list.firstMatch(in: text as String, range: full) {
            let prefixLength = m.range.length
            guard sel.location >= line.location + prefixLength else { return false }
            let rest = text.substring(from: prefixLength).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                replace(line, with: "", select: NSRange(location: line.location, length: 0), actionName: "Typing")
                return true
            }
            let indent = text.substring(with: m.range(at: 1))
            var marker = text.substring(with: m.range(at: 2))
            if let n = Int(marker.dropLast()) { marker = "\(n + 1)\(marker.last!)" }
            var insert = "\n" + indent + marker + " "
            if m.range(at: 3).location != NSNotFound { insert += "[ ] " }
            textView.insertText(insert, replacementRange: sel)
            return true
        }
        if let m = MarkdownScanner.Regex.quote.firstMatch(in: text as String, range: full) {
            guard sel.location >= line.location + m.range.length else { return false }
            if text.substring(from: m.range.length).trimmingCharacters(in: .whitespaces).isEmpty {
                replace(line, with: "", select: NSRange(location: line.location, length: 0), actionName: "Typing")
                return true
            }
            let prefix = text.substring(with: m.range)
            textView.insertText("\n" + (prefix.hasSuffix(" ") ? prefix : prefix + " "), replacementRange: sel)
            return true
        }
        return false
    }

    func indentListItem(outdent: Bool) -> Bool {
        let sel = textView.selectedRange()
        let first = lineRange(at: sel.location).full
        let last = lineRange(at: max(sel.location, NSMaxRange(sel) - (sel.length > 0 ? 1 : 0))).full
        let block = NSUnionRange(first, last)
        let lines = ns.substring(with: block).components(separatedBy: "\n")
        let isList = lines.allSatisfy { l in
            l.isEmpty || MarkdownScanner.Regex.list.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil
        }
        guard isList, lines.contains(where: { !$0.isEmpty }) else { return false }
        var firstDelta = 0
        let changed = lines.enumerated().map { i, l -> String in
            guard !l.isEmpty else { return l }
            var out = l
            if outdent {
                if out.hasPrefix("\t") { out.removeFirst() }
                else { out = String(out.dropFirst(min(4, out.prefix { $0 == " " }.count))) }
            } else {
                out = "\t" + out
            }
            if i == 0 { firstDelta = (out as NSString).length - (l as NSString).length }
            return out
        }
        let joined = changed.joined(separator: "\n")
        let delta = (joined as NSString).length - block.length
        let newSel = sel.length == 0
            ? NSRange(location: max(block.location, sel.location + firstDelta), length: 0)
            : NSRange(location: block.location, length: max(0, block.length + delta - (ns.substring(with: block).hasSuffix("\n") ? 1 : 0)))
        replace(block, with: joined, select: newSel, actionName: outdent ? "Outdent" : "Indent")
        return true
    }

    // MARK: Images

    func image(for ref: ImageRef) -> NSImage? {
        let key = ref.source.removingPercentEncoding ?? ref.source
        if let data = note?.memoryImages[key] { return ImageCache.shared.image(data: data, key: key) }
        if ref.source.hasPrefix("http://") || ref.source.hasPrefix("https://") {
            return URL(string: ref.source).flatMap { ImageCache.shared.remote($0) }
        }
        if let url = workspace?.resolveImage(ref, from: note?.url) ?? noteRelative(key) {
            return ImageCache.shared.image(at: url)
        }
        return nil
    }

    func pasteboardHasImages(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { MarkdownScanner.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            return true
        }
        let types = pb.types ?? []
        if types.contains(.string) || types.contains(.fileURL) { return false }
        return types.contains(.png) || types.contains(.tiff)
    }

    /// Imports images from a pasteboard and inserts Markdown references on their own lines.
    func insertImages(from pb: NSPasteboard, at index: Int?) -> Bool {
        guard textView.isEditable, pasteboardHasImages(pb) else { return false }
        var items: [(data: Data, ext: String, name: String?)] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls where MarkdownScanner.imageExtensions.contains(url.pathExtension.lowercased()) {
                if let data = try? Data(contentsOf: url) { items.append((data, url.pathExtension.lowercased(), url.lastPathComponent)) }
            }
        }
        if items.isEmpty {
            if let png = pb.data(forType: .png) {
                items.append((png, "png", nil))
            } else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                items.append((png, "png", nil))
            }
        }
        return insertImageData(items, at: index)
    }

    func insertImageFiles(_ urls: [URL]) {
        let items = urls.compactMap { url -> (Data, String, String?)? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (data, url.pathExtension.lowercased(), url.lastPathComponent)
        }
        _ = insertImageData(items, at: nil)
    }

    private func insertImageData(_ items: [(data: Data, ext: String, name: String?)], at index: Int?) -> Bool {
        guard !items.isEmpty, let note else { return false }
        var refs: [String] = []
        for item in items {
            if note.isTemporary || workspace == nil {
                let base = item.name.map { ($0 as NSString).deletingPathExtension } ?? Workspace.imageBaseName()
                var path = "attachments/\(base).\(item.ext)"
                var n = 2
                while note.memoryImages[path] != nil { path = "attachments/\(base) \(n).\(item.ext)"; n += 1 }
                note.memoryImages[path] = item.data
                refs.append("![](\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))")
            } else if let workspace {
                do {
                    let url = try workspace.storeImage(item.data, ext: item.ext, for: note.url, preferredName: item.name)
                    refs.append("![](\(Workspace.markdownPath(for: url, from: note.url, root: workspace.root)))")
                } catch {
                    showError(error)
                    return false
                }
            }
        }
        let location = index ?? textView.selectedRange().location
        let range = index.map { NSRange(location: $0, length: 0) } ?? textView.selectedRange()
        let line = lineRange(at: location).content
        let before = location > line.location ? "\n" : ""
        let after = NSMaxRange(range) < NSMaxRange(line) ? "\n" : (NSMaxRange(line) == ns.length ? "\n" : "")
        let insert = before + refs.joined(separator: "\n") + after
        let caret = range.location + (insert as NSString).length
        replace(range, with: insert, select: NSRange(location: caret, length: 0), actionName: "Insert Image")
        return true
    }

    // Object-style image selection: clicking an image selects it without revealing its source.

    func handleClick(at point: NSPoint, clickCount: Int) -> Bool {
        if let editor = tableEditor, !editor.frame.contains(point) { endTableEditing() }
        guard let container = textView.textContainer else { return false }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let blocks = layoutManager.floatBlocks(origin: origin) + layoutManager.blockRects(in: chars, origin: origin)
        for block in blocks where block.content.insetBy(dx: -4, dy: -4).contains(point) {
            switch block.decoration.content {
            case .image:
                if block.decoration.placement != .below || clickCount == 1 {
                    selectImage(at: block.range.location)
                    return true
                }
            case let .table(table):
                if block.decoration.placement != .below {
                    let local = NSPoint(x: point.x - block.content.minX, y: point.y - block.content.minY)
                    let cell = table.cell(at: local) ?? (0, 0)
                    beginTableEditing(at: lineRange(at: block.range.location).content.location, row: cell.row, column: cell.column)
                    return true
                }
            case .math:
                if block.decoration.placement == .replace {
                    textView.window?.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: lineRange(at: block.range.location).content.location + 2, length: 0))
                    return true
                }
            }
        }
        return false
    }

    private func selectImage(at location: Int) {
        let line = lineRange(at: location)
        textView.window?.makeFirstResponder(textView)
        let previous = selectedImageLine
        selectedImageLine = line.content.location
        styler.selectedImageLine = line.content.location
        changingImageSelection = true
        textView.setSelectedRange(NSRange(location: NSMaxRange(line.content), length: 0))
        changingImageSelection = false
        lastSelection = [textView.selectedRange()]
        if let previous, previous != line.content.location { styler.restyleBlock(at: previous, in: storage) }
        styler.restyleBlock(at: line.content.location, in: storage)
        positionImageControls()
        textView.updateInsertionPointStateAndRestartTimer(false)
        textView.needsDisplay = true
    }

    private func clearImageSelection() {
        guard let line = selectedImageLine else { return }
        selectedImageLine = nil
        styler.selectedImageLine = nil
        imageControls.isHidden = true
        captionPopover?.close()
        if line < storage.length { styler.restyleBlock(at: line, in: storage) }
    }

    var hasSelectedImage: Bool { selectedImageLine != nil }

    func deselectImage() -> Bool {
        guard selectedImageLine != nil else { return false }
        clearImageSelection()
        applySelectionStyling()
        return true
    }

    private func selectedImage() -> (line: NSRange, full: NSRange, ref: ImageRef)? {
        guard let loc = selectedImageLine, loc < storage.length else { return nil }
        let line = lineRange(at: loc)
        guard let ref = MarkdownScanner.imageLine(ns.substring(with: line.content)) else { return nil }
        return (line.content, line.full, ref)
    }

    private func positionImageControls() {
        guard let loc = selectedImageLine, let container = textView.textContainer else {
            imageControls.isHidden = true
            return
        }
        layoutManager.ensureLayout(for: container)
        let chars = NSRange(location: loc, length: max(0, min(1, storage.length - loc)))
        guard let block = layoutManager.blockRects(in: chars, origin: textView.textContainerOrigin).first,
              let image = selectedImage() else {
            imageControls.isHidden = true
            return
        }
        imageControls.configure(currentWidth: image.ref.width, column: styler.config.columnWidth, captionAllowed: !image.ref.isWiki)
        let size = imageControls.fittingSize
        var y = block.content.minY - size.height - 10
        if y < textView.visibleRect.minY + 40 { y = block.content.minY + 10 }
        imageControls.frame = NSRect(x: round(block.content.midX - size.width / 2), y: round(y), width: size.width, height: size.height)
        if imageControls.isHidden {
            imageControls.isHidden = false
            imageControls.alphaValue = 0
            imageControls.wantsLayer = true
            imageControls.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 4))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
                ctx.allowsImplicitAnimation = true
                imageControls.animator().alphaValue = 1
                imageControls.layer?.setAffineTransform(.identity)
            }
        }
    }

    private static func markdown(for ref: ImageRef) -> String {
        let width = ref.width.map { "|\(Int($0))" } ?? ""
        if ref.isWiki { return "![[\(ref.source)\(width)]]" }
        let src = ref.source.contains(" ") ? "<\(ref.source)>" : ref.source
        return "![\(ref.alt)\(width)](\(src))"
    }

    private func rewriteSelectedImage(_ transform: (inout ImageRef) -> Void, actionName: String) {
        guard let (line, _, original) = selectedImage() else { return }
        var ref = original
        transform(&ref)
        let loc = line.location
        changingImageSelection = true
        replace(line, with: Self.markdown(for: ref), actionName: actionName)
        textView.setSelectedRange(NSRange(location: NSMaxRange(lineRange(at: loc).content), length: 0))
        changingImageSelection = false
        styler.restyleBlock(at: loc, in: storage)
        positionImageControls()
    }

    private func setSelectedImageWidth(fraction: CGFloat?) {
        let column = styler.config.columnWidth
        rewriteSelectedImage({ ref in ref.width = fraction.map { round(column * $0) } }, actionName: "Image Size")
    }

    private func editSelectedImageCaption() {
        guard let (_, _, ref) = selectedImage() else { return }
        let field = NSTextField(string: ref.alt)
        field.placeholderString = "Caption"
        field.frame = NSRect(x: 10, y: 10, width: 260, height: 24)
        field.focusRingType = .none
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        vc.view.addSubview(field)
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        let commit = CaptionCommitter { [weak self, weak popover] text in
            self?.rewriteSelectedImage({ $0.alt = text.replacingOccurrences(of: "]", with: "") }, actionName: "Caption")
            popover?.close()
        }
        field.target = commit
        field.action = #selector(CaptionCommitter.commit(_:))
        objc_setAssociatedObject(popover, &CaptionCommitter.key, commit, .OBJC_ASSOCIATION_RETAIN)
        captionPopover = popover
        popover.show(relativeTo: imageControls.bounds, of: imageControls, preferredEdge: .maxY)
        vc.view.window?.makeFirstResponder(field)
    }

    func deleteSelectedImage() -> Bool {
        guard let (_, full, _) = selectedImage() else { return false }
        let loc = full.location
        selectedImageLine = nil
        styler.selectedImageLine = nil
        imageControls.isHidden = true
        replace(full, with: "", select: NSRange(location: loc, length: 0), actionName: "Remove Image")
        return true
    }
}

private final class CaptionCommitter: NSObject {
    static var key = 0
    let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    @objc func commit(_ sender: NSTextField) { handler(sender.stringValue) }
}
