import AppKit

/// Arranging blocks from a selection: floats, columns, and full width.
extension EditorController {
    var layoutModel: LayoutModel {
        if let cached = cachedLayout, cached.version == textVersion { return cached.model }
        let starts = Set(styler.regions.map(\.start))
        let model = LayoutModel.build(text: storage.string as NSString, blocks: styler.blocks, validRegionStarts: starts)
        cachedLayout = (textVersion, model)
        return model
    }

    // MARK: Selection bar

    /// Blocks touched by the current selection, in order.
    func selectedGroups() -> [LayoutGroup] {
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return [] }
        return layoutModel.groups.map(\.group).filter { NSIntersectionRange($0.range, sel).length > 0 }
    }

    func updateSelectionBar() {
        let sel = textView.selectedRange()
        let groups = selectedGroups()
        guard textView.isEditable, sel.length > 0, !textView.isTrackingMouse,
              let first = groups.first, let container = textView.textContainer, selectionIsBlockSized(sel, groups: groups) else {
            selectionBar.dismiss()
            return
        }
        let inColumns = caretIsInColumns || layoutModel.itemIndex(of: first).map { i -> Bool in
            if case .region = layoutModel.items[i] { return true }
            return false
        } ?? false
        selectionBar.configure(inColumns: inColumns || floatable(groups)?.right != nil, canWrap: wrappable(groups) != nil)
        let glyphs = layoutManager.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        // A floating block's source is a hidden sliver; the bar belongs over the block itself.
        if let float = layoutManager.floatBlocks(origin: textView.textContainerOrigin)
            .first(where: { NSIntersectionRange($0.range, sel).length > 0 }) {
            rect = float.content
        }
        let size = selectionBar.frame.size
        var x = rect.midX - size.width / 2
        x = min(max(x, textView.visibleRect.minX + 12), textView.visibleRect.maxX - size.width - 12)
        var y = rect.minY - size.height - 10
        if y < textView.visibleRect.minY + TitleBarView.height + 8 { y = rect.maxY + 10 }
        selectionBar.present(at: NSPoint(x: round(x), y: round(y)))
    }

    /// Only offer layout moves for selections that read as "this block": several blocks,
    /// several lines, or most of one block. A selected word shouldn't summon a toolbar.
    private func selectionIsBlockSized(_ sel: NSRange, groups: [LayoutGroup]) -> Bool {
        if groups.count > 1 { return true }
        guard let g = groups.first, g.range.length > 0 else { return false }
        let covered = NSIntersectionRange(g.range, sel).length
        if Double(covered) >= Double(g.range.length) * 0.6 { return true }
        return (storage.string as NSString).substring(with: sel).contains("\n")
    }

    /// A lone table or image outside columns floats instead of opening columns: the
    /// text after it wraps beside it, with no need to arrange what goes where.
    /// Returns its source without any float marker, and the side it floats on now.
    private func floatable(_ groups: [LayoutGroup]) -> (group: LayoutGroup, body: String, right: Bool?)? {
        guard groups.count == 1, let group = groups.first, let i = layoutModel.itemIndex(of: group),
              case .group = layoutModel.items[i] else { return nil }
        var right: Bool?
        var content: [MDBlock] = []
        for b in styler.blocks where NSIntersectionRange(b.range, group.range).length > 0 {
            switch b.kind {
            case .blank, .tableFormulas: continue
            case let .columnMarker(.float(r)) where content.isEmpty && right == nil: right = r
            case .table, .image: content.append(b)
            default: return nil
            }
        }
        guard content.count == 1, let block = content.first else { return nil }
        var body = group.text
        if right != nil, let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
        _ = block
        return (group, body, right)
    }

    /// A table or image alone in one of two columns can become a float instead: the
    /// other column's blocks follow it at full width and wrap beside it.
    private func wrappable(_ groups: [LayoutGroup]) -> (region: LayoutRegion, group: LayoutGroup, right: Bool, rest: [LayoutGroup])? {
        guard groups.count == 1, let group = groups.first, let i = layoutModel.itemIndex(of: group),
              case let .region(region) = layoutModel.items[i], region.columns.count == 2,
              let c = region.columns.firstIndex(where: { $0.groups.count == 1 && $0.groups[0] === group }) else { return nil }
        let kinds = styler.blocks.filter { NSIntersectionRange($0.range, group.range).length > 0 }.map(\.kind)
        let content = kinds.filter {
            switch $0 {
            case .blank, .tableFormulas: return false
            default: return true
            }
        }
        guard content.count == 1 else { return nil }
        switch content[0] {
        case .table, .image: break
        default: return nil
        }
        return (region, group, c == 1, region.columns[1 - c].groups)
    }

    /// Column widths dragged for another context (full width, a column) don't carry
    /// over when a table starts floating: it starts at its natural size.
    private func naturalWidths(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.contains("-") && t.allSatisfy { "|:- ".contains($0) }
        }) else { return text }
        lines[i] = lines[i].replacingOccurrences(of: "-{3,}", with: "---", options: .regularExpression)
        return lines.joined(separator: "\n")
    }

    /// From the table toolbar: full width, or floating with the text wrapping beside it.
    /// A table sitting alone in a column comes out of the columns to float.
    func placeEditedTable(float side: Bool?) {
        guard let location = styler.editingTableLocation, let group = layoutModel.group(containing: location) else { return }
        endTableEditing()
        var edit: (range: NSRange, text: String, body: String, bodyOffset: Int)?
        if let side, let w = wrappable([group]) {
            let marker = "<!-- float \(side ? "right" : "left") -->\n"
            let table = naturalWidths(w.group.text)
            let text = ([marker + table] + w.rest.map(\.text)).joined(separator: "\n\n")
            edit = (w.region.range, text, table, (marker as NSString).length)
        } else if let f = floatable([group]) {
            let marker = side.map { "<!-- float \($0 ? "right" : "left") -->\n" } ?? ""
            let body = side != nil && f.right == nil ? naturalWidths(f.body) : f.body
            edit = (f.group.range, marker + body, body, (marker as NSString).length)
        } else if side == nil, let unwrap = layoutModel.unwrapRegion(containing: group) {
            edit = (unwrap.range, unwrap.text, group.text, (unwrap.text as NSString).range(of: group.text).location)
        }
        guard let edit else { NSSound.beep(); return }
        let offset = scrollView.contentView.bounds.origin
        replace(edit.range, with: edit.text, select: NSRange(location: edit.range.location + max(edit.bodyOffset, 0), length: 0),
                actionName: side == nil ? "Full Width" : "Wrap Text")
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // Keep editing the same table in its new place.
        let tableStart = edit.range.location + max(edit.bodyOffset, 0)
        if let i = styler.blockIndex(containing: tableStart), case .table = styler.blocks[i].kind {
            beginTableEditing(at: styler.blocks[i].range.location, row: 0, column: 0)
        }
    }

    private func performFloatAction(_ action: SelectionBarView.Action, groups: [LayoutGroup]) -> Bool {
        if action == .wrap, let w = wrappable(groups) {
            let marker = "<!-- float \(w.right ? "right" : "left") -->\n"
            let table = naturalWidths(w.group.text)
            let text = ([marker + table] + w.rest.map(\.text)).joined(separator: "\n\n")
            let offset = scrollView.contentView.bounds.origin
            replace(w.region.range, with: text,
                    select: NSRange(location: w.region.range.location + (marker as NSString).length, length: (table as NSString).length),
                    actionName: "Wrap Text")
            scrollView.contentView.scroll(to: offset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            updateSelectionBar()
            return true
        }
        guard let f = floatable(groups) else { return false }
        let text: String, name: String
        switch action {
        case .wrap:
            return false
        case .left, .right:
            text = "<!-- float \(action == .right ? "right" : "left") -->\n" + (f.right == nil ? naturalWidths(f.body) : f.body)
            name = action == .right ? "Place Right" : "Place Left"
        case .fullWidth:
            guard f.right != nil else { return false }
            text = f.body
            name = "Full Width"
        case .swap:
            guard let right = f.right else { return false }
            text = "<!-- float \(right ? "left" : "right") -->\n" + f.body
            name = "Swap Sides"
        }
        let ns = text as NSString
        let markerLength = text.hasPrefix("<!--") ? ns.range(of: "\n").location + 1 : 0
        let offset = scrollView.contentView.bounds.origin
        replace(f.group.range, with: text, select: NSRange(location: f.group.range.location + markerLength, length: ns.length - markerLength),
                actionName: name)
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateSelectionBar()
        return true
    }

    func performSelectionAction(_ action: SelectionBarView.Action) {
        let groups = selectedGroups()
        guard let first = groups.first else { return }
        selectionBar.dismiss()
        if performFloatAction(action, groups: groups) { return }
        let movedText = groups.map(\.text).joined(separator: "\n\n")
        let edit: (range: NSRange, text: String)?
        let name: String
        switch action {
        case .left, .right:
            edit = layoutModel.placeAside(groups, onRight: action == .right, height: { self.height(of: $0) }).map { ($0.range, $0.text) }
            name = action == .right ? "Place Right" : "Place Left"
        case .fullWidth:
            edit = layoutModel.unwrapRegion(containing: first)
            name = "Full Width"
        case .swap:
            edit = layoutModel.swapColumns(containing: first)
            name = "Swap Sides"
        case .wrap:
            edit = nil
            name = "Wrap Text"
        }
        guard let edit else { NSSound.beep(); return }
        // Keep exactly the moved block selected so it can be moved again.
        let inner = (edit.text as NSString).range(of: movedText)
        let select = inner.location != NSNotFound
            ? NSRange(location: edit.range.location + inner.location, length: inner.length)
            : NSRange(location: edit.range.location, length: 0)
        // Stay where the reader was; only nudge if the moved block went out of view.
        let offset = scrollView.contentView.bounds.origin
        replace(edit.range, with: edit.text, select: select, actionName: name)
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.scrollRangeToVisible(select)
        updateSelectionBar()
    }

    /// Laid-out height of a block, as shown on the page.
    func height(of group: LayoutGroup) -> CGFloat {
        let glyphs = layoutManager.glyphRange(forCharacterRange: group.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return 0 }
        var rect = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, _, _ in rect = rect.union(frag) }
        return rect.isNull ? 0 : rect.height
    }

    // MARK: Commands

    private func caretGroup() -> LayoutGroup? {
        layoutModel.group(containing: textView.selectedRange().location)
    }

    var caretIsInColumns: Bool {
        guard let group = caretGroup(), let i = layoutModel.itemIndex(of: group) else { return false }
        if case .region = layoutModel.items[i] { return true }
        return false
    }
}

