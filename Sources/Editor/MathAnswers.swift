import AppKit

/// Type an expression and `=`, and its value appears after the caret in the accent
/// color. Tab writes it in; Esc (or carrying on typing) leaves it.
/// Works in prose (`1 + 2 =`) and in math source (`35.134\text{ g} - 34.794\text{ g} =`).
enum MathAnswer {
    struct Result {
        /// What Tab inserts (LaTeX in math source, plain text in prose).
        let insertion: String
        /// What the suggestion shows.
        let display: String
    }

    /// The answer for the text before the caret on its line, if it ends in `=`.
    static func suggest(lineBeforeCaret line: String, inMath: Bool) -> Result? {
        // Only right after the "=": typing on (even a space) means no thanks.
        var head = line
        guard head.hasSuffix("="), !head.hasSuffix("==") else { return nil }
        head.removeLast()
        // A second "=" earlier ("a = b + c =") limits the expression to the last part.
        let segment = head.split(separator: "=", omittingEmptySubsequences: false).last.map(String.init) ?? head
        // The longest tail that reads as arithmetic: prose before it ("Mass is 2 + 3") is skipped.
        let chars = Array(segment)
        for start in chars.indices where start == 0 || " ($:".contains(chars[start - 1]) {
            let candidate = String(chars[start...]).trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, let r = evaluate(candidate, inMath: inMath) else { continue }
            let spacer = line.hasSuffix(" ") ? "" : " "
            return Result(insertion: spacer + r.text, display: r.shown)
        }
        return nil
    }

    // MARK: Evaluation

    private static func evaluate(_ source: String, inMath: Bool) -> (text: String, shown: String)? {
        var units = Set<String>()
        let plain = normalize(source, units: &units)
        var parser = Parser(plain)
        guard let value = parser.parse(), parser.sawOperator, value.isFinite else { return nil }
        let formatted = format(value, numbers: parser.numbers, additiveOnly: parser.additiveOnly)
        // One shared unit through a sum or difference carries over: 0.340 g.
        if units.count == 1, let unit = units.first, parser.additiveOnly {
            let trimmed = unit.trimmingCharacters(in: .whitespaces)
            return (inMath ? formatted + "\\text{ \(trimmed)}" : "\(formatted) \(trimmed)", "\(formatted) \(trimmed)")
        }
        return (formatted, formatted)
    }

