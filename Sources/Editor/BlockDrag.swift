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

    /// Shows the layout bar over a block-sized selection once the selection has settled.
    /// Selecting in quick steps (Shift-arrows, small drags) passes through whole blocks on
    /// the way; showing the bar at each would make it blink in and out.
    func updateSelectionBar() {
        selectionBarWork?.cancel()
        guard eligibleForSelectionBar() else {
            selectionBar.dismiss()
            return
        }
        if !selectionBar.isHidden, selectionBar.alphaValue > 0 {
            presentSelectionBar()
            return
        }
        let sel = textView.selectedRange()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.textView.selectedRange() == sel, self.eligibleForSelectionBar() else { return }
            self.presentSelectionBar()
        }
        selectionBarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func eligibleForSelectionBar() -> Bool {
        let sel = textView.selectedRange()
        let groups = selectedGroups()
        return textView.isEditable && sel.length > 0 && !textView.isTrackingMouse && !groups.isEmpty
            && textView.textContainer != nil && selectionIsBlockSized(sel, groups: groups)
    }

    private func presentSelectionBar() {
        let sel = textView.selectedRange()
        let groups = selectedGroups()
        guard let first = groups.first, let container = textView.textContainer else { return }
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
        guard content.count == 1 else { return nil }
        var body = group.text
        if right != nil, let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
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

    private static func floatMarker(right: Bool) -> String {
        "<!-- float \(right ? "right" : "left") -->\n"
    }

    /// `replace`, with the page left where it was scrolled.
    private func replaceKeepingScroll(_ range: NSRange, with text: String, select: NSRange, actionName: String) {
        let offset = scrollView.contentView.bounds.origin
        replace(range, with: text, select: select, actionName: actionName)
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
            let marker = Self.floatMarker(right: side)
            let table = naturalWidths(w.group.text)
            let text = ([marker + table] + w.rest.map(\.text)).joined(separator: "\n\n")
            edit = (w.region.range, text, table, (marker as NSString).length)
        } else if let f = floatable([group]) {
            let marker = side.map(Self.floatMarker) ?? ""
            let body = side != nil && f.right == nil ? naturalWidths(f.body) : f.body
            edit = (f.group.range, marker + body, body, (marker as NSString).length)
        } else if side == nil, let unwrap = layoutModel.unwrapRegion(containing: group) {
            edit = (unwrap.range, unwrap.text, group.text, (unwrap.text as NSString).range(of: group.text).location)
        }
        guard let edit else { NSSound.beep(); return }
        replaceKeepingScroll(edit.range, with: edit.text, select: NSRange(location: edit.range.location + max(edit.bodyOffset, 0), length: 0),
                             actionName: side == nil ? "Full Width" : "Wrap Text")
        // Keep editing the same table in its new place.
        let tableStart = edit.range.location + max(edit.bodyOffset, 0)
        if let i = styler.blockIndex(containing: tableStart), case .table = styler.blocks[i].kind {
            beginTableEditing(at: styler.blocks[i].range.location, row: 0, column: 0)
        }
    }

    private func performFloatAction(_ action: SelectionBarView.Action, groups: [LayoutGroup]) -> Bool {
        if action == .wrap, let w = wrappable(groups) {
            let marker = Self.floatMarker(right: w.right)
            let table = naturalWidths(w.group.text)
            let text = ([marker + table] + w.rest.map(\.text)).joined(separator: "\n\n")
            replaceKeepingScroll(w.region.range, with: text,
                                 select: NSRange(location: w.region.range.location + (marker as NSString).length, length: (table as NSString).length),
                                 actionName: "Wrap Text")
            updateSelectionBar()
            return true
        }
        guard let f = floatable(groups) else { return false }
        let text: String, name: String
        switch action {
        case .wrap:
            return false
        case .left, .right:
            text = Self.floatMarker(right: action == .right) + (f.right == nil ? naturalWidths(f.body) : f.body)
            name = action == .right ? "Place Right" : "Place Left"
        case .fullWidth:
            guard f.right != nil else { return false }
            text = f.body
            name = "Full Width"
        case .swap:
            guard let right = f.right else { return false }
            text = Self.floatMarker(right: !right) + f.body
            name = "Swap Sides"
        }
        let ns = text as NSString
        let markerLength = text.hasPrefix("<!--") ? ns.range(of: "\n").location + 1 : 0
        replaceKeepingScroll(f.group.range, with: text, select: NSRange(location: f.group.range.location + markerLength, length: ns.length - markerLength),
                             actionName: name)
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
        replaceKeepingScroll(edit.range, with: edit.text, select: select, actionName: name)
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
/// its formula lines and any float marker: its whole block), every spot it can land is
/// outlined, and a line or an area shows the one it will. Dropping is one undoable edit;
/// Escape cancels.
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
        visibleBlocks().compactMap { block in
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

        // A lifted picture of the table follows the pointer: a wide one shrunk to under
        // half the view, so it never hides where it's going.
        hideTableStrips()
        let snapshotRect = lifted
        let scale = min(1, max(200, textView.visibleRect.width * 0.4) / snapshotRect.width)
        let size = NSSize(width: round(snapshotRect.width * scale), height: round(snapshotRect.height * scale))
        // The picture is clipped to the table's rounded frame; its holder casts the shadow.
        let picture = NSImageView(frame: NSRect(origin: .zero, size: size))
        picture.imageScaling = .scaleProportionallyUpOrDown
        if let rep = textView.bitmapImageRepForCachingDisplay(in: snapshotRect) {
            textView.cacheDisplay(in: snapshotRect, to: rep)
            let image = NSImage(size: snapshotRect.size)
            image.addRepresentation(rep)
            picture.image = image
        }
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 8 * scale
        picture.layer?.masksToBounds = true
        let ghost = NSView(frame: NSRect(origin: snapshotRect.origin, size: size))
        ghost.wantsLayer = true
        ghost.addSubview(picture)
        ghost.alphaValue = 0.9
        ghost.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 16
            s.shadowOffset = NSSize(width: 0, height: -5)
            s.shadowColor = NSColor.black.withAlphaComponent(0.22)
            return s
        }()
        // The table stays put, faded, until it's dropped.
        let veil = NSView(frame: snapshotRect.insetBy(dx: -2, dy: -2))
        veil.wantsLayer = true
        veil.layer?.backgroundColor = Palette.background.withAlphaComponent(0.65).cgColor
        let indicator = DropIndicatorView()
        indicator.isHidden = true
        // Every spot it can go stays outlined for the whole drag, blank space included.
        let zonesView = DropZonesView(frame: textView.bounds)
        var zones = dropZones(dragging: source)
        var zonesSeen = textView.visibleRect
        zonesView.zones = zones
        textView.addSubview(veil)
        textView.addSubview(zonesView)
        textView.addSubview(indicator)
        textView.addSubview(ghost)

        let start = textView.convert(event.locationInWindow, from: nil)
        // Where it was picked up, kept under the pointer (scaled with the picture).
        let offset = NSPoint(x: (start.x - snapshotRect.minX) * scale, y: (start.y - snapshotRect.minY) * scale)
        // Inside the visible page; near its right edge it hangs left of the pointer
        // instead, clear of a spot beside the block there.
        func place(at p: NSPoint) {
            let visible = textView.visibleRect.insetBy(dx: 8, dy: 8)
            var x = p.x - offset.x
            if x + size.width > visible.maxX { x = p.x - size.width - 16 }
            ghost.setFrameOrigin(NSPoint(x: min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width)),
                                         y: min(max(p.y - offset.y, visible.minY), max(visible.minY, visible.maxY - size.height))))
        }
        place(at: start)
        var target: DropTarget?
        NSCursor.closedHand.push()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .leftMouseUp { break }
            if next.type == .keyDown {
                if next.keyCode == 53 { target = nil; break }
                continue
            }
            textView.autoscroll(with: next)
            if textView.visibleRect != zonesSeen {
                zonesSeen = textView.visibleRect
                zones = dropZones(dragging: source)
                zonesView.zones = zones
            }
            let p = textView.convert(next.locationInWindow, from: nil)
            place(at: p)
            if let zone = zones.first(where: { $0.hit.contains(p) }) {
                target = zone.target
                zonesView.active = zone.shape
                indicator.style = zone.style
                indicator.frame = zone.active
                indicator.isHidden = false
                indicator.needsDisplay = true
            } else {
                target = dropTarget(at: p, dragging: source)
                zonesView.active = nil
                showIndicator(indicator, for: target)
            }
            #if DEBUG
            Self.onDragStep?()
            #endif
        }
        NSCursor.pop()
        ghost.removeFromSuperview()
        veil.removeFromSuperview()
        zonesView.removeFromSuperview()
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
        let anchor: LayoutGroup?
        switch target {
        case let .before(g), let .after(g), let .beside(g, _): anchor = g
        default: anchor = nil
        }
        guard let target, let anchor, let frame = visibleGroupFrames().first(where: { $0.group.range == anchor.range }) else {
            indicator.isHidden = true
            return
        }
        let r = frame.rect
        switch target {
        case .before:
            indicator.style = .line
            indicator.frame = NSRect(x: r.minX - 8, y: r.minY - 12, width: r.width + 16, height: 10)
        case let .beside(_, leading):
            indicator.style = .area
            indicator.frame = Self.besideArea(r, leading: leading)
        default:
            indicator.style = .line
            indicator.frame = NSRect(x: r.minX - 8, y: r.maxY + 2, width: r.width + 16, height: 10)
        }
        indicator.isHidden = false
        indicator.needsDisplay = true
    }

    /// The half of a block's row a block dropped beside it will take.
    private static func besideArea(_ r: NSRect, leading: Bool) -> NSRect {
        let w = r.width * 0.48
        return NSRect(x: leading ? r.minX - 6 : r.maxX - w + 6, y: r.minY - 6, width: w, height: max(r.height + 12, 44))
    }

    /// A spot a dragged block can go: `hit` is where the pointer picks it, `shape` its
    /// outline for the whole drag, `active` what shows once it's picked.
    struct DropZone {
        let target: DropTarget
        let hit: NSRect
        let shape: NSRect
        let active: NSRect
        let style: DropIndicatorView.Style
    }

    /// The spots on screen where dropping `dragging` would change the note, most
    /// specific first: blank parts of columns, the space below the last block, the
    /// gaps between blocks, and the sides of full-width blocks.
    func dropZones(dragging: LayoutGroup) -> [DropZone] {
        guard let container = textView.textContainer else { return [] }
        let model = layoutModel
        let text = storage.string as NSString
        let gutter = layoutManager.gutter
        let page = NSRect(x: textView.textContainerOrigin.x + gutter, y: 0, width: container.size.width - gutter * 2, height: 0)
        let frames = visibleGroupFrames()
        func frame(_ g: LayoutGroup) -> NSRect? { frames.first { $0.group === g }?.rect }

        var columnZones: [DropZone] = [], endZones: [DropZone] = [], gapZones: [DropZone] = [], sideZones: [DropZone] = []
        func add(_ target: DropTarget, to list: inout [DropZone], hit: NSRect, shape: NSRect, active: NSRect? = nil, style: DropIndicatorView.Style) {
            guard let edit = model.move(dragging, to: target), edit.text != text.substring(with: edit.range) else { return }
            list.append(DropZone(target: target, hit: hit, shape: shape, active: active ?? shape, style: style))
        }
        func line(at y: CGFloat) -> NSRect { NSRect(x: page.minX - 8, y: round(y) - 5, width: page.width + 16, height: 10) }

        // Top-level items on screen, at the page's full width.
        var shown: [(index: Int, rect: NSRect)] = []
        for (i, item) in model.items.enumerated() {
            let rects: [NSRect]
            switch item {
            case let .group(g): rects = frame(g).map { [$0] } ?? []
            case let .region(r): rects = columnFrames(of: r)
            }
            guard let first = rects.first else { continue }
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            shown.append((i, NSRect(x: page.minX, y: union.minY, width: page.width, height: union.height)))
        }

        for (k, entry) in shown.enumerated() {
            let rect = entry.rect
            switch model.items[entry.index] {
            case let .group(g):
                if entry.index == 0 {
                    add(.before(g), to: &gapZones, hit: NSRect(x: page.minX - gutter, y: rect.minY - 28, width: page.width + gutter * 2, height: 34),
                        shape: line(at: rect.minY - 10), style: .line)
                }
                // Beside it: a slim outline in the margin, growing to the half it would take.
                let edge = min(rect.width * 0.22, 130)
                let tall = max(rect.height + 12, 44)
                for leading in [true, false] {
                    let hit = leading ? NSRect(x: rect.minX - gutter, y: rect.minY, width: gutter + edge, height: rect.height)
                                      : NSRect(x: rect.maxX - edge, y: rect.minY, width: edge + gutter, height: rect.height)
                    let tab = NSRect(x: leading ? rect.minX - 30 : rect.maxX + 10, y: rect.minY - 6, width: 20, height: tall)
                    add(.beside(g, leading: leading), to: &sideZones, hit: hit, shape: tab, active: Self.besideArea(rect, leading: leading), style: .area)
                }
            case let .region(r):
                // The blank foot of each column, or a whole empty column.
                let cols = columnFrames(of: r)
                for (c, col) in cols.enumerated() where c < r.columns.count {
                    let bottom = r.columns[c].groups.compactMap(frame).map(\.maxY).max().map { $0 + 10 } ?? col.minY
                    let blank = NSRect(x: col.minX - 6, y: bottom, width: col.width + 12, height: max(rect.maxY - bottom, r.columns[c].groups.isEmpty ? 44 : 0))
                    guard blank.height >= 28 else { continue }
                    add(.column(r, c), to: &columnZones, hit: blank, shape: blank, style: .area)
                }
            }
            if k + 1 < shown.count, shown[k + 1].index == entry.index + 1 {
                let next = shown[k + 1].rect
                let target: DropTarget
                switch (model.items[entry.index], model.items[entry.index + 1]) {
                case let (_, .group(g)): target = .before(g)
                case let (.group(g), _): target = .after(g)
                case let (.region(r), _): target = .below(r)
                }
                add(target, to: &gapZones, hit: NSRect(x: page.minX - gutter, y: rect.maxY - 6, width: page.width + gutter * 2, height: next.minY - rect.maxY + 12),
                    shape: line(at: (rect.maxY + next.minY) / 2), style: .line)
            }
        }

        // The blank page below the last block: full width in the middle, or a column on
        // either side with the other left empty.
        if let last = shown.last, last.index == model.items.count - 1 {
            let top = last.rect.maxY + 16
            let height = min(max(textView.visibleRect.maxY - 16 - top, 72), 180)
            let w = floor((page.width + 12 - 16) / 3)
            for (n, leading) in [Bool?.some(true), nil, .some(false)].enumerated() {
                let r = NSRect(x: page.minX - 6 + CGFloat(n) * (w + 8), y: top, width: w, height: height)
                let hit = NSRect(x: n == 0 ? r.minX - gutter : r.minX - 4, y: top - 6, width: r.width + (n == 1 ? 8 : gutter + 4), height: height + 400)
                add(.end(leading: leading), to: &endZones, hit: hit, shape: r, style: .area)
            }
        }
        return columnZones + endZones + gapZones + sideZones
    }

    /// Each column of a side-by-side region as laid out (text view coordinates), from
    /// its lines: an empty column has a blank one to write in.
    func columnFrames(of region: LayoutRegion) -> [NSRect] {
        guard region.range.location != NSNotFound, NSMaxRange(region.range) <= storage.length else { return [] }
        let origin = textView.textContainerOrigin
        var frames: [Int: NSRect] = [:]
        let glyphs = layoutManager.glyphRange(forCharacterRange: region.range, actualCharacterRange: nil)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { frag, used, _, lineGlyphs, _ in
            let char = self.layoutManager.characterIndexForGlyph(at: lineGlyphs.location)
            guard let style = self.storage.attribute(.paragraphStyle, at: char, effectiveRange: nil) as? NSParagraphStyle,
                  let cell = style.textBlocks.first as? NSTextTableBlock else { return }
            let r = NSRect(x: frag.minX + origin.x, y: frag.minY + origin.y, width: frag.width, height: max(used.maxY - frag.minY, 1))
            frames[cell.startingColumn] = frames[cell.startingColumn].map { $0.union(r) } ?? r
        }
        return frames.keys.sorted().compactMap { frames[$0] }
    }

    /// Moves a block, as one undo step. Dropping it where it already is changes nothing.
    func moveBlock(_ group: LayoutGroup, to target: DropTarget) {
        guard let edit = layoutModel.move(group, to: target),
              edit.text != (storage.string as NSString).substring(with: edit.range) else { return }
        let isTable = styler.blocks.contains { block in
            if case .table = block.kind { return NSLocationInRange(block.range.location, group.range) }
            return false
        }
        replaceKeepingScroll(edit.range, with: edit.text, select: NSRange(location: edit.range.location + edit.movedOffset, length: 0),
                             actionName: isTable ? "Move Table" : "Move Block")
    }
}
