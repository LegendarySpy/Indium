import Foundation

/// An image that occupies a line of its own: `![alt|300](path)` or `![[path|300]]`.
struct ImageRef: Hashable {
    var source: String
    var alt: String
    var width: CGFloat?
    var isWiki: Bool
    /// Range of the alt text inside the line (relative), used to edit captions.
    var altRange: NSRange
}

/// A GitHub-style pipe table. Offsets are relative to the start of the block.
struct TableSpec: Hashable {
    struct Cell: Hashable {
        var text: String
        var offset: Int
    }
    /// Header first; the delimiter row is not included.
    var rows: [[Cell]]
    /// 0 natural, 1 left, 2 center, 3 right.
    var alignments: [Int]
    /// Dash counts of the delimiter row. Following Pandoc, when they carry widths each
    /// column is `dashes / 72` of the text width, so a table can be narrower than the page.
    var dashes: [Int] = []
    static let widthScale = 72

    /// Set when the dashes were written to size the columns (they aren't all equal).
    var widthFractions: [CGFloat]? {
        guard dashes.count == alignments.count, dashes.count > 1, Set(dashes).count > 1 else { return nil }
        let fractions = dashes.map { CGFloat($0) / CGFloat(Self.widthScale) }
        let total = fractions.reduce(0, +)
        return total > 1 ? fractions.map { $0 / total } : fractions
    }

    var header: [String] { rows.first?.map(\.text) ?? [] }
    var body: [[String]] { rows.dropFirst().map { $0.map(\.text) } }

    /// Markdown for a table, with cells padded so the source stays readable.
    static func markdown(header: [String], body: [[String]], alignments: [Int], dashes: [Int]?) -> String {
        let columns = max(header.count, alignments.count, body.map(\.count).max() ?? 0, 1)
        func cells(_ row: [String]) -> [String] {
            // Escape bare pipes so they can't split the row; already escaped ones stay as they are.
            (0..<columns).map { c in c < row.count ? row[c].replacingOccurrences(of: #"(?<!\\)\|"#, with: #"\\|"#, options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ") : "" }
        }
        let head = cells(header)
        let rows = body.map(cells)
        let widths = (0..<columns).map { c in max(3, ([head] + rows).map { $0[c].count }.max() ?? 3) }
        func line(_ row: [String]) -> String {
            "| " + row.enumerated().map { c, text in
                let pad = String(repeating: " ", count: max(0, widths[c] - text.count))
                let align = c < alignments.count ? alignments[c] : 0
                return align == 3 ? pad + text : (align == 2 ? String(pad.prefix(pad.count / 2)) + text + String(pad.dropFirst(pad.count / 2)) : text + pad)
            }.joined(separator: " | ") + " |"
        }
        let delimiter = "| " + (0..<columns).map { c in
            // Dash counts carry column widths, so only vary them when widths were set.
            let n = dashes.flatMap { c < $0.count ? $0[c] : nil } ?? 3
            let align = c < alignments.count ? alignments[c] : 0
            let body = String(repeating: "-", count: max(3, n))
            switch align {
            case 1: return ":" + body
            case 2: return ":" + body + ":"
            case 3: return body + ":"
            default: return body
            }
        }.joined(separator: " | ") + " |"
        return ([line(head), delimiter] + rows.map(line)).joined(separator: "\n")
    }
}

/// Portable column layout markers (HTML comments, invisible in other renderers):
/// `<!-- columns -->`, `<!-- columns 60/40 -->`, `<!-- column -->`, `<!-- /columns -->`.
/// `<!-- float right -->` / `<!-- float left -->` directly above a table or image lets
/// the text that follows wrap beside it.
enum ColumnMarker: Hashable {
    case start(ratios: [Int])
    case split
    case end
    case float(right: Bool)
}

enum BlockKind: Hashable {
    case columnMarker(ColumnMarker)
    case blank
    case paragraph
    case heading(level: Int, markerLength: Int)
    case quote(depth: Int, markerLength: Int)
    case list(indentLength: Int, markerLength: Int, ordered: Bool, task: Int)
    case hr
    case table(TableSpec)
    case frontmatter
    case code(language: String)
    case math(latex: String)
    case image(ImageRef)

    var isMultiLine: Bool {
        switch self {
        case .frontmatter, .code, .math: true
        default: false
        }
    }
}

/// A styling unit: one line, or a fenced region (code, math, frontmatter).
struct MDBlock: Hashable {
    /// Characters of the block, including the terminator of its last line.
    var range: NSRange
    var kind: BlockKind
}

enum MarkdownScanner {

    // MARK: Blocks

    static func scan(_ text: NSString) -> [MDBlock] {
        var lines: [(content: NSRange, full: NSRange)] = []
        lines.reserveCapacity(text.length / 40 + 1)
        var loc = 0
        let length = text.length
        while loc < length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: loc, length: 0))
            lines.append((NSRange(location: start, length: contentsEnd - start), NSRange(location: start, length: end - start)))
            loc = end
        }

