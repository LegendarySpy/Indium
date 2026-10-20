import Foundation

/// Equations as Desmos writes them (`y=k x^2`, `f(x)=\frac{1}{x}`, `x=2`, `(3,9)`, `k=2`),
/// turned into the evaluator's arithmetic and sampled into curves.
///
/// As in Desmos, a run of letters is a product of one-letter names (`kx` is k·x) unless
/// it names something: a function (`sin`, `ln`), a constant (`pi`), a function or
/// constant defined earlier in the graph, or one of the note's variables (`hydrated`),
/// which only Indium knows.
enum GraphMath {
    /// What one line of a graph is.
    enum Line {
        case curve(Expression)
        case vertical(Double)
        case point(Double, Double)
        /// `k=2` or `f(a)=…`: defines something later lines use; nothing to draw.
        case definition
        case problem(String)
    }

    /// An expression of `x` (and `y`, in restrictions), ready to evaluate many times.
    struct Expression {
        let node: FormulaNode
    }

    /// Everything defined so far in a graph: functions, constants and the note's variables.
    struct Functions {
        fileprivate var functions: [String: (parameter: String, body: [Token])] = [:]
        fileprivate var constants: [String: Double] = [:]
        let variables: [String: Double]
        let degrees: Bool

        init(variables: NoteVariables, degrees: Bool = false) {
            self.variables = variables.values.mapValues(\.value)
            self.degrees = degrees
        }

        /// Reads one line, remembering what it defines.
        mutating func line(_ latex: String) -> Line {
            var tokens: [Token]
            do { tokens = try tokenize(GraphMath.plain(latex)) } catch { return .problem("Indium can’t read this") }
            guard !tokens.isEmpty else { return .problem("Nothing to draw") }
            if tokens.contains(where: { $0.isComparison }) { return .problem("Inequalities aren’t drawn") }
            if tokens.contains(.prime) { return .problem("Derivatives aren’t drawn") }

            let sides = split(tokens, at: .equals)
            switch sides.count {
            case 1:
                if let point = point(tokens) { return point }
                if tokens.contains(.name("y")) { return .problem("Write it as y = …") }
                return curve(tokens)
            case 2:
                let (lhs, rhs) = (sides[0], sides[1])
                if lhs == [.name("y")] {
                    if rhs.contains(.name("y")) { return .problem("Curves like x²+y²=1 aren’t drawn yet; write y = …") }
                    return curve(rhs)
                }
                if lhs == [.name("x")] {
                    guard !rhs.contains(.name("x")), !rhs.contains(.name("y")) else { return .problem("Curves like this aren’t drawn yet; write y = …") }
                    guard let v = value(of: rhs) else { return .problem("Indium can’t work out x here") }
                    return .vertical(v)
                }
                // f(a)=…: a function; drawn too when its parameter is x, as Desmos does.
                if lhs.count == 4, case let .name(f) = lhs[0], lhs[1] == .open, case let .name(p) = lhs[2], lhs[3] == .close, f != "x", f != "y" {
                    functions[f] = (p, rhs)
                    return p == "x" ? curve(rhs) : .definition
                }
                // k=2: a constant.
                if lhs.count == 1, case let .name(k) = lhs[0], k != "y" {
                    guard !rhs.contains(.name("x")), !rhs.contains(.name("y")), let v = value(of: rhs) else {
                        return .problem("Curves like this aren’t drawn yet; write y = …")
                    }
                    constants[k] = v
                    return .definition
                }
                return .problem("Curves like this aren’t drawn yet; write y = …")
            default:
                return .problem("One = per line")
            }
        }

