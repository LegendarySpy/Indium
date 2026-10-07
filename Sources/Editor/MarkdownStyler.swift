import AppKit

extension NSAttributedString.Key {
    /// Character is not drawn and takes no space (syntax hidden while not editing).
    static let mdHidden = NSAttributedString.Key("indium.hidden")
    /// Rendered inline equation covering the whole `$...$` span.
    static let mdInlineMath = NSAttributedString.Key("indium.inlineMath")
    /// Block render (display equation or image) anchored to a line.
    static let mdBlock = NSAttributedString.Key("indium.block")
    /// Decoration drawn behind a group of lines (code block box, quote bar).
    static let mdGroup = NSAttributedString.Key("indium.group")
    /// List bullet drawn in place of `-`, `*` or `+`; value is the nesting depth.
    static let mdBullet = NSAttributedString.Key("indium.bullet")
    /// Rounded background behind inline code or highlighted text.
    static let mdInlineBox = NSAttributedString.Key("indium.inlineBox")
    /// Horizontal rule.
    static let mdRule = NSAttributedString.Key("indium.rule")
    /// A page break written into the note, drawn as a labeled dashed line.
    static let mdPageBreak = NSAttributedString.Key("indium.pageBreak")
    /// Another note shown under an `![[Note]]` line, drawn in a bordered box.
    static let mdEmbed = NSAttributedString.Key("indium.embed")
}

final class InlineMath: NSObject {
    let render: MathRender
    static let padding: CGFloat = 1.5
    /// Followed by punctuation: no trailing padding, and the typesetter's rounding and
    /// space-after-script trimmed, so "HNO₃." doesn't read as "HNO₃ .".
    let tightAfter: Bool
    var advance: CGFloat {
        guard tightAfter else { return render.width + Self.padding * 2 }
        return max(render.width - 1, 1) + Self.padding
    }
    init(render: MathRender, tightAfter: Bool = false) {
        self.render = render
        self.tightAfter = tightAfter
    }
}

final class BlockDecoration: NSObject {
    enum Placement: Equatable {
        case replace, below
        /// Beside the text that follows it, which wraps around it.
        case float(right: Bool)
    }
    enum Content {
        case math(MathRender, scale: CGFloat)
        case image(NSImage?, size: NSSize, caption: String?, name: String)
        case table(TableRender)
    }
    let content: Content
    let placement: Placement
    /// Height of the reserved area, including vertical padding.
    let height: CGFloat
    let padding: CGFloat
    var isSelected = false

    init(content: Content, placement: Placement, height: CGFloat, padding: CGFloat) {
        self.content = content
        self.placement = placement
        self.height = height
        self.padding = padding
    }
}

final class GroupDecoration: NSObject {
    enum Kind { case code, quote(depth: Int) }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

enum InlineBoxKind { case code, highlight, tag }

final class InlineBox: NSObject {
    let kind: InlineBoxKind
    init(_ kind: InlineBoxKind) { self.kind = kind }
}

protocol ImageResolving: AnyObject {
    func image(for ref: ImageRef) -> NSImage?
}

/// Finds the notes `![[Note]]` lines embed. Image resolvers that also adopt this get
/// embedded notes drawn; others show the line as a plain link.
protocol NoteEmbedResolving: AnyObject {
    /// The note being styled, so it never embeds itself.
    var embeddingNoteURL: URL? { get }
    /// The note a wiki target names, resolved the way wiki links are from `note`.
    func noteURL(forEmbed target: String, from note: URL?) -> URL?
    /// An image written in `note`, resolved from that note's folder.
    func image(for ref: ImageRef, from note: URL?) -> NSImage?
}

/// Resolves links and images inside an embedded note from that note's own folder,
/// through the editor's (or Quick Look's) resolver.
final class EmbeddedNoteContext: ImageResolving, NoteEmbedResolving {
    let root: NoteEmbedResolving
    let note: URL
    init(root: NoteEmbedResolving, note: URL) {
        self.root = root
        self.note = note
    }
    var embeddingNoteURL: URL? { note }
    func noteURL(forEmbed target: String, from note: URL?) -> URL? { root.noteURL(forEmbed: target, from: note) }
    func image(for ref: ImageRef, from note: URL?) -> NSImage? { root.image(for: ref, from: note) }
    func image(for ref: ImageRef) -> NSImage? { root.image(for: ref, from: note) }
}

struct StyleConfig {
    var typography: Typography
    var gutter: CGFloat = 56
    var columnWidth: CGFloat
    var syntax: SyntaxVisibility
    var printing = false
    var maxBlockHeight: CGFloat = .greatestFiniteMagnitude

    static var current: StyleConfig {
        StyleConfig(typography: .current, columnWidth: AppSettings.shared.lineWidth.points, syntax: AppSettings.shared.syntax)
    }
}

/// Turns Markdown source into presentation attributes on the text storage.
/// The characters are never changed; only attributes are.
final class MarkdownStyler {
    var config: StyleConfig
    weak var imageResolver: ImageResolving?
    private(set) var blocks: [MDBlock] = []
    /// Location of an image line selected as an object (its source stays hidden).
    var selectedImageLine: Int?
    /// A table being edited in place stays rendered even with the caret nearby.
    var editingTableLocation: Int?
    /// Its column widths, held while it's edited so typing never moves the grid.
    var editingTableWidths: [CGFloat]?
    /// Its cell being typed in, measured with the Markdown markers it shows.
    var editingTableCell: (row: Int, column: Int)?

    private var selection: [NSRange] = []
    private var text: NSString = ""

    /// How deep this styler sits inside embeds (0 for the note itself), and the notes
    /// already open above it, so embeds stop after two levels and never loop.
    var embedDepth = 0
    var embedChain: Set<String> = []
    static let maxEmbedDepth = 2

    // Column layout (`<!-- columns -->` regions rendered as native text tables).
    struct ColumnRegion {
        var start: Int
        var splits: [Int]
        var end: Int
        var ratios: [CGFloat]
    }
    private(set) var regions: [ColumnRegion] = []
    private var cellOfBlock: [Int: (region: Int, column: Int)] = [:]
    private var tableCache: [Int: (key: String, cells: [NSTextTableBlock], widths: [CGFloat])] = [:]
    private var markerSignature: [String] = []
    private var currentCell: NSTextTableBlock?
    private var currentCellWidth: CGFloat?
    static let columnGap: CGFloat = 32

