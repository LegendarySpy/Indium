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
    static func makePDF(text: String, title: String, resolver: ImageResolving?, options: PDFOptions = .saved) -> Data {
        let settings = AppSettings.shared
        let paper = options.paperSize
        let margin: CGFloat = 64
        let column = settings.lineWidth.points
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

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextTitle as String: title,
                  kCGPDFContextCreator as String: "Indium",
              ] as CFDictionary) else { return Data() }

        NSAppearance(named: options.isDark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            styler.styleAll(storage, selection: [])

            // Flow text through page-sized containers until it is all placed,
            // keeping headings with the paragraph that follows them.
            var containers: [NSTextContainer] = []
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
                if !done, glyphs.length > 0, adjustments < 200,
                   keepHeadingWithNext(layout: layout, storage: storage, styler: styler, container: container, glyphs: glyphs) {
                    adjustments += 1
                    continue
                }
                index += 1
                if done || containers.count >= 2000 { break }
            }

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

    /// If a page ends on a heading, pads the line before it so the heading starts the next page.
    private static func keepHeadingWithNext(layout: NSLayoutManager, storage: NSTextStorage, styler: MarkdownStyler,
                                            container: NSTextContainer, glyphs: NSRange) -> Bool {
        var lineGlyphs = NSRange()
        let frag = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: &lineGlyphs)
        guard lineGlyphs.location > glyphs.location, frag.minY > 0 else { return false }
        let charIndex = layout.characterIndexForGlyph(at: lineGlyphs.location)
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