        /// Restriction flags (`x>0`, `0<x<3`, `y\le 2`) as checks on a point.
        func restriction(_ latex: String) -> ((Double, Double) -> Bool)? {
            guard let tokens = try? tokenize(GraphMath.plain(latex.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))) else { return nil }
            var parts: [[Token]] = [[]], ops: [Token] = []
            for t in tokens {
                if t.isComparison { ops.append(t); parts.append([]) } else { parts[parts.count - 1].append(t) }
            }
            guard !ops.isEmpty else { return nil }
            let nodes = parts.compactMap { compile($0)?.node }
            guard nodes.count == parts.count else { return nil }
            let vars = variables.merging(constants) { $1 }
            return { x, y in
                var env = vars
                env["x"] = x
                env["y"] = y
                let values = nodes.map { GraphMath.evaluate($0, env) }
                for (i, op) in ops.enumerated() {
                    guard let a = values[i], let b = values[i + 1] else { return false }
                    switch op {
                    case .less: if !(a < b) { return false }
                    case .lessEqual: if !(a <= b) { return false }
                    case .greater: if !(a > b) { return false }
                    case .greaterEqual: if !(a >= b) { return false }
                    default: break
                    }
                }
                return true
            }
        }

        var environment: [String: Double] { variables.merging(constants) { $1 } }

        private func curve(_ tokens: [Token]) -> Line {
            if let unknown = unknownName(in: tokens, allowing: ["x"]) { return .problem("Unknown name “\(unknown)”") }
            guard let e = compile(tokens) else { return .problem("Indium can’t read this") }
            return .curve(e)
        }

        private func point(_ tokens: [Token]) -> Line? {
            guard tokens.first == .open, tokens.last == .close else { return nil }
            let inner = Array(tokens.dropFirst().dropLast())
            var depth = 0
            for (i, t) in inner.enumerated() {
                if t == .open { depth += 1 } else if t == .close { depth -= 1 }
                else if t == .comma, depth == 0 {
                    guard let x = value(of: Array(inner[..<i])), let y = value(of: Array(inner[(i + 1)...])) else {
                        return .problem("Indium can’t work out this point")
                    }
                    return .point(x, y)
                }
            }
            return nil
        }

        private func value(of tokens: [Token]) -> Double? {
            guard unknownName(in: tokens, allowing: []) == nil, let e = compile(tokens) else { return nil }
            return GraphMath.evaluate(e.node, environment)
        }

        private func unknownName(in tokens: [Token], allowing: Set<String>) -> String? {
            for case let .name(n) in expand(tokens) where !allowing.contains(n) && !GraphMath.known.contains(n) && environment[n] == nil {
                return n
            }
            return nil
        }

        /// The evaluator's syntax: user functions written out, products made explicit.
        private func compile(_ tokens: [Token]) -> Expression? {
            let text = render(expand(tokens))
            let options = Evaluator.Options(allowsReferences: false, allowsUnitWords: false, allowsImplicitProducts: false, allowsPercent: false)
            guard case let .success(node) = Evaluator.parse(text, options: options) else { return nil }
            return Expression(node: node)
        }

        /// Calls of functions defined in the graph replaced by their bodies; `exp(a)` as
        /// `e^(a)`; trigonometry in degrees when the graph says so.
        private func expand(_ tokens: [Token], depth: Int = 0) -> [Token] {
            guard depth < 8 else { return tokens }
            var out: [Token] = []
            var i = 0
            while i < tokens.count {
                let t = tokens[i]
                if case let .name(n) = t, i + 1 < tokens.count, tokens[i + 1] == .open, let close = matching(tokens, from: i + 1) {
                    let arg = expand(Array(tokens[(i + 2)..<close]), depth: depth + 1)
                    if let f = functions[n] {
                        let body = f.body.flatMap { $0 == .name(f.parameter) ? [.open] + arg + [.close] : [$0] }
                        out += [.open] + expand(body, depth: depth + 1) + [.close]
                        i = close + 1
                        continue
                    }
                    if n == "exp" {
                        out += [.name("e"), .op("^"), .open] + arg + [.close]
                        i = close + 1
                        continue
                    }
                    if degrees, ["sin", "cos", "tan"].contains(n) {
                        out += [t, .open, .open, .name("pi"), .op("/"), .number("180"), .close, .op("*"), .open] + arg + [.close, .close]
                        i = close + 1
                        continue
                    }
                }
                out.append(t)
                i += 1
            }
            return out
        }

