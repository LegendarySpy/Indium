import AppKit

/// Moves table cells through the pasteboard. Indium reads its own copies back exactly,
/// as Markdown; other apps get tab-separated text (spreadsheets) and an HTML table
/// (documents, mail, web). Grids are read back from Indium, spreadsheets, web pages
/// and Markdown.
///
/// Cells here are as they're seen in the table editor: pipes bare, line breaks as
/// newlines (`TableSpec.escapeCell` makes them Markdown).
enum TableClipboard {
    static let tabularType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
    /// Indium's own: the cells' Markdown, and a whole table's source with its formulas.
    static let cellsType = NSPasteboard.PasteboardType("dev.garon.indium.table-cells")

    /// Where tables and the page copy and paste. The debug harness swaps in a private
    /// board so its runs never touch the real clipboard.
    static var board: NSPasteboard = .general

    struct Payload: Codable {
        var cells: [[String]]
        var header: Bool
        /// A whole table's Markdown, formula lines included.
        var source: String?
    }

    /// `markdown` goes out as the plain text when a whole table is copied; a block of
    /// cells goes out as tab-separated text, the way spreadsheets copy.
    static func write(_ rows: [[String]], header: Bool, markdown: String?, to pb: NSPasteboard) {
        let tsv = self.tsv(rows)
        pb.clearContents()
        pb.declareTypes([cellsType, .string, tabularType, .html], owner: nil)
        if let data = try? JSONEncoder().encode(Payload(cells: rows, header: header, source: markdown)) {
            pb.setData(data, forType: cellsType)
        }
        pb.setString(markdown ?? tsv, forType: .string)
        pb.setString(tsv, forType: tabularType)
        pb.setString(html(rows, header: header), forType: .html)
    }

    static func payload(_ pb: NSPasteboard) -> Payload? {
        pb.data(forType: cellsType).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
    }

