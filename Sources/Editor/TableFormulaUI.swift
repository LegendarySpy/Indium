import AppKit

/// The editor's side of table formulas (Advanced Tables `<!-- TBLFM: … -->` lines, see
/// Sources/Formulas/README.md): the caption under a table, recalculating after an edit,
/// keeping references pointed at the same rows and columns when rows or columns are
/// inserted or deleted, and the Formula… popover.
enum TableFormulaUI {

    // MARK: Reading a table

    /// Header row first, delimiter left out: the grid `TableFormulas` works on.
    static func grid(of tableMarkdown: String) -> (grid: [[String]], spec: TableSpec)? {
        guard let block = MarkdownScanner.scan(tableMarkdown as NSString).first, case let .table(spec) = block.kind else { return nil }
        return (spec.rows.map { $0.map(\.text) }, spec)
    }

    /// The formula lines in `range` (the scanner's `.tableFormulas` block), without line breaks.
    static func lines(in text: NSString, range: NSRange) -> [String] {
        text.substring(with: range).components(separatedBy: .newlines).filter { TableFormulas.isFormulaLine($0) }
    }

    /// True when the first column holds row names ("Mass of water"), as in a transposed
    /// results table: row formulas then leave it out (`@4$2..@4$>`).
    static func hasLabelColumn(_ grid: [[String]]) -> Bool {
        let labels = grid.dropFirst().compactMap(\.first)
        return !labels.isEmpty && labels.allSatisfy { !$0.isEmpty && Quantity.parse($0) == nil }
    }

    // MARK: Recalculating

    /// The table with its formulas applied, laid out as the table editor writes tables.
    /// Unchanged (byte for byte) when nothing changes or any formula has a problem:
    /// application is atomic.
    static func recalculate(tableMarkdown: String, formulaLines: [String], noteText: String) -> String {
        guard !formulaLines.isEmpty, let (grid, spec) = grid(of: tableMarkdown) else { return tableMarkdown }
        let outcome = TableFormulas.evaluate(grid: grid, formulaLines: formulaLines, variables: NoteVariables.parse(noteText: noteText))
        guard outcome.succeeded, !outcome.changed.isEmpty, let header = outcome.grid.first else { return tableMarkdown }
        let indent = String(tableMarkdown.prefix { $0 == " " || $0 == "\t" })
        let markdown = TableSpec.markdown(header: header, body: Array(outcome.grid.dropFirst()), alignments: spec.alignments,
                                          dashes: spec.widthFractions != nil ? spec.dashes : nil)
        return indent.isEmpty ? markdown : markdown.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
    }

    /// The names a formula line could read as note variables.
    static func names(in formulaLine: String) -> Set<String> {
        guard let body = TableFormulas.formulaText(ofLine: formulaLine) else { return [] }
        let ns = body as NSString
        return Set(nameToken.matches(in: body, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }
    private static let nameToken = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_@$.])[A-Za-z_][A-Za-z0-9_]*"#)

    // MARK: Caption

    /// "ƒ 2 formulas" under a table, or what's wrong in red.
    static func caption(note: NSString, table: MDBlock, formulas: NSRange) -> CaptionDecoration {
        guard case let .table(spec) = table.kind else { return CaptionDecoration(text: "", isError: false) }
        let grid = spec.rows.map { $0.map(\.text) }
        let lines = lines(in: note, range: formulas)
        let outcome = TableFormulas.evaluate(grid: grid, formulaLines: lines, variables: NoteVariables.parse(noteText: note as String))
        if let issue = outcome.issues.first {
            let more = outcome.issues.count > 1 ? " (+\(outcome.issues.count - 1) more)" : ""
            return CaptionDecoration(text: "ƒ " + describe(issue, grid: grid) + more, isError: true)
        }
        let n = outcome.formulas.count
        let stale = outcome.changed.isEmpty ? "" : " · values out of date"
        return CaptionDecoration(text: "ƒ \(n) formula\(n == 1 ? "" : "s")" + stale, isError: false)
    }

