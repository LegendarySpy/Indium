import AppKit

/// A laid-out Markdown table: quiet frame, shaded header, hairline rows,
/// tabular figures so numbers line up. Drawn identically on screen and in PDFs.
final class TableRender {
    static let padX: CGFloat = 12
    static let padY: CGFloat = 7

    let spec: TableSpec
    private(set) var width: CGFloat = 0
    private(set) var height: CGFloat = 0
    private(set) var columnWidths: [CGFloat] = []
    private(set) var rowHeights: [CGFloat] = []
    private var cells: [[NSAttributedString]] = []
    private let columns: Int

    /// A cell a table formula fills: tinted, with a small ƒ, and `tip` on hover.
    /// `isError` when its formula has a problem or its value is out of date.
    struct Mark: Equatable {
        let isError: Bool
        let tip: String
    }
    /// A cell in this layout's numbering: row 0 the header, column 0 the leftmost.
    struct Position: Hashable {
        var row: Int
        var column: Int
    }
    /// Computed cells. Only set on screen; PDFs and Quick Look leave it empty.
    var marks: [Position: Mark] = [:]

    func mark(row: Int, column: Int) -> Mark? { marks[Position(row: row, column: column)] }

    let typography: Typography

    /// Width available to the table (the page column or a column cell).
    let maxWidth: CGFloat

    /// What dash counts are a share of: the text width (Pandoc's convention).
    let fractionBase: CGFloat
    /// Widest a table sizes itself before the writer resizes it.
    let naturalCap: CGFloat

    /// `fixedWidths` holds the columns still while a table is edited, so typing only
    /// grows rows; `revealing` is the cell being edited, measured with its markers shown,
    /// or as `revealingText` when it shows something else (a formula being typed).
    init(spec: TableSpec, typography: Typography, maxWidth: CGFloat, fractionBase: CGFloat? = nil, naturalCap: CGFloat? = nil,
         fixedWidths: [CGFloat]? = nil, revealing: (row: Int, column: Int)? = nil, revealingText: String? = nil) {
        self.maxWidth = maxWidth
        self.fractionBase = fractionBase ?? maxWidth
        self.naturalCap = min(naturalCap ?? maxWidth, maxWidth)
        self.spec = spec
        self.typography = typography
        columns = max(spec.alignments.count, spec.rows.map(\.count).max() ?? 1)
        let size = round(typography.size * 0.9)
        cells = spec.rows.enumerated().map { r, row in
            (0..<columns).map { c in
                // As seen: `\|` a pipe (also inside math, as GFM has it), `<br>` a line break.
                let revealed = revealing.map { $0.row == r && $0.column == c } ?? false
                let text = revealed ? revealingText ?? TableSpec.unescapeCell(c < row.count ? row[c].text : "")
                                    : c < row.count ? TableSpec.unescapeCell(row[c].text) : ""
                return TableRender.render(text, header: r == 0, alignment: c < spec.alignments.count ? spec.alignments[c] : 0,
                                          typography: typography, size: size, revealMarkers: revealed)
            }
        }
        if let fixed = fixedWidths, fixed.count == columns, fixed.reduce(0, +) <= maxWidth + 1 {
            columnWidths = fixed
            measureRows()
            return
        }
        layout(maxWidth: maxWidth)
    }

