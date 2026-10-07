#if DEBUG
import Foundation

/// Regression runners for the formula code, driven from the DEBUG harness
/// (`-IndiumEvalCases file.tsv`). Pure Foundation, so they also run from a plain
/// `swiftc` build of `Sources/Formulas` + `MathAnswers.swift`.
enum FormulaSelfTest {
    /// Quick-answer cases, one per line:
    /// `mode<TAB>line<TAB>display<TAB>insertion`
    /// - mode: `prose` or `math` (the caret is inside math source).
    /// - `∅` in display/insertion: no suggestion. `␠` stands for a space (so trailing spaces survive editors).
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
            let r = MathAnswer.suggest(lineBeforeCaret: line, inMath: p[0] == "math")
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
}
#endif
