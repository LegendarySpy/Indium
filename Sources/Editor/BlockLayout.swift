import AppKit

/// A run of non-blank lines that moves as a unit: a paragraph, list, table, code or
/// math block, image, heading.
final class LayoutGroup {
    let range: NSRange
    let text: String
    init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

final class LayoutColumn {
    var groups: [LayoutGroup]
    init(_ groups: [LayoutGroup] = []) { self.groups = groups }
}

/// A `<!-- columns -->` … `<!-- /columns -->` region.
final class LayoutRegion {
    var ratios: [Int]
    var columns: [LayoutColumn]
    var range: NSRange
    init(ratios: [Int], columns: [LayoutColumn], range: NSRange = NSRange(location: NSNotFound, length: 0)) {
        self.ratios = ratios
        self.columns = columns
        self.range = range
    }
}

enum LayoutItem {
    case group(LayoutGroup)
    case region(LayoutRegion)

    var range: NSRange {
        switch self {
        case let .group(g): g.range
        case let .region(r): r.range
        }
    }
}

enum DropTarget {
    case before(LayoutGroup)
    case after(LayoutGroup)
    case beside(LayoutGroup, leading: Bool)
    /// At the foot of a column of a side-by-side region, an empty one included.
    case column(LayoutRegion, Int)
    /// Just after a side-by-side region, at full width.
    case below(LayoutRegion)
    /// At the end of the note: full width, or in a column on one side with the other
    /// left empty to write in.
    case end(leading: Bool?)
}

/// The document's top-level arrangement, rebuilt from the scanned blocks.
/// Moves rewrite only the span of Markdown between the source and destination.
struct LayoutModel {
    var items: [LayoutItem]

    static func build(text: NSString, blocks: [MDBlock], validRegionStarts: Set<Int>) -> LayoutModel {
        var items: [LayoutItem] = []
        var pending: [Int] = []
        var region: LayoutRegion?
        var regionStart = 0

        func contentEnd(_ block: MDBlock) -> Int {
            var end = NSMaxRange(block.range)
            while end > block.range.location {
                let c = text.character(at: end - 1)
                if c == 0x0A || c == 0x0D { end -= 1 } else { break }
            }
            return end
        }

        func flush() {
            guard let first = pending.first, let last = pending.last else { return }
            let start = blocks[first].range.location
            let range = NSRange(location: start, length: contentEnd(blocks[last]) - start)
            let group = LayoutGroup(range: range, text: text.substring(with: range))
            if let region { region.columns[region.columns.count - 1].groups.append(group) }
            else { items.append(.group(group)) }
            pending = []
        }

        for (i, block) in blocks.enumerated() {
            switch block.kind {
            case .blank:
                flush()
            case let .columnMarker(.start(ratios)) where region == nil && validRegionStarts.contains(i):
                flush()
                region = LayoutRegion(ratios: ratios, columns: [LayoutColumn()])
                regionStart = block.range.location
            case .columnMarker(.split) where region != nil:
                flush()
                region?.columns.append(LayoutColumn())
            case .columnMarker(.end) where region != nil:
                flush()
                region!.range = NSRange(location: regionStart, length: contentEnd(block) - regionStart)
                items.append(.region(region!))
                region = nil
            default:
                pending.append(i)
            }
        }
        flush()
        return LayoutModel(items: items)
    }

    var groups: [(group: LayoutGroup, region: LayoutRegion?)] {
        items.flatMap { item -> [(LayoutGroup, LayoutRegion?)] in
            switch item {
            case let .group(g): [(g, nil)]
            case let .region(r): r.columns.flatMap { $0.groups.map { ($0, r) } }
            }
        }
    }

    func itemIndex(of group: LayoutGroup) -> Int? {
        items.firstIndex { item in
            switch item {
            case let .group(g): g === group
            case let .region(r): r.columns.contains { $0.groups.contains { $0 === group } }
            }
        }
    }

