import AppKit
import PDFKit

/// Typesets a note onto pages using the exact styling and drawing code of the editor.
/// Lines are laid out at the editor's column width and the whole page is scaled to
/// the paper, so line breaks match what you saw while writing. Text and equations
/// stay vector; nothing is rasterized.
/// Choices offered when exporting; remembered between exports.
struct PDFOptions {
    enum Appearance: String, CaseIterable { case light, dark, editor }
    enum Paper: String, CaseIterable { case letter, a4 }

    var appearance: Appearance
    var paper: Paper
    var pageNumbers: Bool

    static var saved: PDFOptions {
        let d = UserDefaults.standard
        let localeA4 = Locale.current.region.map { !["US", "CA", "MX", "PH"].contains($0.identifier) } ?? false
        return PDFOptions(appearance: Appearance(rawValue: d.string(forKey: "pdfAppearance") ?? "") ?? .light,
                          paper: Paper(rawValue: d.string(forKey: "pdfPaper") ?? "") ?? (localeA4 ? .a4 : .letter),
                          pageNumbers: d.object(forKey: "pdfPageNumbers") as? Bool ?? true)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(appearance.rawValue, forKey: "pdfAppearance")
        d.set(paper.rawValue, forKey: "pdfPaper")
        d.set(pageNumbers, forKey: "pdfPageNumbers")
    }

    var paperSize: NSSize { paper == .a4 ? NSSize(width: 595.28, height: 841.89) : NSSize(width: 612, height: 792) }

    var isDark: Bool {
        switch appearance {
        case .light: false
        case .dark: true
        case .editor: NSApp.effectiveAppearance.isDark
        }
    }
}

enum PDFExporter {
    private static let margin: CGFloat = 64

    /// A note styled for paper and flowed into page-sized containers.
    private struct Pages {
        let storage: NSTextStorage
        let layout: MarkdownLayoutManager
        let containers: [NSTextContainer]
        let scale: CGFloat
        let gutter: CGFloat
    }

    /// Where each page after the first begins, as character offsets, so the editor can
    /// show the page lines of the PDF you'd export right now.
    static func pageStarts(text: String, resolver: ImageResolving?, options: PDFOptions = .saved) -> [Int] {
        let pages = paginate(text: text, resolver: resolver, options: options)
        return pages.containers.dropFirst().compactMap { container in
            let glyphs = pages.layout.glyphRange(for: container)
            return glyphs.length > 0 ? pages.layout.characterIndexForGlyph(at: glyphs.location) : nil
        }
    }

    private static func paginate(text: String, resolver: ImageResolving?, options: PDFOptions) -> Pages {
        let paper = options.paperSize
        let column = AppSettings.shared.lineWidth.points
        let scale = (paper.width - margin * 2) / column
        var config = StyleConfig.current
        config.columnWidth = column
        config.printing = true
        let gutter = config.gutter
        let pageHeight = (paper.height - margin * 2 - 18) / scale
        config.maxBlockHeight = pageHeight * 0.92

        let storage = NSTextStorage(string: text)
        let layout = MarkdownLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.gutter = gutter
        layout.bodyLineSpacing = config.typography.lineSpacing
        layout.typoParagraphGap = config.typography.paragraphSpacing
        layout.captionFont = config.typography.text(bold: false, italic: true, size: round(config.typography.size * 0.8))
        storage.addLayoutManager(layout)

        let styler = MarkdownStyler(config: config)
        styler.imageResolver = resolver
        var containers: [NSTextContainer] = []

        NSAppearance(named: options.isDark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            styler.styleAll(storage, selection: [])

            // Flow text through page-sized containers until it is all placed, starting a
            // new page at each written page break and keeping headings with what follows.
            var index = 0
            var adjustments = 0
            while true {
                if index >= containers.count {
                    let c = NSTextContainer(size: NSSize(width: column + gutter * 2, height: pageHeight))
                    c.lineFragmentPadding = 0
                    layout.addTextContainer(c)
                    containers.append(c)
                }
                let container = containers[index]
                layout.ensureLayout(for: container)
                let glyphs = layout.glyphRange(for: container)
                let done = NSMaxRange(glyphs) >= layout.numberOfGlyphs
                if glyphs.length > 0, adjustments < 200,
                   breakPage(layout: layout, storage: storage, styler: styler, container: container, glyphs: glyphs)
                    || (!done && keepHeadingWithNext(layout: layout, storage: storage, styler: styler, container: container, glyphs: glyphs)) {
                    adjustments += 1
                    continue
                }
                index += 1
                if done || containers.count >= 2000 { break }
            }
        }
        return Pages(storage: storage, layout: layout, containers: containers, scale: scale, gutter: gutter)
    }