    /// An issue in the table's own words: the row's label and the column's header.
    static func describe(_ issue: TableFormulas.Issue, grid: [[String]]) -> String {
        if issue.formula.contains(deletedMark) {
            return "“\(issue.formula)” refers to a deleted row or column; fix or remove it with Formula…"
        }
        var place = ""
        if let cell = issue.cell, cell.row - 1 < grid.count {
            let row = grid[cell.row - 1]
            let label = hasLabelColumn(grid) && !row.isEmpty ? "“\(row[0])”" : "Row \(cell.row)"
            let header = cell.column - 1 < grid[0].count ? grid[0][cell.column - 1] : ""
            place = header.isEmpty ? "\(label): " : "\(label), \(header): "
        } else {
            place = "“\(issue.formula)”: "
        }
        return place + issue.error.message
    }

    // MARK: Inserted and deleted rows and columns

    /// What the table editor did to the table's shape, in TBLFM numbering (row 1 the header).
    enum ShapeChange: Equatable {
        case insertRows(at: Int, count: Int)
        case deleteRows(at: Int, count: Int)
        case insertColumns(at: Int, count: Int)
        case deleteColumns(at: Int, count: Int)
    }

    /// Written in place of a reference to a row or column that was deleted. The formula
    /// no longer parses, so the table isn't recalculated until it's fixed or removed.
    static let deletedMark = "#REF"

    private static let reference = try! NSRegularExpression(pattern: #"(@(?:[<>I]|[-+]?\d+))?(\$(?:[<>]|[-+]?\d+))?"#)

    /// Keeps absolute references (`@4`, `$2`) pointing at the same rows and columns after
    /// the table editor inserted or deleted some, as a spreadsheet does. A formula whose
    /// destination was deleted is removed; one that reads a deleted row or column gets
    /// `#REF` there. Relative references and `<`, `>`, `I` are left alone. A line holding
    /// a formula the engine doesn't parse (unsupported, or mistyped) stays byte for byte.
    static func adjust(_ formulaLines: [String], for change: ShapeChange) -> [String] {
        var out: [String] = []
        for line in formulaLines {
            guard let body = TableFormulas.formulaText(ofLine: line) else { out.append(line); continue }
            let pieces = body.components(separatedBy: "::").map { $0.trimmingCharacters(in: .whitespaces) }
            let parses = pieces.allSatisfy { if case .success = TableFormulas.parseFormula($0) { return true }; return false }
            guard parses, let adjusted = try? pieces.map({ try adjust(formula: $0, for: change) }) else { out.append(line); continue }
            let kept = adjusted.compactMap { $0 }
            if kept == pieces { out.append(line); continue }
            if !kept.isEmpty { out.append("<!-- TBLFM: " + kept.joined(separator: "::") + " -->") }
        }
        return out
    }

    private struct Overflow: Error {}

    /// One formula adjusted, or nil when its destination is gone. Throws when an index
    /// would overflow; the line then stays as it was.
    private static func adjust(formula: String, for change: ShapeChange) throws -> String? {
        guard let eq = formula.firstIndex(of: "=") else { return formula }
        let dest = String(formula[..<eq]), source = String(formula[formula.index(after: eq)...])
        guard let newDest = try adjust(references: dest, for: change, destination: true) else { return nil }
        return try newDest + "=" + (adjust(references: source, for: change, destination: false) ?? source)
    }

    private enum Role { case single, start, end }

    private static func adjust(references text: String, for change: ShapeChange, destination: Bool) throws -> String? {
        let ns = text as NSString
        let matches = reference.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { $0.range.length > 0 }
        let rows: Bool, at: Int, count: Int, inserting: Bool
        switch change {
        case let .insertRows(a, c): (rows, at, count, inserting) = (true, a, c, true)
        case let .deleteRows(a, c): (rows, at, count, inserting) = (true, a, c, false)
        case let .insertColumns(a, c): (rows, at, count, inserting) = (false, a, c, true)
        case let .deleteColumns(a, c): (rows, at, count, inserting) = (false, a, c, false)
        }
        /// The new index, or nil when a single reference's row or column was deleted.
        /// Checked: an index that would overflow leaves the formula alone.
        func plus(_ a: Int, _ b: Int) throws -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            if overflow { throw Overflow() }
            return sum
        }
        func shifted(_ n: Int, _ role: Role) throws -> Int? {
            if inserting { return n >= at ? try plus(n, count) : n }
            if n >= (try plus(at, count)) { return n - count }
            guard n >= at else { return n }
            switch role {
            case .single: return nil
            case .start: return at          // the next one moves up into its place
            case .end: return at - 1
            }
        }
        /// The index in `@4` or `$2`; nil for relative ones and `<`, `>`, `I`.
        func absolute(_ r: NSRange) throws -> Int? {
            guard r.location != NSNotFound else { return nil }
            let digits = ns.substring(with: NSRange(location: r.location + 1, length: r.length - 1))
            guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
            guard let n = Int(digits) else { throw Overflow() }
            return n
        }
        var edits: [(range: NSRange, text: String)] = []
        var start: (edit: Int, value: Int?)?
        for m in matches {
            let before = ns.substring(to: m.range.location), after = ns.substring(from: NSMaxRange(m.range))
            let role: Role = after.hasPrefix("..") ? .start : before.hasSuffix("..") ? .end : .single
            let part = m.range(at: rows ? 1 : 2)
            var unit = ns.substring(with: m.range)
            var value = try absolute(part)
            if let n = value {
                guard let s = try shifted(n, role) else {
                    if destination { return nil }
                    edits.append((m.range, deletedMark))
                    continue
                }
                let local = NSRange(location: part.location - m.range.location, length: part.length)
                unit = (unit as NSString).replacingCharacters(in: local, with: (rows ? "@" : "$") + "\(s)")
                value = s
            }
            edits.append((m.range, unit))
            switch role {
            case .start: start = (edits.count - 1, value)
            case .end:
                // A range whose rows (or columns) were all deleted is gone too.
                if let s = start, let a = s.value, let b = value ?? s.value, a > b {
                    if destination { return nil }
                    let whole = NSUnionRange(edits[s.edit].range, m.range)
                    edits.removeLast(edits.count - s.edit)
                    edits.append((whole, deletedMark))
                }
                start = nil
            case .single: break
            }
        }
        var result = text
        for e in edits.reversed() { result = (result as NSString).replacingCharacters(in: e.range, with: e.text) }
        return result
    }

