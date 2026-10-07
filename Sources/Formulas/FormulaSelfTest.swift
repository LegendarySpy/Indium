#if DEBUG
import Foundation

/// Regression runners for the formula code, driven from the DEBUG harness
/// (`-IndiumEvalCases file.tsv`). Pure Foundation, so they also run from a plain
/// `swiftc` build of `Sources/Formulas` + `MathAnswers.swift`.
enum FormulaSelfTest {
    /// Runs case files; each says what it holds on its first line
    /// (`# kind: quick-answers`, `# kind: evaluator`, `# kind: tables`). Returns the failure count.
    static func run(paths: [String], verbose: Bool = false) -> Int {
        var failed = 0
        for path in paths {
            let first = (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n").first ?? ""
            print("== \(path)")
            if first.contains("kind: evaluator") { failed += runEvaluatorCases(path: path) }
            else if first.contains("kind: tables") { failed += runTableCases(path: path, verbose: verbose) }
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
            let input = body("input") ?? ""
            let (output, outcomes) = TableFormulas.apply(toNote: input)
            let issues = outcomes.flatMap(\.issues).map(\.description)
            let expectedIssues = (body("issues") ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
            var problems: [String] = []
            if let expect = body("expect"), output != expect { problems.append("output differs") }
            for want in expectedIssues where !issues.contains(where: { $0.contains(want) }) { problems.append("missing issue: \(want)") }
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
}
#endif
