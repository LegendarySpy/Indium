import Foundation

/// Spreadsheet formulas for Markdown tables, in the Advanced Tables `TBLFM` format
/// (https://github.com/tgrosinger/md-advanced-tables/blob/main/docs/formulas.md):
///
///     | Quantity               | CuSO₄   | MgSO₄   |
///     | ---------------------- | ------- | ------- |
///     | Mass of hydrated salt  | 2.008 g | 1.502 g |
///     | Mass of anhydrous salt | 0.715 g | 0.733 g |
///     | Mass of water          |         |         |
///     <!-- TBLFM: @4$2..@4$>=(@2-@3) -->
///
/// Pure and UI-free: a grid of strings, formula lines and note variables in; a new
/// grid, per-cell errors and the cells that changed out. Application is atomic: if
/// any formula fails to parse, is unsupported, or fails for any cell, nothing changes.
/// See README.md for the supported subset and how it differs from upstream.
enum TableFormulas {
    /// A cell in TBLFM numbering: row 1 is the header row, row 2 the first body row
    /// (the `---` separator line is not counted); column 1 is the leftmost.
    struct Cell: Hashable, Comparable, CustomStringConvertible {
        var row: Int
        var column: Int
        var description: String { "@\(row)$\(column)" }
        static func < (a: Cell, b: Cell) -> Bool { (a.row, a.column) < (b.row, b.column) }
    }

    /// One formula from a TBLFM line, e.g. `@4$2..@4$>=(@2-@3);%.3f`.
    struct Formula {
        /// The formula exactly as written (never rewritten).
        let text: String
        let destination: Destination
        let source: FormulaNode
        /// Decimal places from a `;%.Nf` directive.
        let decimals: Int?
    }

    enum Destination: Equatable {
        case cell(CellReference)                 // @r$c
        case row(CellReference.Index)            // @r: every column of row r (as upstream, including column 1)
        case column(CellReference.Index)         // $c: every row of column c below the header
        case range(CellReference, CellReference) // @r1$c1..@r2$c2
    }

    struct ParsedFormula {
        let text: String
        let line: Int
        let result: Result<Formula, FormulaError>
    }

    /// A problem, tied to a cell when it happened while computing one.
    struct Issue: CustomStringConvertible {
        let formula: String
        let cell: Cell?
        let error: FormulaError
        var description: String { "\(cell.map { "\($0) " } ?? "")[\(error.kind.rawValue)] \(error.message) — in “\(formula)”" }
    }

    struct Outcome {
        /// The table after the formulas: the input grid unchanged when `issues` isn't empty.
        let grid: [[String]]
        /// Every formula found, parsed or not.
        let formulas: [ParsedFormula]
        let issues: [Issue]
        /// Cells whose text the formulas changed (empty when there are issues).
        let changed: [Cell]
        /// Destination cells left blank because an input was blank.
        let blanks: [Cell]
        var succeeded: Bool { issues.isEmpty }
    }

    // MARK: - Formula lines

