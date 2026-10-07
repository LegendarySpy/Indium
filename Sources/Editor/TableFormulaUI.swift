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
        let stale = !outcome.changed.isEmpty
        return CaptionDecoration(text: "ƒ \(n) formula\(n == 1 ? "" : "s")" + (stale ? " · values out of date" : ""), isError: false,
                                 action: stale ? "Recalculate" : nil)
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

    // MARK: Formulas in plain words

    /// A row by its label ("Mass of water"), or "Row 4" in a table without a label column.
    /// The names the Formula… popover offers.
    static func rowName(_ row: Int, grid: [[String]], labelColumn: Bool) -> String {
        let label = labelColumn && row >= 1 && row <= grid.count ? (grid[row - 1].first ?? "") : ""
        return label.isEmpty ? "Row \(row)" : label
    }

    /// A column by its header, or "Column 3".
    static func columnName(_ column: Int, grid: [[String]]) -> String {
        let header = column >= 1 && column - 1 < (grid.first?.count ?? 0) ? grid[0][column - 1] : ""
        return header.isEmpty ? "Column \(column)" : header
    }

    /// One formula in the table's own words: what it fills, and what it's calculated from,
    /// "Mass of water" and "Mass of hydrated salt − Mass of anhydrous salt", or
    /// "(Mass of water ÷ Mass of hydrated salt) × 100, 1 decimal". Nil when it can't be
    /// put that way (it doesn't parse, or uses relative references).
    static func plainWords(_ formula: String, grid: [[String]]) -> (target: String, source: String)? {
        guard case let .success(f) = TableFormulas.parseFormula(formula) else { return nil }
        let labels = hasLabelColumn(grid)
        let height = grid.count, width = grid.map(\.count).max() ?? 0
        func index(_ i: CellReference.Index, rows: Bool) -> Int? {
            switch i {
            case .absolute(let n): return n >= 1 && n <= (rows ? height : width) ? n : nil
            case .first: return 1
            case .last: return rows ? height : width
            case .firstBody: return height >= 2 ? 2 : nil
            case .relative: return nil
            }
        }
        func name(_ r: CellReference) -> String? {
            let row = r.row.map { index($0, rows: true) }, column = r.column.map { index($0, rows: false) }
            switch (row, column) {
            case let (row??, nil): return rowName(row, grid: grid, labelColumn: labels)
            case let (nil, column??): return columnName(column, grid: grid)
            case let (row??, column??):
                return "\(rowName(row, grid: grid, labelColumn: labels)) (\(columnName(column, grid: grid)))"
            default: return nil
            }
        }
        func words(_ node: FormulaNode, top: Bool = false) -> String? {
            switch node {
            case .number(let n): return n
            case .constant(let c): return c
            case .variable(let v): return v
            case .reference(let r): return name(r)
            case let .range(a, b): return name(a).flatMap { a in name(b).map { "\(a) to \($0)" } }
            case .negate(let n): return words(n).map { "−" + $0 }
            case .percent(let n): return words(n).map { $0 + "%" }
            case let .unit(n, u): return words(n).map { "\($0) \(u)" }
            case let .binary(op, a, b):
                let symbol = ["-": "−", "*": "×", "/": "÷"][String(op)] ?? String(op)
                // `(@9*1);%.1f` only rounds a copy; say so without the "× 1".
                if case .number("1") = b, "*/".contains(op) { return words(a, top: top) }
                guard let a = words(a), let b = words(b) else { return nil }
                return "\(a) \(symbol) \(b)"
            case let .implicitProduct(a, b):
                guard let a = words(a), let b = words(b) else { return nil }
                return "\(a) × \(b)"
            case let .call(fn, args):
                let parts = args.compactMap { words($0) }
                return parts.count == args.count ? "\(fn)(\(parts.joined(separator: ", ")))" : nil
            case .group(let inner):
                return words(inner).map { top ? $0 : "(\($0))" }
            }
        }
        let target: String?
        switch f.destination {
        case .cell(let r): target = name(r)
        case .row(let r): target = index(r, rows: true).map { rowName($0, grid: grid, labelColumn: labels) }
        case .column(let c): target = index(c, rows: false).map { columnName($0, grid: grid) }
        case let .range(a, b):
            let r1 = a.row.flatMap { index($0, rows: true) }, r2 = b.row.flatMap { index($0, rows: true) }
            let c1 = a.column.flatMap { index($0, rows: false) }, c2 = (b.column ?? a.column).flatMap { index($0, rows: false) }
            if let r1, r1 == r2 { target = rowName(r1, grid: grid, labelColumn: labels) }
            else if let c1, c1 == c2 { target = columnName(c1, grid: grid) }
            else { target = nil }
        }
        guard let target, var source = words(f.source, top: true) else { return nil }
        if let d = f.decimals { source += ", \(d) decimal\(d == 1 ? "" : "s")" }
        return (target, source)
    }

    /// The row or column the Formula… popover edits for this formula, when it fills one.
    static func target(of formula: String) -> Target? {
        guard case let .success(f) = TableFormulas.parseFormula(formula) else { return nil }
        let candidates: [Target]
        switch f.destination {
        case let .row(.absolute(r)): candidates = [Target(isRow: true, index: r)]
        case let .column(.absolute(c)): candidates = [Target(isRow: false, index: c)]
        case let .range(a, _):
            candidates = [a.row, a.column].enumerated().compactMap { k, i in
                if case let .absolute(n)? = i { return Target(isRow: k == 0, index: n) } else { return nil }
            }
        default: candidates = []
        }
        // Only a target `existing` finds again, so Edit opens this very formula.
        return candidates.first { existing($0, in: ["<!-- TBLFM: \(formula) -->"]) != nil }
    }

    /// The cells the formulas fill, for the rendered table: each with its formula in
    /// plain words for the tooltip, and flagged when the formula has a problem or the
    /// stored value is out of date.
    static func marks(note: NSString, table: MDBlock, formulas: NSRange) -> [TableRender.Position: TableRender.Mark] {
        guard case let .table(spec) = table.kind else { return [:] }
        let grid = spec.rows.map { $0.map(\.text) }
        let lines = lines(in: note, range: formulas)
        let targets = TableFormulas.targets(grid: grid, formulaLines: lines)
        guard !targets.isEmpty else { return [:] }
        let outcome = TableFormulas.evaluate(grid: grid, formulaLines: lines, variables: NoteVariables.parse(noteText: note as String))
        var tips: [Int: String] = [:]
        func tip(_ i: Int) -> String {
            if let t = tips[i] { return t }
            let text = outcome.formulas[i].text
            let t = plainWords(text, grid: grid).map { "= " + $0.source } ?? text
            tips[i] = t
            return t
        }
        var problems: [TableFormulas.Cell: String] = [:]
        for issue in outcome.issues {
            if let cell = issue.cell { problems[cell] = issue.error.message; continue }
            for (cell, i) in targets where outcome.formulas[i].text == issue.formula { problems[cell] = issue.error.message }
        }
        for cell in outcome.changed where problems[cell] == nil {
            let now = outcome.grid[cell.row - 1][cell.column - 1]
            problems[cell] = "Out of date: the formula gives \(now.isEmpty ? "a blank" : now). Recalculate under the table."
        }
        var out: [TableRender.Position: TableRender.Mark] = [:]
        for (cell, i) in targets {
            let problem = problems[cell]
            out[TableRender.Position(row: cell.row - 1, column: cell.column - 1)] = TableRender.Mark(isError: problem != nil, tip: tip(i) + (problem.map { "\n" + $0 } ?? ""))
        }
        return out
    }

    /// Every formula under a table in plain words, "Mass of water = Mass of hydrated salt −
    /// Mass of anhydrous salt", with the row or column Formula… edits for it.
    static func summaries(grid: [[String]], formulaLines: [String]) -> [(text: String, target: Target?, line: Int)] {
        TableFormulas.parse(formulaLines: formulaLines).map { p in
            let text = plainWords(p.text, grid: grid).map { "\($0.target) = \($0.source)" } ?? p.text
            return (text, target(of: p.text), p.line)
        }
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
    /// `target` picks the row or column outright (Edit in the formulas list); otherwise
    /// it follows the focused cell.
    init(grid: [[String]], formulaLines: [String], variables: NoteVariables, focus: (row: Int, column: Int),
         target: TableFormulaUI.Target? = nil) {
        self.grid = grid
        self.formulaLines = formulaLines
        self.variables = variables
        self.focus = focus
        labelColumn = TableFormulaUI.hasLabelColumn(grid)
        let isRow = focus.row == 1 ? false : (focus.column == 1 || labelColumn)
        self.target = target ?? .init(isRow: isRow, index: isRow ? max(focus.row, 2) : focus.column)
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
                (TableFormulaUI.rowName(r, grid: grid, labelColumn: labelColumn), r)
            }
        }
        return (1...max(width, 1)).filter { $0 != target.index }.map { c in (TableFormulaUI.columnName(c, grid: grid), c) }
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

