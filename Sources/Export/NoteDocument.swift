import AppKit

/// A picture for an export. `size` is in points at the HTML body's 16 pt text; `descent`
/// is how far an inline equation sits below the baseline.
struct ExportImage: Hashable {
    var data: Data
    var fileExtension: String
    var size: NSSize
    var descent: CGFloat = 0

    func hash(into hasher: inout Hasher) { hasher.combine(data) }
}

enum ExportInline {
    enum Style { case bold, italic, strike, highlight, underline, sup, sub, key, small, code, tag }
    case text(String)
    case lineBreak
    case styled(Style, [ExportInline])
    case link(String, [ExportInline])
    case image(ExportImage, alt: String)
}

struct ExportListItem {
    var level: Int
    var ordered: Bool
    /// The number as written; 1 for a bullet.
    var number: Int
    /// As the scanner has it: 0 not a task, 1 open, 2 done.
    var task: Int
    var content: [ExportInline]
}

indirect enum ExportBlock {
    case heading(Int, [ExportInline])
    case paragraph([ExportInline])
    case list([ExportListItem])
    case quote([ExportBlock])
    case callout(title: [ExportInline], tint: String, [ExportBlock])
    case code(language: String, String)
    case table(rows: [[[ExportInline]]], alignments: [Int], fractions: [CGFloat]?)
    /// `source` is a web address when the picture isn't embedded.
    case figure(ExportImage?, source: String?, alt: String, caption: String?)
    case columns([[ExportBlock]], ratios: [CGFloat])
    case footnote(label: String, [ExportInline])
    case rule
    case pageBreak
}

/// A note reduced to what its exports show, read with the editor's own scanner. Frontmatter
/// and comments are left out here, so no format can carry them.
struct NoteDocument {
    let blocks: [ExportBlock]

    init(text: String, resolver: ImageResolving?) {
        blocks = Reader(resolver: resolver, depth: 0, chain: []).read(TableFormulas.apply(toNote: text).text)
    }

    static func webAddress(_ raw: String) -> String? {
        guard let url = MarkdownStyler.linkURL(raw),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.absoluteString
    }

    /// `&`, `<`, `>` and quotes escaped, and anything XML can't hold dropped.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF: break
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

private final class Reader {
    private static let chartWidth: CGFloat = 680
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^ {0,3}>[ \t]?"#)

    private let resolver: ImageResolving?
    private let depth: Int
    private let chain: Set<String>
    private var text: NSString = ""
    private var scanned: [MDBlock] = []

    init(resolver: ImageResolving?, depth: Int, chain: Set<String>) {
        self.resolver = resolver
        self.depth = depth
        self.chain = chain
    }

    func read(_ source: String) -> [ExportBlock] {
        text = source as NSString
        scanned = MarkdownScanner.scan(text)
        return walk(0..<scanned.count)
    }

    /// Text from inside a quote: the blank line keeps a leading `---` from reading as frontmatter.
    private func nested(_ lines: [String]) -> [ExportBlock] {
        Reader(resolver: resolver, depth: depth, chain: chain).read("\n" + lines.joined(separator: "\n"))
    }

