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

    var group: LayoutGroup {
        switch self {
        case let .before(g), let .after(g), let .beside(g, _): g
        }
    }
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
        let anchor = target.group
        guard anchor !== dragged, let src = itemIndex(of: dragged), let dst = itemIndex(of: anchor) else { return nil }
        let lo = min(src, dst), hi = max(src, dst)
        var slice = Array(items[lo...hi])

        // 1. Take the dragged block out of wherever it lives.
        slice.removeAll { if case let .group(g) = $0 { return g === dragged }; return false }
        for case let .region(r) in slice {
            for column in r.columns { column.groups.removeAll { $0 === dragged } }
        }

        // 2. Tidy regions: empty columns go; a single remaining column becomes full width.
        func normalize() {
            var out: [LayoutItem] = []
            for item in slice {
                guard case let .region(r) = item else { out.append(item); continue }
                let before = r.columns.count
                r.columns.removeAll { $0.groups.isEmpty }
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

        // 3. Put it back next to, or beside, the anchor.
        var placed = false
        for (k, item) in slice.enumerated() where !placed {
            switch item {
            case let .group(g) where g === anchor:
                switch target {
                case .before: slice.insert(.group(dragged), at: k)
                case .after: slice.insert(.group(dragged), at: k + 1)
                case let .beside(_, leading):
                    let columns = leading ? [LayoutColumn([dragged]), LayoutColumn([anchor])] : [LayoutColumn([anchor]), LayoutColumn([dragged])]
                    slice[k] = .region(LayoutRegion(ratios: [], columns: columns))
                }
                placed = true
            case let .region(r):
                for (c, column) in r.columns.enumerated() {
                    guard let j = column.groups.firstIndex(where: { $0 === anchor }) else { continue }
                    switch target {
                    case .before: column.groups.insert(dragged, at: j)
                    case .after: column.groups.insert(dragged, at: j + 1)
                    case let .beside(_, leading):
                        if r.columns.count < 3 {
                            r.columns.insert(LayoutColumn([dragged]), at: leading ? c : c + 1)
                            r.ratios = []
                        } else {
                            column.groups.insert(dragged, at: leading ? j : j + 1)
                        }
                    }
                    placed = true
                    break
                }
            default:
                break
            }
        }
        guard placed else { return nil }

        // 4. Serialize the rewritten span.
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

/// The grip that appears beside a block on hover.
final class BlockHandleView: NSView {
    var onDrag: ((NSEvent) -> Void)?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag to move · drop at a side to place beside"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Move block")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

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
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        (hovering ? Palette.secondaryText : Palette.tertiaryText).setFill()
        let d: CGFloat = 3
        for row in 0..<3 {
            for col in 0..<2 {
                let x = bounds.midX - 3.5 + CGFloat(col) * 7 - d / 2
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
