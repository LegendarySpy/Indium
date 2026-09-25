import AppKit

/// A single search interface: note titles first, then matching text.
/// Opens as a small centered palette; Return opens, Escape dismisses.
final class QuickOpenView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    enum Row {
        case note(URL)
        case text(NoteSearch.TextHit)
        case header(String)
        case create(String)

        var selectable: Bool {
            if case .header = self { return false }
            return true
        }
    }

    /// URL to open and, for text hits, the query to select in it.
    var onOpen: ((URL, String?) -> Void)?
    var onCreate: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    weak var workspace: Workspace?

    private let content = NSView()
    private var panel: NSView!
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let separator = NSBox()
    private var rows: [Row] = []
    private var titleRows: [Row] = []
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        installArrowCursorArea()
        panel = Glass.make(cornerRadius: 24, content: content)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 30
            s.shadowOffset = NSSize(width: 0, height: -10)
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return s
        }()
        addSubview(panel)

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))!)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(icon)

        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 22, weight: .regular)
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(string: "Open a note or search text", attributes: [
            .foregroundColor: NSColor.placeholderTextColor, .font: NSFont.systemFont(ofSize: 22, weight: .regular),
        ])
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel("Search notes")
        content.addSubview(field)

        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = .separatorColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.focusRingType = .none
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 84),
            panel.widthAnchor.constraint(equalToConstant: 600),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 17),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 15),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { onDismiss?() }
    }

    /// Fades in while the palette settles from slightly smaller, like Spotlight.
    func animateIn() {
        layoutSubtreeIfNeeded()
        alphaValue = 0
        panel.wantsLayer = true
        panel.layer?.setAffineTransform(panel.centeredScale(0.97))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 1
            panel.layer?.setAffineTransform(.identity)
        }
    }

    func animateOut(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 0
            panel.layer?.setAffineTransform(panel.centeredScale(0.985))
        }, completionHandler: completion)
    }

    func present(query: String = "") {
        field.stringValue = query
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        update()
    }

    // MARK: Results

    private func update() {
        guard let workspace else { return }
        let query = field.stringValue
        let titles = NoteSearch.titleMatches(query, in: workspace.notes, relativeTo: workspace.root).prefix(query.isEmpty ? 12 : 8)
        titleRows = titles.map { .note($0.url) }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            titleRows.insert(.header("Recent"), at: 0)
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let exact = titles.contains { $0.url.deletingPathExtension().lastPathComponent.lowercased() == trimmed.lowercased() }
        // Creating is offered last so Return never creates a note by accident when matches exist.
        let createRow: [Row] = !exact && !trimmed.isEmpty ? [.create(trimmed)] : []
        setRows(titleRows + createRow)
        workspace.search.searchText(query, in: workspace.notes) { [weak self] hits in
            guard let self, self.field.stringValue == query else { return }
            var rows = self.titleRows
            if !hits.isEmpty {
                rows.append(.header("In Notes"))
                rows += hits.prefix(20).map { .text($0) }
            }
            self.setRows(rows + createRow)
        }
    }

    private func setRows(_ new: [Row]) {
        let previous = table.selectedRow
        rows = new
        table.reloadData()
        var height: CGFloat = 0
        for i in 0..<min(rows.count, 12) { height += tableView(table, heightOfRow: i) }
        heightConstraint.constant = rows.isEmpty ? 0 : min(height + 12, 440)
        separator.isHidden = rows.isEmpty
        let preferred = rows.firstIndex { if case .create = $0 { return false }; return $0.selectable } ?? rows.firstIndex { $0.selectable } ?? -1
        let start = previous >= 0 && previous < rows.count && rows[previous].selectable && !isCreate(rows[previous]) ? previous : preferred
        if start >= 0 { table.selectRowIndexes([start], byExtendingSelection: false) }
    }

    private func isCreate(_ row: Row) -> Bool {
        if case .create = row { return true }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        table.deselectAll(nil)
        update()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activate(table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): onDismiss?(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var i = table.selectedRow
        repeat {
            i += delta
            if i < 0 || i >= rows.count { return }
        } while !rows[i].selectable
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    @objc private func clicked() {
        activate(table.clickedRow)
    }

    private func activate(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case let .note(url): onOpen?(url, nil)
        case let .text(hit): onOpen?(hit.url, field.stringValue)
        case let .create(name): onCreate?(name)
        case .header: break
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: 30
        case .text: 50
        default: 36
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].selectable }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ResultCell()
        switch rows[row] {
        case let .note(url):
            let folder = workspace.map { ws -> String in
                let rel = ws.relativePath(url.deletingLastPathComponent())
                return url.deletingLastPathComponent().standardizedFileURL == ws.root ? "" : rel
            } ?? ""
            cell.set(title: url.deletingPathExtension().lastPathComponent, detail: folder, match: nil,
                     symbol: NoteIcons.shared.icon(for: url, in: workspace) ?? "doc.text")
        case let .text(hit):
            cell.set(title: hit.url.deletingPathExtension().lastPathComponent, detail: hit.snippet, match: hit.match, stacked: true,
                     symbol: "text.magnifyingglass")
        case let .create(name):
            cell.set(title: "Create “\(name)”", detail: "", match: nil, symbol: "plus")
        case let .header(title):
            cell.setHeader(title)
        }
        return cell
    }
}

private final class ResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

private final class ResultCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let textStack = NSStackView()
    private var detailText = NSAttributedString()
    private var match: NSRange?
    private var isHeader = false

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isHidden = true
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.alignment = .firstBaseline
        textStack.spacing = 8
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(detail)
        addSubview(icon)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 42),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, detail d: String, match: NSRange?, stacked: Bool = false, symbol: String? = nil) {
        title.stringValue = t
        title.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        detailText = NSAttributedString(string: d, attributes: [.font: NSFont.systemFont(ofSize: stacked ? 12.5 : 12)])
        self.match = match
        detail.isHidden = d.isEmpty
        if stacked {
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 2
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12).isActive = true
        }
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            icon.isHidden = false
        }
        applyColors()
    }

    func setHeader(_ text: String) {
        isHeader = true
        title.stringValue = text
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        detail.isHidden = true
        icon.isHidden = true
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = isHeader ? .secondaryLabelColor : (selected ? .white : .labelColor)
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
        let s = NSMutableAttributedString(attributedString: detailText)
        let full = NSRange(location: 0, length: s.length)
        s.addAttribute(.foregroundColor, value: selected ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor, range: full)
        if let match, NSMaxRange(match) <= s.length {
            s.addAttributes(selected ? [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]
                                     : [.foregroundColor: NSColor.labelColor, .backgroundColor: Palette.highlight], range: match)
        }
        detail.attributedStringValue = s
    }
}
