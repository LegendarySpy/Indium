import AppKit

/// A .docx written directly: `NSAttributedString`'s `officeOpenXML` drops images and tables
/// and fakes headings and lists, so it can't carry a note. Word's format is XML in a zip.
enum WordExporter {
    static func makeDocx(text: String, title: String, resolver: ImageResolving?) -> Data {
        let paper = PDFOptions.saved.paperSize
        var writer = Writer()
        let body = writer.blocks(NoteDocument(text: text, resolver: resolver).blocks,
                                 Box(width: paper.width - margin * 2))
        let section = "<w:sectPr><w:pgSz w:w=\"\(twips(paper.width))\" w:h=\"\(twips(paper.height))\"/>"
            + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
        let document = xmlHeader + "<w:document \(namespaces)><w:body>\(body)\(section)</w:body></w:document>"

        var relationships = [
            relationship("rId1", "styles", "styles.xml"),
            relationship("rId2", "numbering", "numbering.xml"),
            relationship("rId3", "settings", "settings.xml"),
        ]
        relationships += writer.links.enumerated().map { i, url in
            "<Relationship Id=\"link\(i)\" Type=\"\(relationshipType)/hyperlink\" Target=\"\(NoteDocument.escaped(url))\" TargetMode=\"External\"/>"
        }
        relationships += writer.media.enumerated().map { i, image in
            relationship("image\(i)", "image", "media/image\(i).\(image.fileExtension)")
        }

        var files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data((xmlHeader + "<Relationships xmlns=\"\(packageRelationships)\">"
                + relationship("rId1", "officeDocument", "word/document.xml")
                + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
                + "</Relationships>").utf8)),
            ("docProps/core.xml", Data((xmlHeader + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(NoteDocument.escaped(title))</dc:title></cp:coreProperties>").utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/_rels/document.xml.rels", Data((xmlHeader + "<Relationships xmlns=\"\(packageRelationships)\">\(relationships.joined())</Relationships>").utf8)),
            ("word/styles.xml", Data(styles.utf8)),
            ("word/numbering.xml", Data(writer.numbering().utf8)),
            ("word/settings.xml", Data(settings.utf8)),
        ]
        files += writer.media.enumerated().map { i, image in ("word/media/image\(i).\(image.fileExtension)", image.data) }
        return package(files)
    }

    private static let margin: CGFloat = 72
    /// Word's body text is 11 pt where an export's pictures are sized for 16.
    private static let pictureScale: CGFloat = 11.0 / 16.0

    private static func twips(_ points: CGFloat) -> Int { Int(round(points * 20)) }

    /// Where a block lands: width left for it, and the quote or callout around it.
    private struct Box {
        var width: CGFloat
        var indent = 0
        var bar: String?
        var fill: String?
    }

    private struct Run {
        var styles: Set<ExportInline.Style> = []
        var link = false
    }

    private struct Writer {
        var links: [String] = []
        var media: [ExportImage] = []
        private var mediaIndex: [ExportImage: Int] = [:]
        private var nextDrawing = 1
        /// Runs of ordered items, each its own numbering so it counts from what's written.
        private var numbered: [(level: Int, start: Int)] = []

        mutating func blocks(_ blocks: [ExportBlock], _ box: Box) -> String {
            var out = ""
            for block in blocks { out += self.block(block, box) }
            return out
        }

