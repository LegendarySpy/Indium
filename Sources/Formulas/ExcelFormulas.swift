import Foundation

/// Table formulas as a spreadsheet shows them: `=B2-B3`, `=SUM(B2:B5)`,
/// `=ROUND(B4/B2*100, 1)`. The note still stores TBLFM lines; this translates both ways.
///
/// Cells are named as in a spreadsheet: columns are letters (A is the leftmost, label
/// column included) and rows are numbers with the header row as 1. So `B4` is TBLFM's
/// `@4$2`, and the numbers match TBLFM's rows exactly.
enum ExcelFormulas {
    typealias Cell = TableFormulas.Cell

    // MARK: Names

    /// 1 → A, 26 → Z, 27 → AA.
    static func columnName(_ column: Int) -> String {
        var n = column, name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func name(_ cell: Cell) -> String { columnName(cell.column) + "\(cell.row)" }

    /// A whole area, `B4` or `B4:D4`.
    static func name(from a: Cell, to b: Cell) -> String { a == b ? name(a) : name(a) + ":" + name(b) }

    /// How a formula typed in one cell is stored.
    enum Fill: Equatable {
        /// Just this cell; every reference is absolute (`@4$2=(@2$2-@3$2)`).
        case cell
        /// Along the row to a column, as Fill Right copies it: references move with the
        /// column (`@4$2..@4$>=(@2-@3)`) unless written with `$` (`$B2`).
        case row(through: CellReference.Index)
        /// Down the column to a row, as Fill Down copies it.
        case column(through: CellReference.Index)
    }

    // MARK: Spreadsheet → TBLFM

    /// The TBLFM formula for `text` (`=B2-B3`, the `=` optional) typed in `cell`.
    /// A top-level `ROUND(x, n)` becomes the `;%.nf` directive. `variables` are the note's
    /// variable names: one shaped like a cell (`x1`) is read as the variable.
    static func tblfm(_ text: String, at cell: Cell, fill: Fill = .cell, variables: Set<String> = []) -> Result<String, FormulaError> {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("=") { body.removeFirst() }
        var parser = Parser(body, cell: cell, fill: fill, variables: variables)
        let node: FormulaNode
        do { node = try parser.parseAll() } catch let e as FormulaError { return .failure(e) } catch {
            return .failure(FormulaError(kind: .parse, message: "\(error)"))
        }
        var source = node, decimals: Int?
        if case let .call("round", args) = node, args.count == 2, case let .number(n) = args[1], let d = Int(n), (0...15).contains(d) {
            source = args[0]
            decimals = d
        }
        let destination: String
        switch fill {
        case .cell: destination = "@\(cell.row)$\(cell.column)"
        case .row(let end): destination = "@\(cell.row)$\(cell.column)..@\(cell.row)" + CellReference(column: end).description
        case .column(let end): destination = "@\(cell.row)$\(cell.column).." + CellReference(row: end).description + "$\(cell.column)"
        }
        let formula = destination + "=" + tblfmText(source, top: true) + (decimals.map { ";%.\($0)f" } ?? "")
        // The engine has the last word, so whatever is stored is what it evaluates.
        return TableFormulas.parseFormula(formula).map { _ in formula }
    }

    /// TBLFM source text: every operation in its own parentheses, as Advanced Tables wants.
    private static func tblfmText(_ node: FormulaNode, top: Bool = false) -> String {
        switch node {
        case .number(let n): return n
        case .constant(let c): return c
        case .variable(let v): return v
        case .reference(let r): return r.description
        case let .range(a, b): return "\(a)..\(b)"
        case .negate(let n): return "-" + tblfmText(n)
        case let .binary(op, a, b):
            var left = tblfmText(a)
            // `ln(x)^2` would read as ln(x^2): a function written without parentheses takes the power.
            if op == "^", case let .call(name, _) = a, Evaluator.mathFunctions.contains(name) { left = "(" + left + ")" }
            return "(" + left + String(op) + tblfmText(b) + ")"
        case let .call(name, args):
            if Evaluator.mathFunctions.contains(name), args.count == 1 {
                if case .binary = args[0] { return name + tblfmText(args[0]) }
                return name + "(" + tblfmText(args[0]) + ")"
            }
            return name + "(" + args.map { tblfmText($0) }.joined(separator: ",") + ")"
        case .group(let n):
            if case .binary = n { return tblfmText(n) }
            return "(" + tblfmText(n) + ")"
        case .percent(let n): return "(" + tblfmText(n) + "/100)"
        case let .unit(n, _): return tblfmText(n)
        case let .implicitProduct(a, b): return "(" + tblfmText(a) + "*" + tblfmText(b) + ")"
        }
    }

    // MARK: TBLFM → spreadsheet

    /// The formula that fills `cell`, as a spreadsheet shows it there (`=C2-C3` in C4 for
    /// `@4$2..@4$>=(@2-@3)`). Nil when no formula fills it or it can't be put that way.
    static func formula(at cell: Cell, grid: [[String]], formulaLines: [String]) -> String? {
        guard let i = TableFormulas.targets(grid: grid, formulaLines: formulaLines)[cell],
              case let .success(f) = TableFormulas.parse(formulaLines: formulaLines)[i].result else { return nil }
        return excel(f, at: cell, width: grid.map(\.count).max() ?? 0, height: grid.count)
    }

    /// One formula as seen from one of the cells it fills. References show `$` where they
    /// stay put as the formula fills more than one cell (`$B2`).
    static func excel(_ f: TableFormulas.Formula, at cell: Cell, width: Int, height: Int) -> String? {
        guard let (first, last) = TableFormulas.corners(of: f.destination, width: width, height: height) else { return nil }
        let spansRows = first.row != last.row, spansColumns = first.column != last.column
        func resolve(_ i: CellReference.Index, current: Int, rows: Bool) -> Int? {
            let n: Int
            switch i {
            case .absolute(let a): n = a
            case .first: n = 1
            case .last: n = rows ? height : width
            case .firstBody: n = 2
            case .relative(let k): n = current + k
            }
            return n >= 1 && n <= (rows ? height : width) ? n : nil
        }
        func fixed(_ i: CellReference.Index?) -> Bool {
            guard let i else { return false }
            if case .relative = i { return false }
            return true
        }
        func ref(_ r: CellReference) -> String? {
            guard let row = r.row.map({ resolve($0, current: cell.row, rows: true) }) ?? cell.row,
                  let column = r.column.map({ resolve($0, current: cell.column, rows: false) }) ?? cell.column else { return nil }
            return (spansColumns && fixed(r.column) ? "$" : "") + columnName(column) + (spansRows && fixed(r.row) ? "$" : "") + "\(row)"
        }
        // Precedence: 1 + −, 2 × ÷, 3 unary minus, 4 ^, 5 everything that can't split.
        func text(_ node: FormulaNode) -> (String, Int)? {
            switch node {
            case .number(let n): return (n, 5)
            case .constant(let c): return (c == "pi" ? "PI()" : c, 5)
            case .variable(let v): return (v, 5)
            case .reference(let r): return ref(r).map { ($0, 5) }
            case let .range(a, b):
                guard let a = ref(a), let b = ref(b) else { return nil }
                return (a + ":" + b, 5)
            case .group(let n): return text(n)
            case .negate(let n):
                guard let (t, p) = text(n) else { return nil }
                return ("-" + (p < 3 ? "(\(t))" : t), 3)
            case let .binary(op, a, b):
                let p = op == "^" ? 4 : "*/".contains(op) ? 2 : 1
                guard let (l, lp) = text(a), let (r, rp) = text(b) else { return nil }
                let wrapLeft = lp < p || (op == "^" && lp == p)
                let wrapRight = rp < p || (rp == p && "-/".contains(op))
                return ((wrapLeft ? "(\(l))" : l) + String(op) + (wrapRight ? "(\(r))" : r), p)
            case let .call(name, args):
                var parts: [String] = []
                for a in args {
                    guard let (t, _) = text(a) else { return nil }
                    parts.append(t)
                }
                return (functionName(name) + "(" + parts.joined(separator: ", ") + ")", 5)
            case .percent, .unit, .implicitProduct:
                return nil
            }
        }
        guard let (source, _) = text(f.source) else { return nil }
        return "=" + (f.decimals.map { "ROUND(\(source), \($0))" } ?? source)
    }

    private static let functionNames = ["mean": "AVERAGE", "log": "LOG10"]
    private static func functionName(_ name: String) -> String { functionNames[name] ?? name.uppercased() }

    // MARK: Messages

    private static let cellPattern = try! NSRegularExpression(pattern: #"@(\d+)\$(\d+)(?:\.\.@(\d+)\$(\d+))?"#)

    /// TBLFM cell names in an engine message (`@4$2`, `@2$2..@5$2`) as spreadsheet names.
    static func readable(_ message: String) -> String {
        let ns = message as NSString
        var out = message
        for m in cellPattern.matches(in: message, range: NSRange(location: 0, length: ns.length)).reversed() {
            func n(_ i: Int) -> Int { Int(ns.substring(with: m.range(at: i))) ?? 0 }
            var name = name(Cell(row: n(1), column: n(2)))
            if m.range(at: 3).location != NSNotFound { name += ":" + self.name(Cell(row: n(3), column: n(4))) }
            out = (out as NSString).replacingCharacters(in: m.range, with: name)
        }
        return out
    }

    /// A problem as a spreadsheet would put it, with its error code where it has one:
    /// "#DIV/0! Division by zero".
    static func message(_ e: FormulaError) -> String {
        let text = readable(e.message)
        switch e.kind {
        case .divisionByZero: return "#DIV/0! Division by zero"
        case .badReference: return "#REF! " + text
        case .notNumeric, .incompatibleUnits: return "#VALUE! " + text
        case .rangeMisuse: return "#VALUE! A range like B2:B5 only works inside SUM, AVERAGE, MIN, MAX or COUNT"
        case .unknownVariable: return "#NAME? " + text + ". Define it in the note's properties"
        case .unknownFunction: return "#NAME? " + text
        case .notReal: return "#NUM! " + text
        case .cycle: return text.replacingOccurrences(of: "Formulas depend on themselves", with: "Circular reference")
        case .parse, .unsupported, .blank: return text
        }
    }

    // MARK: Changing a table's formulas

    /// Every formula under the table, where it is: its line, its place on that line, its
    /// text, and the area it fills (nil when it doesn't parse or reaches outside the table).
    private struct Placed {
        let line: Int
        let index: Int
        let text: String
        let formula: TableFormulas.Formula?
        let area: (Cell, Cell)?
    }

    private static func placed(_ lines: [String], width: Int, height: Int) -> [Placed] {
        var out: [Placed] = []
        for (n, line) in lines.enumerated() {
            guard let body = TableFormulas.formulaText(ofLine: line) else { continue }
            for (k, piece) in body.components(separatedBy: "::").enumerated() {
                let text = piece.trimmingCharacters(in: .whitespaces)
                let f = try? TableFormulas.parseFormula(text).get()
                var area = f.flatMap { TableFormulas.corners(of: $0.destination, width: width, height: height) }
                if let (a, b) = area, a.row < 1 || a.column < 1 || b.row > height || b.column > width { area = nil }
                out.append(Placed(line: n, index: k, text: text, formula: f, area: area))
            }
        }
        return out
    }

    /// `lines` with each piece replaced by what `edit` returns for it (nil removes it). Lines
    /// left with no formula are removed; untouched lines keep their bytes.
    private static func rewrite(_ lines: [String], width: Int, height: Int, _ edit: (Placed) -> [String]?) -> [String] {
        let all = placed(lines, width: width, height: height)
        var out: [String] = []
        for (n, line) in lines.enumerated() {
            let pieces = all.filter { $0.line == n }
            guard !pieces.isEmpty else { out.append(line); continue }
            var changed = false
            var kept: [String] = []
            for p in pieces {
                if let e = edit(p) {
                    if e != [p.text] { changed = true }
                    kept += e
                } else {
                    changed = true
                }
            }
            if !changed { out.append(line); continue }
            if !kept.isEmpty { out.append("<!-- TBLFM: " + kept.joined(separator: "::") + " -->") }
        }
        return out
    }

    private static func contains(_ outer: (Cell, Cell), _ inner: (Cell, Cell)) -> Bool {
        inner.0.row >= outer.0.row && inner.1.row <= outer.1.row && inner.0.column >= outer.0.column && inner.1.column <= outer.1.column
    }

    /// The lines with `formula` (TBLFM, as from `tblfm`) added. Formulas that only fill
    /// cells it fills are dropped. One that filled exactly the same cells is replaced where
    /// it stood, as long as nothing after it takes those cells back; otherwise the new
    /// formula goes on a line of its own at the end, where it wins.
    static func setting(_ formula: String, in lines: [String], grid: [[String]]) -> [String] {
        let width = grid.map(\.count).max() ?? 0, height = grid.count
        guard case let .success(f) = TableFormulas.parseFormula(formula),
              let area = TableFormulas.corners(of: f.destination, width: width, height: height) else { return lines }
        let all = placed(lines, width: width, height: height)
        let same = all.last { $0.area.map { $0 == area } ?? false }
        if let same {
            let inPlace = rewrite(lines, width: width, height: height) { p in
                if p.line == same.line, p.index == same.index { return [formula] }
                return p.area.map { contains(area, $0) } == true ? nil : [p.text]
            }
            let fills = TableFormulas.targets(grid: grid, formulaLines: inPlace)
            let parsed = TableFormulas.parse(formulaLines: inPlace)
            let wins = (area.0.row...area.1.row).allSatisfy { r in
                (area.0.column...area.1.column).allSatisfy { c in
                    fills[Cell(row: r, column: c)].map { parsed[$0].text == formula } ?? false
                }
            }
            if wins { return inPlace }
        }
        let rest = rewrite(lines, width: width, height: height) { p in p.area.map { contains(area, $0) } == true ? nil : [p.text] }
        return rest + ["<!-- TBLFM: \(formula) -->"]
    }

    /// The lines with no formula filling any cell from `a` to `b` any more: formulas
    /// that filled more keep the rest of their cells, split into smaller areas.
    static func removing(from a: Cell, to b: Cell, in lines: [String], grid: [[String]]) -> [String] {
        let width = grid.map(\.count).max() ?? 0, height = grid.count
        let cut = (Cell(row: min(a.row, b.row), column: min(a.column, b.column)), Cell(row: max(a.row, b.row), column: max(a.column, b.column)))
        return rewrite(lines, width: width, height: height) { p in
            guard let f = p.formula, let area = p.area,
                  area.0.row <= cut.1.row, area.1.row >= cut.0.row, area.0.column <= cut.1.column, area.1.column >= cut.0.column
            else { return [p.text] }
            // What's left of the area: whole rows above and below the cut, then the cells
            // beside it in the rows it crosses.
            var pieces: [(Cell, Cell)] = []
            if area.0.row < cut.0.row { pieces.append((area.0, Cell(row: cut.0.row - 1, column: area.1.column))) }
            if area.1.row > cut.1.row { pieces.append((Cell(row: cut.1.row + 1, column: area.0.column), area.1)) }
            let rows = (max(area.0.row, cut.0.row), min(area.1.row, cut.1.row))
            if area.0.column < cut.0.column { pieces.append((Cell(row: rows.0, column: area.0.column), Cell(row: rows.1, column: cut.0.column - 1))) }
            if area.1.column > cut.1.column { pieces.append((Cell(row: rows.0, column: cut.1.column + 1), Cell(row: rows.1, column: area.1.column))) }
            // An area that ran to the last row or column still does, so it grows with the table.
            let (openRow, openColumn): (Bool, Bool)
            switch f.destination {
            case .row: (openRow, openColumn) = (false, true)
            case .column: (openRow, openColumn) = (true, false)
            case .cell(let r): (openRow, openColumn) = (r.row == .last, r.column == .last)
            case let .range(s, e): (openRow, openColumn) = (e.row == .last, (e.column ?? s.column) == .last)
            }
            guard let eq = p.text.firstIndex(of: "=") else { return [p.text] }
            let source = p.text[p.text.index(after: eq)...]
            return pieces.map { s, e in
                let row = openRow && e.row == height ? ">" : "\(e.row)", column = openColumn && e.column == width ? ">" : "\(e.column)"
                let destination = s == e && !row.hasPrefix(">") && !column.hasPrefix(">") ? "@\(s.row)$\(s.column)" : "@\(s.row)$\(s.column)..@\(row)$\(column)"
                return destination + "=" + source
            }
        }
    }

    /// Typing `text` (`=B2-B3`) in `cell`: the formula lines with it as the cell's formula.
    /// The lines come back unchanged when the text is the formula the cell already shows.
    /// Fails with what's wrong when the formula doesn't parse, or gives a problem the
    /// table didn't have before (a division by zero, a reference outside the table, a
    /// circular reference): then nothing should change.
    static func entering(_ text: String, in cell: Cell, grid: [[String]], formulaLines: [String],
                         variables: NoteVariables = .empty) -> Result<[String], FormulaError> {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed == formula(at: cell, grid: grid, formulaLines: formulaLines) { return .success(formulaLines) }
        switch tblfm(typed, at: cell, variables: Set(variables.values.keys)) {
        case .failure(let e): return .failure(e)
        case .success(let f): return checked(setting(f, in: formulaLines, grid: grid), was: formulaLines, grid: grid, variables: variables)
        }
    }

    /// Fill Right or Fill Down: the formula `cell` shows, copied along its row or down its
    /// column to `end` (the last column or row when nil), as a spreadsheet copies it.
    static func filling(from cell: Cell, down: Bool, through end: Int? = nil, grid: [[String]], formulaLines: [String],
                        variables: NoteVariables = .empty) -> Result<[String], FormulaError> {
        guard let shown = formula(at: cell, grid: grid, formulaLines: formulaLines) else {
            return .failure(FormulaError(kind: .parse, message: "\(name(cell)) has no formula to fill"))
        }
        let through: CellReference.Index = end.map { .absolute($0) } ?? .last
        switch tblfm(shown, at: cell, fill: down ? .column(through: through) : .row(through: through), variables: Set(variables.values.keys)) {
        case .failure(let e): return .failure(e)
        case .success(let f): return checked(setting(f, in: formulaLines, grid: grid), was: formulaLines, grid: grid, variables: variables)
        }
    }

    private static func checked(_ lines: [String], was old: [String], grid: [[String]], variables: NoteVariables) -> Result<[String], FormulaError> {
        func key(_ i: TableFormulas.Issue) -> String { "\(i.cell?.description ?? "")|\(i.error.message)" }
        let before = Set(TableFormulas.evaluate(grid: grid, formulaLines: old, variables: variables).issues.map(key))
        let after = TableFormulas.evaluate(grid: grid, formulaLines: lines, variables: variables)
        if let issue = after.issues.first(where: { !before.contains(key($0)) }) { return .failure(issue.error) }
        return .success(lines)
    }

    // MARK: - Parser

    /// Spreadsheet syntax with the usual precedence, as the evaluator has it (`-2^2` is −4):
    ///   expression := term (('+' | '-') term)*
    ///   term       := unary (('*' | '/') unary)*
    ///   unary      := ('-' | '+') unary | power
    ///   power      := postfix ('^' unary)?
    ///   postfix    := primary '%'*
    ///   primary    := number | cell [':' cell] | NAME '(' args ')' | name | '(' expression ')'
    private struct Parser {
        let chars: [Character]
        let cell: Cell
        let fill: Fill
        let variables: Set<String>
        var i = 0

        init(_ s: String, cell: Cell, fill: Fill, variables: Set<String>) {
            chars = Array(s)
            self.cell = cell
            self.fill = fill
            self.variables = variables
        }

        func error(_ message: String) -> FormulaError { FormulaError(kind: .parse, message: message, position: i) }

        mutating func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        mutating func peek() -> Character? {
            skipSpace()
            return i < chars.count ? chars[i] : nil
        }

        static func operatorChar(_ c: Character) -> Character? {
            switch c {
            case "+": "+"
            case "-", "−": "-"
            case "*", "×", "·": "*"
            case "/", "÷": "/"
            default: nil
            }
        }

        mutating func parseAll() throws -> FormulaNode {
            guard peek() != nil else { throw error("Type a formula after =, like =B2-B3") }
            let node = try expression()
            if let c = peek() {
                if c == ")" { throw error("There's a “)” without a “(” before it") }
                if "=<>&".contains(c) { throw error("Formulas here calculate numbers; they can't compare values or join text") }
                if c == "," || c == ";" { throw error("“\(c)” only separates the values given to a function, like SUM(B2, B3)") }
                throw error("Unexpected “\(c)”")
            }
            return node
        }

        mutating func expression() throws -> FormulaNode {
            var node = try term()
            while let c = peek(), let op = Parser.operatorChar(c), op == "+" || op == "-" {
                i += 1
                node = .binary(op, node, try term())
            }
            return node
        }

        mutating func term() throws -> FormulaNode {
            var node = try unary()
            while let c = peek(), let op = Parser.operatorChar(c), op == "*" || op == "/" {
                i += 1
                node = .binary(op, node, try unary())
            }
            return node
        }

        mutating func unary() throws -> FormulaNode {
            if let c = peek(), let op = Parser.operatorChar(c), op == "-" || op == "+" {
                i += 1
                let inner = try unary()
                return op == "-" ? .negate(inner) : inner
            }
            return try power()
        }

        mutating func power() throws -> FormulaNode {
            let base = try postfix()
            if peek() == "^" {
                i += 1
                return .binary("^", base, try unary())
            }
            return base
        }

        mutating func postfix() throws -> FormulaNode {
            var node = try primary()
            while peek() == "%" {
                i += 1
                node = .percent(node)
            }
            return node
        }

        mutating func primary() throws -> FormulaNode {
            guard let c = peek() else { throw error("The formula ends too soon") }
            if c == "(" {
                i += 1
                let inner = try expression()
                guard peek() == ")" else { throw error("A “)” is missing") }
                i += 1
                return .group(inner)
            }
            if c.isASCII, c.isNumber || c == "." { return .number(try number()) }
            if let a = try reference() {
                let save = i
                if peek() == ":" {
                    i += 1
                    skipSpace()
                    guard let b = try reference() else { throw error("A range needs a cell after “:”, like B2:B5") }
                    return range(a, b)
                }
                i = save
                return .reference(single(a))
            }
            if c.isLetter || c == "_" {
                let start = i
                while i < chars.count, chars[i].isASCII, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
                guard i > start else { throw error("“\(c)” isn't something formulas understand") }
                let name = String(chars[start..<i])
                if peek() == "(" {
                    if name.uppercased() == "IF" { throw FormulaError(kind: .unsupported, message: "IF isn't supported yet", position: start) }
                    i += 1
                    var args: [FormulaNode] = []
                    if peek() != ")" {
                        repeat {
                            if peek() == "," || peek() == ";" { i += 1 }
                            args.append(try expression())
                        } while peek() == "," || peek() == ";"
                    }
                    guard peek() == ")" else { throw error("A “)” is missing after \(name.uppercased())(…") }
                    i += 1
                    return try function(name, args)
                }
                let lower = name.lowercased()
                if lower == "pi" || lower == "e" { return .constant(lower) }
                if lower == "true" || lower == "false" { throw error("Formulas here calculate numbers, not TRUE or FALSE") }
                return .variable(name)
            }
            if c == "\"" { throw error("Formulas here calculate numbers; text in quotes isn't supported") }
            if c == "@" || c == "$" { throw error("Name cells by column letter and row number, like B4") }
            throw error("Unexpected “\(c)”")
        }

        mutating func number() throws -> String {
            let start = i
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
            if i < chars.count, chars[i] == "." {
                i += 1
                while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
            }
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                var j = i + 1
                if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                    i = j
                }
            }
            let text = String(chars[start..<i])
            guard text != ".", Double(text) != nil else { throw error("“\(text)” isn't a number") }
            return text
        }

        struct Ref {
            var column: Int, row: Int
            var fixedColumn: Bool, fixedRow: Bool
        }

        /// `B4`, `$B$4`, `b4`. Nil (and nothing read) when the next word isn't a cell,
        /// or is one of the note's variables.
        mutating func reference() throws -> Ref? {
            let start = i
            var j = i
            let fixedColumn = j < chars.count && chars[j] == "$"
            if fixedColumn { j += 1 }
            let letters = j
            while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
            let columnText = String(chars[letters..<j])
            let fixedRow = j < chars.count && chars[j] == "$"
            if fixedRow { j += 1 }
            let digits = j
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            let rowText = String(chars[digits..<j])
            let continues = j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "(")
            guard !columnText.isEmpty, columnText.count <= 3, !rowText.isEmpty, !continues else {
                if fixedColumn || fixedRow { throw error("“\(String(chars[start..<max(j, start + 1)]))” isn't a cell; write cells like B4 or $B$4") }
                return nil
            }
            if !fixedColumn, !fixedRow, variables.contains(columnText + rowText) { return nil }
            let column = columnText.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
            guard let row = Int(rowText), row >= 1, row <= 100_000 else {
                throw FormulaError(kind: .badReference, message: "\(columnText.uppercased())\(rowText) is outside the table", position: start)
            }
            i = j
            return Ref(column: column, row: row, fixedColumn: fixedColumn, fixedRow: fixedRow)
        }