    private static let linePattern = try! NSRegularExpression(pattern: #"^\s*<!--\s*TBLFM:\s*(.*?)\s*-->\s*$"#)

    /// The formula text inside `<!-- TBLFM: … -->`, or nil if the line isn't one.
    static func formulaText(ofLine line: String) -> String? {
        let ns = line as NSString
        guard let m = linePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func isFormulaLine(_ line: String) -> Bool { formulaText(ofLine: line) != nil }

    /// Parses TBLFM lines. Formulas on one line are chained with `::`; lines run top to bottom.
    static func parse(formulaLines: [String]) -> [ParsedFormula] {
        var out: [ParsedFormula] = []
        for (n, line) in formulaLines.enumerated() {
            guard let body = formulaText(ofLine: line) else { continue }
            for piece in body.components(separatedBy: "::") {
                let text = piece.trimmingCharacters(in: .whitespaces)
                out.append(ParsedFormula(text: text, line: n, result: parseFormula(text)))
            }
        }
        return out
    }

    private static let decimalsDirective = try! NSRegularExpression(pattern: #"^%\.(\d+)f$"#)

    static func parseFormula(_ text: String) -> Result<Formula, FormulaError> {
        var body = text
        var decimals: Int?
        // A trailing display directive: ;%.2f (supported), ;dt and ;hm (not).
        if let semi = body.lastIndex(of: ";") {
            let directive = String(body[body.index(after: semi)...]).trimmingCharacters(in: .whitespaces)
            let ns = directive as NSString
            if let m = decimalsDirective.firstMatch(in: directive, range: NSRange(location: 0, length: ns.length)) {
                guard let n = Int(ns.substring(with: m.range(at: 1))), n <= 15 else {
                    return .failure(FormulaError(kind: .parse, message: "“;\(directive)” asks for too many decimal places (15 at most)"))
                }
                decimals = n
            } else if directive == "dt" || directive == "hm" {
                return .failure(FormulaError(kind: .unsupported, message: "The ;\(directive) date/time format isn't supported yet"))
            } else if directive.contains("=") {
                return .failure(FormulaError(kind: .parse, message: "Separate formulas with “::”, not “;” (“;” starts a format such as ;%.2f)"))
            } else {
                return .failure(FormulaError(kind: .parse, message: "Unknown format “;\(directive)”; use ;%.Nf for N decimal places"))
            }
            body = String(body[..<semi])
        }
        guard let eq = body.firstIndex(of: "=") else {
            return .failure(FormulaError(kind: .parse, message: "A formula needs a destination, “=”, and a source"))
        }
        let destText = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
        let sourceText = String(body[body.index(after: eq)...])
        if sourceText.hasPrefix("=") {
            return .failure(FormulaError(kind: .parse, message: "“==” only works inside if(), which isn't supported yet"))
        }
        let destination: Destination
        switch parseDestination(destText) {
        case .success(let d): destination = d
        case .failure(let e): return .failure(e)
        }
        let source: FormulaNode
        switch Evaluator.parse(sourceText, options: .tableFormula) {
        case .success(let n): source = n
        case .failure(var e):
            if let p = e.position { e.position = p + destText.count + 1 }
            return .failure(e)
        }
        if let e = checkParentheses(source, isTop: true) { return .failure(e) }
        return .success(Formula(text: text, destination: destination, source: source, decimals: decimals))
    }

    private static func parseDestination(_ text: String) -> Result<Destination, FormulaError> {
        let node: FormulaNode
        switch Evaluator.parse(text, options: .tableFormula) {
        case .success(let n): node = n
        case .failure: return .failure(FormulaError(kind: .parse, message: "“\(text)” isn't a destination; use @row, $column, @row$column or a range of cells"))
        }
        switch node {
        case .reference(let r):
            guard r.isAbsolute else { return .failure(FormulaError(kind: .badReference, message: "A destination can't be relative (\(r))")) }
            if r.row != nil, r.column != nil { return .success(.cell(r)) }
            if let row = r.row { return .success(.row(row)) }
            if let col = r.column { return .success(.column(col)) }
        case .range(let a, var b):
            guard a.isAbsolute, b.isAbsolute else {
                return .failure(FormulaError(kind: .badReference, message: "A relative range can't be a destination"))
            }
            if b.column == nil { b.column = a.column }
            guard a.row != nil, b.row != nil, a.column != nil else {
                return .failure(FormulaError(kind: .badReference, message: "A destination range needs rows and columns, like @2$3..@5$3"))
            }
            return .success(.range(a, b))
        default: break
        }
        return .failure(FormulaError(kind: .parse, message: "“\(text)” isn't a destination; use @row, $column, @row$column or a range of cells"))
    }

    /// Advanced Tables' grammar wants every arithmetic step in its own parentheses:
    /// `(@2-@3)`, `((@4/@2)*100)`. Indium holds formulas to that so files work in both.
    private static func checkParentheses(_ node: FormulaNode, isTop: Bool, parenthesized: Bool = false) -> FormulaError? {
        switch node {
        case .binary(let op, let a, let b):
            guard parenthesized else {
                return FormulaError(kind: .parse, message: "Put each operation in its own parentheses, as Advanced Tables requires: (a \(op) b)")
            }
            return checkParentheses(a, isTop: false) ?? checkParentheses(b, isTop: false)
        case .group(let inner):
            return checkParentheses(inner, isTop: false, parenthesized: true)
        case .negate(let n), .percent(let n), .unit(let n, _):
            return checkParentheses(n, isTop: false)
        case .implicitProduct(let a, let b):
            return checkParentheses(a, isTop: false) ?? checkParentheses(b, isTop: false)
        case .call(_, let args):
            return args.lazy.compactMap { checkParentheses($0, isTop: false) }.first
        case .number, .constant, .variable, .reference, .range:
            return nil
        }
    }

    // MARK: - Evaluation

    /// Applies `formulaLines` to `grid` (row 0 = header; no separator row).
    static func evaluate(grid input: [[String]], formulaLines: [String], variables: NoteVariables = .empty) -> Outcome {
        let width = input.map(\.count).max() ?? 0
        let grid = input.map { $0 + Array(repeating: "", count: width - $0.count) }
        let height = grid.count
        let parsed = parse(formulaLines: formulaLines)
        var issues: [Issue] = []
        func fail() -> Outcome { Outcome(grid: input, formulas: parsed, issues: issues, changed: [], blanks: []) }

        var formulas: [Formula] = []
        for p in parsed {
            switch p.result {
            case .success(let f): formulas.append(f)
            case .failure(let e): issues.append(Issue(formula: p.text, cell: nil, error: e))
            }
        }
        guard issues.isEmpty else { return fail() }

        func resolve(_ index: CellReference.Index, rows: Bool, current: Int) -> Int {
            switch index {
            case .absolute(let n): n
            case .first: 1
            case .last: rows ? height : width
            case .firstBody: 2
            case .relative(let k):
                // Checked: an absurd offset lands out of bounds instead of overflowing.
                current.addingReportingOverflow(k).overflow ? Int.min : current + k
            }
        }
        func inBounds(_ c: Cell) -> FormulaError? {
            if c.row < 1 || c.row > height {
                return FormulaError(kind: .badReference, message: "Row \(c.row) is outside the table (rows 1–\(height), counting the header as 1)")
            }
            if c.column < 1 || c.column > width {
                return FormulaError(kind: .badReference, message: "Column \(c.column) is outside the table (columns 1–\(width))")
            }
            return nil
        }

        // Which formula fills which cell. A later formula takes over a cell from an earlier one.
        var assigned: [Cell: Int] = [:]
        var order: [Cell] = []
        for (fi, f) in formulas.enumerated() {
            // The corners of the destination, checked against the table before any
            // cell is listed, so a typo like @2$2..@999999$2 costs nothing.
            guard let (first, last) = corners(of: f.destination, width: width, height: height) else { continue }
            if let e = inBounds(first) ?? inBounds(last) {
                issues.append(Issue(formula: f.text, cell: nil, error: e))
                continue
            }
            for r in first.row...last.row {
                for c in first.column...last.column {
                    let cell = Cell(row: r, column: c)
                    if assigned[cell] == nil { order.append(cell) }
                    assigned[cell] = fi
                }
            }
        }
        guard issues.isEmpty else { return fail() }

        // Compute each assigned cell, following references through other formulas
        // (in dependency order, like a spreadsheet), and catching cycles.
        enum Computed { case text(String), blank, failed(FormulaError) }
        var computed: [Cell: Computed] = [:]
        var visiting: [Cell] = []

        func cellValue(_ cell: Cell) throws -> Quantity {
            if let e = inBounds(cell) { throw e }
            if assigned[cell] != nil {
                switch compute(cell) {
                case .text(let t):
                    if t.isEmpty { throw FormulaError(kind: .blank, message: "\(cell) is blank") }
                    guard let q = Quantity.parse(t) else { throw FormulaError(kind: .notNumeric, message: "\(cell) isn't a number (“\(t)”)") }
                    return q
                case .blank: throw FormulaError(kind: .blank, message: "\(cell) is blank")
                case .failed(let e):
                    if e.kind == .cycle { throw e }
                    throw FormulaError(kind: e.kind, message: "\(cell) can't be computed: \(e.message)")
                }
            }
            let text = grid[cell.row - 1][cell.column - 1].trimmingCharacters(in: .whitespaces)
            if text.isEmpty { throw FormulaError(kind: .blank, message: "\(cell) is blank") }
            guard let q = Quantity.parse(text) else { throw FormulaError(kind: .notNumeric, message: "\(cell) isn't a number (“\(text)”)") }
            return q
        }

        func compute(_ cell: Cell) -> Computed {
            if let done = computed[cell] { return done }
            if let at = visiting.firstIndex(of: cell) {
                let path = (visiting[at...] + [cell]).map(\.description).joined(separator: " → ")
                return .failed(FormulaError(kind: .cycle, message: "Formulas depend on themselves: \(path)"))
            }
            visiting.append(cell)
            defer { visiting.removeLast() }
            let f = formulas[assigned[cell]!]
            var env = Evaluator.Environment(variables: variables.values)
            env.cell = { ref in
                let target = Cell(row: ref.row.map { resolve($0, rows: true, current: cell.row) } ?? cell.row,
                                  column: ref.column.map { resolve($0, rows: false, current: cell.column) } ?? cell.column)
                return Result { try cellValue(target) }.mapError { $0 as! FormulaError }
            }
            env.range = { a, b in
                let c1 = a.column.map { resolve($0, rows: false, current: cell.column) } ?? cell.column
                let c2 = b.column.map { resolve($0, rows: false, current: cell.column) } ?? c1
                let r1 = a.row.map { resolve($0, rows: true, current: cell.row) } ?? cell.row
                let r2 = b.row.map { resolve($0, rows: true, current: cell.row) } ?? cell.row
                var values: [Quantity] = []
                // Both corners inside the table before walking it.
                let lo = Cell(row: min(r1, r2), column: min(c1, c2)), hi = Cell(row: max(r1, r2), column: max(c1, c2))
                if let e = inBounds(lo) ?? inBounds(hi) { return .failure(e) }
                for r in lo.row...hi.row {
                    for c in lo.column...hi.column {
                        do { values.append(try cellValue(Cell(row: r, column: c))) } catch let e as FormulaError {
                            if e.kind == .blank { continue }
                            return .failure(e)
                        } catch { return .failure(FormulaError(kind: .parse, message: "\(error)")) }
                    }
                }
                return .success(values)
            }
            let result: Computed
            switch Evaluator.evaluate(f.source, environment: env) {
            case .success(let q): result = .text(q.formatted(decimals: f.decimals))
            case .failure(let e): result = e.kind == .blank ? .blank : .failed(e)
            }
            // A cell inside a cycle is settled once the outermost visit finishes.
            if case .failed(let e) = result, e.kind == .cycle, visiting.first != cell { return result }
            computed[cell] = result
            return result
        }

        var blanks: [Cell] = []
        var output = grid
        var changed: [Cell] = []
        for cell in order {
            let f = formulas[assigned[cell]!]
            switch compute(cell) {
            case .failed(let e): issues.append(Issue(formula: f.text, cell: cell, error: e))
            case .blank:
                blanks.append(cell)
                if !output[cell.row - 1][cell.column - 1].trimmingCharacters(in: .whitespaces).isEmpty { changed.append(cell) }
                output[cell.row - 1][cell.column - 1] = ""
            case .text(let t):
                if output[cell.row - 1][cell.column - 1].trimmingCharacters(in: .whitespaces) != t { changed.append(cell) }
                output[cell.row - 1][cell.column - 1] = t
            }
        }
        guard issues.isEmpty else { return fail() }
        return Outcome(grid: output, formulas: parsed, issues: [], changed: changed.sorted(), blanks: blanks.sorted())
    }

    /// The first and last cell a destination covers (destinations are never relative);
    /// nil for a column destination in a table with no body rows. Not bounds-checked.
    static func corners(of destination: Destination, width: Int, height: Int) -> (Cell, Cell)? {
        func resolve(_ index: CellReference.Index, rows: Bool) -> Int {
            switch index {
            case .absolute(let n): n
            case .first: 1
            case .last: rows ? height : width
            case .firstBody: 2
            case .relative(let k): k
            }
        }
        switch destination {
        case .cell(let r):
            let cell = Cell(row: resolve(r.row!, rows: true), column: resolve(r.column!, rows: false))
            return (cell, cell)
        case .row(let r):
            let row = resolve(r, rows: true)
            return (Cell(row: row, column: 1), Cell(row: row, column: max(width, 1)))
        case .column(let c):
            guard height >= 2 else { return nil }
            let col = resolve(c, rows: false)
            return (Cell(row: 2, column: col), Cell(row: height, column: col))
        case .range(let a, let b):
            let r1 = resolve(a.row!, rows: true), r2 = resolve(b.row!, rows: true)
            let c1 = resolve(a.column!, rows: false), c2 = resolve(b.column!, rows: false)
            return (Cell(row: min(r1, r2), column: min(c1, c2)), Cell(row: max(r1, r2), column: max(c1, c2)))
        }
    }

    /// The cells the formulas fill, each with the index (into `parse(formulaLines:)`) of
    /// the formula that fills it: the last one, as in evaluation. Formulas that don't
    /// parse or reach outside the table fill nothing. For the UI: which cells are computed.
    static func targets(grid: [[String]], formulaLines: [String]) -> [Cell: Int] {
        let width = grid.map(\.count).max() ?? 0, height = grid.count
        var out: [Cell: Int] = [:]
        for (i, p) in parse(formulaLines: formulaLines).enumerated() {
            guard case let .success(f) = p.result, let (first, last) = corners(of: f.destination, width: width, height: height),
                  first.row >= 1, first.column >= 1, last.row <= height, last.column <= width else { continue }
            for r in first.row...last.row {
                for c in first.column...last.column { out[Cell(row: r, column: c)] = i }
            }
        }
        return out
    }

    // MARK: - Markdown

    /// The TBLFM comment lines directly below a table (no blank line between, as in
    /// Advanced Tables), as one range of whole lines including their line breaks; nil if
    /// there are none. `tableRange` is the table's block range (it may or may not include
    /// the final line break). Treat the result as part of the table's block: it should
    /// move, copy and delete with it.
    static func trailingFormulaRange(in text: NSString, tableRange: NSRange) -> NSRange? {
        var loc = NSMaxRange(tableRange)
        guard loc <= text.length else { return nil }
        // If the table range stops before its last line break, start at the next line.
        if loc > 0, loc < text.length {
            var s = 0, e = 0, ce = 0
            text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: loc - 1, length: 0))
            if loc <= ce { loc = e }
        }
        let start = loc
        while loc < text.length {
            var s = 0, e = 0, ce = 0
            text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: loc, length: 0))
            guard isFormulaLine(text.substring(with: NSRange(location: s, length: ce - s))) else { break }
            loc = e
        }
        return loc > start ? NSRange(location: start, length: loc - start) : nil
    }

    /// The cells of a table row (`| a | b |`), trimmed. `\|` and pipes inside backticks stay in the cell.
    static func cells(ofRow line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = [], current = "", inCode = false, escaped = false
        for ch in t {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Applies formulas to one table. `tableMarkdown` is the table's own text (header,
    /// delimiter and body rows, as in the scanner's `.table` block); `formulaLines` are its
    /// TBLFM lines (see `trailingFormulaRange`). Rows with a changed cell are rewritten as
    /// `| a | b |`; every other line, the delimiter row included, keeps its exact bytes.
    /// On any issue the markdown comes back unchanged.
    static func apply(tableMarkdown: String, formulaLines: [String], variables: NoteVariables = .empty) -> (markdown: String, outcome: Outcome) {
        var lines = tableMarkdown.components(separatedBy: "\n")
        // Table rows: every non-blank line except the delimiter (the second one).
        let rowLines = lines.indices.filter { $0 != 1 && !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let grid = rowLines.map { cells(ofRow: lines[$0]) }
        let outcome = evaluate(grid: grid, formulaLines: formulaLines.map { $0.trimmingCharacters(in: .newlines) }, variables: variables)
        for row in Set(outcome.changed.map(\.row)) {
            let i = rowLines[row - 1]
            let indent = String(lines[i].prefix { $0 == " " || $0 == "\t" })
            let crlf = lines[i].hasSuffix("\r") ? "\r" : ""
            lines[i] = indent + "| " + outcome.grid[row - 1].joined(separator: " | ") + " |" + crlf
        }
        return (lines.joined(separator: "\n"), outcome)
    }

    /// Runs the formulas of every table in a note, using the note's frontmatter variables.
    /// Tables are found by the editor's own `MarkdownScanner` (so tables inside code
    /// fences, math or frontmatter are never touched), and each one's formulas are the
    /// TBLFM lines right below it. Returns the new note text; it equals the input when
    /// nothing changed or a table had issues.
    static func apply(toNote text: String) -> (text: String, outcomes: [Outcome]) {
        let ns = text as NSString
        let variables = NoteVariables.parse(noteText: text)
        let out = NSMutableString(string: text)
        var outcomes: [Outcome] = []
        // Back to front, so earlier ranges stay valid as later tables change length.
        for block in MarkdownScanner.scan(ns).reversed() {
            guard case .table = block.kind, let formulas = trailingFormulaRange(in: ns, tableRange: block.range) else { continue }
            let formulaLines = ns.substring(with: formulas).components(separatedBy: "\n").filter { !$0.isEmpty }
            let (markdown, outcome) = apply(tableMarkdown: ns.substring(with: block.range), formulaLines: formulaLines, variables: variables)
            outcomes.insert(outcome, at: 0)
            if !outcome.changed.isEmpty { out.replaceCharacters(in: block.range, with: markdown) }
        }
        return (out as String, outcomes)
    }
}