    /// Width available to images and equations in the block being styled.
    private var contentWidth: CGFloat { currentCellWidth ?? config.columnWidth }

    init(config: StyleConfig) {
        self.config = config
    }

    private var typo: Typography { config.typography }
    private var gutter: CGFloat { config.gutter }

    // MARK: Entry points

    func styleAll(_ storage: NSTextStorage, selection: [NSRange]) {
        self.selection = selection
        text = storage.string as NSString
        blocks = MarkdownScanner.scan(text)
        computeRegions()
        storage.beginEditing()
        if storage.length > 0 {
            storage.setAttributes(baseAttributes(), range: NSRange(location: 0, length: storage.length))
        }
        for i in blocks.indices { style(at: i, in: storage) }
        storage.endEditing()
    }

    /// Called from `textStorage(_:didProcessEditing:...)` after characters changed.
    /// Returns the text it restyled: attributes changed there, outside the edited
    /// paragraph, aren't laid out again unless the caller asks.
    @discardableResult
    func didEdit(_ storage: NSTextStorage, editedRange: NSRange, delta: Int, selection: [NSRange]) -> NSRange? {
        self.selection = selection
        text = storage.string as NSString
        let old = blocks
        let new = MarkdownScanner.scan(text)
        blocks = new
        let oldSignature = markerSignature
        computeRegions()
        if markerSignature != oldSignature {
            // The column structure changed: every block's cell membership may have too.
            for i in blocks.indices { style(at: i, in: storage) }
            return NSRange(location: 0, length: storage.length)
        }

        // Old blocks that sit wholly outside the edit, keyed by their position in new coordinates.
        let oldEditEnd = NSMaxRange(editedRange) - delta
        var unchanged = Set<BlockKey>()
        for b in old {
            if NSMaxRange(b.range) < editedRange.location {
                unchanged.insert(BlockKey(b.range, b.kind))
            } else if b.range.location > oldEditEnd {
                unchanged.insert(BlockKey(NSRange(location: b.range.location + delta, length: b.range.length), b.kind))
            }
        }
        var restyled: NSRange?
        for (i, b) in new.enumerated() {
            let touchesEdit = NSMaxRange(b.range) >= editedRange.location && b.range.location <= NSMaxRange(editedRange)
            if touchesEdit || !unchanged.contains(BlockKey(b.range, b.kind)) {
                style(at: i, in: storage)
                restyled = restyled.map { NSUnionRange($0, b.range) } ?? b.range
            }
        }
        return restyled
    }

    /// Re-renders the blocks whose reveal state depends on the selection.
    func selectionChanged(_ storage: NSTextStorage, from old: [NSRange], to new: [NSRange]) {
        text = storage.string as NSString
        guard config.syntax == .whileEditing || hasRenderedBlocks(near: old + new) else {
            selection = new
            return
        }
        var indices = Set<Int>()
        for r in old + new {
            if let i = blockIndex(containing: r.location) { indices.insert(i) }
            if let i = blockIndex(containing: NSMaxRange(r)) { indices.insert(i) }
            if r.location > 0, let i = blockIndex(containing: r.location - 1) { indices.insert(i) }
        }
        selection = new
        guard !indices.isEmpty else { return }
        storage.beginEditing()
        for i in indices.sorted() where i < blocks.count { style(at: i, in: storage) }
        storage.endEditing()
    }

    func restyleBlock(at location: Int, in storage: NSTextStorage) {
        guard let i = blockIndex(containing: location) else { return }
        text = storage.string as NSString
        storage.beginEditing()
        style(at: i, in: storage)
        storage.endEditing()
    }

    private func hasRenderedBlocks(near ranges: [NSRange]) -> Bool {
        for r in ranges {
            if let i = blockIndex(containing: r.location) {
                switch blocks[i].kind {
                case .math, .image, .code, .hr, .columnMarker: return true
                default:
                    let t = text.length >= NSMaxRange(blocks[i].range) ? text.substring(with: blocks[i].range) : ""
                    if t.contains("$") { return true }
                }
            }
        }
        return false
    }