        var blocks: [MDBlock] = []
        blocks.reserveCapacity(lines.count)
        var i = 0

        func span(_ a: Int, _ b: Int) -> NSRange {
            NSRange(location: lines[a].full.location, length: NSMaxRange(lines[b].full) - lines[a].full.location)
        }

        // Frontmatter only at the very top.
        if !lines.isEmpty, text.substring(with: lines[0].content).trimmingCharacters(in: .whitespaces) == "---" {
            var j = 1
            while j < lines.count {
                let t = text.substring(with: lines[j].content).trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." { break }
                j += 1
            }
            if j < lines.count {
                blocks.append(MDBlock(range: span(0, j), kind: .frontmatter))
                i = j + 1
            }
        }

        while i < lines.count {
            let line = text.substring(with: lines[i].content)

            if let fence = fenceOpening(line) {
                var j = i + 1
                while j < lines.count, !isFenceClose(text.substring(with: lines[j].content), fence: fence.marker) { j += 1 }
                let last = min(j, lines.count - 1)
                blocks.append(MDBlock(range: span(i, last), kind: .code(language: fence.language)))
                i = last + 1
                continue
            }

            if i + 1 < lines.count, line.contains("|"), isTableDelimiter(text.substring(with: lines[i + 1].content)) {
                var j = i + 2
                while j < lines.count {
                    let t = text.substring(with: lines[j].content)
                    if !t.contains("|") || t.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    j += 1
                }
                let last = j - 1
                let range = span(i, last)
                blocks.append(MDBlock(range: range, kind: .table(tableSpec(text, lines: Array(lines[i...last]).map(\.content), base: range.location))))
                i = last + 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$$") {
                if trimmed.count >= 4, trimmed.hasSuffix("$$") {
                    let inner = String(trimmed.dropFirst(2).dropLast(2))
                    blocks.append(MDBlock(range: span(i, i), kind: .math(latex: inner.trimmingCharacters(in: .whitespacesAndNewlines))))
                    i += 1
                    continue
                }
                var j = i + 1
                var body = [String(trimmed.dropFirst(2))]
                var closed = false
                while j < lines.count {
                    let t = text.substring(with: lines[j].content).trimmingCharacters(in: .whitespaces)
                    if t.hasSuffix("$$") {
                        body.append(String(t.dropLast(2)))
                        closed = true
                        break
                    }
                    body.append(t)
                    j += 1
                }
                if closed {
                    let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append(MDBlock(range: span(i, j), kind: .math(latex: latex)))
                    i = j + 1
                    continue
                }
            }

            blocks.append(MDBlock(range: lines[i].full, kind: classify(line: line)))
            i += 1
        }
        return blocks
    }

    private static func fenceOpening(_ line: String) -> (marker: String, language: String)? {
        let stripped = line.drop(while: { $0 == " " })
        guard line.count - stripped.count <= 3, let first = stripped.first, first == "`" || first == "~" else { return nil }
        let run = stripped.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let info = stripped.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init) ?? ""
        return (String(run), language)
    }

    private static func isFenceClose(_ line: String, fence: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let c = fence.first, t.count >= fence.count else { return false }
        return t.allSatisfy { $0 == c }
    }

    static func classify(line: String) -> BlockKind {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if line.allSatisfy({ $0 == " " || $0 == "\t" }) { return .blank }
        if let marker = columnMarker(line) { return .columnMarker(marker) }

        if let m = Regex.heading.firstMatch(in: line, range: full) {
            return .heading(level: m.range(at: 1).length, markerLength: m.range.length)
        }
        if Regex.hr.firstMatch(in: line, range: full) != nil { return .hr }
        if let m = Regex.quote.firstMatch(in: line, range: full) {
            let depth = ns.substring(with: m.range).filter { $0 == ">" }.count
            return .quote(depth: depth, markerLength: m.range.length)
        }
        if let m = Regex.list.firstMatch(in: line, range: full) {
            let marker = ns.substring(with: m.range(at: 2))
            var task = 0
            if m.range(at: 4).location != NSNotFound {
                task = ns.substring(with: m.range(at: 4)).lowercased().contains("x") ? 2 : 1
            }
            return .list(indentLength: m.range(at: 1).length, markerLength: m.range.length,
                         ordered: marker.first?.isNumber == true, task: task)
        }
        if let image = imageLine(line) { return .image(image) }
        return .paragraph
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        let cells = splitRow(t).map { $0.text }
        return !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }
    }

    /// Splits a table row on unescaped pipes, ignoring the optional outer pipes.
    /// Returns trimmed cell text with its offset in the line (UTF-16).
    static func splitRow(_ line: String) -> [(text: String, offset: Int)] {
        let ns = line as NSString
        var cells: [(String, Int)] = []
        var start = 0
        var i = 0
        var inCode = false
        while i <= ns.length {
            let c: unichar = i < ns.length ? ns.character(at: i) : 0x7C
            if c == 0x60 { inCode.toggle() }
            if c == 0x7C, !inCode, i == ns.length || i == 0 || ns.character(at: i - 1) != 0x5C {
                let raw = ns.substring(with: NSRange(location: start, length: i - start))
                let lead = raw.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                cells.append((trimmed, start + lead))
                start = i + 1
            }
            i += 1
        }
        // Outer pipes produce empty first/last cells.
        if let first = cells.first, first.0.isEmpty, line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
        if let last = cells.last, last.0.isEmpty, line.trimmingCharacters(in: .whitespaces).hasSuffix("|") { cells.removeLast() }
        return cells
    }

    private static func tableSpec(_ text: NSString, lines: [NSRange], base: Int) -> TableSpec {
        let delimiter = splitRow(text.substring(with: lines[1])).map(\.text)
        let alignments = delimiter.map { d -> Int in
            let l = d.hasPrefix(":"), r = d.hasSuffix(":")
            return l && r ? 2 : (r ? 3 : (l ? 1 : 0))
        }
        let dashes = delimiter.map { $0.filter { $0 == "-" }.count }
        var rows: [[TableSpec.Cell]] = []
        for (k, line) in lines.enumerated() where k != 1 {
            rows.append(splitRow(text.substring(with: line)).map {
                TableSpec.Cell(text: $0.text, offset: line.location - base + $0.offset)
            })
        }
        return TableSpec(rows: rows, alignments: alignments, dashes: dashes)
    }

    static func columnMarker(_ line: String) -> ColumnMarker? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("<!--"), t.hasSuffix("-->") else { return nil }
        let inner = t.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces).lowercased()
        if inner == "/columns" { return .end }
        if inner == "float right" { return .float(right: true) }
        if inner == "float left" { return .float(right: false) }
        if inner == "column" { return .split }
        if inner == "columns" { return .start(ratios: []) }
        if inner.hasPrefix("columns ") {
            let ratios = inner.dropFirst(8).split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .start(ratios: ratios.allSatisfy { $0 > 0 } ? ratios : [])
        }
        return nil
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif"]

    static func imageLine(_ line: String) -> ImageRef? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = Regex.imageLine.firstMatch(in: line, range: full) {
            var alt = ns.substring(with: m.range(at: 1))
            var altRange = m.range(at: 1)
            var width: CGFloat?
            if let bar = alt.lastIndex(of: "|"), let w = Double(alt[alt.index(after: bar)...].trimmingCharacters(in: .whitespaces)) {
                width = CGFloat(w)
                alt = String(alt[..<bar])
                altRange.length = (alt as NSString).length
            }
            var src = ns.substring(with: m.range(at: 2))
            if src.hasPrefix("<"), src.hasSuffix(">") { src = String(src.dropFirst().dropLast()) }
            return ImageRef(source: src, alt: alt, width: width, isWiki: false, altRange: altRange)
        }
        if let m = Regex.wikiImageLine.firstMatch(in: line, range: full) {
            let inner = ns.substring(with: m.range(at: 1))
            let parts = inner.components(separatedBy: "|")
            let target = parts[0].trimmingCharacters(in: .whitespaces)
            guard imageExtensions.contains((target as NSString).pathExtension.lowercased()) else { return nil }
            let width = parts.count > 1 ? Double(parts[1].trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } : nil
            return ImageRef(source: target, alt: "", width: width, isWiki: true, altRange: NSRange(location: NSNotFound, length: 0))
        }
        return nil
    }

    // MARK: Inline

    struct Span {
        enum Kind {
            case strong, emphasis, strongEmphasis, strike, highlight, code
            case math(String, display: Bool)
            case link(String)
            case wiki(String)
            case escape
        }
        var kind: Kind
        /// Whole span, absolute.
        var range: NSRange
        /// Syntax characters that can be hidden, absolute.
        var markers: [NSRange]
        /// The visible text, absolute.
        var content: NSRange
    }

    static func inlineSpans(in text: NSString, range: NSRange) -> [Span] {
        guard range.length > 0 else { return [] }
        let line = text.substring(with: range) as NSString
        let base = range.location
        let full = NSRange(location: 0, length: line.length)
        var consumed = [Bool](repeating: false, count: line.length)
        var spans: [Span] = []

        func free(_ r: NSRange) -> Bool {
            for i in r.location..<NSMaxRange(r) where consumed[i] { return false }
            return true
        }
        func consume(_ r: NSRange) {
            for i in r.location..<NSMaxRange(r) { consumed[i] = true }
        }
        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + base, length: r.length) }

        // Escapes: the escaped character loses its syntactic meaning.
        for m in Regex.escape.matches(in: line as String, range: full) {
            consume(m.range)
            spans.append(Span(kind: .escape, range: abs(m.range), markers: [abs(NSRange(location: m.range.location, length: 1))],
                              content: abs(NSRange(location: m.range.location + 1, length: 1))))
        }

        // Code spans take precedence over everything else.
        for m in Regex.codeSpan.matches(in: line as String, range: full) where free(m.range) {
            let tick = m.range(at: 1).length
            consume(m.range)
            spans.append(Span(kind: .code, range: abs(m.range),
                              markers: [abs(NSRange(location: m.range.location, length: tick)),
                                        abs(NSRange(location: NSMaxRange(m.range) - tick, length: tick))],
                              content: abs(NSRange(location: m.range.location + tick, length: m.range.length - 2 * tick))))
        }

        // Math.
        for (regex, display) in [(Regex.displayMathInline, true), (Regex.inlineMath, false)] {
            for m in regex.matches(in: line as String, range: full) where free(m.range) {
                let d = display ? 2 : 1
                consume(m.range)
                spans.append(Span(kind: .math(line.substring(with: m.range(at: 1)), display: display), range: abs(m.range),
                                  markers: [abs(NSRange(location: m.range.location, length: d)),
                                            abs(NSRange(location: NSMaxRange(m.range) - d, length: d))],
                                  content: abs(m.range(at: 1))))
            }
        }

        // Wiki links and embeds.
        for m in Regex.wikiLink.matches(in: line as String, range: full) where free(m.range) {
            consume(m.range)
            let inner = m.range(at: 2)
            let innerText = line.substring(with: inner)
            var visible = inner
            let bar = (innerText as NSString).range(of: "|")
            if bar.location != NSNotFound, bar.location + 1 < inner.length {
                visible = NSRange(location: inner.location + bar.location + 1, length: inner.length - bar.location - 1)
            }
            let target = innerText.components(separatedBy: "|")[0]
            spans.append(Span(kind: .wiki(target), range: abs(m.range),
                              markers: [abs(NSRange(location: m.range.location, length: visible.location - m.range.location)),
                                        abs(NSRange(location: NSMaxRange(visible), length: NSMaxRange(m.range) - NSMaxRange(visible)))],
                              content: abs(visible)))
        }

        // Standard links and inline images.
        for m in Regex.link.matches(in: line as String, range: full) where free(m.range) {
            let textRange = m.range(at: 2)
            let open = NSRange(location: m.range.location, length: textRange.location - m.range.location)
            let tail = NSRange(location: NSMaxRange(textRange), length: NSMaxRange(m.range) - NSMaxRange(textRange))
            consume(open)
            consume(tail)
            var url = line.substring(with: m.range(at: 3))
            if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
            spans.append(Span(kind: .link(url), range: abs(m.range), markers: [abs(open), abs(tail)], content: abs(textRange)))
        }

        for m in Regex.autolink.matches(in: line as String, range: full) where free(m.range) {
            consume(m.range)
            let inner = m.range(at: 1)
            spans.append(Span(kind: .link(line.substring(with: inner)), range: abs(m.range),
                              markers: [abs(NSRange(location: m.range.location, length: 1)), abs(NSRange(location: NSMaxRange(m.range) - 1, length: 1))],
                              content: abs(inner)))
        }
        for m in Regex.bareURL.matches(in: line as String, range: full) where free(m.range) {
            consume(m.range)
            spans.append(Span(kind: .link(line.substring(with: m.range)), range: abs(m.range), markers: [], content: abs(m.range)))
        }

        // Emphasis family. Only the markers are consumed so spans can nest.
        let emphasis: [(NSRegularExpression, Span.Kind, Int)] = [
            (Regex.strongEmphasis, .strongEmphasis, 3),
            (Regex.strong, .strong, 2),
            (Regex.strongUnderscore, .strong, 2),
            (Regex.emphasis, .emphasis, 1),
            (Regex.emphasisUnderscore, .emphasis, 1),
            (Regex.strike, .strike, 2),
            (Regex.highlight, .highlight, 2),
        ]
        for (regex, kind, width) in emphasis {
            for m in regex.matches(in: line as String, range: full) {
                let open = NSRange(location: m.range.location, length: width)
                let close = NSRange(location: NSMaxRange(m.range) - width, length: width)
                guard free(open), free(close) else { continue }
                consume(open)
                consume(close)
                spans.append(Span(kind: kind, range: abs(m.range), markers: [abs(open), abs(close)],
                                  content: abs(NSRange(location: open.location + width, length: m.range.length - 2 * width))))
            }
        }
        return spans
    }

    // MARK: Patterns

    enum Regex {
        private static func make(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: o)
        }
        static let heading = make(#"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)
        static let hr = make(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
        static let quote = make(#"^ {0,3}(?:>[ \t]?)+"#)
        static let list = make(#"^([ \t]*)([-*+]|\d{1,9}[.)])(?:[ \t]+|$)(?:(\[([ xX])\])(?:[ \t]+|$))?"#)
        static let imageLine = make(#"^[ \t]*!\[((?:\\.|[^\[\]\\])*)\]\((<[^>\n]*>|[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)(?:[ \t]+"[^"]*")?\)[ \t]*$"#)
        static let wikiImageLine = make(#"^[ \t]*!\[\[([^\[\]\n]+)\]\][ \t]*$"#)

        static let escape = make(#"\\[!-/:-@\[-`{-~]"#)
        static let codeSpan = make(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
        static let displayMathInline = make(#"\$\$(.+?)\$\$"#)
        static let inlineMath = make(#"(?<![\\$])\$(?=[^\s$])((?:\\.|[^\\$])+?)(?<=[^\s\\])\$(?![\d$])"#)
        static let wikiLink = make(#"(!?)\[\[([^\[\]\n]+?)\]\]"#)
        static let link = make(#"(!?)\[((?:\\.|[^\[\]\\]|\[[^\[\]]*\])*)\]\((<[^>\n]*>|[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)(?:[ \t]+(?:"[^"]*"|'[^']*'))?\)"#)
        static let autolink = make(#"<((?:https?|mailto):[^>\s]+)>"#)
        static let bareURL = make(#"(?<![\w/(\[<])https?://[^\s<>]*[^\s<>.,;:!?"')\]]"#)
        static let strongEmphasis = make(#"(?<![*\\])\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*(?!\*)"#)
        static let strong = make(#"(?<![*\\])\*\*(?=\S)(.+?)(?<=\S)\*\*(?!\*)"#)
        static let strongUnderscore = make(#"(?<![\w\\_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#)
        static let emphasis = make(#"(?<![*\\])\*(?=[^\s*])(.+?)(?<=[^\s*\\])\*(?!\*)"#)
        static let emphasisUnderscore = make(#"(?<![\w\\_])_(?=[^\s_])(.+?)(?<=[^\s_\\])_(?![\w_])"#)
        static let strike = make(#"(?<!~)~~(?=\S)(.+?)(?<=\S)~~(?!~)"#)
        static let highlight = make(#"(?<!=)==(?=\S)(.+?)(?<=\S)==(?!=)"#)
    }
}
