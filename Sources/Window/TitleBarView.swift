import AppKit

/// The only permanent chrome: a strip sharing the title bar's height, holding the
/// document title and a few quiet controls. Controls fade out while typing.
final class TitleBarView: NSView, NSTextFieldDelegate, NSMenuDelegate {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    static let height: CGFloat = 38

    var onRename: ((String) -> Void)?
    /// Rename while still typing; conflicts should be skipped quietly.
    var onLiveRename: ((String) -> Void)?
    /// Rename finished or was cancelled; the window returns focus to the page.
    var onRenameEnded: (() -> Void)?
    var headingLevel: (() -> Int)?

    let filesButton: HoverButton
    let searchButton: HoverButton
    private let headingButton: HoverButton
    private let boldButton: HoverButton
    private let italicButton: HoverButton
    private let linkButton: HoverButton
    private let imageButton: HoverButton
    let moreButton: HoverButton
    private let titleField = TitleField()
    private var titleIcon: HoverButton!
    /// The note's icon was clicked: offer the icon picker.
    var onIconClick: ((NSView) -> Void)?
    var iconAvailable = false { didSet { titleIcon.isHidden = !iconAvailable } }
    private let leftStack = NSStackView()
    private let rightStack = NSStackView()
    private(set) var chromeVisible = true
    private var renaming = false
    private var titleHover = false { didSet { if titleHover != oldValue { needsDisplay = true } } }
    private var centerConstraints: [NSLayoutConstraint] = []
    private var leadingConstraint: NSLayoutConstraint!

    var title: String = "" {
        didSet { if !renaming { titleField.stringValue = title } }
    }
    var isTemporary = false {
        didSet {
            titleField.font = isTemporary ? NSFont.systemFont(ofSize: 13, weight: .regular).adding(.italic) : NSFont.systemFont(ofSize: 13, weight: .medium)
            titleField.textColor = isTemporary ? Palette.tertiaryText : Palette.secondaryText
            titleField.isRenamable = !isTemporary
            filesButton.isHidden = isTemporary
            searchButton.isHidden = isTemporary
        }
    }
    var titleIsRenamable: Bool {
        get { titleField.isRenamable }
        set { titleField.isRenamable = newValue && !isTemporary }
    }
    var formattingEnabled = true {
        didSet { rightStack.arrangedSubviews.filter { $0 !== moreButton }.forEach { $0.isHidden = !formattingEnabled } }
    }