    private func walk(_ range: Range<Int>) -> [ExportBlock] {
        var out: [ExportBlock] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let block = scanned[i]
            switch block.kind {
            case .frontmatter, .comment, .blank, .tableFormulas:
                i += 1
            case let .columnMarker(.start(ratios)):
                guard let end = (i + 1..<range.upperBound).first(where: { scanned[$0].kind == .columnMarker(.end) }) else { i += 1; continue }
                let bounds = [i] + (i + 1..<end).filter { scanned[$0].kind == .columnMarker(.split) } + [end]
                let cells = zip(bounds, bounds.dropFirst()).map { walk($0 + 1..<$1) }
                let raw = ratios.count == cells.count ? ratios.map { CGFloat($0) } : Array(repeating: 1, count: cells.count)
                let total = raw.reduce(0, +)
                out.append(.columns(cells, ratios: raw.map { $0 / total }))
                i = end + 1
            case .columnMarker(.pageBreak):
                out.append(.pageBreak)
                i += 1
            case .columnMarker:
                i += 1
            case .paragraph:
                var lines: [[ExportInline]] = []
                while i < range.upperBound, scanned[i].kind == .paragraph {
                    let line = lineText(scanned[i])
                    if !MarkdownStyler.isBlockID(line) { lines.append(inlines(line.trimmingCharacters(in: .whitespaces))) }
                    i += 1
                }
                if !lines.isEmpty { out.append(.paragraph(Array(lines.joined(separator: [.lineBreak])))) }
            case let .heading(level, markerLength):
                out.append(.heading(level, inlines(lineText(block, from: markerLength))))
                i += 1
            case .hr:
                out.append(.rule)
                i += 1
            case .list:
                out.append(list(&i, upTo: range.upperBound))
            case .quote, .callout:
                out.append(quote(&i, upTo: range.upperBound))
            case let .code(language):
                out.append(code(language, block))
                i += 1
            case let .math(latex):
                let image = equation(latex, size: 19, display: true)
                out.append(image.map { .figure($0, source: nil, alt: latex, caption: nil) } ?? .code(language: "latex", latex))
                i += 1
            case let .table(spec):
                out.append(table(spec))
                i += 1
            case let .image(ref):
                out.append(figure(ref))
                i += 1
            case let .embed(ref):
                out += embed(ref)
                i += 1
            case let .footnote(label, markerLength):
                out.append(.footnote(label: label, inlines(lineText(block, from: markerLength).trimmingCharacters(in: .whitespaces))))
                i += 1
            }
        }
        return out
    }

    private func lineText(_ block: MDBlock, from offset: Int = 0) -> String {
        let line = text.substring(with: block.range).trimmingCharacters(in: .newlines) as NSString
        return line.substring(from: min(offset, line.length))
    }

    // MARK: Blocks

    private func list(_ i: inout Int, upTo end: Int) -> ExportBlock {
        var items: [ExportListItem] = []
        var indents: [Int] = []
        while i < end {
            switch scanned[i].kind {
            case let .list(indent, markerLength, ordered, task):
                while let last = indents.last, last > indent { indents.removeLast() }
                if indents.last.map({ indent > $0 }) ?? true { indents.append(indent) }
                let line = lineText(scanned[i])
                let number = Int(line.drop { $0.isWhitespace }.prefix { $0.isNumber }) ?? 1
                items.append(ExportListItem(level: indents.count - 1, ordered: ordered, number: number, task: task,
                                            content: inlines(lineText(scanned[i], from: markerLength))))
                i += 1
            case .blank where i + 1 < end && { if case .list = scanned[i + 1].kind { true } else { false } }():
                i += 1
            case .paragraph where !items.isEmpty && lineText(scanned[i]).first?.isWhitespace == true:
                items[items.count - 1].content += [.lineBreak] + inlines(lineText(scanned[i]).trimmingCharacters(in: .whitespaces))
                i += 1
            default:
                return .list(items)
            }
        }
        return .list(items)
    }

