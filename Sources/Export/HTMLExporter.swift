import AppKit

/// One HTML file that needs nothing beside it: pictures are inline, and no script can run.
enum HTMLExporter {
    static func makeHTML(text: String, title: String, resolver: ImageResolving?) -> Data {
        let body = blocks(NoteDocument(text: text, resolver: resolver).blocks)
        let page = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: http: https:; style-src 'unsafe-inline'">
        <title>\(NoteDocument.escaped(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
        return Data(page.utf8)
    }

    private static let css = """

    :root { color-scheme: light; }
    body { max-width: 720px; margin: 0 auto; padding: 48px 24px; background: #fff; color: #1d1d1f; font: 16px/1.6 -apple-system, "Helvetica Neue", "Segoe UI", Arial, sans-serif; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 .4em; }
    p, ul, ol, pre, table, figure, blockquote, .callout { margin: 0 0 1em; }
    a { color: #2f62a8; }
    img { max-width: 100%; height: auto; }
    figure { text-align: center; }
    figcaption { color: #6e6e73; font-size: .85em; font-style: italic; }
    blockquote { padding-left: 1em; border-left: 3px solid #d2d2d7; color: #515154; }
    .callout { padding: .7em 1em; border-left: 3px solid; border-radius: 4px; background: #f5f5f7; }
    .callout > :last-child { margin-bottom: 0; }
    .callout-title { font-weight: 600; margin-bottom: .3em; }
    code, pre, kbd { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: .9em; }
    code, kbd { padding: .1em .3em; border-radius: 4px; background: #f0f0f2; }
    pre { padding: 1em; overflow-x: auto; border-radius: 6px; background: #f5f5f7; line-height: 1.45; }
    pre code { padding: 0; background: none; font-size: 1em; }
    table { border-collapse: collapse; width: 100%; font-size: .92em; font-variant-numeric: tabular-nums; }
    th, td { padding: .4em .7em; border: 1px solid #d2d2d7; vertical-align: top; }
    th { background: #f5f5f7; }
    .columns { display: grid; gap: 24px; }
    .columns > div { min-width: 0; }
    .task { list-style: none; margin-left: -1.4em; }
    .task input { margin: 0 .4em 0 0; }
    .tag { color: #2f62a8; }
    .footnote { color: #6e6e73; font-size: .85em; }
    .page-break { break-after: page; }

    """

    private static func blocks(_ blocks: [ExportBlock]) -> String {
        blocks.map(block).joined(separator: "\n")
    }

    private static func block(_ block: ExportBlock) -> String {
        switch block {
        case let .heading(level, content):
            return "<h\(level)>\(inlines(content))</h\(level)>"
        case let .paragraph(content):
            return "<p>\(inlines(content))</p>"
        case let .list(items):
            return list(items)
        case let .quote(inner):
            return "<blockquote>\n\(blocks(inner))\n</blockquote>"
        case let .callout(title, tint, inner):
            return "<div class=\"callout\" style=\"border-color: #\(tint)\">\n<p class=\"callout-title\" style=\"color: #\(tint)\">\(inlines(title))</p>\n\(blocks(inner))\n</div>"
        case let .code(language, body):
            let name = language.isEmpty ? "" : " class=\"language-\(NoteDocument.escaped(language))\""
            return "<pre><code\(name)>\(NoteDocument.escaped(body))</code></pre>"
        case let .table(rows, alignments, fractions):
            return table(rows, alignments: alignments, fractions: fractions)
        case let .figure(image, source, alt, caption):
            let picture: String
            if let image {
                picture = img(image, alt: alt)
            } else if let source {
                picture = "<img src=\"\(NoteDocument.escaped(source))\" alt=\"\(NoteDocument.escaped(alt))\">"
            } else {
                return "<p><em>\(NoteDocument.escaped(alt))</em></p>"
            }
            let under = caption.map { "<figcaption>\(NoteDocument.escaped($0))</figcaption>" } ?? ""
            return "<figure>\(picture)\(under)</figure>"
        case let .columns(cells, ratios):
            let template = ratios.map { String(format: "%.3ffr", $0) }.joined(separator: " ")
            return "<div class=\"columns\" style=\"grid-template-columns: \(template)\">\n"
                + cells.map { "<div>\n\(blocks($0))\n</div>" }.joined(separator: "\n") + "\n</div>"
        case let .footnote(label, content):
            return "<p class=\"footnote\"><sup>\(NoteDocument.escaped(label))</sup> \(inlines(content))</p>"
        case .rule:
            return "<hr>"
        case .pageBreak:
            return "<div class=\"page-break\"></div>"
        }
    }

    private static func list(_ items: [ExportListItem]) -> String {
        var out = ""
        var open: [String] = []
        for item in items {
            let tag = item.ordered ? "ol" : "ul"
            while open.count > item.level + 1 { out += "</li></\(open.removeLast())>" }
            if open.count == item.level + 1 {
                out += "</li>"
                if open.last != tag { out += "</\(open.removeLast())><\(tag)>"; open.append(tag) }
            } else {
                out += "<\(tag)>"
                open.append(tag)
            }
            out += "\n"
            switch item.task {
            case 1: out += "<li class=\"task\"><input type=\"checkbox\" disabled>"
            case 2: out += "<li class=\"task\"><input type=\"checkbox\" checked disabled>"
            default: out += item.ordered ? "<li value=\"\(item.number)\">" : "<li>"
            }
            out += inlines(item.content)
        }
        while let tag = open.popLast() { out += "</li></\(tag)>" }
        return out
    }

    private static func table(_ rows: [[[ExportInline]]], alignments: [Int], fractions: [CGFloat]?) -> String {
        var out = "<table>\n"
        if let fractions {
            out += "<colgroup>" + fractions.map { String(format: "<col style=\"width: %.1f%%\">", $0 * 100) }.joined() + "</colgroup>\n"
        }
        for (r, row) in rows.enumerated() {
            let tag = r == 0 ? "th" : "td"
            out += "<tr>" + row.enumerated().map { c, cell in
                let align = c < alignments.count ? [0: "", 1: "left", 2: "center", 3: "right"][alignments[c]] ?? "" : ""
                let style = align.isEmpty ? (r == 0 ? " style=\"text-align: left\"" : "") : " style=\"text-align: \(align)\""
                return "<\(tag)\(style)>\(inlines(cell))</\(tag)>"
            }.joined() + "</tr>\n"
        }
        return out + "</table>"
    }

    private static func inlines(_ content: [ExportInline]) -> String {
        content.map { inline in
            switch inline {
            case let .text(text): return NoteDocument.escaped(text)
            case .lineBreak: return "<br>"
            case let .link(url, inner): return "<a href=\"\(NoteDocument.escaped(url))\">\(inlines(inner))</a>"
            case let .image(image, alt): return img(image, alt: alt)
            case let .styled(style, inner):
                let body = inlines(inner)
                switch style {
                case .bold: return "<strong>\(body)</strong>"
                case .italic: return "<em>\(body)</em>"
                case .strike: return "<s>\(body)</s>"
                case .highlight: return "<mark>\(body)</mark>"
                case .underline: return "<u>\(body)</u>"
                case .sup: return "<sup>\(body)</sup>"
                case .sub: return "<sub>\(body)</sub>"
                case .key: return "<kbd>\(body)</kbd>"
                case .small: return "<small>\(body)</small>"
                case .code: return "<code>\(body)</code>"
                case .tag: return "<span class=\"tag\">\(body)</span>"
                }
            }
        }.joined()
    }

    private static func img(_ image: ExportImage, alt: String) -> String {
        let align = image.descent > 0 ? String(format: " style=\"vertical-align: %.1fpx\"", -image.descent) : ""
        let mime = image.fileExtension == "jpg" ? "image/jpeg" : "image/png"
        return "<img src=\"data:\(mime);base64,\(image.data.base64EncodedString())\" width=\"\(Int(ceil(image.size.width)))\""
            + " height=\"\(Int(ceil(image.size.height)))\" alt=\"\(NoteDocument.escaped(alt))\"\(align)>"
    }
}