// MARK: - Computed cells

/// The text of one computed cell's tooltip on the rendered page.
final class CellTip: NSObject, NSViewToolTipOwner {
    let text: String
    init(_ text: String) { self.text = text }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String { text }
}

/// The caption's popover: each formula in plain words, with Edit.
final class TableFormulaListPopover: NSViewController {
    let rows: [(text: String, editable: Bool)]
    /// Edit on a row (its index): Formula… for its row or column, or its source line.
    var onEdit: ((Int) -> Void)?
    var onShowSource: (() -> Void)?
    weak var presentingPopover: NSPopover?
    private var buttons: [NSButton] = []

    init(rows: [(text: String, editable: Bool)]) {
        self.rows = rows
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: rows.count == 1 ? "Formula" : "Formulas")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        var views: [NSView] = [title]
        for (i, row) in rows.enumerated() {
            let label = NSTextField(wrappingLabelWithString: row.text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.preferredMaxLayoutWidth = 330
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let edit = NSButton(title: "Edit", target: self, action: #selector(edit(_:)))
            edit.controlSize = .small
            edit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            edit.tag = i
            edit.toolTip = row.editable ? "Edit with Formula…" : "Show this formula's source"
            edit.setContentHuggingPriority(.required, for: .horizontal)
            buttons.append(edit)
            let line = NSStackView(views: [label, NSView(), edit])
            line.alignment = .firstBaseline
            line.spacing = 10
            views.append(line)
        }
        let source = NSButton(title: "Show Source", target: self, action: #selector(showSource))
        source.isBordered = false
        source.controlSize = .small
        source.contentTintColor = Palette.link
        source.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        views.append(source)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        for v in views.dropFirst().dropLast() { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        view = stack
    }

    @objc private func edit(_ sender: NSButton) {
        presentingPopover?.close()
        onEdit?(sender.tag)
    }

    @objc private func showSource() {
        presentingPopover?.close()
        onShowSource?()
    }

    // For the debug harness.
    func debugEdit(_ n: Int) { if n < buttons.count { edit(buttons[n]) } }
}

/// Under a computed cell being edited: what happens to typing there, and a way to the
/// formula. Typing isn't blocked.
final class TableCalculatedNote: NSView {
    var onEditFormula: (() -> Void)?
    private let label = NSTextField(wrappingLabelWithString:
        "This cell is calculated. Your change will be replaced the next time the table recalculates. Edit the formula instead.")
    private let button = NSButton(title: "Edit Formula…", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: 11)
        label.textColor = Palette.secondaryText
        label.preferredMaxLayoutWidth = 260
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = Palette.link
        button.refusesFirstResponder = true
        button.target = self
        button.action = #selector(editFormula)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.widthAnchor.constraint(equalToConstant: 260),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label.stringValue)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Palette.surface.cgColor
        layer?.borderColor = Palette.quoteBar.cgColor
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    @objc private func editFormula() { onEditFormula?() }

    var text: String { label.stringValue }

    // For the debug harness.
    func debugEditFormula() { editFormula() }
}