    private func layout(maxWidth: CGFloat) {
        let pad = Self.padX * 2
        if let fractions = spec.widthFractions, fractions.count == columns {
            // Widths the writer chose by dragging dividers, but short cells (numbers,
            // units) still never wrap when the table lands somewhere narrower.
            let minimum = noWrapMinimums()
            var widths = zip(fractions, minimum).map { max(floor($0 * fractionBase), $1) }
            let total = widths.reduce(0, +)
            if total > maxWidth {
                let slack = zip(widths, minimum).map { max($0 - $1, 0) }
                let totalSlack = max(slack.reduce(0, +), 1)
                let excess = total - maxWidth
                widths = zip(widths, slack).map { $0 - $1 / totalSlack * excess }
            }
            columnWidths = widths
            width = floor(columnWidths.reduce(0, +))
            measureRows()
            return
        }
        let maxWidth = naturalCap
        var natural = [CGFloat](repeating: 48, count: columns)
        for row in cells {
            for (c, cell) in row.enumerated() {
                natural[c] = max(natural[c], ceil(cell.size().width) + pad)
            }
        }
        let total = natural.reduce(0, +)
        if total <= maxWidth {
            // Fill the measure; extra space goes to columns in proportion to their content.
            let extra = maxWidth - total
            columnWidths = natural.map { $0 + extra * $0 / total }
        } else {
            // Short cells (numbers, units) never wrap; long prose columns absorb the squeeze.
            let minimum = noWrapMinimums(least: 56)
            let floor = minimum.reduce(0, +)
            if floor >= maxWidth {
                // Too narrow for everything whole: equations shrink before words break
                // (`fit` scales them to the width they get), and only then does every
                // column squeeze.
                let words = noWrapMinimums(least: 56, mathScale: 0)
                let wordsFloor = words.reduce(0, +)
                if wordsFloor < maxWidth {
                    let give = zip(minimum, words).map { $0 - $1 }
                    let totalGive = max(give.reduce(0, +), 1)
                    columnWidths = zip(minimum, give).map { $0 - $1 / totalGive * (floor - maxWidth) }
                } else {
                    columnWidths = words.map { $0 * maxWidth / wordsFloor }
                }
            } else {
                let slack = zip(natural, minimum).map { max($0 - $1, 0) }
                let totalSlack = max(slack.reduce(0, +), 1)
                columnWidths = zip(minimum, slack).map { $0 + $1 * (maxWidth - floor) / totalSlack }
            }
        }
        width = floor(columnWidths.reduce(0, +))
        measureRows()
    }

    /// Per column: the width that keeps short cells on one line (long ones may wrap
    /// at word boundaries). An equation is one unbreakable word, measured at its width.
    /// `mathScale` measures equations smaller (0: words only), for when they must give way.
    private func noWrapMinimums(least: CGFloat = 48, mathScale: CGFloat = 1) -> [CGFloat] {
        let pad = Self.padX * 2
        var minimum = [CGFloat](repeating: least, count: columns)
        for row in cells {
            for (c, original) in row.enumerated() {
                let cell = mathScale < 1 ? Self.scalingMath(original) { _ in mathScale } : original
                let whole = ceil(cell.size().width) + pad
                minimum[c] = max(minimum[c], whole <= 130 ? whole : Self.longestWord(in: cell) + pad)
            }
        }
        return minimum
    }

