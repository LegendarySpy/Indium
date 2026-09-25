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

    let typography: Typography

    /// Width available to the table (the page column or a column cell).
    let maxWidth: CGFloat

    /// What dash counts are a share of: the text width (Pandoc's convention).
    let fractionBase: CGFloat
    /// Widest a table sizes itself before the writer resizes it.
    let naturalCap: CGFloat

    init(spec: TableSpec, typography: Typography, maxWidth: CGFloat, fractionBase: CGFloat? = nil, naturalCap: CGFloat? = nil) {
        self.maxWidth = maxWidth
        self.fractionBase = fractionBase ?? maxWidth
        self.naturalCap = min(naturalCap ?? maxWidth, maxWidth)
        self.spec = spec
        self.typography = typography
        columns = max(spec.alignments.count, spec.rows.map(\.count).max() ?? 1)
        let size = round(typography.size * 0.9)
        cells = spec.rows.enumerated().map { r, row in
            (0..<columns).map { c in
                let text = c < row.count ? row[c].text : ""
                return TableRender.render(text, header: r == 0, alignment: c < spec.alignments.count ? spec.alignments[c] : 0,
                                          typography: typography, size: size)
            }
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
            var minimum = [CGFloat](repeating: 56, count: columns)
            for row in cells {
                for (c, cell) in row.enumerated() {
                    let whole = ceil(cell.size().width) + pad
                    let longestWord = cell.string.split(whereSeparator: \.isWhitespace)
                        .map { ceil(NSAttributedString(string: String($0), attributes: cell.attributes(at: 0, effectiveRange: nil)).size().width) }
                        .max() ?? 0
                    minimum[c] = max(minimum[c], whole <= 130 ? whole : longestWord + pad)
                }
            }
            let floor = minimum.reduce(0, +)
            if floor >= maxWidth {
                columnWidths = minimum.map { $0 * maxWidth / floor }
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
    /// at word boundaries).
    private func noWrapMinimums() -> [CGFloat] {
        let pad = Self.padX * 2
        var minimum = [CGFloat](repeating: 48, count: columns)
        for row in cells {
            for (c, cell) in row.enumerated() {
                let whole = ceil(cell.size().width) + pad
                let longestWord = cell.string.split(whereSeparator: \.isWhitespace)
                    .map { ceil(NSAttributedString(string: String($0), attributes: cell.attributes(at: 0, effectiveRange: nil)).size().width) }
                    .max() ?? 0
                minimum[c] = max(minimum[c], whole <= 130 ? whole : longestWord + pad)
            }
        }
        return minimum
    }

    /// Rows sized to their tallest cell at the current column widths.
    func measureRows() {
        let pad = Self.padX * 2
        width = floor(columnWidths.reduce(0, +))
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

    /// The attributed text of a cell, for matching fonts in the editor.
    func attributes(row: Int, column: Int) -> [NSAttributedString.Key: Any] {
        let cell = cells[row][column]
        if cell.length > 0 { return cell.attributes(at: 0, effectiveRange: nil) }
        return TableRender.render("x", header: row == 0, alignment: column < spec.alignments.count ? spec.alignments[column] : 0,
                                  typography: typography, size: round(typography.size * 0.9)).attributes(at: 0, effectiveRange: nil)
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

    /// Source offset (relative to the block) at the end of a cell's text.
    func sourceOffset(row: Int, column: Int) -> Int? {
        guard row < spec.rows.count else { return nil }
        let cells = spec.rows[row]
        guard !cells.isEmpty else { return nil }
        let cell = cells[min(column, cells.count - 1)]
        return cell.offset + (cell.text as NSString).length
    }

    func draw(in rect: NSRect) {
        drawChrome(in: rect)
        for (r, row) in cells.enumerated() {
            for (c, cell) in row.enumerated() {
                let box = cellRect(row: r, column: c, in: NSRect(x: rect.minX, y: rect.minY, width: width, height: height))
                    .insetBy(dx: Self.padX, dy: Self.padY)
                cell.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
    }

    /// Frame, header shading, row and column rules: everything but the text.
    func drawChrome(in rect: NSRect) {
        guard !rowHeights.isEmpty else { return }
        let frame = NSRect(x: rect.minX, y: rect.minY, width: width, height: height)
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)

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

    // MARK: Cell text

    static func render(_ text: String, header: Bool, alignment: Int, typography: Typography, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = [.natural, .left, .center, .right][min(alignment, 3)]
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        let color = header ? Palette.text : Palette.text
        func font(bold: Bool, italic: Bool, code: Bool) -> NSFont {
            let base = code ? typography.codeVariant(bold: bold || header, italic: italic)
                            : typography.text(bold: bold || header, italic: italic, size: size)
            return base.withTabularFigures()
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
            case let .math(latex, _):
                maths.append((span.range, latex))
                bits = 0
            default: bits = 0
            }
            for i in span.content.location..<NSMaxRange(span.content) where i < traits.count { traits[i] |= bits }
        }

        let out = NSMutableAttributedString()
        var i = 0
        while i < ns.length {
            if let math = maths.first(where: { $0.0.location == i }) {
                if let render = MathRenderer.render(math.1, size: round(size * 1.05), display: false) {
                    let attachment = NSTextAttachment()
                    let image = NSImage(size: NSSize(width: render.width, height: render.height), flipped: false) { _ in
                        render.draw(baselineAt: NSPoint(x: 0, y: render.descent), color: color, scale: 1, flippedContext: false)
                        return true
                    }
                    attachment.image = image
                    attachment.bounds = NSRect(x: 0, y: -render.descent, width: render.width, height: render.height)
                    out.append(NSAttributedString(attachment: attachment))
                } else {
                    out.append(NSAttributedString(string: ns.substring(with: math.0), attributes: [.font: font(bold: false, italic: false, code: true), .foregroundColor: color]))
                }
                i = NSMaxRange(math.0)
                continue
            }
            if hidden.contains(i) { i += 1; continue }
            let t = traits[i]
            var j = i + 1
            while j < ns.length, traits[j] == t, !hidden.contains(j), !maths.contains(where: { $0.0.location == j }) { j += 1 }
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: i, length: j - i)), attributes: [
                .font: font(bold: t & 1 != 0, italic: t & 2 != 0, code: t & 4 != 0), .foregroundColor: color,
            ]))
            i = j
        }
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }
}

extension NSFont {
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