    func group(containing location: Int) -> LayoutGroup? {
        groups.first { NSLocationInRange(location, $0.group.range) || NSMaxRange($0.group.range) == location }?.group
    }

    static func serialize(_ item: LayoutItem) -> String {
        switch item {
        case let .group(g):
            return g.text
        case let .region(r):
            let equal = r.ratios.count != r.columns.count || Set(r.ratios).count <= 1
            let header = equal ? "<!-- columns -->" : "<!-- columns \(r.ratios.map(String.init).joined(separator: "/")) -->"
            let body = r.columns.map { $0.groups.map(\.text).joined(separator: "\n\n") }.joined(separator: "\n<!-- column -->\n")
            return header + "\n" + body + "\n<!-- /columns -->"
        }
    }

    /// Computes the text edit for moving `dragged` to `target`.
    /// Returns the range to replace, the replacement, and where the moved block lands in it.
    func move(_ dragged: LayoutGroup, to target: DropTarget) -> (range: NSRange, text: String, movedOffset: Int)? {
        guard let src = itemIndex(of: dragged) else { return nil }
        func regionIndex(_ r: LayoutRegion) -> Int? {
            items.firstIndex { if case let .region(x) = $0 { return x === r }; return false }
        }
        let dst: Int
        switch target {
        case let .before(g), let .after(g), let .beside(g, _):
            guard g !== dragged, let i = itemIndex(of: g) else { return nil }
            dst = i
        case let .column(r, _), let .below(r):
            guard let i = regionIndex(r) else { return nil }
            dst = i
        case .end:
            dst = items.count - 1
        }
        let lo = min(src, dst), hi = max(src, dst)
        // Regions are copied, so working out a drop (to show only the spots that change
        // something) leaves the model as it was.
        var slice: [LayoutItem] = items[lo...hi].map { item in
            guard case let .region(r) = item else { return item }
            return .region(LayoutRegion(ratios: r.ratios, columns: r.columns.map { LayoutColumn($0.groups) }, range: r.range))
        }
        var targetColumn: LayoutColumn?
        if case let .column(r, c) = target {
            for case let .region(x) in slice where x.range == r.range && c < x.columns.count { targetColumn = x.columns[c] }
        }

        // Take the dragged block out of wherever it lives.
        slice.removeAll { if case let .group(g) = $0 { return g === dragged }; return false }
        var emptied: [LayoutColumn] = []
        for case let .region(r) in slice {
            for column in r.columns where column.groups.contains(where: { $0 === dragged }) {
                column.groups.removeAll { $0 === dragged }
                if column.groups.isEmpty { emptied.append(column) }
            }
        }

        // Columns it leaves empty go (one left empty to write in stays); a single
        // remaining column becomes full width.
        func normalize() {
            var out: [LayoutItem] = []
            for item in slice {
                guard case let .region(r) = item else { out.append(item); continue }
                let before = r.columns.count
                r.columns.removeAll { c in emptied.contains { $0 === c } }
                if r.columns.count != before { r.ratios = [] }
                switch r.columns.count {
                case 0: break
                case 1: out += r.columns[0].groups.map { .group($0) }
                default: out.append(item)
                }
            }
            slice = out
        }
        normalize()

        // Put it back next to, or beside, the anchor.
        var placed = false
        switch target {
        case let .end(leading):
            if let leading {
                let columns = leading ? [LayoutColumn([dragged]), LayoutColumn()] : [LayoutColumn(), LayoutColumn([dragged])]
                slice.append(.region(LayoutRegion(ratios: [], columns: columns)))
            } else {
                slice.append(.group(dragged))
            }
            placed = true
        case let .below(region):
            if let k = slice.firstIndex(where: { if case let .region(x) = $0 { return x.range == region.range }; return false }) {
                slice.insert(.group(dragged), at: k + 1)
                placed = true
            }
        case .column:
            for case let .region(r) in slice {
                guard let column = targetColumn, r.columns.contains(where: { $0 === column }) else { continue }
                column.groups.append(dragged)
                placed = true
            }
        case let .before(anchor), let .after(anchor), let .beside(anchor, _):
            for (k, item) in slice.enumerated() where !placed {
                switch item {
                case let .group(g) where g === anchor:
                    switch target {
                    case .before: slice.insert(.group(dragged), at: k)
                    case let .beside(_, leading):
                        let columns = leading ? [LayoutColumn([dragged]), LayoutColumn([anchor])] : [LayoutColumn([anchor]), LayoutColumn([dragged])]
                        slice[k] = .region(LayoutRegion(ratios: [], columns: columns))
                    default: slice.insert(.group(dragged), at: k + 1)
                    }
                    placed = true
                case let .region(r):
                    for (c, column) in r.columns.enumerated() {
                        guard let j = column.groups.firstIndex(where: { $0 === anchor }) else { continue }
                        switch target {
                        case .before: column.groups.insert(dragged, at: j)
                        case let .beside(_, leading):
                            if r.columns.count < 3 {
                                r.columns.insert(LayoutColumn([dragged]), at: leading ? c : c + 1)
                                r.ratios = []
                            } else {
                                column.groups.insert(dragged, at: leading ? j : j + 1)
                            }
                        default: column.groups.insert(dragged, at: j + 1)
                        }
                        placed = true
                        break
                    }
                default:
                    break
                }
            }
        }
        guard placed else { return nil }

        var text = ""
        var movedOffset = 0
        for (k, item) in slice.enumerated() {
            if k > 0 { text += "\n\n" }
            let piece = LayoutModel.serialize(item)
            if let r = piece.range(of: dragged.text) {
                movedOffset = (text as NSString).length + (String(piece[..<r.lowerBound]) as NSString).length
            }
            text += piece
        }
        let start = items[lo].range.location
        let range = NSRange(location: start, length: NSMaxRange(items[hi].range) - start)
        return (range, text, movedOffset)
    }

