import AppKit

/// Putting charts in a note: Make Chart on a table, `/chart` and `/graph`. A chart of a
/// table names it the way Obsidian's Charts plugin does, with a `^id` line under the
/// table and `id:` in the chart, so the same chart draws in Obsidian with the plugin.
extension EditorController {
    /// A chart to fill in, for each type the slash commands offer: bars and pies of labelled
    /// values as the Charts plugin writes them, lines and scatter plots of points. Every
    /// value in them is changed in the inspector.
    static func chartTemplate(_ type: String) -> String {
        switch type {
        case "line": "```chart\ntype: line\npoints: (0, 1), (1, 3), (2, 4), (3, 7)\n```\n"
        case "scatter": "```chart\ntype: scatter\npoints: (1, 2.1), (2, 3.9), (3, 6.2), (4, 7.8)\nbestFit: true\n```\n"
        case "pie": "```chart\ntype: pie\nlabels: [A, B, C]\nseries:\n  - title: Share\n    data: [50, 30, 20]\n```\n"
        default: "```chart\ntype: bar\nlabels: [A, B, C]\nseries:\n  - title: Values\n    data: [3, 5, 2]\n```\n"
        }
    }
    static let graphTemplate = "```desmos-graph\nleft=-10; right=10; bottom=-10; top=10\n---\ny=x^2\n```\n"

    /// The table a chart typed at `location` would be about: the nearest block above,
    /// past blank lines, the table's formulas and its `^id`.
    func tableAbove(_ location: Int) -> Int? {
        let blocks = styler.blocks
        guard var i = styler.blockIndex(containing: location) else { return nil }
        i -= 1
        while i >= 0 {
            switch blocks[i].kind {
            case .table: return i
            case .blank, .tableFormulas: i -= 1
            case .paragraph where MarkdownStyler.isBlockID(ns.substring(with: blocks[i].range)): i -= 1
            default: return nil
            }
        }
        return nil
    }

    /// Make Chart from the table being edited: a line chart of it right below it.
    func makeChartForEditedTable() {
        guard let location = styler.editingTableLocation else { return }
        endTableEditing()
        guard let i = styler.blockIndex(containing: location), case .table = styler.blocks[i].kind else { return }
        insertChart(forTable: i, type: nil, replacing: nil)
    }