    // MARK: Editing one row's or column's formula

    /// A target for the Formula… popover, in TBLFM numbering.
    struct Target: Equatable {
        var isRow: Bool
        var index: Int
    }

    /// The formula that fills `target`: its line and position on it, and its text.
    static func existing(_ target: Target, in formulaLines: [String]) -> (line: Int, index: Int, text: String)? {
        var found: (Int, Int, String)?
        for (n, line) in formulaLines.enumerated() {
            guard let body = TableFormulas.formulaText(ofLine: line) else { continue }
            for (k, piece) in body.components(separatedBy: "::").enumerated() {
                let text = piece.trimmingCharacters(in: .whitespaces)
                guard case let .success(f) = TableFormulas.parseFormula(text), fills(f.destination, target) else { continue }
                found = (n, k, text)   // the last one wins, as in evaluation
            }
        }
        return found
    }

    private static func fills(_ d: TableFormulas.Destination, _ t: Target) -> Bool {
        let i = CellReference.Index.absolute(t.index)
        switch d {
        case let .row(r): return t.isRow && r == i
        case let .column(c): return !t.isRow && c == i
        case let .range(a, b):
            return t.isRow ? a.row == i && b.row == i : a.column == i && (b.column ?? a.column) == i && a.row != b.row
        case .cell: return false
        }
    }

