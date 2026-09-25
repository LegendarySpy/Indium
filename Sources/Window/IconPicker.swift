import AppKit

/// Popover grid for choosing a note's icon, with Apple Intelligence as a helper.
final class IconPickerController: NSViewController {
    var current: String?
    var onPick: ((String?) -> Void)?
    var onSuggest: (() -> Void)?

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
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: grid.frame.width).isActive = true
        grid.heightAnchor.constraint(equalToConstant: grid.frame.height).isActive = true

        var views: [NSView] = [grid]
        if AppSettings.shared.suggestIcons, NoteIcons.isAvailable {
            let suggest = NSButton(title: "Suggest", image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!,
                                   target: self, action: #selector(suggestTapped))
            suggest.isBordered = false
            suggest.imagePosition = .imageLeading
            suggest.contentTintColor = .controlAccentColor
            suggest.font = .systemFont(ofSize: 13, weight: .medium)
            views.append(suggest)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // Room so a highlighted cell at the edge never touches the popover's rim.
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        view = stack
    }

    @objc private func suggestTapped() {
        onSuggest?()
        dismiss(nil)
    }

    @objc private func picked(_ sender: SymbolCell) {
        onPick?(sender.symbol)
        dismiss(nil)
    }
}

/// One symbol in the picker. Its highlight is inset inside its own cell, so
/// neighbours never overlap.
final class SymbolCell: NSButton {
    let symbol: String
    private let selected: Bool
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
