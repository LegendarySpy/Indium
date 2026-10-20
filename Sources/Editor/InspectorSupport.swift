import AppKit

/// What the inspector needs from the editor: what the caret is in, and a way to change
/// the note that undoes in one step.
extension EditorController {
    /// The part of the note the inspector is about.
    enum InspectorContext: Equatable {
        case note
        /// The table whose block starts at `location`.
        case table(location: Int)
        /// The chart or graph block starting at `location`.
        case chart(location: Int)
    }

    var inspectorContext: InspectorContext {
        if let location = styler.editingTableLocation { return .table(location: location) }
        if let location = styler.selectedChart, location < storage.length { return .chart(location: location) }
        let caret = textView.selectedRange().location
        if let i = styler.blockIndex(containing: caret) {
            switch styler.blocks[i].kind {
            case .table: return .table(location: styler.blocks[i].range.location)
            case let .code(language) where ChartModel.handles(language): return .chart(location: styler.blocks[i].range.location)
            case .tableFormulas where i > 0:
                if case .table = styler.blocks[i - 1].kind { return .table(location: styler.blocks[i - 1].range.location) }
            default: break
            }
        }
        return .note
    }

    /// Changes the note's frontmatter with `edit` (one of `VariableEditing`'s functions)
    /// and recalculates the tables whose formulas read a variable that changed, all as
    /// one undo step named `actionName`. False when the edit was refused.
    @discardableResult
    func changeVariables(actionName: String, _ edit: (String) -> String?) -> Bool {
        guard textView.isEditable else { return false }
        // Pending table results and frontmatter typing go in first, and a table being
        // edited closes, so nothing it holds goes stale under it.
        finishPendingEdits()
        if tableEditor != nil { endTableEditing() }
        let old = storage.string
        guard var new = edit(old), new != old else { return false }
        let before = NoteVariables.parse(noteText: old), after = NoteVariables.parse(noteText: new)
        let changed = Set(before.values.keys).union(after.values.keys).filter { before.values[$0]?.formatted() != after.values[$0]?.formatted() }
        if !changed.isEmpty { new = Self.recalculatingTables(in: new, reading: changed) }
        return replaceDifference(from: old, to: new, actionName: actionName)
    }

    /// Rewrites the lines between the fences of the chart block at `location` with `edit`,
    /// as one undo step named `actionName`.
    @discardableResult
    func changeChart(at location: Int, actionName: String, _ edit: (String) -> String) -> Bool {
        guard textView.isEditable, let i = styler.blockIndex(containing: location), case .code = styler.blocks[i].kind else { return false }
        let block = styler.blocks[i].range
        let first = ns.lineRange(for: NSRange(location: block.location, length: 0))
        var bodyEnd = NSMaxRange(block)
        // Up to the closing fence, if there is one.
        let lastLine = ns.lineRange(for: NSRange(location: max(block.location, NSMaxRange(block) - 1), length: 0))
        let fence = ns.substring(with: first).trimmingCharacters(in: .whitespaces).first
        if lastLine.location > first.location, ns.substring(with: lastLine).trimmingCharacters(in: .whitespaces).first == fence {
            bodyEnd = lastLine.location
        }
        let bodyRange = NSRange(location: NSMaxRange(first), length: max(0, bodyEnd - NSMaxRange(first)))
        var body = ns.substring(with: bodyRange)
        let trailingNewline = body.hasSuffix("\n")
        if trailingNewline { body.removeLast() }
        var new = edit(body)
        if trailingNewline || bodyRange.length == 0 { new += "\n" }
        let old = storage.string
        return replaceDifference(from: old, to: (old as NSString).replacingCharacters(in: bodyRange, with: new), actionName: actionName)
    }

    /// Replaces only the part of the note that differs between `old` and `new`, so the
    /// caret and the rest of the page stay where they are.
    @discardableResult
    func replaceDifference(from old: String, to new: String, actionName: String) -> Bool {
        let a = old as NSString, b = new as NSString
        var start = 0
        let shorter = min(a.length, b.length)
        while start < shorter, a.character(at: start) == b.character(at: start) { start += 1 }
        var end = 0
        while end < shorter - start, a.character(at: a.length - 1 - end) == b.character(at: b.length - 1 - end) { end += 1 }
        let range = NSRange(location: start, length: a.length - start - end)
        let replacement = b.substring(with: NSRange(location: start, length: b.length - start - end))
        guard range.length > 0 || !replacement.isEmpty else { return false }
        // Its own undo step, never merged into typing just before or after it.
        textView.breakUndoCoalescing()
        defer { textView.breakUndoCoalescing() }
        return replace(range, with: replacement, actionName: actionName)
    }

    /// `text` with every table whose formulas read one of `names` recalculated, laid
    /// out as the table editor writes tables. Tables with a problem stay as they were.
    static func recalculatingTables(in text: String, reading names: Set<String>) -> String {
        let ns = text as NSString
        let out = NSMutableString(string: text)
        // Back to front, so earlier ranges stay valid as later tables change length.
        for block in MarkdownScanner.scan(ns).reversed() {
            guard case .table = block.kind, let formulas = TableFormulas.trailingFormulaRange(in: ns, tableRange: block.range) else { continue }
            let lines = ns.substring(with: formulas).components(separatedBy: .newlines).filter { TableFormulas.isFormulaLine($0) }
            guard lines.contains(where: { !TableFormulaUI.names(in: $0).isDisjoint(with: names) }) else { continue }
            var range = block.range
            while range.length > 0, [0x0A, 0x0D].contains(ns.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
            let table = ns.substring(with: range)
            let recalculated = TableFormulaUI.recalculate(tableMarkdown: table, formulaLines: lines, noteText: text)
            if recalculated != table { out.replaceCharacters(in: range, with: recalculated) }
        }
        return out as String
    }
}
