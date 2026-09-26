import AppKit

/// One row of the sidebar. Rows are kept per path, so a rescan updates the list in
/// place: a row that is still there keeps its selection, expansion and any rename
/// in progress, instead of the whole list being rebuilt under the pointer.
private final class SidebarItem: NSObject {
    let url: URL
    let isFolder: Bool

    init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }

    var name: String { isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
}

/// The folder's notes, docked at the window's left edge on a glass panel.
/// Click a note to open it; click a folder to select it (its arrow or a double
/// click opens and closes it). New notes and folders go into the selected folder.
final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    static let width: CGFloat = 256

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    var workspace: Workspace? {
        didSet {
            guard workspace !== oldValue else { return }
            loadExpanded()
            reloadAll()
        }
    }
    var currentURL: URL? {
        didSet {
            guard currentURL?.standardizedFileURL != oldValue?.standardizedFileURL else { return }
            refreshCell(for: oldValue)
            refreshCell(for: currentURL)
            selectCurrent()
        }
    }
    var onOpen: ((URL) -> Void)?
    /// Escape: back to the page.
    var onDismiss: (() -> Void)?
    var onCreateNote: ((URL?) -> Void)?

    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    /// The folder's name; click it to switch folders.
    private let titleButton = NSButton(title: "", target: nil, action: nil)

    private var items: [URL: SidebarItem] = [:]
    /// The children the outline has been handed, by parent (the root under its own URL).
    private var shown: [URL: [SidebarItem]] = [:]
    private var nodes: [URL: FileNode] = [:]
    private var expanded = Set<URL>()
    private var restoringExpansion = false
    private var renaming: SidebarItem?
    /// Where focus goes when a rename ends: a note named right after it was made is
    /// written next, so the page takes over.
    private var focusPageAfterRename = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        installArrowCursorArea()

        titleButton.isBordered = false
        titleButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleButton.contentTintColor = .secondaryLabelColor
        titleButton.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        titleButton.imagePosition = .imageTrailing
        titleButton.imageHugsTitle = true
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.target = self
        titleButton.action = #selector(showFolders)
        titleButton.toolTip = "Switch Folder"
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleButton)

        let newNote = HoverButton(symbol: "square.and.pencil", label: "New Note", pointSize: 12, target: self, action: #selector(newNoteClicked))
        let newFolder = HoverButton(symbol: "folder.badge.plus", label: "New Folder", pointSize: 12, target: self, action: #selector(newFolderClicked))
        let buttons = NSStackView(views: [newNote, newFolder])
        buttons.spacing = 0
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        // A custom size, so the system doesn't restyle the labels (the open note is bold).
        outline.rowSizeStyle = .custom
        outline.rowHeight = 28
        outline.indentationPerLevel = 13
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.menu = {
            let m = NSMenu()
            m.delegate = self
            return m
        }()
        outline.sidebar = self
        outline.setAccessibilityLabel("Files")
        // Renamed and moved folders stay open. Posted before the rescan that shows them.
        NotificationCenter.default.addObserver(self, selector: #selector(itemMoved(_:)), name: Workspace.didMoveItem, object: nil)

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            titleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleButton.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -6),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: titleButton.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: titleButton.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func focus() {
        window?.makeFirstResponder(outline)
        if outline.selectedRow < 0 { selectCurrent() }
    }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    // MARK: Model

    private func key(_ url: URL) -> URL { url.standardizedFileURL }

    private func item(for node: FileNode) -> SidebarItem {
        let k = key(node.url)
        if let existing = items[k], existing.isFolder == node.isFolder { return existing }
        let made = SidebarItem(url: k, isFolder: node.isFolder)
        items[k] = made
        return made
    }

    private func indexNodes() {
        nodes = [:]
        guard let tree = workspace?.tree else { return }
        var stack = [tree]
        while let node = stack.popLast() {
            nodes[key(node.url)] = node
            stack.append(contentsOf: node.children)
        }
    }

    private var rootKey: URL? { workspace.map { key($0.root) } }

    private func children(of parent: URL) -> [SidebarItem] {
        (nodes[parent]?.children ?? []).map(item(for:))
    }

    private func sidebarItem(for url: URL?) -> SidebarItem? {
        url.flatMap { items[key($0)] }
    }

    /// Throws the list away and builds it again: only for a different folder.
    private func reloadAll() {
        cancelRename()
        items = [:]
        shown = [:]
        indexNodes()
        titleButton.title = workspace?.name ?? ""
        outline.reloadData()
        restoreExpansion()
        selectCurrent()
    }

    /// The folder changed on disk: update only the rows that changed.
    func sync() {
        guard let rootKey else { return }
        titleButton.title = workspace?.name ?? ""
        indexNodes()
        if let renaming, nodes[renaming.url] == nil { cancelRename() }
        var inserted: [SidebarItem] = []
        outline.beginUpdates()
        syncChildren(of: rootKey, parent: nil, inserted: &inserted)
        outline.endUpdates()
        // Folders that come back (renamed, moved, or undone) open the way they were.
        restoringExpansion = true
        for item in inserted where item.isFolder && expanded.contains(item.url) { outline.expandItem(item) }
        restoringExpansion = false
        let live = Set(nodes.keys)
        items = items.filter { live.contains($0.key) }
        if outline.selectedRow < 0 { selectCurrent() }
    }

    private func syncChildren(of parentURL: URL, parent: SidebarItem?, inserted: inout [SidebarItem]) {
        guard let old = shown[parentURL] else { return }
        let new = children(of: parentURL)
        if !old.elementsEqual(new, by: ===) {
            let newIDs = Set(new.map(ObjectIdentifier.init))
            let oldIDs = Set(old.map(ObjectIdentifier.init))
            let removed = IndexSet(old.indices.filter { !newIDs.contains(ObjectIdentifier(old[$0])) })
            let added = IndexSet(new.indices.filter { !oldIDs.contains(ObjectIdentifier(new[$0])) })
            shown[parentURL] = new
            if !removed.isEmpty { outline.removeItems(at: removed, inParent: parent, withAnimation: []) }
            if !added.isEmpty {
                outline.insertItems(at: added, inParent: parent, withAnimation: [])
                inserted += added.map { new[$0] }
            }
        }
        for child in new where child.isFolder && outline.isItemExpanded(child) {
            syncChildren(of: child.url, parent: child, inserted: &inserted)
        }
    }

    // MARK: Expansion, remembered per folder

    private var expansionKey: String? { workspace.map { "sidebarExpanded:" + $0.root.path } }

    private func loadExpanded() {
        guard let workspace, let k = expansionKey else { expanded = []; return }
        let paths = UserDefaults.standard.stringArray(forKey: k) ?? []
        expanded = Set(paths.map { key(workspace.root.appendingPathComponent($0)) })
    }

    private func saveExpanded() {
        guard let workspace, let k = expansionKey else { return }
        UserDefaults.standard.set(expanded.map { workspace.relativePath($0) }.sorted(), forKey: k)
    }

    private func restoreExpansion() {
        restoringExpansion = true
        for url in expanded.sorted(by: { $0.path.count < $1.path.count }) {
            if let item = items[url] ?? nodes[url].map(item(for:)) { outline.expandItem(item) }
        }
        restoringExpansion = false
    }

    @objc private func itemMoved(_ n: Notification) {
        guard let from = (n.userInfo?["from"] as? URL).map(key), let to = (n.userInfo?["to"] as? URL).map(key) else { return }
        let moved = expanded.filter { $0 == from || $0.path.hasPrefix(from.path + "/") }
        guard !moved.isEmpty else { return }
        expanded.subtract(moved)
        for url in moved { expanded.insert(key(URL(fileURLWithPath: to.path + url.path.dropFirst(from.path.count)))) }
        saveExpanded()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoringExpansion, let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        expanded.insert(item.url)
        saveExpanded()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoringExpansion, let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        expanded.remove(item.url)
        saveExpanded()
    }

    // MARK: Selection

    /// Selects the open note, opening the folders above it.
    private func selectCurrent() {
        guard let currentURL, let rootKey, renaming == nil else { return }
        var chain: [URL] = []
        var dir = key(currentURL).deletingLastPathComponent()
        while dir.path.count > rootKey.path.count, dir.path.hasPrefix(rootKey.path) {
            chain.insert(dir, at: 0)
            dir = dir.deletingLastPathComponent()
        }
        restoringExpansion = true
        for folder in chain {
            if let node = nodes[folder] { outline.expandItem(item(for: node)) }
        }
        restoringExpansion = false
        select(currentURL)
    }

    private func select(_ url: URL) {
        guard let item = sidebarItem(for: url) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        if !NSLocationInRange(row, outline.rows(in: outline.visibleRect)) { outline.scrollRowToVisible(row) }
    }

    private func refreshCell(for url: URL?) {
        guard let item = sidebarItem(for: url), item !== renaming else { return }
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell else { return }
        configure(cell, item)
    }

    /// A note's icon changed.
    func refreshIcon(for url: URL) { refreshCell(for: url) }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let parent = (item as? SidebarItem)?.url ?? rootKey else { return 0 }
        let kids = children(of: parent)
        shown[parent] = kids
        return kids.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let parent = (item as? SidebarItem)?.url ?? rootKey!
        return shown[parent]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("cell"), owner: self) as? SidebarCell ?? SidebarCell()
        cell.identifier = .init("cell")
        configure(cell, item)
        cell.label.delegate = self
        return cell
    }

    private func configure(_ cell: SidebarCell, _ item: SidebarItem) {
        cell.configure(name: item.name, isFolder: item.isFolder,
                       isCurrent: item.url == currentURL.map(key),
                       symbol: item.isFolder ? nil : NoteIcons.shared.icon(for: item.url, in: workspace))
    }

    // Dragging notes and folders between folders.

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? SidebarItem)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView === outlineView, let rootKey else { return [] }
        var folder = (item as? SidebarItem)?.url ?? rootKey
        if let target = item as? SidebarItem, !target.isFolder { folder = target.url.deletingLastPathComponent() }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        for url in urls.map(key) {
            if url.deletingLastPathComponent() == folder { return [] }
            if folder == url || folder.path.hasPrefix(url.path + "/") { return [] }
        }
        outlineView.setDropItem(folder == rootKey ? nil : items[folder], dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let workspace else { return false }
        let folder = (item as? SidebarItem)?.url ?? workspace.root
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        var moved = false
        for url in urls {
            do {
                _ = try workspace.move(url, into: folder)
                moved = true
            } catch {
                showError(error)
            }
        }
        if moved, let target = item as? SidebarItem {
            expanded.insert(target.url)
            saveExpanded()
            outline.expandItem(target)
        }
        return moved
    }

    // MARK: Clicks and keys

    private var clickedItem: SidebarItem? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? SidebarItem : nil
    }

    private var selectedItem: SidebarItem? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? SidebarItem : nil
    }

    /// A click opens a note. On a folder it only selects it; clicking a folder
    /// shouldn't fold away what you were looking at.
    @objc private func rowClicked() {
        guard outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) as? SidebarItem, !item.isFolder else { return }
        onOpen?(item.url)
    }

    @objc private func rowDoubleClicked() {
        guard outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) as? SidebarItem, item.isFolder else { return }
        toggle(item)
    }

    private func toggle(_ item: SidebarItem) {
        if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
    }

    fileprivate func openSelection() {
        guard let item = selectedItem else { return }
        if item.isFolder { toggle(item) } else { onOpen?(item.url) }
    }

    /// New items go in the folder the menu was opened on, or for the buttons, the
    /// selected folder (or the selected note's folder); else the top of the folder.
    private func targetFolder(_ sender: Any?) -> URL? {
        guard let item = sender is NSMenuItem ? clickedItem : selectedItem else { return nil }
        return item.isFolder ? item.url : item.url.deletingLastPathComponent()
    }

    @objc private func showFolders() {
        let menu = NSMenu()
        AppDelegate.shared.fillFolderMenu(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: titleButton.bounds.height + 4), in: titleButton)
    }

    @objc private func newNoteClicked(_ sender: Any?) {
        onCreateNote?(targetFolder(sender))
    }

    @objc private func newFolderClicked(_ sender: Any?) {
        guard let workspace else { return }
        let parent = targetFolder(sender)
        do {
            if let parent, let parentItem = items[key(parent)] {
                outline.expandItem(parentItem)
            }
            let url = try workspace.createFolder(in: parent)
            beginRename(url)
        } catch { showError(error) }
    }

    // MARK: Renaming

    /// Names a row in place. `focusPage` hands focus to the page afterwards.
    func beginRename(_ url: URL, focusPage: Bool = false) {
        cancelRename()
        guard let item = sidebarItem(for: url) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else { return }
        let field = cell.label
        renaming = item
        focusPageAfterRename = focusPage
        field.isEditable = true
        field.isSelectable = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func cancelRename() {
        guard let item = renaming else { return }
        renaming = nil
        focusPageAfterRename = false
        let row = outline.row(forItem: item)
        if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell {
            cell.endEditing()
            configure(cell, item)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let item = renaming, let workspace else { return }
        renaming = nil
        let focusPage = focusPageAfterRename
        focusPageAfterRename = false
        field.isEditable = false
        field.isSelectable = false
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = item.url
        if name.isEmpty || name == item.name {
            field.stringValue = item.name
        } else {
            // A rename replaces the row, and this field may already be reused for another
            // row, so it's only touched when the name stays.
            do {
                result = try workspace.rename(item.url, to: name)
            } catch {
                field.stringValue = item.name
                showError(error)
            }
        }
        select(result)
        if focusPage {
            // After the list has taken focus back from the finished edit.
            DispatchQueue.main.async { self.onDismiss?() }
        } else if window?.firstResponder === window {
            window?.makeFirstResponder(outline)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), let item = renaming {
            (control as? NSTextField)?.stringValue = item.name
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
        let item = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? SidebarItem : nil
        menu.addItem(withTitle: "New Note", action: #selector(newNoteClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Folder", action: #selector(newFolderClicked), keyEquivalent: "").target = self
        guard let item else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: #selector(renameClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealClicked), keyEquivalent: "").target = self
        if AppSettings.shared.suggestIcons, NoteIcons.isAvailable, !item.isFolder {
            menu.addItem(withTitle: "Suggest New Icon", action: #selector(suggestIconClicked), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(trashClicked), keyEquivalent: "").target = self
    }

    @objc private func renameClicked() {
        if let item = clickedItem { beginRename(item.url) }
    }

    @objc private func suggestIconClicked() {
        guard let item = clickedItem, let workspace, let text = try? Note.read(item.url) else { return }
        NoteIcons.shared.suggest(for: item.url, text: text, in: workspace, force: true)
    }

    @objc private func revealClicked() {
        if let item = clickedItem { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    }

    @objc fileprivate func trashClicked() {
        guard let item = clickedItem, let workspace, let window else { return }
        let confirm = {
            do { try workspace.trash(item.url) } catch { self.showError(error) }
        }
        if item.isFolder {
            let alert = NSAlert()
            alert.messageText = "Move “\(item.name)” to the Trash?"
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

private final class SidebarOutlineView: NSOutlineView {
    weak var sidebar: SidebarView?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: sidebar?.openSelection()
        case 53: sidebar?.cancelOperation(nil)
        case 51 where event.modifierFlags.contains(.command): sidebar?.trashClicked()
        default: super.keyDown(with: event)
        }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: 2, dy: 0)
    }
}

/// The selection keeps one quiet color whether or not the list has focus, so opening
/// a note (which moves focus to the page) doesn't flip it from blue to gray.
private final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    /// Text on the soft gray selection keeps its normal style (no bold selected look).
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

private final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    /// Only the open note is bold; selection doesn't change the weight.
    private var isCurrent = false


    private func applyFont() {
        label.font = NSFont.systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
    }

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
        // Not the cell's standard text field: the list would restyle it (bold) when selected.
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

    func configure(name: String, isFolder: Bool, isCurrent: Bool, symbol: String?) {
        label.stringValue = name
        self.isCurrent = isCurrent
        applyFont()
        label.textColor = .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.image = isFolder
            ? NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?.withSymbolConfiguration(config)
            : NSImage(systemSymbolName: symbol ?? "doc.text", accessibilityDescription: "Note")?.withSymbolConfiguration(config)
        icon.contentTintColor = isFolder ? .controlAccentColor : .secondaryLabelColor
        setAccessibilityLabel(name)
    }

    func endEditing() {
        if let editor = label.currentEditor() { label.window?.endEditing(for: editor) }
        label.isEditable = false
        label.isSelectable = false
    }
}

#if DEBUG
extension SidebarView {
    /// `-IndiumSidebarSteps click:Chem,newFolder,type:Physics,return,wait`: drives the
    /// sidebar the way clicks and keys would. Paths are relative to the folder.
    func debugStep(_ step: String) {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let url = workspace?.root.appendingPathComponent(arg)
        let editor = window?.firstResponder as? NSTextView
        switch parts[0] {
        case "click":
            guard let url, let item = sidebarItem(for: url) else { print("no row for", arg); return }
            select(url)
            if !item.isFolder { onOpen?(item.url) }
        case "double":
            if let item = sidebarItem(for: url) { toggle(item) }
        case "newNote": newNoteClicked(nil)
        case "newFolder": newFolderClicked(nil)
        case "rename": if let url { beginRename(url) }
        case "type": editor?.insertText(arg, replacementRange: editor?.selectedRange() ?? NSRange())
        case "return": editor?.insertNewline(nil)
        case "touch": if let url { FileManager.default.createFile(atPath: url.path, contents: Data("# New\n".utf8)) }
        case "escape": editor?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        default: print("unknown step", step)
        }
    }

    func debugDump() -> String {
        var lines: [String] = []
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? SidebarItem else { continue }
            let indent = String(repeating: "  ", count: outline.level(forRow: row))
            let mark = item.isFolder ? (outline.isItemExpanded(item) ? "v " : "> ") : "  "
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell
            let shown = cell?.label.stringValue ?? "?"
            let bold = (cell?.label.font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false) ? " [bold]" : ""
            lines.append("\(outline.isRowSelected(row) ? "*" : " ") \(indent)\(mark)\(shown)\(bold)")
        }
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
            lines.append("editing: \"\(editor.string)\" selected \(NSStringFromRange(editor.selectedRange()))")
        } else {
            lines.append("focus: " + (window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"))
        }
        return lines.joined(separator: "\n")
    }
}
#endif