    /// `formulaLines` with the target's formula replaced by `text`, added on a line of its
    /// own when it had none, or removed when `text` is nil.
    static func setting(_ text: String?, for target: Target, in formulaLines: [String]) -> [String] {
        var lines = formulaLines
        if let old = existing(target, in: lines) {
            var pieces = TableFormulas.formulaText(ofLine: lines[old.line])!.components(separatedBy: "::").map { $0.trimmingCharacters(in: .whitespaces) }
            if let text { pieces[old.index] = text } else { pieces.remove(at: old.index) }
            if pieces.isEmpty { lines.remove(at: old.line) } else { lines[old.line] = "<!-- TBLFM: " + pieces.joined(separator: "::") + " -->" }
        } else if let text {
            lines.append("<!-- TBLFM: \(text) -->")
        }
        return lines
    }
}

// MARK: - Popover

/// "Row “Mass of water” = [Hydrated ▾] [− ▾] [Anhydrous ▾]", the formula in upstream
/// syntax underneath (editable), and a live preview of the values it gives.
final class TableFormulaPopover: NSViewController, NSTextFieldDelegate {
    enum Operation: String, CaseIterable {
        case subtract = "−", add = "+", multiply = "×", divide = "÷", percent = "% of"
        var symbol: String { ["−": "-", "+": "+", "×": "*", "÷": "/"][rawValue] ?? "/" }
    }

    let grid: [[String]]
    let formulaLines: [String]
    let variables: NoteVariables
    let labelColumn: Bool
    private(set) var target: TableFormulaUI.Target
    private let focus: (row: Int, column: Int)
    /// New formula lines: with the target's formula set, or removed.
    var onApply: (([String]) -> Void)?