    static func canPaste(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: [cellsType, tabularType, .string, .html]) != nil
    }

    /// Plain text, quoted as Excel and Numbers quote: around tabs, line breaks, quotes
    /// and spaces at either end, with quotes doubled.
    static func tsv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                let text = cell.components(separatedBy: "\n").map(plain).joined(separator: "\n")
                guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\"" }) || text.first == " " || text.last == " "
                else { return text }
                return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func html(_ rows: [[String]], header: Bool) -> String {
        var out = "<meta charset=\"utf-8\"><table style=\"border-collapse:collapse\">"
        for (r, row) in rows.enumerated() {
            let tag = header && r == 0 ? "th" : "td"
            out += "<tr>" + row.map { cell in
                let inner = cell.components(separatedBy: "\n").map(inlineHTML).joined(separator: "<br>")
                return "<\(tag) style=\"border:1px solid #ccc;padding:4px 8px;text-align:left\">\(inner)</\(tag)>"
            }.joined() + "</tr>"
        }
        return out + "</table>"
    }

    /// Cell Markdown as HTML: emphasis, code, strikethrough and links become tags.
    static func inlineHTML(_ markdown: String) -> String {
        render(markdown) { kind, inner in
            switch kind {
            case .strong: "<b>\(inner)</b>"
            case .emphasis: "<i>\(inner)</i>"
            case .strongEmphasis: "<b><i>\(inner)</i></b>"
            case .strike: "<s>\(inner)</s>"
            case .highlight: "<mark>\(inner)</mark>"
            case .code: "<code>\(inner)</code>"
            case let .link(url): "<a href=\"\(escape(url))\">\(inner)</a>"
            default: inner
            }
        } text: { escape($0) }
    }

    /// Cell Markdown with its markers dropped, for tab-separated text.
    static func plain(_ markdown: String) -> String {
        render(markdown) { $1 } text: { $0 }
    }

    /// Walks a cell's spans outermost first, dropping markers and wrapping each span.
    private static func render(_ markdown: String, wrap: (MarkdownScanner.Span.Kind, String) -> String,
                               text: (String) -> String) -> String {
        let ns = markdown as NSString
        let spans = MarkdownScanner.inlineSpans(in: ns, range: NSRange(location: 0, length: ns.length))
        func build(_ range: NSRange, _ inside: [MarkdownScanner.Span]) -> String {
            var out = "", i = range.location
            // Outermost spans in this range: those not contained in another one here.
            func contains(_ outer: NSRange, _ inner: NSRange) -> Bool { outer != inner && NSIntersectionRange(outer, inner) == inner }
            let top = inside.filter { s in !inside.contains { contains($0.range, s.range) } }
                .sorted { $0.range.location < $1.range.location }
            for span in top where span.range.location >= i {
                out += text(ns.substring(with: NSRange(location: i, length: span.range.location - i)))
                let nested = inside.filter { $0.range != span.range && NSIntersectionRange(span.content, $0.range) == $0.range }
                    as [MarkdownScanner.Span]
                let inner: String
                if case .escape = span.kind { inner = text(ns.substring(with: span.content)) }
                else if case .math = span.kind { inner = text(ns.substring(with: span.range)) }
                else { inner = build(span.content, nested) }
                out += wrap(span.kind, inner)
                i = NSMaxRange(span.range)
            }
            if i < NSMaxRange(range) { out += text(ns.substring(with: NSRange(location: i, length: NSMaxRange(range) - i))) }
            return out
        }
        return build(NSRange(location: 0, length: ns.length), spans)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }


    /// HTML for copied note text that holds a table, so documents and mail paste a real
    /// table instead of pipes. nil when there's no table in it (plain text is enough).
    static func noteHTML(_ markdown: String) -> String? {
        let ns = markdown as NSString
        let blocks = MarkdownScanner.scan(ns)
        guard blocks.contains(where: { if case .table = $0.kind { return true }; return false }) else { return nil }
        var out = "<meta charset=\"utf-8\">"
        for block in blocks {
            let source = ns.substring(with: block.range).trimmingCharacters(in: .newlines)
            switch block.kind {
            case let .table(spec):
                let columns = max(spec.alignments.count, spec.rows.map(\.count).max() ?? 0)
                let rows = spec.rows.map { row in (0..<columns).map { $0 < row.count ? TableSpec.unescapeCell(row[$0].text) : "" } }
                out += html(rows, header: true).replacingOccurrences(of: "<meta charset=\"utf-8\">", with: "")
            case .tableFormulas:
                continue
            case let .heading(level, markerLength):
                let text = (source as NSString).substring(from: min(markerLength, (source as NSString).length)).trimmingCharacters(in: .whitespaces)
                out += "<h\(level)>\(inlineHTML(text))</h\(level)>"
            default:
                guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                out += "<p>" + source.components(separatedBy: .newlines).map(inlineHTML).joined(separator: "<br>") + "</p>"
            }
        }
        return out
    }

    // MARK: Reading

    /// A grid on the pasteboard, best source first: Indium's own cells, a spreadsheet's
    /// tab-separated text, a Markdown table, a web page's HTML table, tab-separated plain
    /// text. Plain lines count only when `lines` is set (pasting over selected cells
    /// fills them down).
    static func grid(from pb: NSPasteboard, lines: Bool = false) -> [[String]]? {
        if let payload = payload(pb), !payload.cells.isEmpty { return payload.cells }
        if let tsv = pb.string(forType: tabularType), !tsv.isEmpty { return parseTSV(tsv) }
        let text = pb.string(forType: .string)
        if let text, let table = markdownTable(text) { return table }
        if let html = pb.string(forType: .html), let table = htmlTable(html) { return table }
        guard let text, !text.isEmpty else { return nil }
        if text.contains("\t") { return parseTSV(text) }
        if lines {
            let rows = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            return (rows.last == "" ? rows.dropLast() : rows[...]).map { [$0] }
        }
        return nil
    }

    /// Markdown for a table pasted into the page, or nil to paste the plain text:
    /// a whole table copied in Indium as it was (formulas too), cells from Indium, a
    /// spreadsheet or a web page as a new table, a Markdown table (with any formula
    /// lines) as it is, on lines of its own.
    static func pageTable(from pb: NSPasteboard) -> String? {
        func table(_ rows: [[String]]) -> String? {
            guard rows.count >= 2 || (rows.first?.count ?? 0) >= 2, let first = rows.first else { return nil }
            return TableSpec.markdown(header: first.map(TableSpec.escapeCell), body: rows.dropFirst().map { $0.map(TableSpec.escapeCell) },
                                      alignments: [], dashes: nil)
        }
        if let payload = payload(pb) { return payload.source ?? table(payload.cells) }
        let text = pb.string(forType: .string)
        if let text, markdownTable(text) != nil { return text.trimmingCharacters(in: .newlines) }
        if let tsv = pb.string(forType: tabularType), !tsv.isEmpty, let t = spreadsheet(tsv) { return t }
        if let html = pb.string(forType: .html), let rows = htmlTable(html) { return table(rows) }
        return text.flatMap(spreadsheet)
        // Tab-indented text (code, outlines) isn't a table; cells are two by two at least.
        func spreadsheet(_ text: String) -> String? {
            guard text.contains("\t"), !text.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("\t") }) else { return nil }
            let rows = parseTSV(text)
            guard rows.count >= 2, (rows.first?.count ?? 0) >= 2 else { return nil }
            return table(rows)
        }
    }

    /// One cell copied in Indium, pasted into the page: its Markdown, not the plain text.
    static func singleCell(from pb: NSPasteboard) -> String? {
        guard let cells = payload(pb)?.cells, cells.count == 1, cells[0].count == 1 else { return nil }
        return cells[0][0]
    }

    /// Cells of a pipe table that is the whole of `text` (header first, no delimiter),
    /// as they're seen. Formula lines under it are left out.
    static func markdownTable(_ text: String) -> [[String]]? {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        while let last = lines.last, lines.count > 2, MarkdownScanner.isTableFormulaLine(last) { lines.removeLast() }
        guard lines.count >= 2, lines[0].contains("|"), MarkdownScanner.isTableDelimiter(lines[1]),
              lines.dropFirst(2).allSatisfy({ $0.contains("|") }) else { return nil }
        let rows = lines.enumerated().filter { $0.offset != 1 }.map { MarkdownScanner.splitRow($0.element).map { TableSpec.unescapeCell($0.text) } }
        let width = max(rows.map(\.count).max() ?? 1, MarkdownScanner.splitRow(lines[1]).count)
        return rows.map { $0 + Array(repeating: "", count: max(0, width - $0.count)) }
    }

    /// Tab-separated text as Excel, Numbers, Sheets and browsers copy it (RFC 4180 with
    /// tabs): a quoted cell may hold tabs, line breaks, doubled quotes and spaces at its
    /// ends, all kept. Rows are padded to one width.
    static func parseTSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = ""
        var quoted = false, atCellStart = true
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")), i = 0
        if chars.last == "\n" { chars.removeLast() }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"", i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 }
                else if c == "\"" { quoted = false }
                else { cell.append(c) }
            } else if c == "\"", atCellStart {
                quoted = true
            } else if c == "\t" {
                row.append(cell); cell = ""; atCellStart = true; i += 1; continue
            } else if c == "\n" {
                row.append(cell); rows.append(row); row = []; cell = ""; atCellStart = true; i += 1; continue
            } else {
                cell.append(c)
            }
            atCellStart = false
            i += 1
        }
        row.append(cell)
        rows.append(row)
        let width = rows.map(\.count).max() ?? 1
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    // MARK: HTML tables

    /// The cells of an HTML table (a web page's, Numbers', Excel's, Sheets'), with bold,
    /// italics, code, strikethrough and links as Markdown and `<br>` as a line break.
    /// nil unless the HTML is a table and nothing more: a page with a table in it pastes
    /// as text. Spanned cells take one cell and leave the rest empty.
    static func htmlTable(_ html: String) -> [[String]]? {
        var s = html
        for pattern in [#"(?s)<!--.*?-->"#, #"(?is)<(style|script|head|title)\b[^>]*>.*?</\1\s*>"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        guard let open = s.range(of: #"(?i)<table\b[^>]*>"#, options: .regularExpression),
              let close = s.range(of: #"(?i)</table\s*>"#, options: .regularExpression, range: open.upperBound..<s.endIndex)
        else { return nil }
        let outside = String(s[..<open.lowerBound]) + String(s[close.upperBound...])
        guard cellMarkdown(outside).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let body = String(s[open.upperBound..<close.lowerBound])
        var rows: [[String]] = []
        for row in matches(#"(?is)<tr\b[^>]*>(.*?)(?=<tr\b|</tbody|</thead|</tfoot|\z)"#, in: body) {
            var cells: [String] = []
            for cell in matches(#"(?is)<t[dh]\b([^>]*)>(.*?)(?=<t[dh]\b|</tr|\z)"#, in: row[1]) {
                cells.append(cellMarkdown(cell[2]))
                let span = matches(#"(?i)colspan\s*=\s*["']?(\d+)"#, in: cell[1]).first.flatMap { Int($0[1]) } ?? 1
                if span > 1 { cells += Array(repeating: "", count: min(span, 64) - 1) }
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return nil }
        let width = rows.map(\.count).max() ?? 1
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        let ns = text as NSString
        return (try! NSRegularExpression(pattern: pattern)).matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    /// A cell's HTML as Markdown: inline formatting as markers, links, line breaks;
    /// other tags dropped, whitespace collapsed, entities decoded.
    static func cellMarkdown(_ html: String) -> String {
        var out = ""
        // Open tags: their name, what closes them in Markdown, and where their opener starts.
        var stack: [(name: String, closer: String, at: Int, opener: Int)] = []
        func close(_ entry: (name: String, closer: String, at: Int, opener: Int)) {
            guard !entry.closer.isEmpty else { return }
            let inner = String(out.dropFirst(entry.at + entry.opener))
            if inner.trimmingCharacters(in: .whitespaces).isEmpty {
                // Nothing inside: drop the markers.
                out = String(out.prefix(entry.at)) + inner
                return
            }
            // Markers hug the text: spaces at the end go outside.
            let trailing = inner.reversed().prefix { $0 == " " }.count
            out = String(out.dropLast(trailing)) + entry.closer + String(repeating: " ", count: trailing)
        }
        let token = #"(?s)<(/?)([A-Za-z][A-Za-z0-9]*)([^>]*)>|([^<]+)|<"#
        for m in matches(token, in: html) {
            if !m[4].isEmpty || m[0] == "<" {
                var text = (m[0] == "<" ? "<" : m[4]).replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
                text = decodeEntities(text)
                // Spaces right after a marker go before it.
                if let top = stack.last, !top.closer.isEmpty, out.count == top.at + top.opener {
                    let leading = text.prefix { $0 == " " }.count
                    if leading > 0 {
                        out.insert(contentsOf: String(repeating: " ", count: leading), at: out.index(out.startIndex, offsetBy: top.at))
                        stack[stack.count - 1].at += leading
                        text = String(text.dropFirst(leading))
                    }
                }
                if out.isEmpty || out.hasSuffix(" ") || out.hasSuffix("\n") { text = String(text.drop { $0 == " " }) }
                out += text
                continue
            }
            let name = m[2].lowercased(), attrs = m[3]
            if m[1] == "/" {
                if let k = stack.lastIndex(where: { $0.name == name }) {
                    for entry in stack[k...].reversed() { close(entry) }
                    stack.removeSubrange(k...)
                }
                if ["p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name), !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
                continue
            }
            switch name {
            case "br":
                out += "\n"
                continue
            case "img", "meta", "input", "hr", "wbr", "col", "link":
                continue
            default: break
            }
            var opener = "", closer = ""
            switch name {
            case "b", "strong": (opener, closer) = ("**", "**")
            case "i", "em": (opener, closer) = ("*", "*")
            case "s", "del", "strike": (opener, closer) = ("~~", "~~")
            case "code": (opener, closer) = ("`", "`")
            case "mark": (opener, closer) = ("==", "==")
            case "a":
                if let href = matches(#"(?i)href\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: attrs).first.map({ $0[1].isEmpty ? $0[2] : $0[1] }),
                   !href.isEmpty, !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:") {
                    (opener, closer) = ("[", "](\(decodeEntities(href).replacingOccurrences(of: " ", with: "%20")))")
                }
            case "span":
                // Google Docs and some pages set weight and slant on spans.
                let style = attrs.lowercased()
                let bold = style.range(of: #"font-weight\s*:\s*(bold|[6-9]00)"#, options: .regularExpression) != nil
                let italic = style.range(of: #"font-style\s*:\s*italic"#, options: .regularExpression) != nil
                opener = (bold ? "**" : "") + (italic ? "*" : "")
                closer = String(opener.reversed())
            default: break
            }
            if ["p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name), !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
            if attrs.hasSuffix("/") { continue }
            stack.append((name, closer, out.count, opener.count))
            out += opener
        }
        for entry in stack.reversed() { close(entry) }
        return out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
                     "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "times": "×", "minus": "−", "deg": "°"]
        let ns = text as NSString
        var out = "", last = 0
        for m in (try! NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")).matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            var value: String?
            if name.hasPrefix("#") {
                let hex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let code = hex ? UInt32(name.dropFirst(2), radix: 16) : UInt32(name.dropFirst())
                value = code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                value = named[name]
            }
            guard let value else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + value
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }
}

// MARK: - Copying from the page

extension EditorController {
    /// What Copy takes from the page: the selection, and when it holds a whole table, the
    /// table's formula lines with it (they belong to the table, as when it's moved).
    func copyRange(for selection: NSRange) -> NSRange {
        guard selection.length > 0 else { return selection }
        let text = storage.string as NSString
        var range = selection
        for (i, block) in styler.blocks.enumerated() where i + 1 < styler.blocks.count {
            guard case .table = block.kind, case .tableFormulas = styler.blocks[i + 1].kind else { continue }
            var tableEnd = NSMaxRange(block.range), formulasEnd = NSMaxRange(styler.blocks[i + 1].range)
            while tableEnd > block.range.location, [0x0A, 0x0D].contains(text.character(at: tableEnd - 1)) { tableEnd -= 1 }
            while formulasEnd > tableEnd, [0x0A, 0x0D].contains(text.character(at: formulasEnd - 1)) { formulasEnd -= 1 }
            if range.location <= block.range.location, NSMaxRange(range) >= tableEnd, NSMaxRange(range) < formulasEnd {
                range.length = formulasEnd - range.location
            }
        }
        return range
    }

    /// Copies the selection (see `copyRange`) as text, and as HTML when it holds a table.
    /// Returns the range copied, nil when nothing is selected.
    @discardableResult
    func copySelection(to pb: NSPasteboard) -> NSRange? {
        let range = copyRange(for: textView.selectedRange())
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let text = (storage.string as NSString).substring(with: range)
        let html = TableClipboard.noteHTML(text)
        pb.clearContents()
        pb.declareTypes(html == nil ? [.string] : [.string, .html], owner: nil)
        pb.setString(text, forType: .string)
        if let html { pb.setString(html, forType: .html) }
        return range
    }
}