    override init(frame: NSRect) {
        filesButton = HoverButton(symbol: "sidebar.left", label: "Files (⌃⌘S)", target: nil, action: #selector(DocumentWindowController.toggleFiles(_:)))
        searchButton = HoverButton(symbol: "magnifyingglass", label: "Open Note (⌘O)", target: nil, action: #selector(DocumentWindowController.openQuickly(_:)))
        headingButton = HoverButton(symbol: "textformat.size", label: "Text Style", target: nil, action: nil)
        boldButton = HoverButton(symbol: "bold", label: "Bold (⌘B)", target: nil, action: #selector(DocumentWindowController.toggleBold(_:)))
        italicButton = HoverButton(symbol: "italic", label: "Italic (⌘I)", target: nil, action: #selector(DocumentWindowController.toggleItalic(_:)))
        linkButton = HoverButton(symbol: "link", label: "Link (⌘K)", target: nil, action: #selector(DocumentWindowController.insertLink(_:)))
        imageButton = HoverButton(symbol: "photo", label: "Insert Image (⇧⌘I)", target: nil, action: #selector(DocumentWindowController.insertImage(_:)))
        moreButton = HoverButton(symbol: "ellipsis", label: "More", target: nil, action: nil)
        super.init(frame: frame)
        installArrowCursorArea()

        headingButton.popUpMenu = headingMenu()
        moreButton.popUpMenu = moreMenu()

        for stack in [leftStack, rightStack] {
            stack.orientation = .horizontal
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        leftStack.addArrangedSubview(filesButton)
        leftStack.addArrangedSubview(searchButton)
        for b in [headingButton, boldButton, italicButton, linkButton, imageButton] { rightStack.addArrangedSubview(b) }
        rightStack.setCustomSpacing(10, after: imageButton)
        rightStack.addArrangedSubview(moreButton)

        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.usesSingleLineMode = true
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.onBeginRename = { [weak self] in
            self?.renaming = true
            self?.titleHover = false
        }
        titleField.onHoverChange = { [weak self] on in self?.titleHover = on }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleField)
        titleIcon = HoverButton(symbol: "doc.text", label: "Change Icon", pointSize: 12, target: self, action: #selector(iconClicked))
        titleIcon.restingTint = Palette.tertiaryText
        titleIcon.isHidden = true
        addSubview(titleIcon)
        NSLayoutConstraint.activate([
            titleIcon.trailingAnchor.constraint(equalTo: titleField.leadingAnchor, constant: -9),
            titleIcon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
        ])
        isTemporary = false

        leadingConstraint = leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 80)
        centerConstraints = [
            leftStack.centerYAnchor.constraint(equalTo: topAnchor, constant: 19),
            rightStack.centerYAnchor.constraint(equalTo: topAnchor, constant: 19),
            titleField.centerYAnchor.constraint(equalTo: topAnchor, constant: 19),
        ]
        NSLayoutConstraint.activate(centerConstraints + [
            leadingConstraint,
            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleField.centerXAnchor.constraint(equalTo: centerXAnchor).withPriority(.defaultHigh),
            titleField.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 16),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -16),
        ])
    }

    /// Aligns the controls with the window's traffic lights.
    func alignWithTrafficLights() {
        guard let window, let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview else { return }
        let frame = superview.convert(zoom.frame, to: nil)
        let centerFromTop = window.frame.height - frame.midY
        let fullScreen = window.styleMask.contains(.fullScreen)
        let center = fullScreen ? 19 : round(centerFromTop)
        for c in centerConstraints { c.constant = center }
        leadingConstraint.constant = fullScreen ? 12 : round(frame.maxX + 14)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Empty title bar space passes clicks to the system title bar underneath, so
    // dragging and double-clicking behave exactly as in any Mac app. In full screen
    // the window can't move, and dragging it would pull it out of full screen.
    override var mouseDownCanMoveWindow: Bool { window?.styleMask.contains(.fullScreen) != true }

    override func mouseDown(with event: NSEvent) {
        if window?.styleMask.contains(.fullScreen) == true { return }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A pill behind the name on hover, hinting that it can be renamed.
        guard titleHover else { return }
        Palette.hoverFill.setFill()
        NSBezierPath(roundedRect: titleField.frame.insetBy(dx: -8, dy: -4), xRadius: 8, yRadius: 8).fill()
    }

    override var isFlipped: Bool { true }

    func setChromeVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? (visible ? 0.18 : 0.35) : 0
            leftStack.animator().alphaValue = visible ? 1 : 0
            rightStack.animator().alphaValue = visible ? 1 : 0
        }
    }

    func beginRename() {
        titleField.beginRename()
    }

    /// The note's icon beside its title. Clicking it opens the icon picker.
    func setIcon(_ symbol: String?) {
        let name = symbol ?? "doc.text"
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "Note icon")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) else { return }
        titleIcon.restingTint = symbol == nil ? Palette.syntax : Palette.tertiaryText
        guard titleIcon.image != image else { return }
        // Cross-fade to the new symbol.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            titleIcon.animator().alphaValue = 0.2
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.titleIcon.image = image
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; self.titleIcon.animator().alphaValue = 1 }
        })
    }

    @objc private func iconClicked() {
        onIconClick?(titleIcon)
    }

    // MARK: Menus

    private func headingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let items: [(String, Selector, String)] = [
            ("Body", #selector(DocumentWindowController.setBody(_:)), "0"),
            ("Heading 1", #selector(DocumentWindowController.setHeading1(_:)), "1"),
            ("Heading 2", #selector(DocumentWindowController.setHeading2(_:)), "2"),
            ("Heading 3", #selector(DocumentWindowController.setHeading3(_:)), "3"),
        ]
        for (i, (title, action, key)) in items.enumerated() {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Strikethrough", action: #selector(DocumentWindowController.toggleStrikethrough(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Inline Code", action: #selector(DocumentWindowController.toggleInlineCode(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Highlight", action: #selector(DocumentWindowController.toggleHighlight(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Inline Equation", action: #selector(DocumentWindowController.insertInlineMath(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Display Equation", action: #selector(DocumentWindowController.insertDisplayMath(_:)), keyEquivalent: ""))
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "New Note", action: #selector(DocumentWindowController.newNote(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "New Temporary Note", action: #selector(AppDelegate.newTemporaryNote(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Export as PDF…", action: #selector(DocumentWindowController.exportPDF(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Print…", action: #selector(DocumentWindowController.printNote(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Rename…", action: #selector(DocumentWindowController.renameNote(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show in Finder", action: #selector(DocumentWindowController.revealInFinder(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Move to Trash", action: #selector(DocumentWindowController.trashNote(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ""))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let level = headingLevel?() ?? 0
        for item in menu.items where item.tag >= 0 && item.tag <= 3 && item.action != nil {
            if item.title.hasPrefix("Heading") || item.title == "Body" { item.state = item.tag == level ? .on : .off }
        }
    }

    // MARK: Rename

    private var renameTimer: Timer?

    /// Renames follow typing, a moment after the last keystroke: no Return or ⌘S needed.
    func controlTextDidChange(_ obj: Notification) {
        guard renaming else { return }
        renameTimer?.invalidate()
        renameTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self, self.renaming else { return }
            let name = self.titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != self.title { self.onLiveRename?(name) }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        renameTimer?.invalidate()
        guard renaming else { return }
        renaming = false
        let newName = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        titleField.endRename()
        titleField.stringValue = title
        if !newName.isEmpty, newName != title { onRename?(newName) }
        onRenameEnded?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renaming = false
            titleField.stringValue = title
            titleField.endRename()
            onRenameEnded?()
            return true
        }
        return false
    }
}

/// The document title: a borderless field that AppKit edits natively on click.
/// Clicking selects the whole name, like renaming in Finder.
final class TitleField: NSTextField {
    var isRenamable = true {
        didSet {
            isEditable = isRenamable
            isSelectable = isRenamable
        }
    }
    var onBeginRename: (() -> Void)?
    /// The bar draws the hover pill so it can wrap the note icon too.
    var onHoverChange: ((Bool) -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { onHoverChange?(hovering && !isRenaming) } } }

    private var isRenaming: Bool { currentEditor() != nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isRenamable ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = isRenamable
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    /// The window hands focus to the field before `mouseDown` runs, so a rename
    /// starts here: however the field got focus, typing will rename the note.
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if isRenamable {
            onBeginRename?()
            textColor = Palette.text
            hovering = false
            invalidateIntrinsicContentSize()
            justFocused = true
            DispatchQueue.main.async { self.justFocused = false }
        }
        return true
    }

    private var justFocused = false

    override func mouseDown(with event: NSEvent) {
        let selectEverything = justFocused
        super.mouseDown(with: event)
        // The click that starts a rename selects the whole name, like Finder.
        if selectEverything { currentEditor()?.selectAll(nil) }
    }

    /// Hugs its text, including while renaming. (Editable fields report no intrinsic
    /// width on their own, which would collapse the title.)
    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        guard let font else { return base }
        let text = currentEditor()?.string ?? stringValue
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(max(width, 24)) + 6, height: max(base.height, ceil(font.lineHeight) + 2))
    }

    override var stringValue: String {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }

    func beginRename() {
        guard isRenamable else { return }
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
        invalidateIntrinsicContentSize()
    }

    func endRename() {
        textColor = Palette.secondaryText
        hovering = false
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