    /// Width of the widest run the text can't break inside: a word, or an equation
    /// together with any letters touching it.
    private static func longestWord(in cell: NSAttributedString) -> CGFloat {
        let ns = cell.string as NSString
        var widest: CGFloat = 0, start = 0
        for i in 0...ns.length {
            let breaks = i == ns.length || (UnicodeScalar(ns.character(at: i)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false)
            guard breaks else { continue }
            if i > start { widest = max(widest, ceil(cell.attributedSubstring(from: NSRange(location: start, length: i - start)).size().width)) }
            start = i + 1
        }
        return widest
    }

    /// Rows sized to their tallest cell at the current column widths.
    private func measureRows() {
        let pad = Self.padX * 2
        width = floor(columnWidths.reduce(0, +))
        for (r, row) in cells.enumerated() {
            for (c, cell) in row.enumerated() { cells[r][c] = Self.fit(cell, width: columnWidths[c] - pad) }
        }
        rowHeights = cells.map { row in
            row.enumerated().map { c, cell in
                ceil(cell.boundingRect(with: NSSize(width: max(columnWidths[c] - pad, 10), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + Self.padY * 2
            }.max() ?? 0
        }
        height = ceil(rowHeights.reduce(0, +))
    }

    /// Override column widths (live divider drag) and re-measure.
    func setColumnWidths(_ widths: [CGFloat]) {
        columnWidths = widths
        measureRows()
    }

    func cellRect(row: Int, column: Int, in rect: NSRect) -> NSRect {
        let x = rect.minX + columnWidths[..<column].reduce(0, +)
        let y = rect.minY + rowHeights[..<row].reduce(0, +)
        return NSRect(x: x, y: y, width: columnWidths[column], height: rowHeights[row])
    }

    /// Row and column under a point relative to the table's origin.
    func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        guard point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else { return nil }
        var y: CGFloat = 0, row = 0
        while row < rowHeights.count - 1, y + rowHeights[row] < point.y { y += rowHeights[row]; row += 1 }
        var x: CGFloat = 0, column = 0
        while column < columnWidths.count - 1, x + columnWidths[column] < point.x { x += columnWidths[column]; column += 1 }
        return (row, column)
    }

    func draw(in rect: NSRect) {
        drawChrome(in: rect)
        drawMarks(in: rect)
        for (r, row) in cells.enumerated() {
            for (c, cell) in row.enumerated() {
                let box = cellRect(row: r, column: c, in: NSRect(x: rect.minX, y: rect.minY, width: width, height: height))
                    .insetBy(dx: Self.padX, dy: Self.padY)
                cell.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
    }

    /// The rounded frame around a table's grid.
    static func outline(of frame: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
    }

    /// Frame, header shading, row and column rules: everything but the text.
    func drawChrome(in rect: NSRect) {
        guard !rowHeights.isEmpty else { return }
        let frame = NSRect(x: rect.minX, y: rect.minY, width: width, height: height)
        let outline = Self.outline(of: frame)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        Palette.fill.setFill()
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: rowHeights[0]).fill()
        var y = frame.minY
        for (r, h) in rowHeights.enumerated() {
            y += h
            guard r < rowHeights.count - 1 else { break }
            (r == 0 ? Palette.quoteBar : Palette.separator).setFill()
            NSRect(x: frame.minX, y: y - 0.5, width: frame.width, height: r == 0 ? 1 : 0.5).fill()
        }
        // Column dividers.
        var x = frame.minX
        for w in columnWidths.dropLast() {
            x += w
            Palette.separator.setFill()
            NSRect(x: floor(x) - 0.25, y: frame.minY, width: 0.5, height: frame.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        Palette.quoteBar.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    /// Computed cells: a faint tint (amber when something's wrong) and a small ƒ in
    /// the top-left corner, clear of the text, which doesn't move.
    func drawMarks(in rect: NSRect) {
        guard !marks.isEmpty, !rowHeights.isEmpty else { return }
        let frame = NSRect(x: rect.minX, y: rect.minY, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        Self.outline(of: frame).addClip()
        let glyph = NSFont.systemFont(ofSize: 9, weight: .regular)
        for (cell, mark) in marks {
            let r = cell.row, c = cell.column
            guard r >= 0, c >= 0, r < rowHeights.count, c < columnWidths.count else { continue }
            let box = cellRect(row: r, column: c, in: frame)
            (mark.isError ? Palette.warningFill : Palette.computedFill).setFill()
            box.insetBy(dx: 0.25, dy: 0.25).fill()
            ("ƒ" as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1.5), withAttributes: [
                .font: glyph, .foregroundColor: mark.isError ? Palette.warningText : Palette.secondaryText,
            ])
        }
    }

    // MARK: Cell text

    /// The cell's text with any equation too wide for `width` scaled down to fit, so a
    /// column the table can't widen shows the whole equation, smaller, instead of
    /// cutting it off. Equations that fit keep their natural size.
    static func fit(_ text: NSAttributedString, width: CGFloat) -> NSAttributedString {
        scalingMath(text) { min(1, max(width, 10) / max($0.natural.width, 1)) }
    }

    /// The text with each equation drawn at `scale(equation)` of its typeset size.
    private static func scalingMath(_ text: NSAttributedString, _ scale: (MathCellAttachment) -> CGFloat) -> NSAttributedString {
        var out: NSMutableAttributedString?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let math = value as? MathCellAttachment else { return }
            let scale = scale(math)
            guard abs(math.natural.width * scale - math.bounds.width) > 0.25 else { return }
            let copy = MathCellAttachment(natural: math.natural, image: math.image)
            copy.bounds = NSRect(x: 0, y: math.natural.minY * scale, width: math.natural.width * scale, height: math.natural.height * scale)
            if out == nil { out = NSMutableAttributedString(attributedString: text) }
            out?.addAttribute(.attachment, value: copy, range: range)
        }
        return out ?? text
    }

    /// `revealMarkers` keeps the Markdown syntax, dimmed, for the cell being edited.
    static func render(_ text: String, header: Bool, alignment: Int, typography: Typography, size: CGFloat,
                       revealMarkers: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = [.natural, .left, .center, .right][min(alignment, 3)]
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        let color = Palette.text
        func font(bold: Bool, italic: Bool, code: Bool) -> NSFont {
            let base = code ? typography.codeVariant(bold: bold || header, italic: italic)
                            : typography.text(bold: bold || header, italic: italic, size: size)
            return base.withTabularFigures().withSystemFallback()
        }

        let ns = text as NSString
        let spans = MarkdownScanner.inlineSpans(in: ns, range: NSRange(location: 0, length: ns.length))
        var hidden = IndexSet()
        var traits = [UInt8](repeating: 0, count: ns.length)
        var maths: [(NSRange, String)] = []
        for span in spans {
            for m in span.markers { hidden.insert(integersIn: m.location..<NSMaxRange(m)) }
            let bits: UInt8
            switch span.kind {
            case .strong: bits = 1
            case .emphasis: bits = 2
            case .strongEmphasis: bits = 3
            case .code: bits = 4
            case .strike: bits = 8
            case .highlight: bits = 16
            case let .math(latex, _):
                if !revealMarkers { maths.append((span.range, latex)) }
                bits = revealMarkers ? 4 : 0
            default: bits = 0
            }
            for i in span.content.location..<NSMaxRange(span.content) where i < traits.count { traits[i] |= bits }
        }

        let out = NSMutableAttributedString()
        var i = 0
        while i < ns.length {
            if let math = maths.first(where: { $0.0.location == i }) {
                if let render = MathRenderer.render(math.1, size: round(size * 1.05), display: false) {
                    let image = NSImage(size: NSSize(width: render.width, height: render.height), flipped: false) { _ in
                        render.draw(baselineAt: NSPoint(x: 0, y: render.descent), color: color, scale: 1, flippedContext: false)
                        return true
                    }
                    let attachment = MathCellAttachment(natural: NSRect(x: 0, y: -render.descent, width: render.width, height: render.height), image: image)
                    out.append(NSAttributedString(attachment: attachment))
                } else {
                    out.append(NSAttributedString(string: ns.substring(with: math.0), attributes: [.font: font(bold: false, italic: false, code: true), .foregroundColor: color]))
                }
                i = NSMaxRange(math.0)
                continue
            }
            if hidden.contains(i) {
                if revealMarkers {
                    out.append(NSAttributedString(string: ns.substring(with: NSRange(location: i, length: 1)), attributes: [
                        .font: font(bold: false, italic: false, code: false), .foregroundColor: Palette.syntax,
                    ]))
                }
                i += 1
                continue
            }
            let t = traits[i]
            var j = i + 1
            while j < ns.length, traits[j] == t, !hidden.contains(j), !maths.contains(where: { $0.0.location == j }) { j += 1 }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(bold: t & 1 != 0, italic: t & 2 != 0, code: t & 4 != 0), .foregroundColor: color,
            ]
            if t & 8 != 0 {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = Palette.secondaryText
            }
            if t & 16 != 0 { attributes[.backgroundColor] = Palette.highlight }
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: i, length: j - i)), attributes: attributes))
            i = j
        }
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// An equation in a cell. Remembers its typeset size so a narrow column can scale it
/// down, and a wider one back up.
final class MathCellAttachment: NSTextAttachment {
    let natural: NSRect

    init(natural: NSRect, image: NSImage?) {
        self.natural = natural
        super.init(data: nil, ofType: nil)
        self.image = image
        bounds = natural
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension NSFont {
    /// Same font, falling back to the system font for characters it lacks (New York has
    /// no subscript digits), so `H₂O` stays tight instead of borrowing a wide glyph.
    func withSystemFallback() -> NSFont {
        let fallback = NSFont.systemFont(ofSize: pointSize, weight: fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .regular)
        let descriptor = fontDescriptor.addingAttributes([.cascadeList: [fallback.fontDescriptor]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }

    /// Same font with tabular (fixed-width) digits so columns of numbers align.
    func withTabularFigures() -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