        private mutating func block(_ block: ExportBlock, _ box: Box) -> String {
            switch block {
            case let .heading(level, content):
                return paragraph(box, style: "Heading\(level)", runs: runs(content, Run(), box))
            case let .paragraph(content):
                return paragraph(box, runs: runs(content, Run(), box))
            case let .list(items):
                return list(items, box)
            case let .quote(inner):
                return blocks(inner, nestedBox(box, bar: "C7C7CC", fill: nil))
            case let .callout(title, tint, inner):
                let boxed = nestedBox(box, bar: tint, fill: "F5F5F7")
                var run = Run()
                run.styles = [.bold]
                return paragraph(boxed, keepNext: true, runs: runs(title, run, boxed)) + blocks(inner, boxed)
            case let .code(_, body):
                let lines = body.components(separatedBy: "\n").map { text($0, Run()) }
                return paragraph(box, style: "Code", shade: "F5F5F7", runs: lines.joined(separator: "<w:r><w:br/></w:r>"))
            case let .table(rows, alignments, fractions):
                return table(rows, alignments: alignments, fractions: fractions, box)
            case let .figure(image, source, alt, caption):
                if let image {
                    let picture = paragraph(box, keepNext: caption != nil, align: "center", runs: drawing(image, alt: alt, box))
                    return picture + (caption.map { paragraph(box, style: "Caption", align: "center", runs: text($0, Run())) } ?? "")
                }
                var run = Run()
                run.styles = [.italic]
                let words = text(alt, run)
                if let source { return paragraph(box, runs: hyperlink(source, words)) }
                return paragraph(box, runs: words)
            case let .columns(cells, ratios):
                return columns(cells, ratios: ratios, box)
            case let .footnote(label, content):
                var run = Run()
                run.styles = [.sup]
                return paragraph(box, style: "Footnote", runs: text(label, run) + text(" ", Run()) + runs(content, Run(), box))
            case .rule:
                return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"C7C7CC\"/></w:pBdr>\(indentation(box.indent, hanging: 0))</w:pPr></w:p>"
            case .pageBreak:
                return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }

        private func nestedBox(_ box: Box, bar: String, fill: String?) -> Box {
            var inner = box
            inner.indent += 240
            inner.width -= 12
            inner.bar = bar
            inner.fill = fill ?? box.fill
            return inner
        }

        private func indentation(_ left: Int, hanging: Int) -> String {
            guard left > 0 || hanging > 0 else { return "" }
            return "<w:ind w:left=\"\(left)\"" + (hanging > 0 ? " w:hanging=\"\(hanging)\"" : "") + "/>"
        }

        // Children of pPr in the order the schema requires.
        private func paragraph(_ box: Box, style: String? = nil, keepNext: Bool = false, numbering: String = "", shade: String? = nil,
                               left: Int? = nil, hanging: Int = 0, align: String? = nil, runs: String) -> String {
            var properties = style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? ""
            if keepNext { properties += "<w:keepNext/>" }
            properties += numbering
            if let bar = box.bar {
                properties += "<w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"\(bar)\"/></w:pBdr>"
            }
            if let fill = shade ?? box.fill { properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>" }
            properties += indentation(left ?? box.indent, hanging: hanging)
            if let jc = align { properties += "<w:jc w:val=\"\(jc)\"/>" }
            return "<w:p>\(properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>")\(runs)</w:p>"
        }

        private mutating func runs(_ content: [ExportInline], _ run: Run, _ box: Box) -> String {
            var out = ""
            for inline in content {
                switch inline {
                case let .text(words): out += text(words, run)
                case .lineBreak: out += "<w:r><w:br/></w:r>"
                case let .image(image, alt): out += drawing(image, alt: alt, box)
                case let .styled(style, inner):
                    var styled = run
                    styled.styles.insert(style)
                    out += runs(inner, styled, box)
                case let .link(url, inner):
                    var linked = run
                    linked.link = true
                    let words = runs(inner, linked, box)
                    out += hyperlink(url, words)
                }
            }
            return out
        }

        private func properties(_ run: Run) -> String {
            let s = run.styles
            var out = ""
            if s.contains(.code) || s.contains(.key) { out += "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/>" }
            if s.contains(.bold) { out += "<w:b/>" }
            if s.contains(.italic) { out += "<w:i/>" }
            if s.contains(.strike) { out += "<w:strike/>" }
            if run.link || s.contains(.tag) { out += "<w:color w:val=\"2F62A8\"/>" }
            if s.contains(.small) { out += "<w:sz w:val=\"18\"/>" }
            if run.link || s.contains(.underline) { out += "<w:u w:val=\"single\"/>" }
            if s.contains(.highlight) {
                out += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"FFF2A8\"/>"
            } else if s.contains(.code) || s.contains(.key) {
                out += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F0F0F2\"/>"
            }
            if s.contains(.sup) { out += "<w:vertAlign w:val=\"superscript\"/>" }
            if s.contains(.sub) { out += "<w:vertAlign w:val=\"subscript\"/>" }
            return out.isEmpty ? "" : "<w:rPr>\(out)</w:rPr>"
        }

        private func text(_ words: String, _ run: Run) -> String {
            "<w:r>\(properties(run))<w:t xml:space=\"preserve\">\(NoteDocument.escaped(words))</w:t></w:r>"
        }

        private mutating func hyperlink(_ url: String, _ words: String) -> String {
            let index = links.firstIndex(of: url) ?? { links.append(url); return links.count - 1 }()
            return "<w:hyperlink r:id=\"link\(index)\">\(words)</w:hyperlink>"
        }

        private mutating func drawing(_ image: ExportImage, alt: String, _ box: Box) -> String {
            let index = mediaIndex[image] ?? { media.append(image); mediaIndex[image] = media.count - 1; return media.count - 1 }()
            let scale = min(pictureScale, box.width / max(image.size.width, 1))
            let (cx, cy) = (Int(image.size.width * scale * 12700), Int(image.size.height * scale * 12700))
            let id = nextDrawing
            nextDrawing += 1
            let lowered = image.descent > 0 ? "<w:rPr><w:position w:val=\"\(-Int(round(image.descent * scale * 2)))\"/></w:rPr>" : ""
            let name = NoteDocument.escaped(alt)
            return "<w:r>\(lowered)<w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
                + "<wp:docPr id=\"\(id)\" name=\"Picture \(id)\" descr=\"\(name)\"/><a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
                + "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                + "<pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"Picture \(id)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"image\(index)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        }

        private mutating func list(_ items: [ExportListItem], _ box: Box) -> String {
            var out = ""
            // The numbering in use at each level and the number due next; a shallower item ends the deeper ones.
            var current: [Int: (id: Int, next: Int)] = [:]
            for item in items {
                for level in current.keys where level > item.level { current[level] = nil }
                let left = box.indent + 360 * (item.level + 1)
                if item.task != 0 {
                    let mark = text(item.task == 2 ? "\u{2611} " : "\u{2610} ", Run())
                    out += paragraph(box, left: left, hanging: 360, runs: mark + runs(item.content, Run(), box))
                    continue
                }
                var id = 1
                if item.ordered {
                    if let run = current[item.level], run.next == item.number {
                        id = run.id
                    } else {
                        numbered.append((item.level, item.number))
                        id = numbered.count + 1
                    }
                    current[item.level] = (id, item.number + 1)
                } else {
                    current[item.level] = nil
                }
                let numbering = "<w:numPr><w:ilvl w:val=\"\(min(item.level, 8))\"/><w:numId w:val=\"\(id)\"/></w:numPr>"
                out += paragraph(box, numbering: numbering, left: left, hanging: 360, runs: runs(item.content, Run(), box))
            }
            return out
        }

        func numbering() -> String {
            func levels(_ format: String, start: (level: Int, value: Int)? = nil, _ text: (Int) -> String) -> String {
                (0..<9).map { level in
                    let first = start?.level == level ? start?.value ?? 1 : 1
                    return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"\(first)\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text(level))\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(360 * (level + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                }.joined()
            }
            let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
            var out = xmlHeader + "<w:numbering \(namespaces)>"
            out += "<w:abstractNum w:abstractNumId=\"0\">\(levels("bullet") { bullets[$0 % 3] })</w:abstractNum>"
            for (i, list) in numbered.enumerated() {
                out += "<w:abstractNum w:abstractNumId=\"\(i + 1)\">\(levels("decimal", start: (min(list.level, 8), list.start)) { "%\($0 + 1)." })</w:abstractNum>"
            }
            out += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
            for i in numbered.indices {
                out += "<w:num w:numId=\"\(i + 2)\"><w:abstractNumId w:val=\"\(i + 1)\"/></w:num>"
            }
            return out + "</w:numbering>"
        }

        private mutating func table(_ rows: [[[ExportInline]]], alignments: [Int], fractions: [CGFloat]?, _ box: Box) -> String {
            let columns = rows.first?.count ?? 0
            guard columns > 0 else { return "" }
            let shares = fractions.flatMap { $0.count == columns ? $0 : nil } ?? naturalShares(rows, columns: columns)
            let widths = shares.map { $0 * box.width }
            var cellBox = box
            cellBox.indent = 0
            cellBox.bar = nil
            cellBox.fill = nil
            var out = "<w:tbl><w:tblPr><w:tblW w:w=\"\(twips(widths.reduce(0, +)))\" w:type=\"dxa\"/>"
            if box.indent > 0 { out += "<w:tblInd w:w=\"\(box.indent)\" w:type=\"dxa\"/>" }
            let line = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"C7C7CC\""
            out += "<w:tblBorders><w:top \(line)/><w:left \(line)/><w:bottom \(line)/><w:right \(line)/><w:insideH \(line)/><w:insideV \(line)/></w:tblBorders><w:tblLayout w:type=\"fixed\"/></w:tblPr>"
            out += "<w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\(twips($0))\"/>" }.joined() + "</w:tblGrid>"
            for (r, row) in rows.enumerated() {
                out += "<w:tr>" + (r == 0 ? "<w:trPr><w:cantSplit/><w:tblHeader/></w:trPr>" : "<w:trPr><w:cantSplit/></w:trPr>")
                for (c, cell) in row.enumerated() {
                    cellBox.width = max(widths[c] - 11, 20)
                    let shade = r == 0 ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F5F5F7\"/>" : ""
                    var run = Run()
                    if r == 0 { run.styles = [.bold] }
                    let align = c < alignments.count ? [2: "center", 3: "right"][alignments[c]] : nil
                    out += "<w:tc><w:tcPr><w:tcW w:w=\"\(twips(widths[c]))\" w:type=\"dxa\"/>\(shade)</w:tcPr>"
                        + paragraph(cellBox, style: "TableText", align: align, runs: runs(cell, run, cellBox)) + "</w:tc>"
                }
                out += "</w:tr>"
            }
            // Two tables in a row would merge without a paragraph between.
            return out + "</w:tbl><w:p><w:pPr><w:spacing w:after=\"60\"/></w:pPr></w:p>"
        }

        private func naturalShares(_ rows: [[[ExportInline]]], columns: Int) -> [CGFloat] {
            func length(_ content: [ExportInline]) -> CGFloat {
                content.reduce(0) { total, inline in
                    switch inline {
                    case let .text(words): return total + CGFloat(words.count)
                    case .lineBreak: return total
                    case let .styled(_, inner), let .link(_, inner): return total + length(inner)
                    case let .image(image, _): return total + image.size.width / 7
                    }
                }
            }
            let longest = (0..<columns).map { c in max(4, min(40, rows.map { length($0[c]) }.max() ?? 4)) }
            let total = longest.reduce(0, +)
            return longest.map { $0 / total }
        }

        private mutating func columns(_ cells: [[ExportBlock]], ratios: [CGFloat], _ box: Box) -> String {
            var out = "<w:tbl><w:tblPr><w:tblW w:w=\"\(twips(box.width))\" w:type=\"dxa\"/>"
            if box.indent > 0 { out += "<w:tblInd w:w=\"\(box.indent)\" w:type=\"dxa\"/>" }
            out += "<w:tblLayout w:type=\"fixed\"/></w:tblPr><w:tblGrid>"
            out += ratios.map { "<w:gridCol w:w=\"\(twips($0 * box.width))\"/>" }.joined() + "</w:tblGrid><w:tr>"
            for (cell, ratio) in zip(cells, ratios) {
                let inner = Box(width: max(ratio * box.width - 11, 20))
                // A cell must end in a paragraph.
                out += "<w:tc><w:tcPr><w:tcW w:w=\"\(twips(ratio * box.width))\" w:type=\"dxa\"/></w:tcPr>\(blocks(cell, inner))<w:p/></w:tc>"
            }
            return out + "</w:tr></w:tbl><w:p><w:pPr><w:spacing w:after=\"60\"/></w:pPr></w:p>"
        }
    }

