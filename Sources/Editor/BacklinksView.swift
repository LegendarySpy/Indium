import AppKit

/// The quiet list of notes linking here, below the text. Only its rows take clicks:
/// anywhere else belongs to the page, where a click puts the caret at the end.
final class BacklinksView: NSView {
    struct Row: Equatable {
        let url: URL
        let title: String
        let path: String
    }

    /// How far a row's hover background reaches past the text column.
    static let hoverInset: CGFloat = 8
    private static let gap: CGFloat = 36
    private static let rowHeight: CGFloat = 26

    var onOpen: ((URL) -> Void)?
    private var rows: [Row] = []
    private var fontSize: CGFloat = 0
    private var fontName = ""
    private var buttons: [HoverButton] = []
    private let header = NSTextField(labelWithString: "Backlinks")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.textColor = Palette.tertiaryText
        addSubview(header)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Backlinks")
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }

    /// False when nothing changed.
    func show(_ newRows: [Row], typography: Typography) -> Bool {
        let font = typography.text(bold: false, italic: false, size: round(typography.size * 0.9))
        guard newRows != rows || font.fontName != fontName || font.pointSize != fontSize else { return false }
        rows = newRows
        fontName = font.fontName
        fontSize = font.pointSize
        buttons.forEach { $0.removeFromSuperview() }
        buttons = rows.map { row in
            let button = HoverButton(text: row.title, label: row.path, target: self, action: #selector(open(_:)))
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.firstLineHeadIndent = Self.hoverInset
            style.tailIndent = -Self.hoverInset
            button.alignment = .left
            button.attributedTitle = NSAttributedString(string: row.title, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: Palette.secondaryText])
            button.translatesAutoresizingMaskIntoConstraints = true
            button.autoresizingMask = [.width]
            addSubview(button)
            return button
        }
        header.font = typography.text(bold: false, italic: false, size: round(typography.size * 0.8))
        header.sizeToFit()
        header.frame.origin = NSPoint(x: Self.hoverInset - 2, y: Self.gap)
        let top = header.frame.maxY + 4
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: 0, y: top + CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
        }
        isHidden = rows.isEmpty
        frame.size.height = rows.isEmpty ? 0 : top + CGFloat(rows.count) * Self.rowHeight
        return true
    }

    @objc private func open(_ sender: HoverButton) {
        guard let i = buttons.firstIndex(of: sender) else { return }
        onOpen?(rows[i].url)
    }

    #if DEBUG
    var debugTitles: [String] { rows.map(\.title) }
    func debugClick(_ title: String) {
        guard let i = rows.firstIndex(where: { $0.title == title }) else { return print("  no backlink", title) }
        buttons[i].performClick(nil)
    }
    #endif
}
