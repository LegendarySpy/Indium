import AppKit

/// Temporary file browser that slides over the page from the left.
final class FilePanelView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    static let width: CGFloat = 264

    var workspace: Workspace? { didSet { reload() } }
    var currentURL: URL? { didSet { outline.reloadData(); revealCurrent() } }
    var onOpen: ((URL) -> Void)?
    var onDismiss: (() -> Void)?
    var onCreateNote: ((URL?) -> Void)?

    private let outline = PanelOutlineView()
    private let scroll = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var expanded = Set<URL>()
    private var renamingURL: URL?

    private let inner = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        installArrowCursorArea()
        // Hosted in a popover, which supplies the Liquid Glass surface.
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor),
            inner.topAnchor.constraint(equalTo: topAnchor),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(titleLabel)

        let newNote = HoverButton(symbol: "square.and.pencil", label: "New Note", pointSize: 12, target: self, action: #selector(newNoteClicked))
        let newFolder = HoverButton(symbol: "folder.badge.plus", label: "New Folder", pointSize: 12, target: self, action: #selector(newFolderClicked))
        let buttons = NSStackView(views: [newNote, newFolder])
        buttons.spacing = 0
        buttons.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(buttons)

        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 13
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.menu = {
            let m = NSMenu()
            m.delegate = self
            return m
        }()
        outline.panel = self
        outline.setAccessibilityLabel("Files")

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        inner.addSubview(scroll)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: inner.topAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }


    func focus() {
        window?.makeFirstResponder(outline)
        if outline.selectedRow < 0, outline.numberOfRows > 0 {
            outline.selectRowIndexes([max(0, rowForCurrent() ?? 0)], byExtendingSelection: false)
        }
    }

    func reload() {
        titleLabel.stringValue = workspace?.name ?? ""
        outline.reloadData()
        for url in expanded.sorted(by: { $0.path.count < $1.path.count }) {
            if let node = node(for: url) { outline.expandItem(node) }
        }
        revealCurrent()
    }

    private func node(for url: URL, in root: FileNode? = nil) -> FileNode? {
        guard let start = root ?? workspace?.tree else { return nil }
        let target = url.standardizedFileURL
        for child in start.children {
            if child.url.standardizedFileURL == target { return child }
            if child.isFolder, target.path.hasPrefix(child.url.standardizedFileURL.path + "/"),
               let found = node(for: url, in: child) { return found }
        }
        return nil
    }

    private func revealCurrent() {
        guard let currentURL, let node = node(for: currentURL) else { return }
        var chain: [FileNode] = []
        var p = node.parent
        while let n = p, n.parent != nil { chain.insert(n, at: 0); p = n.parent }
        for n in chain { outline.expandItem(n) }
        let row = outline.row(forItem: node)
        if row >= 0 { outline.scrollRowToVisible(row) }
    }

    private func rowForCurrent() -> Int? {
        guard let currentURL, let node = node(for: currentURL) else { return nil }
        let r = outline.row(forItem: node)
        return r >= 0 ? r : nil
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? workspace?.tree)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? workspace!.tree).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? FileNode { expanded.insert(n.url) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? FileNode { expanded.remove(n.url) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("cell"), owner: self) as? FileCell ?? FileCell()
        cell.identifier = .init("cell")
        cell.configure(node, isCurrent: node.url.standardizedFileURL == currentURL?.standardizedFileURL,
                       symbol: node.isFolder ? nil : NoteIcons.shared.icon(for: node.url, in: workspace))
        cell.textField?.delegate = self
        return cell
    }


    // Dragging files between folders.

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView === outlineView else { return [] }
        var target = item as? FileNode
        if let t = target, !t.isFolder { target = t.parent }
        let folder = target ?? workspace?.tree
        guard let folder else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        for url in urls {
            if url.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL { return [] }
            if folder.url.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") || folder.url == url { return [] }
        }
        outlineView.setDropItem(folder === workspace?.tree ? nil : folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let workspace else { return false }
        let folder = (item as? FileNode)?.url ?? workspace.root
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        var ok = false
        for url in urls {
            do {
                _ = try workspace.move(url, into: folder)
                expanded.insert(folder)
                ok = true
            } catch {
                showError(error)
            }
        }
        reload()
        return ok
    }

    // MARK: Actions

    @objc private func rowClicked() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isFolder {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpen?(node.url)
        }
    }

    func openSelection() {
        rowClicked()
    }

    private var targetFolder: URL? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return nil }
        return node.isFolder ? node.url : node.url.deletingLastPathComponent()
    }

    @objc private func newNoteClicked() {
        onCreateNote?(targetFolder)
    }

    @objc private func newFolderClicked() {
        guard let workspace else { return }
        do {
            let parent = targetFolder
            let url = try workspace.createFolder(in: parent)
            if let parent { expanded.insert(parent) }
            reload()
            beginRename(url)
        } catch { showError(error) }
    }

    func beginRename(_ url: URL) {
        guard let node = node(for: url) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell,
              let field = cell.textField else { return }
        outline.scrollRowToVisible(row)
        renamingURL = url
        field.isEditable = true
        field.isSelectable = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let url = renamingURL, let workspace else { return }
        renamingURL = nil
        field.isEditable = false
        field.isSelectable = false
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = node(for: url)?.name ?? ""
        guard !name.isEmpty, name != current else {
            field.stringValue = current
            return
        }
        do {
            _ = try workspace.rename(url, to: name)
        } catch {
            field.stringValue = current
            showError(error)
        }
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), let url = renamingURL {
            (control as? NSTextField)?.stringValue = node(for: url)?.name ?? ""
            window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        let node = row >= 0 ? outline.item(atRow: row) as? FileNode : nil
        menu.addItem(withTitle: "New Note", action: #selector(newNoteClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Folder", action: #selector(newFolderClicked), keyEquivalent: "").target = self
        guard node != nil else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: #selector(renameClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealClicked), keyEquivalent: "").target = self
        if AppSettings.shared.suggestIcons, NoteIcons.isAvailable, node?.isFolder == false {
            menu.addItem(withTitle: "Suggest New Icon", action: #selector(suggestIconClicked), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(trashClicked), keyEquivalent: "").target = self
    }

    private var clickedNode: FileNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    @objc private func renameClicked() {
        if let n = clickedNode { beginRename(n.url) }
    }

    @objc private func suggestIconClicked() {
        guard let n = clickedNode, let workspace, let text = try? Note.read(n.url) else { return }
        NoteIcons.shared.suggest(for: n.url, text: text, in: workspace, force: true)
    }

    @objc private func revealClicked() {
        if let n = clickedNode { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
    }

    @objc func trashClicked() {
        guard let node = clickedNode, let workspace, let window else { return }
        let confirm = {
            do { try workspace.trash(node.url) } catch { self.showError(error) }
            self.reload()
        }
        if node.isFolder {
            let alert = NSAlert()
            alert.messageText = "Move “\(node.name)” to the Trash?"
            alert.informativeText = "The folder and everything in it will be moved to the Trash."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { confirm() } }
        } else {
            confirm()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

private final class PanelOutlineView: NSOutlineView {
    weak var panel: FilePanelView?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: panel?.openSelection()
        case 53: panel?.cancelOperation(nil)
        case 51 where event.modifierFlags.contains(.command): panel?.trashClicked()
        default: super.keyDown(with: event)
        }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: 2, dy: 0)
    }
}

private final class FileCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.focusRingType = .none
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ node: FileNode, isCurrent: Bool, symbol: String?) {
        label.stringValue = node.name
        label.font = NSFont.systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
        label.textColor = .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.image = node.isFolder
            ? NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?.withSymbolConfiguration(config)
            : NSImage(systemSymbolName: symbol ?? "doc.text", accessibilityDescription: "Note")?.withSymbolConfiguration(config)
        icon.contentTintColor = node.isFolder ? .controlAccentColor : .secondaryLabelColor
        setAccessibilityLabel(node.name)
    }
}