    static func makePDF(text: String, title: String, resolver: ImageResolving?, options: PDFOptions = .saved) -> Data {
        let paper = options.paperSize
        let pages = paginate(text: text, resolver: resolver, options: options)
        let (storage, layout, containers, scale, gutter) = (pages.storage, pages.layout, pages.containers, pages.scale, pages.gutter)

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextTitle as String: title,
                  kCGPDFContextCreator as String: "Indium",
              ] as CFDictionary) else { return Data() }

        NSAppearance(named: options.isDark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = graphics
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
                .foregroundColor: Palette.tertiaryText,
            ]

            for (i, container) in containers.enumerated() {
                let glyphs = layout.glyphRange(for: container)
                if glyphs.length == 0, i > 0 { continue }
                ctx.beginPDFPage(nil)
                if options.isDark {
                    ctx.setFillColor((Palette.background.usingColorSpace(.sRGB) ?? .black).cgColor)
                    ctx.fill(CGRect(origin: .zero, size: paper))
                }
                ctx.saveGState()
                // Flip to AppKit's top-left origin, then scale the column to the paper.
                ctx.translateBy(x: 0, y: paper.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: margin, y: margin)
                ctx.scaleBy(x: scale, y: scale)
                let origin = NSPoint(x: -gutter, y: 0)
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                ctx.restoreGState()
                addLinkAnnotations(ctx: ctx, layout: layout, storage: storage, container: container, glyphs: glyphs,
                                   paper: paper, margin: margin, scale: scale, gutter: gutter)

                if containers.count > 1, options.pageNumbers {
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: paper.height)
                    ctx.scaleBy(x: 1, y: -1)
                    let label = "\(i + 1)" as NSString
                    let size = label.size(withAttributes: footerAttrs)
                    label.draw(at: NSPoint(x: (paper.width - size.width) / 2, y: paper.height - margin * 0.6), withAttributes: footerAttrs)
                    ctx.restoreGState()
                }
                ctx.endPDFPage()
            }
            NSGraphicsContext.current = previous
        }
        ctx.closePDF()
        return data as Data
    }

    /// If a written page break has text after it on this page, pads the break's line so
    /// that text starts the next page. A break at the top of a page already has one.
    private static func breakPage(layout: NSLayoutManager, storage: NSTextStorage, styler: MarkdownStyler,
                                  container: NSTextContainer, glyphs: NSRange) -> Bool {
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for block in styler.blocks where block.kind == .columnMarker(.pageBreak) {
            let line = (storage.string as NSString).lineRange(for: NSRange(location: block.range.location, length: 0))
            guard line.location >= chars.location else { continue }
            guard NSMaxRange(line) < NSMaxRange(chars) else { break }
            var lineGlyphs = NSRange()
            let frag = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: line.location), effectiveRange: &lineGlyphs)
            guard lineGlyphs.location > glyphs.location, frag.minY > 0 else { continue }
            guard let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle else { continue }
            style.paragraphSpacing += container.size.height - frag.maxY
            storage.addAttribute(.paragraphStyle, value: style, range: line)
            return true
        }
        return false
    }

    /// If a page ends on a heading, pads the line before it so the heading starts the next page.
    /// Blank lines and layout markers after the heading don't count as something following it.
    private static func keepHeadingWithNext(layout: NSLayoutManager, storage: NSTextStorage, styler: MarkdownStyler,
                                            container: NSTextContainer, glyphs: NSRange) -> Bool {
        let string = storage.string as NSString
        var lineGlyphs = NSRange()
        var frag = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: &lineGlyphs)
        while lineGlyphs.location > glyphs.location {
            let line = string.lineRange(for: NSRange(location: layout.characterIndexForGlyph(at: lineGlyphs.location), length: 0))
            let blank = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Hidden source that draws nothing, like a column marker; equations and images draw a block.
            var drawsBlock = false
            storage.enumerateAttribute(.mdBlock, in: line) { value, _, stop in if value != nil { drawsBlock = true; stop.pointee = true } }
            let hidden = storage.attribute(.mdHidden, at: line.location, effectiveRange: nil) != nil && !drawsBlock
            guard blank || hidden else { break }
            frag = layout.lineFragmentRect(forGlyphAt: lineGlyphs.location - 1, effectiveRange: &lineGlyphs)
        }
        // A heading that wraps ends the page on its last line; move it from its first.
        let charIndex = string.lineRange(for: NSRange(location: layout.characterIndexForGlyph(at: lineGlyphs.location), length: 0)).location
        frag = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: charIndex), effectiveRange: &lineGlyphs)
        guard lineGlyphs.location > glyphs.location, frag.minY > 0 else { return false }
        guard let block = styler.blockIndex(containing: charIndex).map({ styler.blocks[$0] }),
              case .heading = block.kind, block.range.location == charIndex, charIndex > 0 else { return false }
        let previous = (storage.string as NSString).paragraphRange(for: NSRange(location: charIndex - 1, length: 0))
        guard let style = (storage.attribute(.paragraphStyle, at: previous.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle else { return false }
        style.paragraphSpacing += container.size.height - frag.minY - 0.5
        storage.addAttribute(.paragraphStyle, value: style, range: previous)
        return true
    }

    /// Makes web links in the text clickable in the PDF.
    private static func addLinkAnnotations(ctx: CGContext, layout: NSLayoutManager, storage: NSTextStorage,
                                           container: NSTextContainer, glyphs: NSRange, paper: NSSize,
                                           margin: CGFloat, scale: CGFloat, gutter: CGFloat) {
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.link, in: chars) { value, range, _ in
            guard let url = value as? URL, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            let linkGlyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: linkGlyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                let x = margin + (rect.minX - gutter) * scale
                let top = margin + rect.minY * scale
                let pdfRect = CGRect(x: x, y: paper.height - top - rect.height * scale, width: rect.width * scale, height: rect.height * scale)
                ctx.setURL(url as CFURL, for: pdfRect)
            }
        }
    }

    static func printOperation(text: String, title: String, resolver: ImageResolving?) -> NSPrintOperation? {
        let data = makePDF(text: text, title: title, resolver: resolver)
        guard let doc = PDFDocument(data: data) else { return nil }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        let op = doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)
        op?.jobTitle = title
        return op
    }
}