        /// How the reference is stored for the way the formula fills: absolute for one cell;
        /// moving with the fill, as TBLFM writes it, unless fixed with `$`. A part that
        /// stays on the formula's own row or column is left out (`@2` is row 2 of this
        /// column); in a range it's written `+0` instead, unless both ends leave it out.
        func encode(_ r: Ref) -> CellReference {
            var ref = CellReference(row: .absolute(r.row), column: .absolute(r.column))
            switch fill {
            case .cell: break
            case .row: if !r.fixedColumn { ref.column = .relative(r.column - cell.column) }
            case .column: if !r.fixedRow { ref.row = .relative(r.row - cell.row) }
            }
            return ref
        }

        func single(_ r: Ref) -> CellReference {
            var ref = encode(r)
            if ref.row == .relative(0) { ref.row = nil }
            if ref.column == .relative(0) { ref.column = nil }
            return ref
        }

        func range(_ a: Ref, _ b: Ref) -> FormulaNode {
            var x = encode(a), y = encode(b)
            if x.row == .relative(0), y.row == .relative(0) { x.row = nil; y.row = nil }
            if x.column == .relative(0), y.column == .relative(0) { x.column = nil; y.column = nil }
            return .range(x, y)
        }

        func function(_ raw: String, _ args: [FormulaNode]) throws -> FormulaNode {
            let name = raw.uppercased()
            func one() throws -> FormulaNode {
                guard args.count == 1 else { throw FormulaError(kind: .parse, message: "\(name) takes one value, like \(name)(B2)") }
                return args[0]
            }
            switch name {
            case "SUM", "MIN", "MAX", "COUNT":
                guard !args.isEmpty else { throw FormulaError(kind: .parse, message: "\(name) needs values, like \(name)(B2:B5)") }
                return .call(name.lowercased(), args)
            case "AVERAGE":
                guard !args.isEmpty else { throw FormulaError(kind: .parse, message: "AVERAGE needs values, like AVERAGE(B2:B5)") }
                return .call("mean", args)
            case "SQRT", "ABS", "LN", "SIN", "COS", "TAN": return .call(name.lowercased(), [try one()])
            case "LOG10": return .call("log", [try one()])
            case "LOG":
                guard args.count == 1 else { throw FormulaError(kind: .unsupported, message: "LOG with a base isn't supported; LOG(x) is base 10, and LN(x) base e") }
                return .call("log", args)
            case "ROUND":
                guard args.count == 2 else { throw FormulaError(kind: .parse, message: "ROUND takes a value and a number of decimal places, like ROUND(B4, 1)") }
                return .call("round", args)
            case "POWER":
                guard args.count == 2 else { throw FormulaError(kind: .parse, message: "POWER takes two values, like POWER(B2, 2)") }
                return .binary("^", args[0], args[1])
            case "PI":
                guard args.isEmpty else { throw FormulaError(kind: .parse, message: "PI() takes no values") }
                return .constant("pi")
            default:
                throw FormulaError(kind: .unknownFunction, message: "Unknown function \(name)")
            }
        }
    }
}