    private func quote(_ i: inout Int, upTo end: Int) -> ExportBlock {
        var header: (CalloutHeader, String)?
        if case let .callout(h) = scanned[i].kind {
            header = (h, lineText(scanned[i], from: h.markerLength))
            i += 1
        }
        var lines: [String] = []
        while i < end, case .quote = scanned[i].kind {
            let line = lineText(scanned[i])
            lines.append(Self.quoteMarker.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: ""))
            i += 1
        }
        guard let (callout, title) = header else { return .quote(nested(lines)) }
        let look = CalloutLook.of(callout.type)
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return .callout(title: trimmed.isEmpty ? [.text(look.title)] : inlines(trimmed), tint: Self.hex(look.color), nested(lines))
    }

    private func code(_ language: String, _ block: MDBlock) -> ExportBlock {
        let full = text.substring(with: block.range)
        var lines = full.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let opening = lines[0].trimmingCharacters(in: .whitespaces)
        let closing = lines.last?.trimmingCharacters(in: .whitespaces) ?? ""
        let fence = opening.prefix { $0 == opening.first }
        let closed = lines.count > 1 && closing.count >= fence.count && closing.allSatisfy { $0 == opening.first }
        let body = lines.dropFirst().dropLast(closed ? 1 : 0).joined(separator: "\n")
        guard ChartModel.handles(language) else { return .code(language: language, body) }
        let text = self.text, blocks = scanned
        let context = ChartModel.Context(table: { MarkdownStyler.table(named: $0, in: text, blocks: blocks) },
                                         variables: NoteVariables.parse(noteText: text as String))
        let render = ChartRender.make(ChartModel.build(language: language, body: body, context: context), column: Self.chartWidth)
        let image = Self.picture(render.size, scale: 3) { rect in
            render.image(dark: false).draw(in: rect)
        }
        return .figure(image, source: nil, alt: "Chart", caption: nil)
    }

    private func table(_ spec: TableSpec) -> ExportBlock {
        let columns = max(spec.alignments.count, spec.rows.map(\.count).max() ?? 1)
        let rows = spec.rows.map { row in
            (0..<columns).map { c in c < row.count ? inlines(TableSpec.unescapeCell(row[c].text)) : [] }
        }
        // Shares of the table: exports don't know the editor's text width, so a narrow table fills the page.
        let total = spec.widthFractions?.reduce(0, +) ?? 1
        return .table(rows: rows, alignments: spec.alignments, fractions: spec.widthFractions?.map { $0 / total })
    }

    private func figure(_ ref: ImageRef) -> ExportBlock {
        let remote = ref.source.hasPrefix("http://") || ref.source.hasPrefix("https://") ? NoteDocument.webAddress(ref.source) : nil
        let alt = ref.alt.trimmingCharacters(in: .whitespaces)
        let isFileName = MarkdownScanner.imageExtensions.contains((alt as NSString).pathExtension.lowercased()) || alt.hasPrefix("Pasted image")
        let caption = alt.isEmpty || isFileName ? nil : alt
        guard let found = resolver?.image(for: ref), found.size.width > 0, found.size.height > 0 else {
            return .figure(nil, source: remote, alt: alt.isEmpty ? ref.source : alt, caption: nil)
        }
        return .figure(Self.encoded(found, width: ref.width), source: nil, alt: alt, caption: caption)
    }

    /// Embedded notes read as a titled box, the way the editor draws them. One that can't be
    /// read, or would loop, is just its name.
    private func embed(_ ref: EmbedRef) -> [ExportBlock] {
        let name = ExportBlock.paragraph([.text(ref.note)])
        guard let host = resolver as? NoteEmbedResolving, depth < MarkdownStyler.maxEmbedDepth else { return [name] }
        var chain = chain
        if let note = host.embeddingNoteURL { chain.insert(note.standardizedFileURL.path) }
        guard let url = host.noteURL(forEmbed: ref.note, from: host.embeddingNoteURL), !chain.contains(url.standardizedFileURL.path),
              let source = NoteEmbed.text(at: url),
              let section = NoteEmbed.section(of: TableFormulas.apply(toNote: source).text, subpath: ref.subpath) else { return [name] }
        let context = EmbeddedNoteContext(root: (host as? EmbeddedNoteContext)?.root ?? host, note: url)
        let inner = Reader(resolver: context, depth: depth + 1, chain: chain.union([url.standardizedFileURL.path])).read("\n" + section)
        return [.callout(title: [.text(ref.note)], tint: "7D7872", inner)]
    }

    // MARK: Inline

    private func inlines(_ source: String) -> [ExportInline] {
        let lines = source.components(separatedBy: "\n").map { line -> [ExportInline] in
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            return tree(full, in: ns, spans: MarkdownScanner.inlineSpans(in: ns, range: full))
        }
        return Array(lines.joined(separator: [.lineBreak]))
    }

    /// Spans come flat and may nest; each takes what lies inside its content. One that
    /// crosses another (`*a **b* c**`) stays as written.
    private func tree(_ range: NSRange, in line: NSString, spans: [MarkdownScanner.Span]) -> [ExportInline] {
        let inside = spans.filter { $0.range.location >= range.location && NSMaxRange($0.range) <= NSMaxRange(range) }
            .sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
        var out: [ExportInline] = []
        var position = range.location
        func plain(to end: Int) {
            if end > position { out.append(.text(line.substring(with: NSRange(location: position, length: end - position)))) }
        }
        for span in inside where span.range.location >= position {
            plain(to: span.range.location)
            let rest = spans.filter { !NSEqualRanges($0.range, span.range) }
            func children() -> [ExportInline] { tree(span.content, in: line, spans: rest) }
            func content() -> String { line.substring(with: span.content) }
            switch span.kind {
            case .strong: out.append(.styled(.bold, children()))
            case .emphasis: out.append(.styled(.italic, children()))
            case .strongEmphasis: out.append(.styled(.bold, [.styled(.italic, children())]))
            case .strike: out.append(.styled(.strike, children()))
            case .highlight: out.append(.styled(.highlight, children()))
            case .code: out.append(.styled(.code, [.text(content())]))
            case let .math(latex, display):
                if let image = equation(latex, size: display ? 18 : 17, display: display) {
                    out.append(.image(image, alt: latex))
                } else {
                    out.append(.styled(.code, [.text("$" + latex + "$")]))
                }
            case let .link(raw):
                if let url = NoteDocument.webAddress(raw) { out.append(.link(url, children())) } else { out += children() }
            case .wiki, .escape: out += children()
            case .comment: break
            case .tag: out.append(.styled(.tag, [.text(content())]))
            case let .html(tag):
                switch tag {
                case .br: out.append(.lineBreak)
                case .sup: out.append(.styled(.sup, children()))
                case .sub: out.append(.styled(.sub, children()))
                case .u: out.append(.styled(.underline, children()))
                case .mark: out.append(.styled(.highlight, children()))
                case .kbd: out.append(.styled(.key, children()))
                }
            case let .footnoteRef(label): out.append(.styled(.sup, [.text(label)]))
            case .inlineFootnote: out += [.text(" "), .styled(.small, children())]
            }
            position = NSMaxRange(span.range)
        }
        plain(to: NSMaxRange(range))
        return out
    }

    // MARK: Pictures

    private func equation(_ latex: String, size: CGFloat, display: Bool) -> ExportImage? {
        guard let render = MathRenderer.render(latex, size: size, display: display) else { return nil }
        // A point of margin: glyphs can overhang the typesetter's box.
        let margin: CGFloat = 1
        let box = NSSize(width: render.width + margin * 2, height: render.height + margin * 2)
        var image = Self.picture(box, scale: 3) { _ in
            render.draw(baselineAt: NSPoint(x: margin, y: render.descent + margin), color: .black, flippedContext: false)
        }
        image.descent = render.descent + margin
        return image
    }

    /// Redrawn rather than copied, so a photo's location and camera details stay behind.
    private static func encoded(_ image: NSImage, width: CGFloat?) -> ExportImage {
        let bitmap = image.representations.first as? NSBitmapImageRep
        let native = bitmap.map { CGFloat($0.pixelsWide) / image.size.width } ?? 3
        let scale = min(max(native, 1), 4096 / max(image.size.width, image.size.height))
        var result = picture(image.size, scale: scale) { rect in image.draw(in: rect) }
        if result.data.count > 1_000_000, bitmap?.hasAlpha == false,
           let rep = NSBitmapImageRep(data: result.data),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
            result.data = jpeg
            result.fileExtension = "jpg"
        }
        if let width, width <= 10_000 {
            result.size = NSSize(width: width, height: width * image.size.height / image.size.width)
        }
        return result
    }

    private static func picture(_ size: NSSize, scale: CGFloat, draw: (NSRect) -> Void) -> ExportImage {
        let pixels = (Int(ceil(size.width * scale)), Int(ceil(size.height * scale)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels.0, pixelsHigh: pixels.1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return ExportImage(data: Data(), fileExtension: "png", size: size) }
        // Set before the context exists, which takes its scale from it.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return ExportImage(data: Data(), fileExtension: "png", size: size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { draw(NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        return ExportImage(data: rep.representation(using: .png, properties: [:]) ?? Data(), fileExtension: "png", size: size)
    }

    private static func hex(_ color: NSColor) -> String {
        var out = "7D7872"
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                out = String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            }
        }
        return out
    }
}