    func blockIndex(containing location: Int) -> Int? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = blocks[mid].range
            if location < r.location { hi = mid - 1 }
            else if location >= NSMaxRange(r) { lo = mid + 1 }
            else { return mid }
        }
        // The position after the final character belongs to the last block.
        if let last = blocks.last, location == NSMaxRange(last.range) { return blocks.count - 1 }
        return nil
    }

    private struct BlockKey: Hashable {
        let location: Int, length: Int, kind: BlockKind
        init(_ r: NSRange, _ k: BlockKind) { location = r.location; length = r.length; kind = k }
    }

    // MARK: Helpers

    private func touches(_ r: NSRange, caretOnly: Bool = false) -> Bool {
        if config.printing { return false }
        for s in selection {
            let a = s.location, b = NSMaxRange(s)
            if s.length == 0 {
                if a >= r.location && a <= NSMaxRange(r) { return true }
            } else if !caretOnly && a >= r.location && b <= NSMaxRange(r) {
                // A selection inside the block is editing it; one that merely starts or
                // ends there (Select All, a drag across) shouldn't flip it to source.
                return true
            }
        }
        return false
    }

    private func hides(active: Bool) -> Bool {
        config.printing || (config.syntax == .whileEditing && !active)
    }

    /// Lines of a block as (content without terminator) ranges.
    private func lines(of r: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var loc = r.location
        let end = NSMaxRange(r)
        while loc < end {
            var s = 0, e = 0, ce = 0
            text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: loc, length: 0))
            result.append(NSRange(location: s, length: ce - s))
            loc = max(e, loc + 1)
        }
        return result
    }

    func paragraph(indent: CGFloat = 0, first: CGFloat? = nil, tail: CGFloat = 0, before: CGFloat = 0,
                   after: CGFloat? = nil, lineSpacing: CGFloat? = nil, alignment: NSTextAlignment = .natural,
                   fixedHeight: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        if let cell = currentCell {
            // Inside a column the cell is the frame; no page gutter.
            p.headIndent = indent
            p.firstLineHeadIndent = max(0, first ?? indent)
            p.tailIndent = -tail
            p.textBlocks = [cell]
        } else {
            p.headIndent = gutter + indent
            p.firstLineHeadIndent = gutter + (first ?? indent)
            p.tailIndent = -(gutter + tail)
        }
        p.lineSpacing = lineSpacing ?? typo.lineSpacing
        p.paragraphSpacing = after ?? typo.paragraphSpacing
        p.paragraphSpacingBefore = before
        p.alignment = alignment
        p.defaultTabInterval = 28
        p.tabStops = []
        p.lineBreakMode = .byWordWrapping
        if let h = fixedHeight {
            p.minimumLineHeight = h
            p.maximumLineHeight = h
            p.lineSpacing = 0
            p.paragraphSpacing = 0
            p.paragraphSpacingBefore = 0
        }
        return p
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: typo.body, .foregroundColor: Palette.text, .paragraphStyle: paragraph()]
    }

    private static let tinyFont = NSFont.systemFont(ofSize: 1)

    private func collapse(_ r: NSRange, in s: NSTextStorage, height: CGFloat = 1) {
        s.setAttributes([.font: Self.tinyFont, .foregroundColor: NSColor.clear, .mdHidden: true,
                         .paragraphStyle: paragraph(fixedHeight: height)], range: r)
    }

    private func width(of string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: Columns

    private func computeRegions() {
        regions = []
        cellOfBlock = [:]
        markerSignature = []
        var open: (start: Int, ratios: [Int], splits: [Int])?
        for (i, b) in blocks.enumerated() {
            guard case let .columnMarker(m) = b.kind else { continue }
            markerSignature.append("\(i):\(m)")
            switch m {
            case let .start(ratios): open = (i, ratios, [])
            case .split: open?.splits.append(i)
            case .float, .pageBreak: break
            case .end:
                if let o = open {
                    let n = o.splits.count + 1
                    let raw = o.ratios.count == n ? o.ratios.map(CGFloat.init) : Array(repeating: 1, count: n)
                    let total = raw.reduce(0, +)
                    regions.append(ColumnRegion(start: o.start, splits: o.splits, end: i, ratios: raw.map { $0 / total }))
                }
                open = nil
            }
        }
        for (ri, region) in regions.enumerated() {
            var column = 0
            for i in (region.start + 1)..<region.end {
                // A split marker closes the column before it, so its hidden line doesn't
                // push the next column's first line down a point.
                cellOfBlock[i] = (ri, column)
                if region.splits.contains(i) { column += 1 }
            }
        }
        floatOfBlock = [:]
        for (i, b) in blocks.enumerated() where i + 1 < blocks.count {
            guard case let .columnMarker(.float(right)) = b.kind, cellOfBlock[i + 1] == nil else { continue }
            switch blocks[i + 1].kind {
            case .table, .image: floatOfBlock[i + 1] = right
            default: break
            }
        }
    }

    /// Tables and images marked to float, by block index: true for the right side.
    private(set) var floatOfBlock: [Int: Bool] = [:]
    /// Side of the block being styled when it floats (never in print).
    private var currentFloat: Bool?
    /// The blank line after a floating block: the float takes no room in the flow, so
    /// neither should the gap that used to separate it from the next block.
    private var followsFloat = false

    /// Widest a floating block may be, leaving the text beside it room to read.
    private var floatMaxWidth: CGFloat { round(config.columnWidth * 0.6) }
    /// How wide a floating table starts before the writer resizes it.
    private var floatNaturalWidth: CGFloat { round(config.columnWidth * 0.52) }

    /// Region and column of a block, if it sits inside a column layout.
    func cell(ofBlock index: Int) -> (region: Int, column: Int)? { cellOfBlock[index] }

    private func cells(forRegion index: Int) -> (cells: [NSTextTableBlock], widths: [CGFloat]) {
        let region = regions[index]
        let column = config.columnWidth
        let key = "\(region.ratios)|\(column)|\(gutter)"
        if let cached = tableCache[index], cached.key == key { return (cached.cells, cached.widths) }
        let table = NSTextTable()
        table.numberOfColumns = region.ratios.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = false
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        // The right gutter already comes from the paragraphs' tail indent; a margin
        // there too made the columns 56 pt narrower than the widths computed below.
        table.setWidth(gutter, type: .absoluteValueType, for: .margin, edge: .minX)
        var cells: [NSTextTableBlock] = []
        var widths: [CGFloat] = []
        let n = region.ratios.count
        for (i, ratio) in region.ratios.enumerated() {
            let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: i, columnSpan: 1)
            let lead: CGFloat = i > 0 ? Self.columnGap / 2 : 0
            let trail: CGFloat = i < n - 1 ? Self.columnGap / 2 : 0
            cell.setWidth(lead, type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(trail, type: .absoluteValueType, for: .padding, edge: .maxX)
            let width = floor(column * ratio - lead - trail)
            cell.setContentWidth(width, type: .absoluteValueType)
            cell.verticalAlignment = .topAlignment
            cells.append(cell)
            widths.append(width)
        }
        tableCache[index] = (key, cells, widths)
        return (cells, widths)
    }

    private func style(at index: Int, in s: NSTextStorage) {
        if let c = cellOfBlock[index], c.region < regions.count {
            let info = cells(forRegion: c.region)
            currentCell = info.cells[c.column]
            currentCellWidth = info.widths[c.column]
        } else {
            currentCell = nil
            currentCellWidth = nil
        }
        currentFloat = config.printing ? nil : floatOfBlock[index]
        followsFloat = !config.printing && index > 0 && floatOfBlock[index - 1] != nil
        style(blocks[index], in: s)
        followsFloat = false
        currentFloat = nil
        currentCell = nil
        currentCellWidth = nil
    }

    // MARK: Block styling

    private func style(_ block: MDBlock, in s: NSTextStorage) {
        let r = block.range
        guard r.length > 0, NSMaxRange(r) <= s.length else { return }
        s.setAttributes(baseAttributes(), range: r)
        let lineRanges = lines(of: r)
        guard let first = lineRanges.first else { return }

        switch block.kind {
        case .columnMarker(.pageBreak) where currentCell == nil && !config.printing:
            if hides(active: touches(first)) {
                s.addAttributes([.mdHidden: true, .mdPageBreak: true,
                                 .paragraphStyle: paragraph(fixedHeight: round(typo.size * 2.2))], range: r)
            } else {
                s.addAttribute(.foregroundColor, value: Palette.syntax, range: first)
            }

        case .columnMarker:
            // Layout markers are arranged from the page, never typed over: they only
            // show when the writer asked to always see Markdown.
            if config.printing || config.syntax != .always || !touches(first) {
                collapse(r, in: s, height: currentCell == nil ? 1 : 1)
            } else {
                let font = NSFont.monospacedSystemFont(ofSize: round(typo.size * 0.72), weight: .regular)
                s.addAttributes([.font: font, .foregroundColor: Palette.syntax,
                                 .paragraphStyle: paragraph(after: 2, lineSpacing: 0)], range: r)
            }

        case .blank where followsFloat:
            collapse(r, in: s)

        case .blank where config.printing:
            // On paper a blank line only needs to separate blocks, not add a full line.
            s.addAttribute(.paragraphStyle, value: paragraph(fixedHeight: round(typo.size * 0.5)), range: r)

        case .blank:
            s.addAttribute(.paragraphStyle, value: paragraph(after: 0, lineSpacing: round(typo.lineSpacing * 0.5)), range: r)

        case .paragraph:
            inline(first, in: s, font: { self.typo.text(bold: $0, italic: $1) }, color: Palette.text)

        case let .heading(level, markerLength):
            let font = typo.heading(level)
            let marker = NSRange(location: first.location, length: min(markerLength, first.length))
            let markerWidth = currentCell == nil ? min(width(of: text.substring(with: marker), font: font), gutter) : 0
            let before: CGFloat = [1.5, 1.25, 1.0, 0.8, 0.7, 0.7][level - 1] * typo.size * (config.printing ? 0.75 : 1)
            s.addAttributes([.font: font,
                             .paragraphStyle: paragraph(first: -markerWidth, before: before, after: round(typo.size * 0.35),
                                                        lineSpacing: round(font.pointSize * 0.22))], range: r)
            if level <= 2, typo.headingKern != 0 { s.addAttribute(.kern, value: typo.headingKern, range: first) }
            let active = touches(first)
            if currentCell != nil || gutter == 0 {
                // No gutter to hang the marker in: hide it outright.
                s.addAttributes(hides(active: active) ? [.mdHidden: true] : [.foregroundColor: Palette.syntax], range: marker)
            } else {
                s.addAttribute(.foregroundColor, value: hides(active: active) ? NSColor.clear : Palette.syntax, range: marker)
            }
            let content = NSRange(location: NSMaxRange(marker), length: first.length - marker.length)
            inline(content, in: s, font: { _, italic in self.typo.heading(level, italic: italic) }, color: Palette.text)

        case let .quote(depth, markerLength):
            let marker = NSRange(location: first.location, length: min(markerLength, first.length))
            let indent = CGFloat(depth) * 22
            let active = touches(first)
            let hide = hides(active: active)
            let markerWidth = hide ? 0 : width(of: text.substring(with: marker), font: typo.body)
            s.addAttributes([.paragraphStyle: paragraph(indent: indent, first: indent - markerWidth),
                             .mdGroup: GroupDecoration(.quote(depth: depth))], range: r)
            s.addAttributes(hide ? [.mdHidden: true] : [.foregroundColor: Palette.syntax], range: marker)
            let content = NSRange(location: NSMaxRange(marker), length: first.length - marker.length)
            inline(content, in: s, font: { self.typo.text(bold: $0, italic: $1) }, color: Palette.quoteText)

        case let .list(indentLength, markerLength, ordered, task):
            let prefix = NSRange(location: first.location, length: min(markerLength, first.length))
            let prefixString = text.substring(with: prefix)
            let tabs = prefixString.prefix(indentLength).filter { $0 == "\t" }.count
            let spaces = indentLength - tabs
            let indentWidth = CGFloat(tabs) * 28 + width(of: String(repeating: " ", count: spaces), font: typo.body)
            let hang = indentWidth + width(of: String(prefixString.dropFirst(indentLength)), font: typo.body)
            s.addAttribute(.paragraphStyle, value: paragraph(indent: hang, first: 0, after: round(typo.paragraphSpacing * 0.5)), range: r)
            let markerChar = NSRange(location: first.location + indentLength, length: 1)
            let depth = tabs + spaces / 2
            if ordered {
                let digits = (prefixString.dropFirst(indentLength).prefix { !$0.isWhitespace } as Substring)
                s.addAttribute(.foregroundColor, value: Palette.secondaryText,
                               range: NSRange(location: markerChar.location, length: (String(digits) as NSString).length))
            } else if config.syntax == .always && touches(first) && !config.printing {
                s.addAttribute(.foregroundColor, value: Palette.syntax, range: markerChar)
            } else {
                s.addAttributes([.foregroundColor: NSColor.clear, .mdBullet: depth], range: markerChar)
            }
            if task > 0 {
                let boxStart = NSMaxRange(markerChar)
                let taskRange = NSRange(location: boxStart, length: NSMaxRange(prefix) - boxStart)
                s.addAttribute(.foregroundColor, value: Palette.syntax, range: taskRange)
            }
            let content = NSRange(location: NSMaxRange(prefix), length: first.length - prefix.length)
            inline(content, in: s, font: { self.typo.text(bold: $0, italic: $1) },
                   color: task == 2 ? Palette.secondaryText : Palette.text)

        case .hr:
            let active = touches(first)
            if hides(active: active) {
                s.addAttributes([.mdHidden: true, .mdRule: true,
                                 .paragraphStyle: paragraph(fixedHeight: round(typo.size * 2.2))], range: r)
            } else {
                s.addAttribute(.foregroundColor, value: Palette.syntax, range: first)
            }

        case let .table(spec):
            styleTable(spec, block: block, lines: lineRanges, in: s)

        case .frontmatter where config.printing:
            for line in lineRanges { collapse(lineWithTerminator(line), in: s) }

        case .frontmatter:
            let font = NSFont.monospacedSystemFont(ofSize: round(typo.size * 0.76), weight: .regular)
            s.addAttributes([.font: font, .foregroundColor: Palette.tertiaryText,
                             .paragraphStyle: paragraph(after: 0, lineSpacing: round(font.pointSize * 0.4))], range: r)
            if let last = lineRanges.last, lineRanges.count > 1 {
                s.addAttribute(.paragraphStyle, value: paragraph(after: typo.size, lineSpacing: round(font.pointSize * 0.4)),
                               range: last)
            }

        case .code:
            styleCode(block, lines: lineRanges, in: s)

        case let .math(latex):
            styleMath(latex: latex, block: block, lines: lineRanges, in: s)

        case let .image(ref):
            styleImage(ref, line: first, block: block, in: s)

        case let .embed(ref):
            styleEmbed(ref, line: first, block: block, in: s)

        case .comment:
            // Notes to self: gone from the page (and from print) until the caret is in them.
            let content = NSRange(location: r.location, length: max(0, NSMaxRange(lineRanges.last!) - r.location))
            if hides(active: touches(content)) {
                for line in lineRanges { collapse(lineWithTerminator(line), in: s) }
            } else {
                s.addAttribute(.foregroundColor, value: Palette.syntax, range: r)
            }
        }
    }

    private func styleCode(_ block: MDBlock, lines: [NSRange], in s: NSTextStorage) {
        let font = typo.code
        let pad: CGFloat = 16
        let codeStyle = paragraph(indent: pad, tail: pad, after: 0, lineSpacing: round(font.pointSize * 0.42))
        s.addAttributes([.font: font, .paragraphStyle: codeStyle, .mdGroup: GroupDecoration(.code)], range: block.range)

        let active = touches(NSRange(location: block.range.location, length: block.range.length - 1))
        let hide = hides(active: active)
        let fenceChar = text.substring(with: lines[0]).trimmingCharacters(in: .whitespaces).first
        let closed = lines.count > 1 && text.substring(with: lines[lines.count - 1]).trimmingCharacters(in: .whitespaces).first == fenceChar
        var fences = [lines[0]]
        if closed { fences.append(lines[lines.count - 1]) }

        for (i, fence) in fences.enumerated() {
            let lineRange = i == 0 ? lineWithTerminator(fence) : fence
            if hide {
                let group = s.attribute(.mdGroup, at: block.range.location, effectiveRange: nil)!
                collapse(lineRange, in: s, height: 12)
                s.addAttribute(.mdGroup, value: group, range: lineRange)
            } else {
                s.addAttribute(.foregroundColor, value: Palette.syntax, range: fence)
            }
        }
        // Breathing room between the box and the paragraphs around it.
        if !hide {
            s.addAttribute(.paragraphStyle, value: paragraph(indent: pad, tail: pad, after: 0, lineSpacing: codeStyle.lineSpacing), range: lines[0])
        }
    }

    private func lineWithTerminator(_ content: NSRange) -> NSRange {
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: content.location, length: 0))
        return NSRange(location: s, length: e - s)
    }

    private func styleMath(latex: String, block: MDBlock, lines: [NSRange], in s: NSTextStorage) {
        let content = NSRange(location: block.range.location, length: max(0, NSMaxRange(lines.last!) - block.range.location))
        let active = touches(content)
        let size = round(typo.size * 1.2)
        // Half-typed LaTeX still previews while it's being written.
        let render = active ? MathRenderer.renderWhileTyping(latex, size: size, display: true) : MathRenderer.render(latex, size: size, display: true)
        let column = contentWidth
        let pad = round(typo.size * (config.printing ? 0.35 : 0.55))

        guard let render else {
            let font = typo.code
            s.addAttributes([.font: font, .foregroundColor: latex.isEmpty || active ? Palette.secondaryText : Palette.error,
                             .paragraphStyle: paragraph(after: 0, lineSpacing: round(font.pointSize * 0.4))], range: block.range)
            return
        }
        let scale = min(1, column / max(render.width, 1))
        let height = min(ceil(render.height * scale) + pad * 2, config.maxBlockHeight)

        if active {
            let font = typo.code
            s.addAttributes([.font: font, .foregroundColor: Palette.secondaryText,
                             .paragraphStyle: paragraph(after: 0, lineSpacing: round(font.pointSize * 0.4))], range: block.range)
            let last = lines.last!
            let anchor = last.length > 0 ? last : lineWithTerminator(last)
            s.addAttributes([.paragraphStyle: paragraph(after: height, lineSpacing: round(font.pointSize * 0.4)),
                             .mdBlock: BlockDecoration(content: .math(render, scale: scale), placement: .below, height: height, padding: pad)],
                            range: anchor)
            for (i, ch) in text.substring(with: block.range).utf16.enumerated() where ch == 0x24 {
                s.addAttribute(.foregroundColor, value: Palette.syntax, range: NSRange(location: block.range.location + i, length: 1))
            }
        } else {
            for (i, line) in lines.enumerated() {
                let full = lineWithTerminator(line)
                if i == 0 {
                    s.setAttributes([.font: typo.body, .foregroundColor: NSColor.clear, .mdHidden: true,
                                     .paragraphStyle: paragraph(fixedHeight: height)], range: full)
                    s.addAttribute(.mdBlock, value: BlockDecoration(content: .math(render, scale: scale), placement: .replace,
                                                                    height: height, padding: pad),
                                   range: line.length > 0 ? line : full)
                } else {
                    collapse(full, in: s)
                }
            }
        }
    }

    private func styleTable(_ spec: TableSpec, block: MDBlock, lines: [NSRange], in s: NSTextStorage) {
        let content = NSRange(location: block.range.location, length: max(0, NSMaxRange(lines.last!) - block.range.location))
        // Tables stay tables: selecting one doesn't turn it into pipes. The source only
        // shows when the writer asked to always see Markdown.
        if config.syntax == .always, !config.printing, touches(content), editingTableLocation != block.range.location {
            // Editing: the source, with the pipes and rules pushed back.
            let font = typo.code
            s.addAttributes([.font: font, .paragraphStyle: paragraph(after: 0, lineSpacing: round(font.pointSize * 0.45))], range: block.range)
            for (k, line) in lines.enumerated() {
                if k == 1 {
                    s.addAttribute(.foregroundColor, value: Palette.syntax, range: line)
                    continue
                }
                inline(line, in: s, font: { self.typo.codeVariant(bold: $0 || k == 0, italic: $1) }, color: Palette.text)
                for (i, ch) in (text.substring(with: line) as NSString).utf16Characters where ch == 0x7C {
                    s.addAttribute(.foregroundColor, value: Palette.syntax, range: NSRange(location: line.location + i, length: 1))
                }
            }
            if let last = lines.last {
                s.addAttribute(.paragraphStyle, value: paragraph(after: typo.paragraphSpacing, lineSpacing: round(typo.code.pointSize * 0.45)),
                               range: lineWithTerminator(last))
            }
            return
        }
        let editing = editingTableLocation == block.range.location && !config.printing
        let fixed = editing ? editingTableWidths : nil
        let reveal = editing ? editingTableCell : nil
        let render = currentFloat != nil
            ? TableRender(spec: spec, typography: typo, maxWidth: floatMaxWidth, fractionBase: config.columnWidth, naturalCap: floatNaturalWidth,
                          fixedWidths: fixed, revealing: reveal)
            : TableRender(spec: spec, typography: typo, maxWidth: contentWidth, fixedWidths: fixed, revealing: reveal)
        // The blank line before a table already separates it; only a hair more on top,
        // so a label directly above reads as belonging to it.
        let pad: CGFloat = 2
        let padBelow = round(typo.size * 0.5)
        let height = min(render.height + pad + padBelow, config.maxBlockHeight)
        if let right = currentFloat {
            // Floating: the source takes no room in the flow; the grid is drawn beside
            // the text that follows, which wraps around it.
            for (i, line) in lines.enumerated() {
                let full = lineWithTerminator(line)
                collapse(full, in: s)
                if i == 0 {
                    s.addAttribute(.mdBlock, value: BlockDecoration(content: .table(render), placement: .float(right: right), height: height, padding: pad),
                                   range: line.length > 0 ? line : full)
                }
            }
            return
        }
        for (i, line) in lines.enumerated() {
            let full = lineWithTerminator(line)
            if i == 0 {
                s.setAttributes([.font: typo.body, .foregroundColor: NSColor.clear, .mdHidden: true,
                                 .paragraphStyle: paragraph(fixedHeight: height)], range: full)
                s.addAttribute(.mdBlock, value: BlockDecoration(content: .table(render), placement: .replace, height: height, padding: pad),
                               range: line.length > 0 ? line : full)
            } else {
                collapse(full, in: s)
            }
        }
    }

    private func styleImage(_ ref: ImageRef, line: NSRange, block: MDBlock, in s: NSTextStorage) {
        let image = imageResolver?.image(for: ref)
        let floating = currentFloat
        let column = floating != nil ? floatNaturalWidth : contentWidth
        let pad = round(typo.size * 0.6)
        var size = NSSize(width: min(column, 360), height: 56)
        if let image, image.size.width > 0, image.size.height > 0 {
            let w = min(ref.width ?? image.size.width, column)
            size = NSSize(width: w, height: w * image.size.height / image.size.width)
        }
        var caption: String? = ref.alt.trimmingCharacters(in: .whitespaces)
        if let c = caption, c.isEmpty || MarkdownScanner.imageExtensions.contains((c as NSString).pathExtension.lowercased()) || c.hasPrefix("Pasted image") {
            caption = nil
        }
        let captionFont = typo.small(0.8)
        let captionHeight = caption == nil ? 0 : ceil(captionFont.lineHeight * 1.6)
        let maxImageHeight = config.maxBlockHeight - pad * 2 - captionHeight
        if size.height > maxImageHeight {
            size = NSSize(width: size.width * maxImageHeight / size.height, height: maxImageHeight)
        }
        let height = ceil(size.height) + pad * 2 + captionHeight
        let name = (ref.source as NSString).lastPathComponent.removingPercentEncoding ?? ref.source
        let content = BlockDecoration.Content.image(image, size: size, caption: caption, name: name)

        let objectSelected = selectedImageLine == block.range.location
        let active = touches(line) && !objectSelected
        if active {
            let font = typo.small(0.86)
            s.addAttributes([.font: font, .foregroundColor: Palette.secondaryText,
                             .paragraphStyle: paragraph(after: height)], range: block.range)
            s.addAttribute(.mdBlock, value: BlockDecoration(content: content, placement: .below, height: height, padding: pad),
                           range: line)
        } else if let right = floating {
            let decoration = BlockDecoration(content: content, placement: .float(right: right), height: height, padding: pad)
            decoration.isSelected = objectSelected && !config.printing
            collapse(block.range, in: s)
            s.addAttribute(.mdBlock, value: decoration, range: line)
        } else {
            let decoration = BlockDecoration(content: content, placement: .replace, height: height, padding: pad)
            decoration.isSelected = objectSelected && !config.printing
            s.setAttributes([.font: typo.body, .foregroundColor: NSColor.clear, .mdHidden: true,
                             .paragraphStyle: paragraph(fixedHeight: height)], range: block.range)
            s.addAttribute(.mdBlock, value: decoration, range: line)
        }
    }

    private func styleEmbed(_ ref: EmbedRef, line: NSRange, block: MDBlock, in s: NSTextStorage) {
        let link: (Bool, Bool) -> NSFont = { self.typo.text(bold: $0, italic: $1) }
        guard let resolver = imageResolver as? NoteEmbedResolving, embedDepth < Self.maxEmbedDepth else {
            // Too deep (or nothing to resolve notes with): a link to the note.
            inline(line, in: s, font: link, color: Palette.text)
            return
        }
        var chain = embedChain
        let host = resolver.embeddingNoteURL
        if let host { chain.insert(host.standardizedFileURL.path) }
        let url = resolver.noteURL(forEmbed: ref.note, from: host)
        if let url, chain.contains(url.standardizedFileURL.path) {
            // A note embedding one that's already open above it: a link, not a loop.
            inline(line, in: s, font: link, color: Palette.text)
            return
        }
        let pad = round(typo.size * 0.7)
        let innerWidth = max(contentWidth - pad * 2, 80)
        let content: NoteEmbed.Content
        if let url {
            if let text = NoteEmbed.text(at: url) {
                if let section = NoteEmbed.section(of: text, subpath: ref.subpath) {
                    var nested = config
                    nested.columnWidth = innerWidth
                    nested.gutter = 0
                    nested.printing = true
                    nested.maxBlockHeight = min(config.maxBlockHeight, 600)
                    let root = (resolver as? EmbeddedNoteContext)?.root ?? resolver
                    content = .note(NoteEmbed.Render(markdown: section, config: nested, context: EmbeddedNoteContext(root: root, note: url),
                                                     depth: embedDepth + 1, chain: chain.union([url.standardizedFileURL.path])))
                } else {
                    content = .message(ref.subpath?.hasPrefix("^") == true ? "Block not found" : "Heading not found",
                                       detail: ref.subpath ?? "")
                }
            } else {
                content = .message("Note can't be read", detail: ref.note)
            }
        } else {
            content = .message("Note not found", detail: ref.note)
        }
        let cap = config.printing ? config.maxBlockHeight * 0.8 : 420
        let contentHeight: CGFloat
        switch content {
        case let .note(render): contentHeight = min(render.height, cap)
        case .message: contentHeight = round(typo.size * 1.4)
        }
        // The line itself is the box's title: the note's name, a link that opens it.
        let font = typo.small(0.8)
        s.addAttribute(.paragraphStyle, value: paragraph(indent: pad, first: pad, tail: pad, before: round(pad * 0.9),
                                                         after: contentHeight + pad * 2, lineSpacing: 0), range: block.range)
        inline(line, in: s, font: { _, _ in font }, color: Palette.secondaryText)
        var dependencies: Set<String> = []
        if let url { dependencies.insert(NoteEmbed.key(url)) }
        if case let .note(render) = content { dependencies.formUnion(render.dependencies) }
        s.addAttribute(.mdEmbed, value: NoteEmbed(content: content, contentHeight: contentHeight, padding: pad, dependencies: dependencies),
                       range: line.length > 0 ? line : block.range)
    }

    // MARK: Inline styling

    private func inline(_ range: NSRange, in s: NSTextStorage, font: @escaping (Bool, Bool) -> NSFont, color: NSColor) {
        guard range.length > 0 else { return }
        s.addAttribute(.foregroundColor, value: color, range: range)
        let spans = MarkdownScanner.inlineSpans(in: text, range: range)
        if spans.isEmpty {
            s.addAttribute(.font, value: font(false, false), range: range)
            return
        }

        // Per-character traits: 1 bold, 2 italic, 4 code.
        var traits = [UInt8](repeating: 0, count: range.length)
        func mark(_ r: NSRange, _ bit: UInt8) {
            let lo = max(r.location - range.location, 0), hi = min(NSMaxRange(r) - range.location, range.length)
            if lo < hi { for i in lo..<hi { traits[i] |= bit } }
        }
        var deferred: [(NSRange, [NSAttributedString.Key: Any])] = []

        for span in spans {
            // Selecting text to format it leaves the markers hidden; only a caret reveals them.
            let caretOnly: Bool
            switch span.kind {
            case .math, .link, .wiki: caretOnly = false
            default: caretOnly = true
            }
            let active = touches(span.range, caretOnly: caretOnly)
            let hide = hides(active: active)
            func styleMarkers() {
                for m in span.markers where m.length > 0 {
                    deferred.append((m, hide ? [.mdHidden: true] : [.foregroundColor: Palette.syntax]))
                }
            }
            switch span.kind {
            case .strong:
                mark(span.content, 1); styleMarkers()
            case .emphasis:
                mark(span.content, 2); styleMarkers()
            case .strongEmphasis:
                mark(span.content, 3); styleMarkers()
            case .strike:
                deferred.append((span.content, [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                                .strikethroughColor: Palette.secondaryText,
                                                .foregroundColor: Palette.secondaryText]))
                styleMarkers()
            case .highlight:
                deferred.append((span.content, [.mdInlineBox: InlineBox(.highlight)]))
                styleMarkers()
            case .code:
                mark(span.range, 4)
                deferred.append((hide ? span.content : span.range, [.mdInlineBox: InlineBox(.code)]))
                styleMarkers()
            case .escape:
                styleMarkers()
            case .comment:
                deferred.append((span.range, hide ? [.mdHidden: true] : [.foregroundColor: Palette.syntax]))
            case .tag:
                deferred.append((span.range, [.foregroundColor: Palette.link, .mdInlineBox: InlineBox(.tag)]))
            case let .math(latex, display):
                mark(span.range, 4)
                let size = round(typo.size * (display ? 1.12 : 1.06))
                if !active, let render = MathRenderer.render(latex, size: size, display: display) {
                    // Punctuation right after the math sits against it, as it would after a word.
                    let after = NSMaxRange(span.range)
                    let next = after < text.length ? Character(UnicodeScalar(text.character(at: after)) ?? " ") : " "
                    let tight = ".,;:!?)]}’”'\"".contains(next)
                    deferred.append((span.range, [.mdInlineMath: InlineMath(render: render, tightAfter: tight), .foregroundColor: color]))
                } else {
                    let parsed = MathRenderer.render(latex, size: size, display: display) != nil
                    // Mid-edit LaTeX is often briefly incomplete; only settled math shows as an error.
                    deferred.append((span.content, [.foregroundColor: parsed || active ? color : Palette.error]))
                    for m in span.markers { deferred.append((m, [.foregroundColor: Palette.syntax])) }
                }
            case let .link(url):
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: Palette.link]
                if hide, let link = Self.linkURL(url) {
                    attrs[.link] = link
                } else {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.underlineColor] = Palette.linkUnderline
                }
                deferred.append((span.content, attrs))
                for m in span.markers where m.length > 0 {
                    deferred.append((m, hide ? [.mdHidden: true] : [.foregroundColor: Palette.syntax]))
                }
            case let .wiki(target):
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: Palette.link]
                if hide, let link = Self.wikiURL(target) {
                    attrs[.link] = link
                } else {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.underlineColor] = Palette.linkUnderline
                }
                deferred.append((span.content, attrs))
                styleMarkers()
            }
        }

        // Fonts in runs of equal traits.
        var runStart = 0
        for i in 1...range.length {
            if i == range.length || traits[i] != traits[runStart] {
                let t = traits[runStart]
                let f = t & 4 != 0 ? typo.codeVariant(bold: t & 1 != 0, italic: t & 2 != 0) : font(t & 1 != 0, t & 2 != 0)
                s.addAttribute(.font, value: f, range: NSRange(location: range.location + runStart, length: i - runStart))
                runStart = i
            }
        }
        for (r, attrs) in deferred { s.addAttributes(attrs, range: r) }
    }

    static func linkURL(_ raw: String) -> URL? {
        if raw.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil {
            return URL(string: raw) ?? URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        var c = URLComponents()
        c.scheme = "indium-file"
        c.path = "/" + (raw.removingPercentEncoding ?? raw)
        return c.url
    }

    static func wikiURL(_ target: String) -> URL? {
        var c = URLComponents()
        c.scheme = "indium-wiki"
        c.path = "/" + target
        return c.url
    }
}

