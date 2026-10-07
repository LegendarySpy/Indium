import AppKit

/// Popover grid for choosing a note's icon, with Apple Intelligence as a helper.
///
/// Suggest keeps the picker open and shows its progress in place, then how it went.
final class IconPickerController: NSViewController {
    var current: String?
    /// The note being edited. Without it, Suggest just starts and the picker closes.
    var noteURL: URL?
    var onPick: ((String?) -> Void)?
    var onSuggest: (() -> Void)?

    /// Notes with a picker open, so the title bar doesn't repeat what the picker says.
    private static var showing: [URL: Int] = [:]
    static func isShowing(for url: URL) -> Bool { (showing[NoteIcons.key(url)] ?? 0) > 0 }

    private var cells: [SymbolCell] = []
    private let suggestButton = NSButton(title: "Suggest", target: nil, action: nil)
    private let spinner = IconSpinner()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?
    private var counted = false

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        // Fixed square cells on an exact grid; nothing gets stretched.
        let columns = 9
        let cellSize: CGFloat = 32
        let gap: CGFloat = 4
        let symbols = NoteIcons.palette
        let rows = (symbols.count + columns - 1) / columns
        let grid = FlippedView(frame: NSRect(x: 0, y: 0,
                                             width: CGFloat(columns) * cellSize + CGFloat(columns - 1) * gap,
                                             height: CGFloat(rows) * cellSize + CGFloat(rows - 1) * gap))
        for (i, symbol) in symbols.enumerated() {
            let cell = SymbolCell(symbol: symbol, selected: symbol == current)
            cell.target = self
            cell.action = #selector(picked(_:))
            cell.frame = NSRect(x: CGFloat(i % columns) * (cellSize + gap), y: CGFloat(i / columns) * (cellSize + gap),
                                width: cellSize, height: cellSize)
            grid.addSubview(cell)
            cells.append(cell)
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: grid.frame.width).isActive = true
        grid.heightAnchor.constraint(equalToConstant: grid.frame.height).isActive = true

        var views: [NSView] = [grid]
        if AppSettings.shared.suggestIcons {
            suggestButton.target = self
            suggestButton.action = #selector(suggestTapped)
            suggestButton.isBordered = false
            suggestButton.imagePosition = .imageLeading
            suggestButton.font = .systemFont(ofSize: 13, weight: .medium)
            let row = NSStackView(views: [spinner, suggestButton])
            row.spacing = 5
            status.font = .systemFont(ofSize: 12)
            status.textColor = .secondaryLabelColor
            status.preferredMaxLayoutWidth = grid.frame.width
            views += [row, status]
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        if views.count > 1 { stack.setCustomSpacing(6, after: views[1]) }
        // Room so a highlighted cell at the edge never touches the popover's rim.
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        view = stack

        if let noteURL {
            // Matched by value: notification objects are otherwise matched by identity.
            let key = NoteIcons.key(noteURL)
            observer = NotificationCenter.default.addObserver(forName: NoteIcons.suggestionDidChange, object: nil, queue: .main) { [weak self] n in
                guard n.object as? URL == key else { return }
                self?.render(NoteIcons.shared.suggestion(for: key), animated: true)
            }
        }
        // Opened again while one is running: show it running. An old outcome isn't news.
        let running = noteURL.map { NoteIcons.shared.suggestion(for: $0) == .suggesting } ?? false
        render(running ? .suggesting : .idle, animated: false)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if let noteURL, !counted { Self.showing[NoteIcons.key(noteURL), default: 0] += 1; counted = true }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let noteURL, counted { Self.showing[NoteIcons.key(noteURL), default: 1] -= 1; counted = false }
    }