    // MARK: Package

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let namespaces = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
    private static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let relationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static func relationship(_ id: String, _ type: String, _ target: String) -> String {
        "<Relationship Id=\"\(id)\" Type=\"\(relationshipType)/\(type)\" Target=\"\(target)\"/>"
    }

    private static let contentTypes = xmlHeader + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        + "<Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>"
        + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
        + "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
        + "<Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>"
        + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"

    private static let settings = xmlHeader + "<w:settings \(namespaces)><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"

    private static let styles: String = {
        func heading(_ level: Int, size: Int, before: Int) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
                + "<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(before)\" w:after=\"80\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        func paragraph(_ id: String, _ name: String, _ properties: String, _ run: String) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr>\(properties)</w:pPr><w:rPr>\(run)</w:rPr></w:style>"
        }
        return xmlHeader + "<w:styles \(namespaces)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + heading(1, size: 44, before: 320) + heading(2, size: 34, before: 280) + heading(3, size: 28, before: 240)
            + heading(4, size: 24, before: 200) + heading(5, size: 22, before: 160) + heading(6, size: 22, before: 160)
            + paragraph("Code", "Code", "<w:spacing w:line=\"240\" w:lineRule=\"auto\"/>", "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:sz w:val=\"19\"/>")
            + paragraph("Caption", "caption", "", "<w:i/><w:color w:val=\"6E6E73\"/><w:sz w:val=\"18\"/>")
            + paragraph("Footnote", "Footnote", "", "<w:color w:val=\"6E6E73\"/><w:sz w:val=\"18\"/>")
            + paragraph("TableText", "Table Text", "<w:spacing w:before=\"40\" w:after=\"40\" w:line=\"240\" w:lineRule=\"auto\"/>", "<w:sz w:val=\"20\"/>")
            + "</w:styles>"
    }()

    /// A zip of stored (uncompressed) entries with a fixed date, so nothing says when or by whom.
    private static func package(_ files: [(String, Data)]) -> Data {
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        // Version 2.0, no flags, stored, 1980-01-01 00:00.
        let common = le16(20) + le16(0) + le16(0) + le16(0) + le16(33)
        var out = Data()
        var directory = Data()
        for (name, data) in files {
            let path = Data(name.utf8)
            let sizes = le32(crc32(data)) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(path.count) + le16(0)
            directory += le32(0x0201_4B50) + le16(20) + common + sizes + le16(0) + le16(0) + le16(0) + le32(0) + le32(UInt32(out.count)) + path
            out += le32(0x0403_4B50) + common + sizes + path + data
        }
        let start = out.count
        out += directory
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(UInt32(directory.count)) + le32(UInt32(start)) + le16(0)
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