/// A note drawn inside another (`![[Note]]`): its text styled by a styler of its own
/// and laid out once at the width of the box, then drawn read-only under the line.
final class NoteEmbed: NSObject {
    enum Content {
        case note(Render)
        case message(String, detail: String)
    }
    let content: Content
    /// Height shown, capped for long notes.
    let contentHeight: CGFloat
    let padding: CGFloat
    /// Every note file this embed shows, nested ones included, so a change to any of
    /// them can refresh it.
    let dependencies: Set<String>

    init(content: Content, contentHeight: CGFloat, padding: CGFloat, dependencies: Set<String>) {
        self.content = content
        self.contentHeight = contentHeight
        self.padding = padding
        self.dependencies = dependencies
    }

    final class Render {
        let storage: NSTextStorage
        let layout = MarkdownLayoutManager()
        let container: NSTextContainer
        let height: CGFloat
        /// Resolves the note's links and images from its own folder while it's styled.
        let context: EmbeddedNoteContext
        private(set) var dependencies: Set<String> = []

        init(markdown: String, config: StyleConfig, context: EmbeddedNoteContext, depth: Int, chain: Set<String>) {
            self.context = context
            storage = NSTextStorage(string: markdown)
            container = NSTextContainer(size: NSSize(width: config.columnWidth, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.allowsNonContiguousLayout = false
            layout.gutter = 0
            layout.bodyLineSpacing = config.typography.lineSpacing
            layout.typoParagraphGap = config.typography.paragraphSpacing
            layout.captionFont = config.typography.text(bold: false, italic: true, size: round(config.typography.size * 0.8))
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            let styler = MarkdownStyler(config: config)
            styler.imageResolver = context
            styler.embedDepth = depth
            styler.embedChain = chain
            styler.styleAll(storage, selection: [])
            // Read-only: links take the editor's link color rather than AppKit's blue,
            // and the box's padding is the only space above the first line.
            let storage = self.storage
            var links: [NSRange] = []
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value != nil { links.append(range) }
            }
            storage.beginEditing()
            for range in links {
                storage.removeAttribute(.link, range: range)
                storage.addAttribute(.foregroundColor, value: Palette.link, range: range)
            }
            if storage.length > 0, let first = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
               let style = first.mutableCopy() as? NSMutableParagraphStyle {
                style.paragraphSpacingBefore = 0
                let line = (storage.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
                storage.addAttribute(.paragraphStyle, value: style, range: line)
            }
            storage.endEditing()
            layout.ensureLayout(for: container)
            // A nested embed's box hangs below its line, in spacing the last line of a
            // text doesn't get, so it counts on its own.
            var bottom = layout.usedRect(for: container).height
            let layout = self.layout
            var dependencies: Set<String> = []
            storage.enumerateAttribute(.mdEmbed, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let embed = value as? NoteEmbed else { return }
                dependencies.formUnion(embed.dependencies)
                let glyph = layout.glyphIndexForCharacter(at: max(range.location, NSMaxRange(range) - 1))
                let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                bottom = max(bottom, used.maxY + embed.contentHeight + embed.padding * 1.5)
            }
            height = ceil(bottom)
            self.dependencies = dependencies
        }

        /// Draws the note with its top-left at `origin`, clipped to `clip`.
        func draw(at origin: NSPoint, clip: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            let glyphs = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The note's text, read fresh each time the embed is styled (notes are small, and
    /// a cache would have to know about every note nested inside).
    static func text(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// How dependencies are named: symlinks resolved, so file events (which report
    /// `/private/tmp/...`) match the paths links resolve to.
    static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    /// The part of a note an embed shows: all of it (without frontmatter), the section
    /// under a heading (down to the next heading as high or higher), or a `^block`.
    static func section(of text: String, subpath: String?) -> String? {
        let ns = text as NSString
        let body = MarkdownScanner.scan(ns).filter { if case .frontmatter = $0.kind { return false }; return true }
        guard let subpath else {
            guard let start = body.first?.range.location else { return "" }
            return ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if subpath.hasPrefix("^") {
            let id = NSRegularExpression.escapedPattern(for: String(subpath.dropFirst()))
            guard let regex = try? NSRegularExpression(pattern: #"(?:^|\s)\^"# + id + #"\s*$"#) else { return nil }
            for (i, b) in body.enumerated() {
                let line = ns.substring(with: b.range).trimmingCharacters(in: .newlines) as NSString
                guard let m = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { continue }
                let before = line.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { return before }
                // An id on a line of its own names the block just above it (a list or a
                // table, usually with a blank line between).
                var j = i - 1
                while j >= 0, body[j].kind == .blank { j -= 1 }
                var lines: [String] = []
                while j >= 0, body[j].kind != .blank {
                    lines.insert(ns.substring(with: body[j].range).trimmingCharacters(in: .newlines), at: 0)
                    j -= 1
                }
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
            return nil
        }
        // `Note#A#B` points at B under A; the last heading is the one shown.
        let wanted = normalize(subpath.components(separatedBy: "#").last ?? subpath)
        var start: (index: Int, level: Int)?
        for (i, b) in body.enumerated() {
            guard case let .heading(level, markerLength) = b.kind else { continue }
            if let s = start {
                guard level <= s.level else { continue }
                let from = body[s.index].range.location
                return ns.substring(with: NSRange(location: from, length: b.range.location - from)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let line = ns.substring(with: b.range) as NSString
            if normalize(line.substring(from: min(markerLength, line.length))) == wanted { start = (i, level) }
        }
        guard let s = start else { return nil }
        return ns.substring(from: body[s.index].range.location).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ heading: String) -> String {
        var t = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        // Closing hashes (`## Title ##`) aren't part of the title.
        while t.hasSuffix("#") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

extension NSString {
    var utf16Characters: [(Int, unichar)] {
        (0..<length).map { ($0, character(at: $0)) }
    }
}