    /// The Suggest row and its status line for one state.
    private func render(_ state: NoteIcons.Suggestion, animated: Bool) {
        guard AppSettings.shared.suggestIcons else { return }
        var title = "Suggest", symbol: String? = "sparkles", enabled = true, message: String?
        switch state {
        case .idle: break
        case .suggesting: (title, symbol, enabled) = ("Suggesting…", nil, false)
        case let .changed(icon):
            (title, symbol, enabled) = ("Suggested", "checkmark", false)
            current = icon
            for cell in cells {
                cell.selected = cell.symbol == icon
                if cell.selected, animated { cell.springIn() }
            }
            // The new icon shows here and in the title bar; then the picker steps aside.
            if animated { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.close() } }
        case .unchanged: (title, message) = ("Suggest Again", "Kept the same icon.")
        case let .failed(failure):
            message = failure.message
            if failure.canRetry { title = "Try Again" }
            if case .unavailable = failure { enabled = false }
            if case .frontmatter = failure { enabled = false }
        }
        if state == .suggesting { spinner.start() } else { spinner.stop() }
        suggestButton.title = title
        suggestButton.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        suggestButton.isEnabled = enabled
        // Disabled borderless buttons go gray; keep the accent while it's working or done.
        suggestButton.contentTintColor = enabled || symbol != "sparkles" ? .controlAccentColor : .tertiaryLabelColor
        status.stringValue = message ?? ""
        status.isHidden = message == nil
        if let message, animated {
            NSAccessibility.post(element: status, notification: .announcementRequested, userInfo: [.announcement: message])
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    @objc private func suggestTapped() {
        guard let noteURL else {
            onSuggest?()
            close()
            return
        }
        // Visible at once, before the request even reports back.
        render(.suggesting, animated: true)
        onSuggest?()
        // It settled at once (too short, frontmatter, unavailable): say so instead of spinning.
        let state = NoteIcons.shared.suggestion(for: noteURL)
        if state != .suggesting { render(state, animated: true) }
    }

    /// The popover showing the picker; `dismiss` alone doesn't close a shown popover.
    weak var popover: NSPopover?

    private func close() {
        if let popover { popover.performClose(nil) } else { dismiss(nil) }
    }

    @objc private func picked(_ sender: SymbolCell) {
        onPick?(sender.symbol)
        close()
    }
}

/// One symbol in the picker. Its highlight is inset inside its own cell, so
/// neighbours never overlap.
final class SymbolCell: NSButton {
    let symbol: String
    var selected: Bool {
        didSet {
            contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            needsDisplay = true
        }
    }
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, selected: Bool) {
        self.symbol = symbol
        self.selected = selected
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        translatesAutoresizingMaskIntoConstraints = true
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        imagePosition = .imageOnly
        contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        toolTip = symbol
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            shape.fill()
        } else if hovering {
            Palette.hoverFill.setFill()
            shape.fill()
        }
        super.draw(dirtyRect)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A small popover saying how an icon suggestion went when the picker isn't open:
/// "Kept the same icon.", or why it couldn't, with Try Again when that helps.
/// A new icon needs no words; it springs in where it's shown.
final class IconSuggestionNotice: NSViewController {
    private let message: String
    private let onRetry: (() -> Void)?

    private init(message: String, onRetry: (() -> Void)?) {
        self.message = message
        self.onRetry = onRetry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func show(_ state: NoteIcons.Suggestion, relativeTo rect: NSRect, of anchor: NSView, edge: NSRectEdge = .maxY, onRetry: @escaping () -> Void) {
        guard anchor.window != nil else { return }
        let notice: IconSuggestionNotice
        switch state {
        case .unchanged: notice = IconSuggestionNotice(message: "Kept the same icon.", onRetry: nil)
        case let .failed(failure): notice = IconSuggestionNotice(message: failure.message, onRetry: failure.canRetry ? onRetry : nil)
        default: return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = notice
        notice.popover = popover
        popover.show(relativeTo: rect, of: anchor, preferredEdge: edge)
        if case .unchanged = state {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak popover] in popover?.performClose(nil) }
        }
    }

    override func loadView() {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 230
        let stack = NSStackView(views: [label])
        if onRetry != nil {
            let button = NSButton(title: "Try Again", target: self, action: #selector(retryTapped))
            button.controlSize = .small
            stack.addArrangedSubview(button)
        }
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        view = stack
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        preferredContentSize = stack.fittingSize
        NSAccessibility.post(element: label, notification: .announcementRequested, userInfo: [.announcement: message])
    }

    private weak var popover: NSPopover?

    @objc private func retryTapped() {
        popover?.performClose(nil)
        onRetry?()
    }
}