    let axis = NSSegmentedControl(labels: ["Row", "Column"], trackingMode: .selectOne, target: nil, action: nil)
    let titleLabel = NSTextField(labelWithString: "")
    let left = NSPopUpButton(), operation = NSPopUpButton(), right = NSPopUpButton()
    let field = NSTextField(string: "")
    let preview = NSTextField(wrappingLabelWithString: "")
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)

    /// `focus` is the focused cell in TBLFM numbering.
    init(grid: [[String]], formulaLines: [String], variables: NoteVariables, focus: (row: Int, column: Int)) {
        self.grid = grid
        self.formulaLines = formulaLines
        self.variables = variables
        self.focus = focus
        labelColumn = TableFormulaUI.hasLabelColumn(grid)
        let isRow = focus.row == 1 ? false : (focus.column == 1 || labelColumn)
        target = .init(isRow: isRow, index: isRow ? max(focus.row, 2) : focus.column)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var height: Int { grid.count }
    private var width: Int { grid.map(\.count).max() ?? 0 }

    override func loadView() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        axis.target = self
        axis.action = #selector(axisChanged)
        axis.controlSize = .small
        for p in [left, operation, right] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            p.target = self
            p.action = #selector(builderChanged)
            (p.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        }
        operation.addItems(withTitles: Operation.allCases.map(\.rawValue))
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.placeholderString = "@4$2..@4$>=(@2-@3)"
        field.delegate = self
        field.lineBreakMode = .byTruncatingMiddle
        preview.font = .systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor
        preview.preferredMaxLayoutWidth = 340
        preview.maximumNumberOfLines = 4
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.controlSize = .small
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.controlSize = .small
        applyButton.keyEquivalent = "\r"

        let header = NSStackView(views: [titleLabel, NSView(), axis])
        header.distribution = .fill
        let builder = NSStackView(views: [left, operation, right])
        builder.spacing = 6
        builder.distribution = .fill
        operation.widthAnchor.constraint(equalToConstant: 72).isActive = true
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        for p in [left, right] { p.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let buttons = NSStackView(views: [removeButton, NSView(), cancel, applyButton])
        let stack = NSStackView(views: [header, builder, field, preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        for v in [header, builder, field, preview, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true
        view = stack
        loadTarget()
    }

    /// The operand choices: the other body rows, or the other columns.
    private var choices: [(title: String, index: Int)] {
        if target.isRow {
            return (2...max(height, 2)).filter { $0 != target.index && $0 <= height }.map { r in
                let label = labelColumn ? grid[r - 1][0] : ""
                return (label.isEmpty ? "Row \(r)" : label, r)
            }
        }
        return (1...max(width, 1)).filter { $0 != target.index }.map { c in
            let h = c - 1 < grid[0].count ? grid[0][c - 1] : ""
            return (h.isEmpty ? "Column \(c)" : h, c)
        }
    }

    private var targetName: String {
        if target.isRow {
            let label = labelColumn && target.index <= height ? grid[target.index - 1][0] : ""
            return label.isEmpty ? "Row \(target.index)" : "Row “\(label)”"
        }
        let h = target.index - 1 < grid[0].count ? grid[0][target.index - 1] : ""
        return h.isEmpty ? "Column \(target.index)" : "Column “\(h)”"
    }

    private func loadTarget() {
        axis.selectedSegment = target.isRow ? 0 : 1
        titleLabel.stringValue = targetName + " ="
        let options = choices
        for p in [left, right] {
            p.removeAllItems()
            p.addItems(withTitles: options.map(\.title))
            // Titles can repeat ("Row 3" twice can't, but two blank headers can); tags tell them apart.
            for (i, item) in p.itemArray.enumerated() { item.tag = options[i].index }
        }
        let existing = TableFormulaUI.existing(target, in: formulaLines)
        removeButton.isHidden = existing == nil
        applyButton.title = existing == nil ? "Add" : "Apply"
        if let existing, selectBuilder(from: existing.text) {
            field.stringValue = existing.text
        } else if let existing {
            field.stringValue = existing.text
        } else {
            // A new formula: the two before it, the first minus the second (hydrated − anhydrous),
            // from the ones no formula fills, so the suggestion never depends on itself.
            let all = options.map(\.index)
            let inputs = all.filter { TableFormulaUI.existing(.init(isRow: target.isRow, index: $0), in: formulaLines) == nil }
            let idx = inputs.count >= 2 ? inputs : all
            let before = idx.filter { $0 < target.index }
            let a = before.count >= 2 ? before[before.count - 2] : idx.first, b = before.last ?? (idx.count > 1 ? idx[1] : idx.first)
            if let a { left.selectItem(withTag: a) }
            if let b { right.selectItem(withTag: b) }
            operation.selectItem(at: 0)
            field.stringValue = builtFormula()
        }
        updatePreview()
    }

    /// What the destination looks like for this target. Row formulas leave out the label
    /// column; `@R=(…)` would fill it too, and fail on its text.
    private var destination: String {
        if target.isRow { return labelColumn ? "@\(target.index)$2..@\(target.index)$>" : "@\(target.index)" }
        return "$\(target.index)"
    }

    private func builtFormula() -> String {
        let p = target.isRow ? "@" : "$"
        let a = p + "\(left.selectedTag())", b = p + "\(right.selectedTag())"
        let op = Operation.allCases[max(operation.indexOfSelectedItem, 0)]
        if op == .percent { return destination + "=((\(a)/\(b))*100);%.1f" }
        return destination + "=(\(a)\(op.symbol)\(b))"
    }

    private static let simple = try! NSRegularExpression(pattern: #"^\(([@$])(\d+)([-+*/])([@$])(\d+)\)$"#)
    private static let percent = try! NSRegularExpression(pattern: #"^\(\(([@$])(\d+)/([@$])(\d+)\)\*100\);%\.1f$"#)

    /// Sets the menus from a formula they can express; false if they can't.
    private func selectBuilder(from text: String) -> Bool {
        guard let eq = text.firstIndex(of: "="), String(text[..<eq]) == destination else { return false }
        let source = String(text[text.index(after: eq)...])
        let ns = source as NSString, full = NSRange(location: 0, length: ns.length)
        let p = target.isRow ? "@" : "$"
        if let m = Self.percent.firstMatch(in: source, range: full), ns.substring(with: m.range(at: 1)) == p, ns.substring(with: m.range(at: 3)) == p {
            left.selectItem(withTag: Int(ns.substring(with: m.range(at: 2))) ?? 0)
            right.selectItem(withTag: Int(ns.substring(with: m.range(at: 4))) ?? 0)
            operation.selectItem(withTitle: Operation.percent.rawValue)
            return true
        }
        if let m = Self.simple.firstMatch(in: source, range: full), ns.substring(with: m.range(at: 1)) == p, ns.substring(with: m.range(at: 4)) == p,
           let op = Operation.allCases.first(where: { $0 != .percent && $0.symbol == ns.substring(with: m.range(at: 3)) }) {
            left.selectItem(withTag: Int(ns.substring(with: m.range(at: 2))) ?? 0)
            right.selectItem(withTag: Int(ns.substring(with: m.range(at: 5))) ?? 0)
            operation.selectItem(withTitle: op.rawValue)
            return true
        }
        return false
    }

    @objc private func axisChanged() {
        let isRow = axis.selectedSegment == 0
        guard isRow != target.isRow else { return }
        target = .init(isRow: isRow, index: isRow ? max(focus.row, 2) : focus.column)
        loadTarget()
    }

    @objc private func builderChanged() {
        field.stringValue = builtFormula()
        updatePreview()
    }

    func controlTextDidChange(_ obj: Notification) { updatePreview() }

    /// The values the formula gives this row or column, or what's wrong.
    func updatePreview() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            preview.stringValue = "Type a formula, or pick rows above."
            preview.textColor = .secondaryLabelColor
            applyButton.isEnabled = false
            return
        }
        let lines = TableFormulaUI.setting(text, for: target, in: formulaLines)
        let outcome = TableFormulas.evaluate(grid: grid, formulaLines: lines, variables: variables)
        if case let .failure(e) = TableFormulas.parseFormula(text) {
            show(error: e.message)
            return
        }
        if let issue = outcome.issues.first {
            show(error: TableFormulaUI.describe(issue, grid: outcome.grid))
            return
        }
        var values: [String] = []
        if target.isRow {
            for c in (labelColumn ? 2 : 1)...max(width, 1) where target.index <= outcome.grid.count && c <= outcome.grid[target.index - 1].count {
                let v = outcome.grid[target.index - 1][c - 1]
                values.append("\(grid[0][c - 1]): \(v.isEmpty ? "blank" : v)")
            }
        } else {
            for r in 2...max(height, 2) where r <= outcome.grid.count && target.index <= outcome.grid[r - 1].count {
                let v = outcome.grid[r - 1][target.index - 1]
                let label = labelColumn ? grid[r - 1][0] : "Row \(r)"
                values.append("\(label): \(v.isEmpty ? "blank" : v)")
            }
        }
        var note = values.joined(separator: " · ")
        if text.contains("*100") { note += "\nA percentage as a plain number from 0 to 100, to one decimal (64.4)." }
        if text.contains("min(") || text.contains("max(") || text.contains("count(") || variables.values.keys.contains(where: { text.contains($0) }) {
            note += "\nUses an Indium extension: Obsidian's Advanced Tables won't evaluate this line."
        }
        preview.stringValue = "→ " + note
        preview.textColor = .secondaryLabelColor
        applyButton.isEnabled = true
    }

    private func show(error: String) {
        preview.stringValue = error
        preview.textColor = Palette.error
        applyButton.isEnabled = false
    }

    @objc func apply() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard applyButton.isEnabled, !text.isEmpty else { NSSound.beep(); return }
        presentingPopover?.close()
        onApply?(TableFormulaUI.setting(text, for: target, in: formulaLines))
    }

    @objc func remove() {
        presentingPopover?.close()
        onApply?(TableFormulaUI.setting(nil, for: target, in: formulaLines))
    }

    @objc func cancel() { presentingPopover?.close() }

    weak var presentingPopover: NSPopover?

    // For the debug harness.
    func debugSet(left l: Int?, operation op: String?, right r: Int?) {
        if let l { left.selectItem(withTag: l) }
        if let op { operation.selectItem(withTitle: op) }
        if let r { right.selectItem(withTag: r) }
        builderChanged()
    }
}
