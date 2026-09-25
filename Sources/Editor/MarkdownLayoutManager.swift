import AppKit

/// TextKit 1 layout manager that hides syntax glyphs, reserves space for rendered
/// equations and images, and draws the quiet decorations (code boxes, quote bars,
/// bullets, rules). The same drawing is used on screen and for PDF export.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var gutter: CGFloat = 56
    /// Line spacing of body text, used to trim quote bars.
    var bodyLineSpacing: CGFloat = 8
    /// Where floating tables and images sit (container coordinates), keyed by the
    /// character location of their block. Set by the editor after layout.
    var floatFrames: [Int: NSRect] = [:]
    /// A floating table being edited is drawn by its editor instead.
    var hiddenFloat: Int?

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Glyph generation

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        var modified: [NSLayoutManager.GlyphProperty]?
        var runEnd = -1
        var hidden = false
        var math: InlineMath?

        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            if ci >= runEnd {
                var eff = NSRange()
                let attrs = storage.attributes(at: ci, effectiveRange: &eff)
                hidden = attrs[.mdHidden] != nil
                math = attrs[.mdInlineMath] as? InlineMath
                runEnd = NSMaxRange(eff)
            }
            var p: NSLayoutManager.GlyphProperty?
            if let math {
                let isFirst = ci == 0 || (storage.attribute(.mdInlineMath, at: ci - 1, effectiveRange: nil) as? InlineMath) !== math
                p = isFirst ? .controlCharacter : .null
            } else if hidden {
                // Zero-width control glyphs rather than null glyphs: a line whose first
                // glyph is null gets absorbed into the previous line fragment.
                let c = (storage.string as NSString).character(at: ci)
                if c != 0x0A && c != 0x0D { p = .controlCharacter }
            }
            if let p {
                if modified == nil { modified = Array(UnsafeBufferPointer(start: props, count: glyphRange.length)) }
                modified![i] = p
            }
        }
        guard let modified else { return 0 }
        modified.withUnsafeBufferPointer { buffer in
            setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage else { return action }
        let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
        if attrs[.mdInlineMath] != nil { return .whitespace }
        if attrs[.mdHidden] != nil {
            let c = (storage.string as NSString).character(at: charIndex)
            if c != 0x0A && c != 0x0D { return .zeroAdvancement }
        }
        return action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let math = textStorage?.attribute(.mdInlineMath, at: charIndex, effectiveRange: nil) as? InlineMath else {
            return .zero
        }
        return NSRect(x: glyphPosition.x, y: glyphPosition.y - math.render.ascent, width: math.advance, height: math.render.height)
    }

    // MARK: Geometry helpers

    private func column(for container: NSTextContainer, origin: NSPoint) -> (x: CGFloat, width: CGFloat) {
        (origin.x + gutter, container.size.width - gutter * 2)
    }

    private func isInColumnCell(charIndex: Int) -> Bool {
        guard let storage = textStorage, charIndex < storage.length,
              let ps = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle else { return false }
        return !ps.textBlocks.isEmpty
    }

    /// Horizontal extent available to decorations at a glyph: the page column, or the
    /// column cell when the text sits in a side-by-side layout.
    func contentColumn(glyph: Int, container: NSTextContainer, origin: NSPoint) -> (x: CGFloat, width: CGFloat) {
        if isInColumnCell(charIndex: characterIndexForGlyph(at: glyph)) {
            let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return (origin.x + frag.minX, frag.width)
        }
        let col = column(for: container, origin: origin)
        guard !container.exclusionPaths.isEmpty else { return col }
        // Beside a floating block the line is narrower; decorations follow it.
        let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let minX = max(col.x, origin.x + frag.minX)
        let maxX = min(col.x + col.width, origin.x + frag.maxX)
        return maxX - minX > 40 ? (minX, maxX - minX) : col
    }

    /// Glyph range limited to the container (page) the glyph belongs to.
    private func clampToContainer(_ glyphs: NSRange, container: NSTextContainer) -> NSRange {
        NSIntersectionRange(glyphs, glyphRange(for: container))
    }

    // MARK: Drawing

    /// Rendered blocks show selection with their own tint; the system's selection band
    /// across their hidden source line would just be a gray slab.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let origin = firstTextView?.textContainerOrigin else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        let areas = blockRects(in: charRange, origin: origin).filter { $0.decoration.placement != .below }
            .map { $0.area.insetBy(dx: 0, dy: -4) }
        // Every band goes through the same shaping, whether or not this part of the page
        // has a block in it; otherwise band widths change as different parts redraw.
        // Cut the block areas out of each band rather than dropping whole bands: after
        // Select All a single band can span many lines and several equations.
        var kept: [NSRect] = (0..<rectCount).map { rectArray[$0] }
        for area in areas {
            kept = kept.flatMap { r -> [NSRect] in
                guard r.maxY > area.minY, r.minY < area.maxY else { return [r] }
                var parts: [NSRect] = []
                if area.minY - r.minY > 0.5 { parts.append(NSRect(x: r.minX, y: r.minY, width: r.width, height: area.minY - r.minY)) }
                if r.maxY - area.maxY > 0.5 { parts.append(NSRect(x: r.minX, y: area.maxY, width: r.width, height: r.maxY - area.maxY)) }
                return parts
            }
        }
        // Slivers are a block's collapsed source lines (a table's rows), not text.
        kept.removeAll { $0.height < 3 }
        // Whole-line bands stop at the text column instead of running into the margins.
        if let container = textContainers.first {
            let col = column(for: container, origin: origin)
            kept = kept.map { r in
                let minX = max(r.minX, col.x - 6), maxX = min(r.maxX, col.x + col.width + 6)
                return NSRect(x: minX, y: r.minY, width: max(maxX - minX, 0), height: r.height)
            }
        }
        guard !kept.isEmpty else { return }
        kept.withUnsafeBufferPointer {
            super.fillBackgroundRectArray($0.baseAddress!, count: kept.count, forCharacterRange: charRange, color: color)
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, glyphsToShow.length > 0 {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            drawGroups(in: chars, storage: storage, origin: origin)
            drawInlineBoxes(in: chars, storage: storage, origin: origin)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, glyphsToShow.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawBullets(in: chars, storage: storage, origin: origin)
        drawRules(in: chars, storage: storage, origin: origin)
        drawInlineMath(in: chars, storage: storage, origin: origin)
        drawBlocks(in: chars, storage: storage, origin: origin)
    }

    private func drawGroups(in chars: NSRange, storage: NSTextStorage, origin: NSPoint) {
        var seen = Set<ObjectIdentifier>()
        var quoteBars: [(depth: Int, rect: NSRect)] = []
        storage.enumerateAttribute(.mdGroup, in: chars) { value, range, _ in
            guard let group = value as? GroupDecoration else { return }
            switch group.kind {
            case .code:
                guard seen.insert(ObjectIdentifier(group)).inserted else { return }
                var full = NSRange()
                _ = storage.attribute(.mdGroup, at: range.location, longestEffectiveRange: &full,
                                      in: NSRange(location: 0, length: storage.length))
                var glyphs = glyphRange(forCharacterRange: full, actualCharacterRange: nil)
                guard glyphs.length > 0, let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
                glyphs = clampToContainer(glyphs, container: container)
                if glyphs.length == 0 {
                    // The block starts on an earlier page; clamp from this page's start.
                    let firstGlyph = glyphIndexForCharacter(at: range.location)
                    guard let c = textContainer(forGlyphAt: firstGlyph, effectiveRange: nil) else { return }
                    glyphs = clampToContainer(glyphRange(forCharacterRange: full, actualCharacterRange: nil), container: c)
                }
                var box = NSRect.null
                enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
                    box = box.union(NSRect(x: rect.minX, y: used.minY, width: rect.width, height: used.height))
                }
                guard !box.isNull, let c = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
                let col = contentColumn(glyph: glyphs.location, container: c, origin: origin)
                let r = NSRect(x: col.x, y: origin.y + box.minY, width: col.width, height: box.height)
                Palette.fill.setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            case let .quote(depth):
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let inCell = isInColumnCell(charIndex: range.location)
                enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
                    // x holds the bar's left edge in view coordinates.
                    let x = origin.x + (inCell ? rect.minX : self.gutter)
                    quoteBars.append((depth, NSRect(x: x, y: rect.minY, width: rect.width,
                                                    height: max(used.maxY - rect.minY, 1))))
                }
            }
        }
        // Merge vertically adjacent fragments into continuous bars.
        guard !quoteBars.isEmpty else { return }
        quoteBars.sort { ($0.rect.minX, $0.rect.minY) < ($1.rect.minX, $1.rect.minY) }
        var merged: [(depth: Int, rect: NSRect)] = []
        for bar in quoteBars {
            if var last = merged.last, last.rect.minX == bar.rect.minX,
               bar.rect.minY - last.rect.maxY <= bodyLineSpacing + typoParagraphGap + 1 {
                last.rect = last.rect.union(bar.rect)
                last.depth = max(last.depth, bar.depth)
                merged[merged.count - 1] = last
            } else {
                merged.append(bar)
            }
        }
        Palette.quoteBar.setFill()
        for bar in merged {
            for d in 0..<bar.depth {
                let x = bar.rect.minX + CGFloat(d) * 22 + 1
                NSBezierPath(roundedRect: NSRect(x: x, y: origin.y + bar.rect.minY + 2, width: 2.5, height: bar.rect.height - 4),
                             xRadius: 1.25, yRadius: 1.25).fill()
            }
        }
    }

    var typoParagraphGap: CGFloat = 5
    var captionFont = NSFont.systemFont(ofSize: 13)
    /// The text view's selection, so rendered blocks (tables, equations, images) can show
    /// they're selected with a tint instead of revealing their source.
    var selectedRanges: [NSRange] = []

    private func drawInlineBoxes(in chars: NSRange, storage: NSTextStorage, origin: NSPoint) {
        storage.enumerateAttribute(.mdInlineBox, in: chars) { value, range, _ in
            guard let box = value as? InlineBox else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0, let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = rect.minY + self.location(forGlyphAt: part.location).y
                let top = baseline - font.ascender - 1.5
                let bottom = baseline - font.descender + 1.5
                let r = NSRect(x: origin.x + bounds.minX - 3, y: origin.y + top, width: bounds.width + 6, height: bottom - top)
                (box.kind == .code ? Palette.fill : Palette.highlight).setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    private func drawBullets(in chars: NSRange, storage: NSTextStorage, origin: NSPoint) {
        storage.enumerateAttribute(.mdBullet, in: chars) { value, range, _ in
            guard let depth = value as? Int else { return }
            let g = glyphIndexForCharacter(at: range.location)
            guard let container = textContainer(forGlyphAt: g, effectiveRange: nil) else { return }
            let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let glyphBox = boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
            let loc = location(forGlyphAt: g)
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
            let d = max(4.5, round(font.pointSize * 0.3 * 2) / 2)
            let cx = origin.x + glyphBox.midX
            let cy = origin.y + frag.minY + loc.y - font.xHeight / 2
            let circle = NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
            let color = (storage.attribute(.foregroundColor, at: max(NSMaxRange(range), 0) < storage.length ? NSMaxRange(range) : range.location,
                                           effectiveRange: nil) as? NSColor) ?? Palette.text
            let bulletColor = color.withAlphaComponent(color.alphaComponent * 0.75)
            switch depth % 3 {
            case 0:
                bulletColor.setFill()
                NSBezierPath(ovalIn: circle).fill()
            case 1:
                bulletColor.setStroke()
                let p = NSBezierPath(ovalIn: circle.insetBy(dx: 0.6, dy: 0.6))
                p.lineWidth = 1.2
                p.stroke()
            default:
                bulletColor.setFill()
                NSBezierPath(rect: circle.insetBy(dx: 0.5, dy: 0.5)).fill()
            }
        }
    }

    private func drawRules(in chars: NSRange, storage: NSTextStorage, origin: NSPoint) {
        storage.enumerateAttribute(.mdRule, in: chars) { value, range, _ in
            guard value != nil else { return }
            let g = glyphIndexForCharacter(at: range.location)
            guard let container = textContainer(forGlyphAt: g, effectiveRange: nil) else { return }
            let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let col = contentColumn(glyph: g, container: container, origin: origin)
            let w: CGFloat = min(120, col.width)
            let y = origin.y + frag.midY
            Palette.quoteBar.setFill()
            NSRect(x: col.x + (col.width - w) / 2, y: round(y), width: w, height: 1).fill()
        }
    }

    private func drawInlineMath(in chars: NSRange, storage: NSTextStorage, origin: NSPoint) {
        storage.enumerateAttribute(.mdInlineMath, in: chars) { value, range, _ in
            guard let math = value as? InlineMath else { return }
            // Only draw from the span's first character; a range may begin mid-span.
            if range.location > 0, (storage.attribute(.mdInlineMath, at: range.location - 1, effectiveRange: nil) as? InlineMath) === math {
                return
            }
            let g = glyphIndexForCharacter(at: range.location)
            let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let loc = location(forGlyphAt: g)
            let color = (storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor) ?? Palette.text
            math.render.draw(baselineAt: NSPoint(x: origin.x + frag.minX + loc.x + InlineMath.padding,
                                                 y: origin.y + frag.minY + loc.y), color: color)
        }
    }

    /// Image and equation areas, in view coordinates. Used for hit testing too.
    func blockRects(in chars: NSRange, origin: NSPoint) -> [(decoration: BlockDecoration, range: NSRange, area: NSRect, content: NSRect)] {
        guard let storage = textStorage else { return [] }
        var result: [(BlockDecoration, NSRange, NSRect, NSRect)] = []
        storage.enumerateAttribute(.mdBlock, in: chars) { value, range, _ in
            guard let deco = value as? BlockDecoration else { return }
            let anchorChar = deco.placement == .replace ? range.location : max(range.location, NSMaxRange(range) - 1)
            let g = glyphIndexForCharacter(at: anchorChar)
            guard let container = textContainer(forGlyphAt: g, effectiveRange: nil) else { return }
            if case .float = deco.placement {
                guard let frame = floatFrames[range.location] else { return }
                let content = frame.offsetBy(dx: origin.x, dy: origin.y).integral
                let area = NSRect(x: content.minX, y: content.minY - deco.padding, width: content.width, height: deco.height)
                result.append((deco, range, area, content))
                return
            }
            let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let col = contentColumn(glyph: g, container: container, origin: origin)
            var area: NSRect
            if deco.placement == .replace {
                area = NSRect(x: col.x, y: origin.y + frag.minY, width: col.width, height: frag.height)
            } else {
                let used = lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
                let top = origin.y + frag.maxY - deco.height
                area = NSRect(x: col.x, y: max(top, origin.y + used.maxY), width: col.width, height: deco.height)
            }
            var content: NSRect
            switch deco.content {
            case let .math(render, scale):
                // Shrinks to fit a line narrowed by a floating block beside it.
                let fit = min(scale, col.width / max(render.width, 1))
                let w = render.width * fit, h = render.height * fit
                content = NSRect(x: col.x + (col.width - w) / 2, y: area.minY + (area.height - h) / 2, width: w, height: h)
            case let .image(_, size, _, _):
                content = NSRect(x: col.x + (col.width - size.width) / 2, y: area.minY + deco.padding, width: size.width, height: size.height)
            case let .table(table):
                content = NSRect(x: col.x, y: area.minY + deco.padding, width: table.width, height: table.height)
            }
            content = content.integral
            result.append((deco, range, area, content))
        }
        return result
    }

    /// Floating blocks, in view coordinates. Their source can be scrolled out of view
    /// while they still show, so they're found by frame rather than by character range.
    func floatBlocks(origin: NSPoint) -> [(decoration: BlockDecoration, range: NSRange, area: NSRect, content: NSRect)] {
        guard let storage = textStorage else { return [] }
        return floatFrames.keys.sorted().flatMap { location -> [(BlockDecoration, NSRange, NSRect, NSRect)] in
            guard location < storage.length else { return [] }
            return blockRects(in: NSRange(location: location, length: 1), origin: origin).filter {
                if case .float = $0.decoration.placement { return true }
                return false
            }
        }
    }

    /// Drawn by the text view after the text, so they show even when their source
    /// line isn't among the glyphs being drawn. Never used for print.
    func drawFloats(in rect: NSRect, origin: NSPoint) {
        for block in floatBlocks(origin: origin) where block.area.intersects(rect) && block.range.location != hiddenFloat {
            drawBlock(block.decoration, range: block.range, area: block.area, content: block.content)
        }
    }

    private func drawBlocks(in chars: NSRange, storage: NSTextStorage, origin: NSPoint) {
        for (deco, range, area, content) in blockRects(in: chars, origin: origin) {
            if case .float = deco.placement { continue }
            drawBlock(deco, range: range, area: area, content: content)
        }
    }

    private func drawBlock(_ deco: BlockDecoration, range: NSRange, area: NSRect, content: NSRect) {
        do {
            defer {
                if deco.placement != .below, selectedRanges.contains(where: { $0.length > 0 && NSIntersectionRange($0, range).length > 0 }) {
                    NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill()
                    NSBezierPath(roundedRect: content.insetBy(dx: -4, dy: -4), xRadius: 9, yRadius: 9).fill()
                }
            }
            switch deco.content {
            case let .math(render, _):
                let scale = content.width / max(render.width, 1)
                render.draw(baselineAt: NSPoint(x: content.minX, y: content.minY + render.ascent * scale),
                            color: Palette.text, scale: scale)
            case let .table(table):
                table.draw(in: content)
            case let .image(image, _, caption, name):
                if let image {
                    NSGraphicsContext.saveGraphicsState()
                    let path = NSBezierPath(roundedRect: content, xRadius: 6, yRadius: 6)
                    path.addClip()
                    image.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                               hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
                    NSGraphicsContext.restoreGraphicsState()
                    Palette.separator.setStroke()
                    let border = NSBezierPath(roundedRect: content.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
                    border.lineWidth = 0.5
                    border.stroke()
                } else {
                    Palette.fill.setFill()
                    NSBezierPath(roundedRect: content, xRadius: 6, yRadius: 6).fill()
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.tertiaryText]
                    let label = "Image not found · \(name)" as NSString
                    let size = label.size(withAttributes: attrs)
                    label.draw(at: NSPoint(x: content.midX - size.width / 2, y: content.midY - size.height / 2), withAttributes: attrs)
                }
                if deco.isSelected {
                    Palette.accentRing.setStroke()
                    let ring = NSBezierPath(roundedRect: content.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
                    ring.lineWidth = 2
                    ring.stroke()
                }
                if let caption {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    let attrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: Palette.secondaryText, .paragraphStyle: style]
                    let rect = NSRect(x: area.minX, y: content.maxY + 8, width: area.width, height: captionFont.lineHeight + 2)
                    (caption as NSString).draw(in: rect, withAttributes: attrs)
                }
            }
        }
    }
}

extension MarkdownLayoutManager {
    /// Places floating tables and images: each sits at its source line's position, and
    /// an exclusion beside it makes the text that follows wrap around it. Returns the
    /// bottom of the lowest float, or nil when there are none.
    func placeFloats(in container: NSTextContainer, styler: MarkdownStyler) -> CGFloat? {
        guard let textStorage else { return nil }
        var floats: [(location: Int, decoration: BlockDecoration, right: Bool)] = []
        textStorage.enumerateAttribute(.mdBlock, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let d = value as? BlockDecoration, case let .float(right) = d.placement { floats.append((range.location, d, right)) }
        }
        if floats.isEmpty {
            if !container.exclusionPaths.isEmpty { container.exclusionPaths = [] }
            if !floatFrames.isEmpty { floatFrames = [:] }
            return nil
        }
        let width = container.size.width
        let gap = round(styler.config.typography.size * 1.6)
        // An exclusion only moves text after its own block, so a couple of passes settle.
        for _ in 0..<3 {
            var frames: [Int: NSRect] = [:]
            var rects: [NSRect] = []
            for f in floats {
                let g = glyphIndexForCharacter(at: f.location)
                ensureLayout(forGlyphRange: NSRange(location: 0, length: min(g + 1, numberOfGlyphs)))
                let top = lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY
                let size: NSSize
                switch f.decoration.content {
                case let .table(t): size = NSSize(width: t.width, height: t.height)
                case let .image(_, s, _, _): size = s
                case let .math(r, scale): size = NSSize(width: r.width * scale, height: r.height * scale)
                }
                let x = f.right ? width - gutter - size.width : gutter
                // The table's top lines up with the first text beside it (a heading's
                // spacing above would otherwise leave the table hanging higher).
                let y = max(top + f.decoration.padding, firstTextTop(after: f.location, styler: styler) ?? 0)
                frames[f.location] = NSRect(x: x, y: y, width: size.width, height: size.height)
                // Ends at the block's bottom edge, so the next line isn't squeezed by padding.
                let height = y - top + size.height + 2
                rects.append(f.right
                    ? NSRect(x: x - gap, y: top, width: width - x + gap, height: height)
                    : NSRect(x: 0, y: top, width: x + size.width + gap, height: height))
            }
            floatFrames = frames
            let current = container.exclusionPaths.map(\.bounds)
            if current == rects { break }
            container.exclusionPaths = rects.map { NSBezierPath(rect: $0) }
            // Lines already laid out beside the old area must not survive the change
            // (after a window zoom they otherwise keep stale, overlapping positions).
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length), actualCharacterRange: nil)
            invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
        return floatFrames.values.map(\.maxY).max() ?? 0
    }

    /// Top of the first visible text after the block at `location` (container coordinates).
    private func firstTextTop(after location: Int, styler: MarkdownStyler) -> CGFloat? {
        guard let storage = textStorage, let i = styler.blockIndex(containing: location) else { return nil }
        let ns = storage.string as NSString
        var c = NSMaxRange(styler.blocks[i].range)
        let limit = min(ns.length, c + 600)
        while c < limit {
            let hidden = storage.attribute(.mdHidden, at: c, effectiveRange: nil) != nil
            let ch = ns.character(at: c)
            if !hidden, ch != 0x0A, ch != 0x20, ch != 0x09 { break }
            c += 1
        }
        guard c < limit else { return nil }
        let glyph = glyphIndexForCharacter(at: c)
        ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
        let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = self.location(forGlyphAt: glyph).y
        let font = storage.attribute(.font, at: c, effectiveRange: nil) as? NSFont ?? styler.config.typography.body
        // Cap height, not ascender: the grid's top edge meets the tops of the letters.
        return frag.minY + baseline - font.capHeight - 3
    }
}