    /// Puts consecutive top-level blocks in a column on one side, with the blocks that
    /// follow (or, at the end of a note, precede) flowing in the other column until the
    /// two sides are about the same height.
    func placeAside(_ selected: [LayoutGroup], onRight: Bool, height: (LayoutGroup) -> CGFloat) -> (range: NSRange, text: String, movedOffset: Int)? {
        let indices = selected.compactMap { g in items.firstIndex { if case let .group(x) = $0 { return x === g }; return false } }
        guard let a = indices.min(), let b = indices.max(), indices.count == b - a + 1 else { return nil }
        let chosen = items[a...b].compactMap { if case let .group(g) = $0 { return g }; return nil }
        guard chosen.count == b - a + 1 else { return nil }
        let target = chosen.reduce(0) { $0 + height($1) }

        func collect(_ range: [Int]) -> [LayoutGroup] {
            var out: [LayoutGroup] = []
            var total: CGFloat = 0
            for k in range {
                guard case let .group(g) = items[k] else { break }
                out.append(g)
                total += height(g)
                if total >= target * 0.9 { break }
            }
            return out
        }
        var companion = collect(Array((b + 1)..<items.count))
        var lo = a, hi = b
        if companion.isEmpty {
            companion = collect(Array((0..<a).reversed())).reversed()
            lo = a - companion.count
        } else {
            hi = b + companion.count
        }
        guard !companion.isEmpty else { return nil }

        let columns = onRight ? [LayoutColumn(companion), LayoutColumn(chosen)] : [LayoutColumn(chosen), LayoutColumn(companion)]
        let region = LayoutRegion(ratios: [], columns: columns)
        let text = LayoutModel.serialize(.region(region))
        let start = items[lo].range.location
        let range = NSRange(location: start, length: NSMaxRange(items[hi].range) - start)
        let movedOffset = (text as NSString).range(of: chosen[0].text).location
        return (range, text, movedOffset == NSNotFound ? 0 : movedOffset)
    }

