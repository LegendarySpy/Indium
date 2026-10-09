#if DEBUG
import Foundation

/// Regression runners for the formula code, driven from the DEBUG harness
/// (`-IndiumEvalCases file.tsv`). Pure Foundation, so they also run from a plain
/// `swiftc` build of `Sources/Formulas` + `MathAnswers.swift`.
enum FormulaSelfTest {
    /// Runs case files; each says what it holds on its first line
    /// (`# kind: quick-answers`, `# kind: evaluator`, `# kind: tables`, `# kind: excel`). Returns the failure count.
    static func run(paths: [String], verbose: Bool = false) -> Int {
        var failed = 0
        for path in paths {
            let first = (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n").first ?? ""
            print("== \(path)")
            if first.contains("kind: evaluator") { failed += runEvaluatorCases(path: path) }
            else if first.contains("kind: tables") { failed += runTableCases(path: path, verbose: verbose) }
            else if first.contains("kind: excel") { failed += runExcelCases(path: path) }
            else { failed += runQuickAnswerCases(path: path) }
        }
        print(failed == 0 ? "ALL FORMULA CASES PASSED" : "FORMULA CASES FAILED: \(failed)")
        return failed
    }

    /// Evaluator cases: `expression<TAB>expected[<TAB>frontmatter]`. Expected is the formatted
    /// result (`1.293 g`) or `ERROR:kind` (`ERROR:incompatibleUnits`). Every successful result
    /// must also read back: `Quantity.parse` of its text formats to the same text.
    @discardableResult
    static func runEvaluatorCases(path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); return 1 }
        var failed = 0, total = 0
        for raw in text.components(separatedBy: "\n") where !raw.isEmpty && !raw.hasPrefix("#") {
            let p = raw.components(separatedBy: "\t")
            guard p.count >= 2 else { continue }
            total += 1
            let vars = p.count > 2 ? NoteVariables.parse(noteText: p[2].replacingOccurrences(of: "↵", with: "\n")) : .empty
            let got: String
            var roundTrip = true
            switch Evaluator.evaluate(p[0], environment: .init(variables: vars.values)) {
            case .success(let q):
                got = q.formatted()
                if let back = Quantity.parse(got) { roundTrip = back.formatted() == got && back.unit == q.unit } else { roundTrip = false }
            case .failure(let e): got = "ERROR:\(e.kind.rawValue)"
                if !p[1].hasPrefix("ERROR") { print("    (\(e.message))") }
            }
            let ok = got == p[1] && roundTrip
            if !ok { failed += 1 }
            print(ok ? "PASS" : "FAIL", p[0], "→", got, ok ? "" : roundTrip ? "(expected \(p[1]))" : "(doesn't read back)")
        }
        print("EVALUATOR CASES: \(total - failed)/\(total) passed")
        return failed
    }

    /// Spreadsheet-syntax cases (ExcelFormulas.swift), one per line, in a table 6 rows by 4 columns:
    /// - `tblfm<TAB>cell<TAB>fill<TAB>typed<TAB>expected[<TAB>shown]`: `typed` (`=B2-B3`) in `cell` (`B4`)
    ///   stored for `fill` (`cell`, `row` or `column`, to the last) as `expected` (TBLFM, or `ERROR:kind`).
    ///   A success must show again as `shown` in that cell (`typed` when omitted).
    /// - `excel<TAB>cell<TAB><TAB>formula<TAB>expected`: the TBLFM `formula` shown in `cell`.
    /// - `message<TAB>kind<TAB><TAB>engine message<TAB>expected`: a problem as the table editor words it.
    @discardableResult
    static func runExcelCases(path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); return 1 }
        func cell(_ name: String) -> TableFormulas.Cell? {
            let letters = name.prefix { $0.isLetter }, digits = name.dropFirst(letters.count)
            guard !letters.isEmpty, let row = Int(digits) else { return nil }
            return TableFormulas.Cell(row: row, column: letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 })
        }
        var failed = 0, total = 0
        for raw in text.components(separatedBy: "\n") where !raw.isEmpty && !raw.hasPrefix("#") {
            let p = raw.components(separatedBy: "\t")
            guard p.count >= 5 else { print("SKIP", raw); continue }
            total += 1
            var got = "", want = p[4], note = ""
            switch p[0] {
            case "tblfm":
                guard let at = cell(p[1]) else { got = "bad cell"; break }
                let fill: ExcelFormulas.Fill = p[2] == "row" ? .row(through: .last) : p[2] == "column" ? .column(through: .last) : .cell
                switch ExcelFormulas.tblfm(p[3], at: at, fill: fill, variables: ["x1", "water_molar_mass"]) {
                case .success(let f):
                    got = f
                    let shown = try? TableFormulas.parseFormula(f).get()
                    let back = shown.flatMap { ExcelFormulas.excel($0, at: at, width: 4, height: 6) } ?? "nil"
                    let expected = p.count > 5 ? p[5] : p[3]
                    if back != expected { note = " (shows as \(back), expected \(expected))" }
                case .failure(let e):
                    got = "ERROR:\(e.kind.rawValue)"
                    if !want.hasPrefix("ERROR") { note = " (\(e.message))" }
                }
            case "excel":
                guard let at = cell(p[1]) else { got = "bad cell"; break }
                switch TableFormulas.parseFormula(p[3]) {
                case .success(let f): got = ExcelFormulas.excel(f, at: at, width: 4, height: 6) ?? "nil"
                case .failure(let e): got = "ERROR:\(e.kind.rawValue)"
                }
            case "message":
                guard let kind = FormulaError.Kind(rawValue: p[1]) else { got = "bad kind"; break }
                got = ExcelFormulas.message(FormulaError(kind: kind, message: p[3]))
            default:
                want = "?"
            }
            let ok = got == want && note.isEmpty
            if !ok { failed += 1 }
            print(ok ? "PASS" : "FAIL", p[0], p[1], p[3], "→", got, ok ? "" : "(expected \(want))\(note)")
        }
        print("EXCEL CASES: \(total - failed)/\(total) passed")
        return failed
    }

    /// Quick-answer cases, one per line:
    /// `mode<TAB>line<TAB>display<TAB>insertion[<TAB>frontmatter]`
    /// - mode: `prose` or `math` (the caret is inside math source).
    /// - `∅` in display/insertion: no suggestion. `␠` stands for a space (so trailing spaces survive editors).
    /// - frontmatter: the note's opening text for variables, `↵` for line breaks.
    /// Lines starting with `#` are comments. Prints PASS/FAIL per case and a total; returns the failure count.
    @discardableResult
    static func runQuickAnswerCases(path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("EVAL CASES: can't read \(path)")
            return 1
        }
        func unescape(_ s: String) -> String {
            s.replacingOccurrences(of: "␠", with: " ").replacingOccurrences(of: "↵", with: "\n")
        }
        var failed = 0, total = 0
        for (n, raw) in text.components(separatedBy: "\n").enumerated() where !raw.isEmpty && !raw.hasPrefix("#") {
            let p = raw.components(separatedBy: "\t")
            guard p.count >= 4 else { print("SKIP line \(n + 1): needs 4 tab-separated fields"); continue }
            total += 1
            let line = unescape(p[1])
            let variables = p.count > 4 ? NoteVariables.parse(noteText: unescape(p[4])) : .empty
            let r = MathAnswer.suggest(lineBeforeCaret: line, inMath: p[0] == "math", variables: variables)
            let display = r?.display ?? "∅", insertion = r?.insertion ?? "∅"
            let ok = display == unescape(p[2]) && insertion == unescape(p[3])
            if !ok { failed += 1 }
            let shown = { (s: String) in s.replacingOccurrences(of: " ", with: "␠") }
            print(ok ? "PASS" : "FAIL", p[0], p[1], "→", shown(display), "|", shown(insertion),
                  ok ? "" : "(expected \(p[2]) | \(p[3]))")
        }
        print("EVAL CASES: \(total - failed)/\(total) passed")
        return failed
    }

    /// Whole-note table formula cases. Each case:
    ///
    ///     === name
    ///     <note text in: optional frontmatter, a table, its TBLFM lines>
    ///     --- expect
    ///     <the whole note text out>
    ///     --- issues
    ///     <one line per expected issue: text each must contain; omit the section for none>
    ///     --- edit
    ///     <optional: typing in the first table's cells before the formulas run, one per line:
    ///      `B4 =B2-B3` a formula, `C4 5` a value, `C4` cleared, `fill-right B4`, `fill-down B2`;
    ///      an edit that's refused adds the issue `refused: <message>` and changes nothing>
    ///     --- show
    ///     <optional: `B4 =B2-B3`, the formula a cell of the first table shows afterwards, `B4 ∅` none>
    ///
    /// Prints PASS/FAIL per case (with the output on failure or when `verbose`) and a total.
    @discardableResult
    static func runTableCases(path: String, verbose: Bool = false) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("TABLE CASES: can't read \(path)")
            return 1
        }
        var failed = 0, total = 0
        for chunk in text.components(separatedBy: "\n=== ").dropFirst() {
            var lines = chunk.components(separatedBy: "\n")
            let name = lines.removeFirst()
            var sections: [String: [String]] = ["input": []]
            var current = "input"
            for line in lines {
                if line.hasPrefix("--- ") { current = String(line.dropFirst(4)); sections[current] = []; continue }
                sections[current, default: []].append(line)
            }
            func body(_ key: String) -> String? {
                guard var l = sections[key] else { return nil }
                while l.last?.isEmpty == true { l.removeLast() }
                return l.joined(separator: "\n")
            }
            total += 1
            let edits = (body("edit") ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
            let (input, refusals) = editing(body("input") ?? "", edits)
            let (output, outcomes) = TableFormulas.apply(toNote: input)
            let issues = refusals + outcomes.flatMap(\.issues).map(\.description)
            let expectedIssues = (body("issues") ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
            var problems: [String] = []
            if let expect = body("expect"), output != expect { problems.append("output differs") }
            for want in expectedIssues where !issues.contains(where: { $0.contains(want) }) { problems.append("missing issue: \(want)") }
            if let table = firstTable(output) {
                for line in (body("show") ?? "").components(separatedBy: "\n") where !line.isEmpty {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    guard let cell = cellNamed(parts[0]) else { problems.append("bad cell \(parts[0])"); continue }
                    let shown = ExcelFormulas.formula(at: cell, grid: table.grid, formulaLines: table.formulas) ?? "∅"
                    if shown != (parts.count > 1 ? parts[1] : "∅") { problems.append("\(parts[0]) shows \(shown)") }
                }
            }
            if issues.count != expectedIssues.count { problems.append("expected \(expectedIssues.count) issue(s), got \(issues.count)") }
            if !problems.isEmpty { failed += 1 }
            print(problems.isEmpty ? "PASS" : "FAIL", name, problems.isEmpty ? "" : "— " + problems.joined(separator: "; "))
            if verbose || !problems.isEmpty {
                print(output.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
                for issue in issues { print("    ! " + issue) }
                for o in outcomes where !o.blanks.isEmpty { print("    blank:", o.blanks.map(\.description).joined(separator: " ")) }
            }
        }
        print("TABLE CASES: \(total - failed)/\(total) passed")
        return failed
    }

    static func cellNamed(_ name: String) -> TableFormulas.Cell? {
        let letters = name.prefix { $0.isLetter }, digits = name.dropFirst(letters.count)
        guard !letters.isEmpty, let row = Int(digits) else { return nil }
        return TableFormulas.Cell(row: row, column: letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 })
    }

    /// The note's first table: where it and its formula lines are, its lines, its grid.
    private static func firstTable(_ note: String) -> (range: NSRange, lines: [String], rows: [Int], grid: [[String]], formulas: [String])? {
        let ns = note as NSString
        guard let block = MarkdownScanner.scan(ns).first(where: { if case .table = $0.kind { return true }; return false }) else { return nil }
        var end = NSMaxRange(block.range)
        if end > 0, ns.character(at: end - 1) != 0x0A { end = NSMaxRange(ns.lineRange(for: NSRange(location: end - 1, length: 0))) }
        var formulas: [String] = []
        if let f = TableFormulas.trailingFormulaRange(in: ns, tableRange: block.range) {
            formulas = ns.substring(with: f).components(separatedBy: "\n").filter { !$0.isEmpty }
            end = NSMaxRange(f)
        }
        let lines = ns.substring(with: block.range).components(separatedBy: "\n").filter { !$0.isEmpty }
        let rows = lines.indices.filter { $0 != 1 }
        return (NSRange(location: block.range.location, length: end - block.range.location), lines, rows, rows.map { TableFormulas.cells(ofRow: lines[$0]) }, formulas)
    }

    /// The note after typing in its first table's cells, as the table editor does it.
    private static func editing(_ note: String, _ edits: [String]) -> (String, [String]) {
        var text = note, refusals: [String] = []
        for edit in edits {
            guard var table = firstTable(text) else { break }
            let parts = edit.split(separator: " ", maxSplits: 1).map(String.init)
            let fill = parts[0].hasPrefix("fill-")
            guard let cell = cellNamed(fill ? parts.count > 1 ? parts[1] : "" : parts[0]) else { refusals.append("bad edit \(edit)"); continue }
            let typed = fill || parts.count < 2 ? "" : parts[1]
            let variables = NoteVariables.parse(noteText: text)
            let result: Result<[String], FormulaError>
            if fill {
                result = ExcelFormulas.filling(from: cell, down: parts[0] == "fill-down", grid: table.grid, formulaLines: table.formulas, variables: variables)
            } else if typed.hasPrefix("=") {
                result = ExcelFormulas.entering(typed, in: cell, grid: table.grid, formulaLines: table.formulas, variables: variables)
            } else {
                result = .success(ExcelFormulas.removing(from: cell, to: cell, in: table.formulas, grid: table.grid))
                var row = table.grid[cell.row - 1]
                while row.count < cell.column { row.append("") }
                row[cell.column - 1] = typed
                table.lines[table.rows[cell.row - 1]] = "| " + row.joined(separator: " | ") + " |"
            }
            switch result {
            case .failure(let e): refusals.append("refused: " + ExcelFormulas.message(e))
            case .success(let formulas):
                let ending = (text as NSString).substring(with: table.range).hasSuffix("\n") ? "\n" : ""
                text = (text as NSString).replacingCharacters(in: table.range, with: (table.lines + formulas).joined(separator: "\n") + ending)
            }
        }
        return (text, refusals)
    }
}
#endif