    /// A chart of the table at block `index`: written over `replacing` (a typed `/chart`),
    /// or below the table. The table gets a `^id` line if it hasn't one. One undo step.
    /// Without a `type`, bars for labels that are words and a line for numbers.
    func insertChart(forTable index: Int, type: String?, replacing: NSRange?) {
        let blocks = styler.blocks
        var words = false
        if case let .table(spec) = blocks[index].kind {
            let labels = spec.rows.dropFirst().map { TableSpec.unescapeCell($0.first?.text ?? "").trimmingCharacters(in: .whitespaces) }
            words = labels.contains { !$0.isEmpty && Quantity.parse($0) == nil }
        }
        let type = type ?? (words ? "bar" : "line")
        // Past the table's formulas: where its ^id goes, or already is.
        var end = index
        if end + 1 < blocks.count, blocks[end + 1].kind == .tableFormulas { end += 1 }
        var id: String?
        var k = end + 1
        while k < blocks.count, blocks[k].kind == .blank { k += 1 }
        if k < blocks.count, case .paragraph = blocks[k].kind {
            let line = ns.substring(with: blocks[k].range).trimmingCharacters(in: .whitespacesAndNewlines)
            if MarkdownStyler.isBlockID(line) { id = String(line.dropFirst()); end = k }
        }
        let afterTable = NSMaxRange(blocks[end].range)
        let needsBreak = afterTable > 0 && ns.character(at: afterTable - 1) != 0x0A
        var idText = ""
        if id == nil {
            let taken = Set(ns.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
            var name = "table"
            var n = 2
            while taken.contains("^" + name) { name = "table-\(n)"; n += 1 }
            id = name
            idText = (needsBreak ? "\n" : "") + "\n^\(name)\n"
        }
        let chart = "```chart\ntype: \(type)\nid: \(id!)\n```\n"

        guard let undo = textView.undoManager else { return }
        undo.beginUndoGrouping()
        defer {
            undo.endUndoGrouping()
            undo.setActionName("Chart")
        }
        if let replacing {
            // The later edit first, so the earlier one's offsets still hold.
            let lineStart = ns.lineRange(for: NSRange(location: replacing.location, length: 0)).location
            let before = ns.substring(with: NSRange(location: lineStart, length: replacing.location - lineStart))
            let lead = before.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
            let start = lead.isEmpty ? lineStart : replacing.location
            let range = NSRange(location: start, length: NSMaxRange(replacing) - start)
            replace(range, with: lead + chart)
            if !idText.isEmpty { replace(NSRange(location: afterTable, length: 0), with: idText) }
            let shift = (idText as NSString).length
            selectChart(at: start + shift + (lead as NSString).length)
        } else {
            let text = idText.isEmpty ? (needsBreak ? "\n\n" : "\n") + chart : idText + "\n" + chart
            replace(NSRange(location: afterTable, length: 0), with: text)
            selectChart(at: afterTable + (text as NSString).length - (chart as NSString).length)
        }
        onChartInserted?()
    }

    // MARK: Selecting a chart

    /// The chart block holding `location` (its first line's start through its last character).
    func chartBlock(containing location: Int) -> MDBlock? {
        guard let i = styler.blockIndex(containing: location), case let .code(language) = styler.blocks[i].kind,
              ChartModel.handles(language) else { return nil }
        return styler.blocks[i]
    }

    /// Where the caret sits while a chart is selected: the end of its last line.
    private func chartEnd(_ block: MDBlock) -> Int {
        var end = NSMaxRange(block.range)
        while end > block.range.location, [0x0A, 0x0D].contains(ns.character(at: end - 1)) { end -= 1 }
        return end
    }

    /// Selects the chart whose block starts at `location`, as an object: a ring around it,
    /// the caret hidden at its end, and the inspector showing it.
    func selectChart(at location: Int) {
        guard let block = chartBlock(containing: location) else { return }
        textView.window?.makeFirstResponder(textView)
        let previous = styler.selectedChart
        let source = styler.chartSourceShown
        styler.selectedChart = block.range.location
        styler.chartSourceShown = nil
        changingChartSelection = true
        textView.setSelectedRange(NSRange(location: chartEnd(block), length: 0))
        changingChartSelection = false
        lastSelection = [textView.selectedRange()]
        for loc in Set([previous, source, block.range.location].compactMap { $0 }) where loc < storage.length {
            styler.restyleBlock(at: loc, in: storage)
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: loc, length: 1), actualCharacterRange: nil)
        }
        textView.needsDisplay = true
        textView.updateInsertionPointStateAndRestartTimer(false)
        // All of it in view, where there's room.
        if let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let glyphs = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += textView.textContainerOrigin.y
            textView.scrollToVisible(rect.insetBy(dx: 0, dy: -12))
        }
        onContextChange?()
        onChartSelected?()
    }

    /// No chart selected any more (it stays where it is).
    func clearChartSelection() {
        guard let loc = styler.selectedChart else { return }
        styler.selectedChart = nil
        if loc < storage.length { styler.restyleBlock(at: loc, in: storage) }
        textView.needsDisplay = true
    }

    /// Escape: the chart lets go, and the caret goes to the line after it.
    func deselectChart() -> Bool {
        guard styler.selectedChart != nil else { return false }
        leaveSelectedChart()
        return true
    }

    /// Before typing with a chart selected: the caret moves to a line of its own after the
    /// chart, so the keys never land in the chart's Markdown.
    func leaveSelectedChart() {
        guard let loc = styler.selectedChart, let block = chartBlock(containing: loc) else { return }
        clearChartSelection()
        changingChartSelection = true
        defer { changingChartSelection = false }
        let end = NSMaxRange(block.range)
        if end >= storage.length, !ns.substring(with: block.range).hasSuffix("\n") {
            replace(NSRange(location: storage.length, length: 0), with: "\n", select: NSRange(location: storage.length + 1, length: 0))
        } else if end < storage.length, ns.lineRange(for: NSRange(location: end, length: 0)).length > 1 {
            // Text right below: a new line between it and the chart.
            replace(NSRange(location: end, length: 0), with: "\n", select: NSRange(location: end, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: min(end, storage.length), length: 0))
        }
        lastSelection = [textView.selectedRange()]
    }

    /// Delete with a chart selected removes it, in one undo step.
    func deleteSelectedChart() -> Bool {
        guard let loc = styler.selectedChart, let block = chartBlock(containing: loc) else { return false }
        styler.selectedChart = nil
        replace(block.range, with: "", select: NSRange(location: block.range.location, length: 0), actionName: "Delete Chart")
        return true
    }

    /// Edit Markdown: the chart's source opens, the caret on its first line after the fence.
    func showChartSource(at location: Int) {
        guard let block = chartBlock(containing: location) else { return }
        styler.selectedChart = nil
        styler.chartSourceShown = block.range.location
        textView.window?.makeFirstResponder(textView)
        changingChartSelection = true
        let first = ns.lineRange(for: NSRange(location: block.range.location, length: 0))
        textView.setSelectedRange(NSRange(location: min(NSMaxRange(first), chartEnd(block)), length: 0))
        changingChartSelection = false
        lastSelection = [textView.selectedRange()]
        styler.restyleBlock(at: block.range.location, in: storage)
        layoutManager.invalidateLayout(forCharacterRange: block.range, actualCharacterRange: nil)
        textView.needsDisplay = true
        onContextChange?()
    }

    /// Keeps chart selection in step with the caret: arrowing onto a chart selects it,
    /// arrowing on past it lets go, and leaving an open source closes it. True when the
    /// caret was moved here (the selection change it causes does the rest).
    func chartSelectionFollowsCaret() -> Bool {
        let sel = textView.selectedRange()
        if let shown = styler.chartSourceShown {
            let block = chartBlock(containing: shown)
            if block == nil || !NSLocationInRange(sel.location, NSRange(location: block!.range.location, length: chartEnd(block!) - block!.range.location + 1)) {
                styler.chartSourceShown = nil
                if let block { styler.restyleBlock(at: block.range.location, in: storage) }
            }
        }
        if let selected = styler.selectedChart {
            guard let block = chartBlock(containing: selected) else { styler.selectedChart = nil; return false }
            if sel.length == 0, sel.location == chartEnd(block) { return false }
            clearChartSelection()
            // Arrowed back up from a selected chart: to the end of the line before it.
            if sel.length == 0, sel.location >= block.range.location, sel.location < chartEnd(block) {
                changingChartSelection = true
                textView.setSelectedRange(NSRange(location: max(0, block.range.location - 1), length: 0))
                changingChartSelection = false
                return false
            }
        }
        // The caret came onto a drawn chart: select it.
        if sel.length == 0, styler.chartSourceShown == nil, styler.config.syntax != .always, let block = chartBlock(containing: sel.location),
           sel.location >= block.range.location, sel.location <= chartEnd(block) {
            selectChart(at: block.range.location)
            return true
        }
        return false
    }
}