    /// Swaps the columns of the region containing `group`.
    func swapColumns(containing group: LayoutGroup) -> (range: NSRange, text: String)? {
        guard let i = itemIndex(of: group), case let .region(r) = items[i] else { return nil }
        let swapped = LayoutRegion(ratios: r.ratios.reversed(), columns: r.columns.reversed())
        return (r.range, LayoutModel.serialize(.region(swapped)))
    }

    /// Unwraps the region containing `group` back to full width.
    func unwrapRegion(containing group: LayoutGroup) -> (range: NSRange, text: String)? {
        guard let i = itemIndex(of: group), case let .region(r) = items[i] else { return nil }
        let text = r.columns.flatMap(\.groups).map(\.text).joined(separator: "\n\n")
        return (r.range, text)
    }
}

// MARK: - Views

/// The grip that appears beside a table's header on hover.
final class BlockHandleView: NSView {
    static let size = NSSize(width: 18, height: 24)
    var onDrag: ((NSEvent) -> Void)?
    /// Set while its block is being dragged, so hovering elsewhere doesn't take it away.
    var dragging = false
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag to move the table · drop at a side to place it beside"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Move table")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onDrag?(event) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Palette.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        (hovering ? Palette.secondaryText : Palette.tertiaryText).setFill()
        let d: CGFloat = 3
        for row in 0..<3 {
            for col in 0..<2 {
                let x = bounds.midX - 3 + CGFloat(col) * 6 - d / 2
                let y = bounds.midY - 6 + CGFloat(row) * 6 - d / 2
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
            }
        }
    }
}

/// Shows where a dragged block will land: a line between blocks, or a half-width
/// area when it will sit beside another block.
final class DropIndicatorView: NSView {
    enum Style { case line, area }
    var style: Style = .line { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        switch style {
        case .line:
            accent.setFill()
            let line = NSRect(x: 4, y: bounds.midY - 1.5, width: bounds.width - 8, height: 3)
            NSBezierPath(roundedRect: line, xRadius: 1.5, yRadius: 1.5).fill()
            for x in [line.minX, line.maxX] {
                NSBezierPath(ovalIn: NSRect(x: x - 4, y: bounds.midY - 4, width: 8, height: 8)).fill()
            }
        case .area:
            let r = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.1).setFill()
            path.fill()
            accent.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

/// Outlines every spot a dragged block can go, faintly, so blank space reads as a
/// place to drop too. The one under the pointer is left to `DropIndicatorView`.
final class DropZonesView: NSView {
    var zones: [EditorController.DropZone] = [] { didSet { needsDisplay = true } }
    var active: NSRect? { didSet { if active != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for zone in zones where zone.shape.intersects(dirtyRect) && zone.shape != active {
            switch zone.style {
            case .line:
                let line = NSBezierPath()
                line.move(to: NSPoint(x: zone.shape.minX + 4, y: zone.shape.midY))
                line.line(to: NSPoint(x: zone.shape.maxX - 4, y: zone.shape.midY))
                line.lineWidth = 1.5
                line.lineCapStyle = .round
                line.setLineDash([6, 4], count: 2, phase: 0)
                accent.withAlphaComponent(0.4).setStroke()
                line.stroke()
            case .area:
                let path = NSBezierPath(roundedRect: zone.shape.insetBy(dx: 1, dy: 1), xRadius: min(10, zone.shape.width / 2), yRadius: min(10, zone.shape.width / 2))
                accent.withAlphaComponent(0.04).setFill()
                path.fill()
                accent.withAlphaComponent(0.4).setStroke()
                path.lineWidth = 1.5
                path.setLineDash([6, 4], count: 2, phase: 0)
                path.stroke()
            }
        }
    }
}
