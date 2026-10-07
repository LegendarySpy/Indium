import Foundation

/// Type an expression and `=`, and its value appears after the caret in the accent
/// color. Tab writes it in; Esc (or carrying on typing) leaves it.
/// Works in prose (`1 + 2 =`) and in math source (`35.134\text{ g} - 34.794\text{ g} =`),
/// and with the note's frontmatter numbers (`hydrated - anhydrous =`).
/// The arithmetic, units and significant figures live in `Sources/Formulas/Evaluator.swift`.
enum MathAnswer {
    struct Result {
        /// What Tab inserts (LaTeX in math source, plain text in prose).
        let insertion: String
        /// What the suggestion shows.
        let display: String
    }

    /// The answer for the text before the caret on its line, if it ends in `=`.
    /// `variables` are the note's frontmatter numbers (see `NoteVariables`), only read
    /// once the line ends in `=`, so passing a parse of the whole note costs nothing per keystroke.
    static func suggest(lineBeforeCaret line: String, inMath: Bool, variables: @autoclosure () -> NoteVariables = .empty) -> Result? {
        // Only right after the "=": typing on (even a space) means no thanks.
        var head = line
        guard head.hasSuffix("="), !head.hasSuffix("==") else { return nil }
        head.removeLast()
        // A second "=" earlier ("a = b + c =") limits the expression to the last part.
        let segment = head.split(separator: "=", omittingEmptySubsequences: false).last.map(String.init) ?? head
        // The longest tail that reads as arithmetic: prose before it ("Mass is 2 + 3") is skipped.
        // Every name in a candidate must be a known function, constant or note variable.
        let chars = Array(segment)
        let variables = variables()
        for start in chars.indices where start == 0 || " ($:".contains(chars[start - 1]) {
            let candidate = String(chars[start...]).trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, let r = evaluate(candidate, inMath: inMath, variables: variables) else { continue }
            let spacer = line.hasSuffix(" ") ? "" : " "
            return Result(insertion: spacer + r.text, display: r.shown)
        }
        return nil
    }

    // MARK: Evaluation

    private static func evaluate(_ source: String, inMath: Bool, variables: NoteVariables) -> (text: String, shown: String)? {
        guard case .success(let node) = Evaluator.parse(normalize(source)), node.hasOperation,
              case .success(let q) = Evaluator.evaluate(node, environment: .init(variables: variables.values)),
              q.value.isFinite else { return nil }
        let number = q.numberText()
        guard let unit = q.unit?.text else { return (number, number) }
        return (inMath ? number + "\\text{ \(unit)}" : "\(number) \(unit)", "\(number) \(unit)")
    }

    /// LaTeX and typographic symbols to the evaluator's plain arithmetic.
    private static func normalize(_ s: String) -> String {
        var t = s
        func replace(_ pattern: String, _ template: String) {
            let re = try! NSRegularExpression(pattern: pattern)
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        // \text{ g} and friends are units: they become the evaluator's explicit unit ⟦g⟧,
        // attached to the value before them.
        replace(#"\\(?:text|mathrm)\{([^{}]*)\}"#, "⟦$1⟧")
        // Exponents and subscript-free groups first, so fractions see flat arguments.
        replace(#"\^\{([^{}]*)\}"#, "^($1)")
        // \frac{a}{b} → ((a)/(b)), innermost first.
        let frac = try! NSRegularExpression(pattern: #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#)
        while frac.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
            t = frac.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "(($1)/($2))")
        }
        replace(#"\\sqrt\{([^{}]*)\}"#, "sqrt($1)")
        for (a, b) in [("\\times", "*"), ("\\cdot", "*"), ("\\div", "/"), ("\\left", ""), ("\\right", ""), ("\\pi", "pi"),
                       ("\\%", "%"), ("\\,", ""), ("\\;", ""), ("\\!", ""), ("\\ ", ""), ("{", "("), ("}", ")"), ("$", "")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}
