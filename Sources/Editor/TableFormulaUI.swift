import AppKit

/// The editor's side of table formulas (Advanced Tables `<!-- TBLFM: … -->` lines, see
/// Sources/Formulas/README.md): the caption under a table, recalculating after an edit,
/// keeping references pointed at the same rows and columns when rows or columns are
/// inserted or deleted, and the views around a cell a formula is typed in.
enum TableFormulaUI {
    // MARK: Reading a table

    /// Header row first, delimiter left out: the grid `TableFormulas` works on.
    static func grid(of tableMarkdown: String) -> (grid: [[String]], spec: TableSpec)? {
        guard let block = MarkdownScanner.scan(tableMarkdown as NSString).first, case let .table(spec) = block.kind else { return nil }
        return (spec.rows.map { $0.map(\.text) }, spec)
    }

    /// The formula lines in `range` (the scanner's `.tableFormulas` block), without line breaks.
    private static func lines(in text: NSString, range: NSRange) -> [String] {
        text.substring(with: range).components(separatedBy: .newlines).filter { TableFormulas.isFormulaLine($0) }
    }

    /// True when the first column holds row names ("Mass of water"), as in a transposed
    /// results table: row formulas then leave it out (`@4$2..@4$>`).
    private static func hasLabelColumn(_ grid: [[String]]) -> Bool {
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
            return "#REF! “\(issue.formula)” refers to a deleted row or column; fix or remove it in Show Source"
        }
        var place = ""
        if let cell = issue.cell, cell.row - 1 < grid.count {
            let row = grid[cell.row - 1]
            let label = hasLabelColumn(grid) && !row.isEmpty && cell.column != 1 ? "“\(row[0])”" : ""
            let header = cell.column - 1 < grid[0].count && cell.row != 1 ? grid[0][cell.column - 1] : ""
            let words = [label, header].filter { !$0.isEmpty }.joined(separator: ", ")
            place = ExcelFormulas.name(cell) + (words.isEmpty ? "" : " (\(words))") + ": "
        } else {
            place = "“\(issue.formula)”: "
        }
        return place + ExcelFormulas.message(issue.error)
    }

    // MARK: Formulas in plain words

    /// A row by its label ("Mass of water"), or "Row 4" in a table without a label column.
    private static func rowName(_ row: Int, grid: [[String]], labelColumn: Bool) -> String {
        let label = labelColumn && row >= 1 && row <= grid.count ? (grid[row - 1].first ?? "") : ""
        return label.isEmpty ? "Row \(row)" : label
    }

    /// A column by its header, or "Column 3".
    private static func columnName(_ column: Int, grid: [[String]]) -> String {
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
        let width = grid.map(\.count).max() ?? 0
        var words: [Int: String] = [:]
        func tip(_ i: Int, _ cell: TableFormulas.Cell) -> String {
            let text = outcome.formulas[i].text
            if words[i] == nil { words[i] = plainWords(text, grid: grid).map { $0.source } ?? "" }
            let shown = (try? outcome.formulas[i].result.get()).flatMap { ExcelFormulas.excel($0, at: cell, width: width, height: grid.count) }
            return [shown ?? text, words[i]!].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        var problems: [TableFormulas.Cell: String] = [:]
        for issue in outcome.issues {
            if let cell = issue.cell { problems[cell] = ExcelFormulas.message(issue.error); continue }
            for (cell, i) in targets where outcome.formulas[i].text == issue.formula { problems[cell] = ExcelFormulas.message(issue.error) }
        }
        for cell in outcome.changed where problems[cell] == nil {
            let now = outcome.grid[cell.row - 1][cell.column - 1]
            problems[cell] = "Out of date: the formula gives \(now.isEmpty ? "a blank" : now). Recalculate under the table."
        }
        var out: [TableRender.Position: TableRender.Mark] = [:]
        for (cell, i) in targets {
            let problem = problems[cell]
            out[TableRender.Position(row: cell.row - 1, column: cell.column - 1)] = TableRender.Mark(isError: problem != nil, tip: tip(i, cell) + (problem.map { "\n" + $0 } ?? ""))
        }
        return out
    }

    /// Every formula under a table, as its first cell shows it, with the cells it fills and
    /// what they are: "B4:D4, Mass of water: =B2-B3". With the first cell, to edit it there.
    static func summaries(grid: [[String]], formulaLines: [String]) -> [(text: String, cell: TableFormulas.Cell?, line: Int)] {
        let width = grid.map(\.count).max() ?? 0, height = grid.count
        return TableFormulas.parse(formulaLines: formulaLines).map { p in
            guard case let .success(f) = p.result, let (first, last) = TableFormulas.corners(of: f.destination, width: width, height: height),
                  first.row >= 1, first.column >= 1, last.row <= height, last.column <= width,
                  let shown = ExcelFormulas.excel(f, at: first, width: width, height: height) else { return (p.text, nil, p.line) }
            let target = plainWords(p.text, grid: grid)?.target
            return (ExcelFormulas.name(from: first, to: last) + (target.map { ", " + $0 } ?? "") + ": " + shown, first, p.line)
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
    private static let deletedMark = "#REF"

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
        // Checked: an index that would overflow leaves the formula alone.
        func plus(_ a: Int, _ b: Int) throws -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            if overflow { throw Overflow() }
            return sum
        }
        // The new index, or nil when a single reference's row or column was deleted.
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
        // The index in `@4` or `$2`; nil for relative ones and `<`, `>`, `I`.
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
    /// Edit on a row (its index): its first cell, or its source line.
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
            edit.toolTip = row.editable ? "Edit this formula in its first cell" : "Show this formula's source"
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

    #if DEBUG
    func debugEdit(_ n: Int) { if n < buttons.count { edit(buttons[n]) } }
    #endif
}

/// Under a cell a formula is typed in: its value as it stands, or what's wrong, and how
/// to go on. Clicks pass through to the page.
final class TableFormulaHint: NSView {
    private let value = NSTextField(wrappingLabelWithString: "")
    private let help = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        value.font = .systemFont(ofSize: 11.5, weight: .medium)
        value.preferredMaxLayoutWidth = 300
        help.font = .systemFont(ofSize: 10.5)
        help.textColor = Palette.secondaryText
        help.preferredMaxLayoutWidth = 300
        let stack = NSStackView(views: [value, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 318),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `isError` in red; `help` hidden when empty.
    func show(_ text: String, isError: Bool, help helpText: String) {
        value.stringValue = text
        value.textColor = isError ? Palette.error : Palette.text
        help.stringValue = helpText
        help.isHidden = helpText.isEmpty
        setAccessibilityLabel([text, helpText].filter { !$0.isEmpty }.joined(separator: ". "))
        needsLayout = true
    }

    #if DEBUG
    var text: String { [value.stringValue, help.isHidden ? "" : help.stringValue].filter { !$0.isEmpty }.joined(separator: " | ") }
    #endif

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Palette.surface.cgColor
        layer?.borderColor = Palette.quoteBar.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Column letters along the top of a table and row numbers down its left side, while a
/// formula is typed, so cells can be named the way the formula names them. Each sits on
/// the grid's edge, half outside it; the edited cell's column and row are lit.
final class TableReferenceRuler: NSView {
    static let left: CGFloat = 12
    static let top: CGFloat = 8
    private var columns: [(x: CGFloat, width: CGFloat)] = []
    private var rows: [(y: CGFloat, height: CGFloat)] = []
    private var focus: (row: Int, column: Int) = (0, 0)

    /// `origin`: the grid's top-left corner in the superview.
    func update(render: TableRender, origin: NSPoint, focus: (row: Int, column: Int)) {
        var x: CGFloat = 0, y: CGFloat = 0
        columns = render.columnWidths.map { w in defer { x += w }; return (x, w) }
        rows = render.rowHeights.map { h in defer { y += h }; return (y, h) }
        self.focus = focus
        frame = NSRect(x: origin.x - Self.left, y: origin.y - Self.top, width: render.width + Self.left, height: render.height + Self.top)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    #if DEBUG
    var labels: (columns: [String], rows: [String]) {
        (columns.indices.map { ExcelFormulas.columnName($0 + 1) }, rows.indices.map { "\($0 + 1)" })
    }
    #endif

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        func pill(_ text: String, center: NSPoint, lit: Bool) {
            let size = (text as NSString).size(withAttributes: [.font: font])
            let box = NSRect(x: round(center.x - max(size.width + 8, 15) / 2), y: round(center.y - 7), width: max(size.width + 8, 15), height: 14)
            let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
            (lit ? NSColor.controlAccentColor : Palette.surface).setFill()
            path.fill()
            if !lit {
                Palette.quoteBar.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            (text as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: [
                .font: font, .foregroundColor: lit ? NSColor.white : Palette.secondaryText,
            ])
        }
        for (i, c) in columns.enumerated() {
            pill(ExcelFormulas.columnName(i + 1), center: NSPoint(x: Self.left + c.x + c.width / 2, y: Self.top), lit: i == focus.column)
        }
        for (i, r) in rows.enumerated() {
            pill("\(i + 1)", center: NSPoint(x: Self.left, y: Self.top + r.y + r.height / 2), lit: i == focus.row)
        }
    }
}
