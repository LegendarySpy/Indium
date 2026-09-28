import AppKit

/// Moves table cells through the pasteboard in the forms other apps read: tab-separated
/// text for spreadsheets, an HTML table for documents and mail, and Markdown for a whole
/// table pasted as text. Reads grids back from spreadsheets, web pages and Markdown.
enum TableClipboard {
    static let tabularType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")

    /// `markdown` goes out as the plain text when a whole table is copied; a block of
    /// cells goes out as tab-separated text, the way spreadsheets copy.
    static func write(_ rows: [[String]], header: Bool, markdown: String?, to pb: NSPasteboard) {
        let tsv = self.tsv(rows)
        pb.clearContents()
        pb.declareTypes([.string, tabularType, .html], owner: nil)
        pb.setString(markdown ?? tsv, forType: .string)
        pb.setString(tsv, forType: tabularType)
        pb.setString(html(rows, header: header), forType: .html)
    }

    static func tsv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                let text = plain(cell)
                // Quoted like Excel and Sheets do, so tabs and line breaks survive.
                guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\"" }) else { return text }
                return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func html(_ rows: [[String]], header: Bool) -> String {
        var out = "<meta charset=\"utf-8\"><table style=\"border-collapse:collapse\">"
        for (r, row) in rows.enumerated() {
            let tag = header && r == 0 ? "th" : "td"
            out += "<tr>" + row.map { "<\(tag) style=\"border:1px solid #ccc;padding:4px 8px;text-align:left\">\(inlineHTML($0))</\(tag)>" }.joined() + "</tr>"
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
                let rows = spec.rows.map { row in (0..<columns).map { $0 < row.count ? row[$0].text.replacingOccurrences(of: #"\|"#, with: "|") : "" } }
                out += html(rows, header: true).replacingOccurrences(of: "<meta charset=\"utf-8\">", with: "")
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

    /// A grid on the pasteboard: a Markdown table or tab-separated cells. Plain lines
    /// count only when `lines` is set (pasting over selected cells fills them down).
    static func grid(from pb: NSPasteboard, lines: Bool = false) -> [[String]]? {
        let text = pb.string(forType: tabularType) ?? pb.string(forType: .string)
        guard let text, !text.isEmpty else { return nil }
        if let table = markdownTable(text) { return table }
        if text.contains("\t") { return parseTSV(text) }
        if lines {
            let rows = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            return (rows.last == "" ? rows.dropLast() : rows[...]).map { [$0] }
        }
        return nil
    }

    /// Rows of a pipe table that is the whole of `text` (header first, no delimiter).
    static func markdownTable(_ text: String) -> [[String]]? {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        guard lines.count >= 2, lines[0].contains("|"), MarkdownScanner.isTableDelimiter(lines[1]),
              lines.dropFirst(2).allSatisfy({ $0.contains("|") }) else { return nil }
        return lines.enumerated().filter { $0.offset != 1 }.map { MarkdownScanner.splitRow($0.element).map(\.text) }
    }

    /// Tab-separated text as Excel, Numbers, Sheets and browsers copy it; quoted cells
    /// may hold tabs, line breaks and doubled quotes. Rows are padded to one width.
    static func parseTSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = ""
        var quoted = false, atCellStart = true
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")), i = 0
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
        return rows.map { r in (r + Array(repeating: "", count: width - r.count)).map { $0.trimmingCharacters(in: .whitespaces) } }
    }
}