        /// Tokens back to text, with `*` wherever two operands meet (`2x`, `k(x+1)`, `)(`).
        private func render(_ tokens: [Token]) -> String {
            var s = ""
            var previous: Token?
            for t in tokens {
                if let p = previous, p.endsOperand, t.startsOperand, !p.isFunction { s += " * " }
                s += t.text + " "
                previous = t
            }
            return s
        }

        private func matching(_ tokens: [Token], from open: Int) -> Int? {
            var depth = 0
            for i in open..<tokens.count {
                if tokens[i] == .open { depth += 1 } else if tokens[i] == .close { depth -= 1; if depth == 0 { return i } }
            }
            return nil
        }

        private func split(_ tokens: [Token], at separator: Token) -> [[Token]] {
            tokens.split(separator: separator, omittingEmptySubsequences: false).map(Array.init)
        }

        /// Plain text to tokens, splitting runs of letters into names the graph knows.
        fileprivate func tokenize(_ s: String) throws -> [Token] {
            let names = GraphMath.known.union(functions.keys).union(constants.keys).union(variables.keys)
            var out: [Token] = []
            let chars = Array(s)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                    var j = i
                    while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                    out.append(.number(String(chars[i..<j])))
                    i = j
                    continue
                }
                if c.isLetter {
                    var j = i
                    while j < chars.count, chars[j].isLetter { j += 1 }
                    let run = String(chars[i..<j])
                    var parts = names.contains(run) ? [run] : GraphMath.splitRun(run, names: names)
                    // A subscript joins the name before it: k_1, m_{water}.
                    if j < chars.count, chars[j] == "_" {
                        var k = j + 1
                        while k < chars.count, chars[k].isLetter || chars[k].isNumber { k += 1 }
                        parts[parts.count - 1] += String(chars[j..<k])
                        j = k
                    }
                    out += parts.map { .name($0) }
                    i = j
                    continue
                }
                let two = i + 1 < chars.count ? String(chars[i...(i + 1)]) : ""
                switch two {
                case "<=": out.append(.lessEqual); i += 2; continue
                case ">=": out.append(.greaterEqual); i += 2; continue
                default: break
                }
                switch c {
                case "(": out.append(.open)
                case ")": out.append(.close)
                case ",": out.append(.comma)
                case "=": out.append(.equals)
                case "<": out.append(.less)
                case ">": out.append(.greater)
                case "'": out.append(.prime)
                case "+", "-", "*", "/", "^": out.append(.op(c))
                default: throw GraphError.unreadable
                }
                i += 1
            }
            return out
        }
    }

    private enum GraphError: Error { case unreadable }

    fileprivate enum Token: Hashable {
        case number(String)
        case name(String)
        case op(Character)
        case open, close, comma, equals, less, lessEqual, greater, greaterEqual, prime

        var isComparison: Bool { [.less, .lessEqual, .greater, .greaterEqual].contains(self) }
        var isFunction: Bool { if case let .name(n) = self { return GraphMath.functionNames.contains(n) }; return false }
        var endsOperand: Bool {
            switch self { case .number, .name, .close: true; default: false }
        }
        var startsOperand: Bool {
            switch self { case .number, .name, .open: true; default: false }
        }
        var text: String {
            switch self {
            case let .number(s): s
            case let .name(s): s
            case let .op(c): String(c)
            case .open: "("
            case .close: ")"
            case .comma: ","
            case .equals: "="
            case .less: "<"
            case .lessEqual: "<="
            case .greater: ">"
            case .greaterEqual: ">="
            case .prime: "'"
            }
        }
    }

    fileprivate static let functionNames: Set<String> = ["sin", "cos", "tan", "ln", "log", "sqrt", "abs", "exp"]
    fileprivate static let known: Set<String> = functionNames.union(["pi", "e"])

    /// `kx` → k, x; `sinx` → sin, x; `xsin` → x, sin: the longest known name at each
    /// place, else one letter.
    fileprivate static func splitRun(_ run: String, names: Set<String>) -> [String] {
        let chars = Array(run)
        var out: [String] = []
        var i = 0
        while i < chars.count {
            var taken = 1
            for len in stride(from: chars.count - i, to: 1, by: -1) where names.contains(String(chars[i..<(i + len)])) {
                taken = len
                break
            }
            out.append(String(chars[i..<(i + taken)]))
            i += taken
        }
        return out
    }

    /// LaTeX to plain arithmetic: `\frac{a}{b}` → ((a)/(b)), `x^{2}` → x^(2), `\sqrt{a}`,
    /// `\sin` → sin, `\cdot` → *, `\le` → <=.
    static func plain(_ latex: String) -> String {
        var t = latex.replacingOccurrences(of: "$", with: "")
        for (a, b) in [("\\left", ""), ("\\right", ""), ("\\cdot", "*"), ("\\times", "*"), ("\\div", "/"), ("\\leq", "<="), ("\\geq", ">="),
                       ("\\le", "<="), ("\\ge", ">="), ("≤", "<="), ("≥", ">="), ("·", "*"), ("×", "*"), ("−", "-"), ("π", "pi"),
                       ("\\,", " "), ("\\;", " "), ("\\!", ""), ("\\ ", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        func replace(_ pattern: String, _ template: String) -> Bool {
            let re = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(t.startIndex..., in: t)
            guard re.firstMatch(in: t, range: range) != nil else { return false }
            t = re.stringByReplacingMatches(in: t, range: range, withTemplate: template)
            return true
        }
        _ = replace(#"\\operatorname\{([A-Za-z]+)\}"#, "$1")
        // Innermost groups first, until nothing changes.
        var changed = true
        while changed {
            changed = false
            changed = replace(#"_\{([A-Za-z0-9]*)\}"#, "_$1") || changed
            changed = replace(#"\^\{([^{}]*)\}"#, "^($1)") || changed
            changed = replace(#"\\sqrt\[([^\[\]{}]*)\]\{([^{}]*)\}"#, "((($2))^(1/($1)))") || changed
            changed = replace(#"\\sqrt\{([^{}]*)\}"#, "sqrt($1)") || changed
            changed = replace(#"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, "(($1)/($2))") || changed
        }
        _ = replace(#"\\([A-Za-z]+)"#, "$1")
        return t.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
    }

    static func evaluate(_ node: FormulaNode, _ env: [String: Double]) -> Double? {
        let environment = Evaluator.Environment(variables: env.mapValues { Quantity($0) })
        guard case let .success(q) = Evaluator.evaluate(node, environment: environment), q.value.isFinite else { return nil }
        return q.value
    }

    /// The curve of `expression` across `x`, broken where it has no value, fails a
    /// restriction, or jumps (an asymptote), so no line is drawn across a gap.
    static func sample(_ expression: Expression, functions: Functions, x: ClosedRange<Double>, y: ClosedRange<Double>?,
                       restrictions: [String] = [], count: Int = 600) -> [[ChartModel.Point]] {
        let checks = restrictions.compactMap { functions.restriction($0) }
        var env = functions.environment
        var segments: [[ChartModel.Point]] = [], current: [ChartModel.Point] = []
        let span = y.map { $0.upperBound - $0.lowerBound }
        for i in 0...count {
            let xv = x.lowerBound + (x.upperBound - x.lowerBound) * Double(i) / Double(count)
            env["x"] = xv
            var point: ChartModel.Point?
            if let yv = evaluate(expression.node, env), checks.allSatisfy({ $0(xv, yv) }) {
                // Held a little past the visible range, so huge values can't swamp the scale.
                let held = y.flatMap { y in span.map { min(max(yv, y.lowerBound - $0), y.upperBound + $0) } } ?? yv
                point = ChartModel.Point(x: xv, y: held)
            }
            if let p = point, let last = current.last, let span, abs(p.y - last.y) > span * 2 {
                // Off one edge and back in from the other: an asymptote, not a line.
                segments.append(current)
                current = []
            }
            if let p = point {
                current.append(p)
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}