// MARK: - Moving a table by its grip

/// Hovering a table shows a grip beside its header; dragging it lifts the table (with
/// its formula lines and any float marker: its whole block) and a line or a half-width
/// area shows where it will land. Dropping is one undoable edit; Escape cancels.
extension EditorController {
    struct GroupFrame {
        let group: LayoutGroup
        let rect: NSRect
        let inColumn: Bool
    }

    #if DEBUG
    /// The debug harness's look at a drag in progress, after the drop spot is shown.
    static var onDragStep: (() -> Void)?
    #endif

    var tableGrip: BlockHandleView? { textView.subviews.lazy.compactMap { $0 as? BlockHandleView }.first }

    /// Rendered tables on screen (text view coordinates), floating ones first.
    func visibleTables() -> [(location: Int, content: NSRect, headerHeight: CGFloat)] {
        guard let container = textView.textContainer else { return [] }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let chars = layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(forBoundingRect: visible, in: container), actualGlyphRange: nil)
        return (layoutManager.floatBlocks(origin: origin) + layoutManager.blockRects(in: chars, origin: origin)).compactMap { block in
            guard case let .table(table) = block.decoration.content, block.decoration.placement != .below else { return nil }
            return (block.range.location, block.content, table.rowHeights.first ?? 30)
        }
    }

    /// Left of the header row, in the margin.
    static func gripFrame(table: NSRect, headerHeight: CGFloat) -> NSRect {
        NSRect(x: table.minX - BlockHandleView.size.width - 6, y: table.minY + max(0, (headerHeight - BlockHandleView.size.height) / 2),
               width: BlockHandleView.size.width, height: BlockHandleView.size.height)
    }

    /// Shows the grip of the table under the pointer.
    func hoverTableGrip(at point: NSPoint) {
        if tableGrip?.dragging == true { return }
        guard textView.isEditable, AppSettings.shared.syntax != .always else { return hideTableGrip() }
        for table in visibleTables() {
            let frame = Self.gripFrame(table: table.content, headerHeight: table.headerHeight)
            guard table.content.union(frame).insetBy(dx: -4, dy: -4).contains(point) else { continue }
            let grip = tableGrip ?? {
                let grip = BlockHandleView(frame: frame)
                textView.addSubview(grip)
                return grip
            }()
            grip.frame = frame
            let location = table.location
            grip.onDrag = { [weak self] event in self?.dragTable(at: location, from: event) }
            return
        }
        hideTableGrip()
    }

    func hideTableGrip() {
        guard let grip = tableGrip, !grip.dragging else { return }
        grip.removeFromSuperview()
    }

    /// Frames (text view coordinates) of the blocks on screen.
    func visibleGroupFrames() -> [GroupFrame] {
        guard let container = textView.textContainer else { return [] }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -200)
        let glyphsOnScreen = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let charsOnScreen = layoutManager.characterRange(forGlyphRange: glyphsOnScreen, actualGlyphRange: nil)
        var frames: [GroupFrame] = []
        for (group, region) in layoutModel.groups where NSIntersectionRange(group.range, charsOnScreen).length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: group.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var rect = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { frag, used, _, _, _ in
                rect = rect.union(NSRect(x: frag.minX, y: used.minY, width: frag.width, height: max(used.height, 1)))
            }
            guard !rect.isNull else { continue }
            let col = layoutManager.contentColumn(glyph: glyphs.location, container: container, origin: origin)
            frames.append(GroupFrame(group: group, rect: NSRect(x: col.x, y: rect.minY + origin.y, width: col.width, height: rect.height),
                                     inColumn: region != nil))
        }
        return frames
    }

    private func dragTable(at location: Int, from event: NSEvent) {
        guard let window = textView.window, let grip = tableGrip else { return }
        if let editing = styler.editingTableLocation, editing == location { endTableEditing() }
        guard let source = layoutModel.group(containing: location),
              let lifted = visibleTables().first(where: { $0.location == location })?.content else { return }
        grip.dragging = true
        grip.isHidden = true
        // Only the table moves: a selection elsewhere and its bar go.
        selectionBar.dismiss()
        textView.setSelectedRange(NSRange(location: source.range.location, length: 0))
        defer {
            grip.dragging = false
            grip.removeFromSuperview()
        }

        // A lifted picture of the table follows the pointer.
        let snapshotRect = lifted.insetBy(dx: -6, dy: -4)
        let ghost = NSImageView(frame: snapshotRect)
        if let rep = textView.bitmapImageRepForCachingDisplay(in: snapshotRect) {
            textView.cacheDisplay(in: snapshotRect, to: rep)
            let image = NSImage(size: snapshotRect.size)
            image.addRepresentation(rep)
            ghost.image = image
        }
        ghost.wantsLayer = true
        ghost.layer?.cornerRadius = 10
        ghost.layer?.backgroundColor = Palette.background.cgColor
        ghost.alphaValue = 0.85
        ghost.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 18
            s.shadowOffset = NSSize(width: 0, height: -6)
            s.shadowColor = NSColor.black.withAlphaComponent(0.2)
            return s
        }()
        // The table stays put, faded, until it's dropped.
        let veil = NSView(frame: snapshotRect)
        veil.wantsLayer = true
        veil.layer?.backgroundColor = Palette.background.withAlphaComponent(0.65).cgColor
        let indicator = DropIndicatorView()
        indicator.isHidden = true
        textView.addSubview(veil)
        textView.addSubview(indicator)
        textView.addSubview(ghost)

        let start = textView.convert(event.locationInWindow, from: nil)
        let offset = NSPoint(x: start.x - snapshotRect.minX, y: start.y - snapshotRect.minY)
        var target: DropTarget?
        NSCursor.closedHand.push()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .leftMouseUp { break }
            if next.type == .keyDown {
                if next.keyCode == 53 { target = nil; break }
                continue
            }
            textView.autoscroll(with: next)
            let p = textView.convert(next.locationInWindow, from: nil)
            ghost.setFrameOrigin(NSPoint(x: p.x - offset.x, y: p.y - offset.y))
            target = dropTarget(at: p, dragging: source)
            showIndicator(indicator, for: target)
            #if DEBUG
            Self.onDragStep?()
            #endif
        }
        NSCursor.pop()
        ghost.removeFromSuperview()
        veil.removeFromSuperview()
        indicator.removeFromSuperview()
        if let target { moveBlock(source, to: target) }
    }

    /// Where a block dropped at `p` goes: before or after the block under the pointer
    /// (by its upper or lower half), or beside it near its left or right edge.
    func dropTarget(at p: NSPoint, dragging: LayoutGroup) -> DropTarget? {
        let frames = visibleGroupFrames()
        let candidates = frames.filter { f in
            p.y >= f.rect.minY - 14 && p.y <= f.rect.maxY + 14 && (!f.inColumn || (p.x >= f.rect.minX - 16 && p.x <= f.rect.maxX + 16))
        }
        let frame = candidates.min { abs($0.rect.midY - p.y) < abs($1.rect.midY - p.y) }
            ?? frames.min { abs($0.rect.midY - p.y) < abs($1.rect.midY - p.y) }
        guard let frame, frame.group !== dragging else { return nil }
        let edge = min(frame.rect.width * 0.22, 130)
        if p.x < frame.rect.minX + edge { return .beside(frame.group, leading: true) }
        if p.x > frame.rect.maxX - edge { return .beside(frame.group, leading: false) }
        return p.y < frame.rect.midY ? .before(frame.group) : .after(frame.group)
    }

    private func showIndicator(_ indicator: DropIndicatorView, for target: DropTarget?) {
        guard let target, let frame = visibleGroupFrames().first(where: { $0.group.range == target.group.range }) else {
            indicator.isHidden = true
            return
        }
        let r = frame.rect
        switch target {
        case .before:
            indicator.style = .line
            indicator.frame = NSRect(x: r.minX - 8, y: r.minY - 12, width: r.width + 16, height: 10)
        case .after:
            indicator.style = .line
            indicator.frame = NSRect(x: r.minX - 8, y: r.maxY + 2, width: r.width + 16, height: 10)
        case let .beside(_, leading):
            indicator.style = .area
            let w = r.width * 0.48
            indicator.frame = NSRect(x: leading ? r.minX - 6 : r.maxX - w + 6, y: r.minY - 6, width: w, height: max(r.height + 12, 44))
        }
        indicator.isHidden = false
        indicator.needsDisplay = true
    }

    /// Moves a block, as one undo step. Dropping it where it already is changes nothing.
    func moveBlock(_ group: LayoutGroup, to target: DropTarget) {
        guard let edit = layoutModel.move(group, to: target),
              edit.text != (storage.string as NSString).substring(with: edit.range) else { return }
        let isTable = styler.blocks.contains { block in
            if case .table = block.kind { return NSLocationInRange(block.range.location, group.range) }
            return false
        }
        let offset = scrollView.contentView.bounds.origin
        replace(edit.range, with: edit.text, select: NSRange(location: edit.range.location + edit.movedOffset, length: 0),
                actionName: isTable ? "Move Table" : "Move Block")
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