    /// LaTeX and typographic symbols to plain arithmetic.
    private static func normalize(_ s: String, units: inout Set<String>) -> String {
        var t = s
        // \text{ g} and friends are units: noted, then dropped from the arithmetic.
        let unit = try! NSRegularExpression(pattern: #"\\(?:text|mathrm)\{([^{}]*)\}"#)
        for m in unit.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            if let r = Range(m.range(at: 1), in: t) {
                let u = String(t[r]).trimmingCharacters(in: .whitespaces)
                if !u.isEmpty { units.insert(u) }
            }
        }
        t = unit.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        // Exponents and subscript-free groups first, so fractions see flat arguments.
        let exponent = try! NSRegularExpression(pattern: #"\^\{([^{}]*)\}"#)
        t = exponent.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "^($1)")
        // \frac{a}{b} → ((a)/(b)), innermost first.
        let frac = try! NSRegularExpression(pattern: #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#)
        while frac.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
            t = frac.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "(($1)/($2))")
        }
        let sqrt = try! NSRegularExpression(pattern: #"\\sqrt\{([^{}]*)\}"#)
        t = sqrt.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "sqrt($1)")
        for (a, b) in [("\\times", "*"), ("\\cdot", "*"), ("\\div", "/"), ("\\left", ""), ("\\right", ""), ("\\pi", "pi"),
                       ("\\,", ""), ("\\;", ""), ("\\!", ""), ("\\ ", ""), ("×", "*"), ("·", "*"), ("÷", "/"), ("−", "-"),
                       ("{", "("), ("}", ")"), ("$", "")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// Significant figures, as a chemistry notebook expects. Whole numbers count as
    /// exact; sums keep the fewest decimal places, products the fewest significant digits.
    private static func format(_ value: Double, numbers: [String], additiveOnly: Bool) -> String {
        let measured = numbers.filter { $0.contains(".") }
        if measured.isEmpty {
            // Exact arithmetic: up to 6 decimals, trailing zeros trimmed.
            var s = String(format: "%.6f", value)
            while s.contains("."), s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s == "-0" ? "0" : s
        }
        if additiveOnly {
            let places = measured.map { $0.split(separator: ".").last?.count ?? 0 }.min() ?? 0
            return String(format: "%.\(places)f", value)
        }
        let figures = max(1, measured.map(significantFigures).min() ?? 3)
        if value == 0 { return "0" }
        let magnitude = Int(floor(log10(abs(value))))
        if magnitude >= 9 || magnitude <= -6 { return String(format: "%.\(figures - 1)e", value) }
        let places = figures - 1 - magnitude
        if places >= 0 { return String(format: "%.\(places)f", value) }
        let step = pow(10, Double(-places))
        return String(format: "%.0f", (value / step).rounded() * step)
    }

    private static func significantFigures(_ n: String) -> Int {
        let digits = n.filter(\.isNumber)
        let trimmed = digits.drop { $0 == "0" }
        return max(trimmed.count, 1)
    }

    // MARK: Parser

    /// Recursive descent: + - * / ^, parentheses, implicit multiplication (2(3)),
    /// %, sqrt/sin/cos/tan/log/ln/abs, pi and e.
    private struct Parser {
        private let chars: [Character]
        private var i = 0
        private(set) var numbers: [String] = []
        private(set) var sawOperator = false
        private(set) var additiveOnly = true

        init(_ s: String) { chars = Array(s.filter { !$0.isWhitespace }) }

        mutating func parse() -> Double? {
            guard !chars.isEmpty, let v = expression(), i == chars.count else { return nil }
            return v
        }

        private var peek: Character? { i < chars.count ? chars[i] : nil }

        private mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek, c == "+" || c == "-" {
                i += 1
                sawOperator = true
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        private mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek {
                if c == "*" || c == "/" {
                    i += 1
                    sawOperator = true
                    additiveOnly = false
                    guard let r = power() else { return nil }
                    v = c == "*" ? v * r : v / r
                } else if c == "(" || c.isLetter {
                    // 2(3) or 2pi
                    sawOperator = true
                    additiveOnly = false
                    guard let r = power() else { return nil }
                    v *= r
                } else {
                    break
                }
            }
            return v
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek == "^" {
                i += 1
                sawOperator = true
                additiveOnly = false
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek == "-" { i += 1; return unary().map { -$0 } }
            if peek == "+" { i += 1; return unary() }
            guard var v = primary() else { return nil }
            if peek == "%" { i += 1; v /= 100; sawOperator = true; additiveOnly = false }
            return v
        }

        private mutating func primary() -> Double? {
            guard let c = peek else { return nil }
            if c == "(" {
                i += 1
                guard let v = expression(), peek == ")" else { return nil }
                i += 1
                return v
            }
            if c.isNumber || c == "." {
                let start = i
                while let d = peek, d.isNumber || d == "." { i += 1 }
                let text = String(chars[start..<i])
                guard let v = Double(text) else { return nil }
                numbers.append(text)
                return v
            }
            if c.isLetter {
                let start = i
                while let d = peek, d.isLetter { i += 1 }
                let name = String(chars[start..<i]).lowercased()
                switch name {
                case "pi": return .pi
                case "e": return M_E
                case "sqrt", "sin", "cos", "tan", "log", "ln", "abs":
                    sawOperator = true
                    additiveOnly = false
                    guard let arg = power() else { return nil }
                    switch name {
                    case "sqrt": return arg.squareRoot()
                    case "sin": return sin(arg)
                    case "cos": return cos(arg)
                    case "tan": return tan(arg)
                    case "log": return log10(arg)
                    case "ln": return log(arg)
                    default: return abs(arg)
                    }
                default: return nil
                }
            }
            return nil
        }
    }
}
