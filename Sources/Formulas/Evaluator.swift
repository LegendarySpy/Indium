import Foundation

// The arithmetic core shared by quick answers (MathAnswers.swift) and table
// formulas (TableFormulas.swift). Pure Foundation: no AppKit, no UI.
// See README.md in this folder for the syntax and the unit/precision rules.

// MARK: - Errors

/// Why an expression has no value. `message` is written for the person typing.
struct FormulaError: Error, Equatable, CustomStringConvertible {
    enum Kind: String {
        case parse              // malformed expression; `position` says where
        case unknownVariable    // an identifier that is no variable, constant or function
        case unknownFunction
        case divisionByZero
        case incompatibleUnits  // g + mol, or sum over mixed units
        case notReal            // sqrt(-1), log(0), overflow
        case badReference       // a cell outside the table, a relative destination
        case notNumeric         // a referenced cell holds text
        case blank              // a referenced cell is empty (tables leave the result blank)
        case rangeMisuse        // a range outside sum/mean/min/max/count
        case cycle              // formulas that depend on themselves
        case unsupported        // valid upstream syntax Indium doesn't evaluate (if(), ;dt, ;hm)
    }
    let kind: Kind
    let message: String
    /// Character offset into the expression, for parse errors.
    var position: Int? = nil

    var description: String { position.map { "\(message) (at \($0))" } ?? message }
}

// MARK: - Units

/// A unit such as `g`, `mL`, `g/mol` or `J/(mol·K)`. Units made of simple symbols
/// (`[A-Za-zµμΩ°Å]+`, optionally `^n`) are algebraic and multiply, divide and cancel;
/// anything else (`g Zn`, `apples (red)`) is an opaque label that survives only + and -.
/// There is no conversion: `g` and `kg` are simply different units.
struct FormulaUnit: Equatable, CustomStringConvertible {
    /// Symbol exponents in first-seen order; empty for an opaque label.
    private(set) var factors: [(symbol: String, power: Int)] = []
    /// The text to show. Kept as written for units read from the input.
    let text: String
    var isOpaque: Bool { factors.isEmpty }

    var description: String { text }

    static func == (a: FormulaUnit, b: FormulaUnit) -> Bool {
        if a.isOpaque || b.isOpaque { return a.isOpaque && b.isOpaque && a.text == b.text }
        return a.normalized == b.normalized
    }

    private var normalized: [String: Int] {
        var d: [String: Int] = [:]
        for f in factors { d[f.symbol, default: 0] += f.power }
        return d.filter { $0.value != 0 }
    }

    private init(factors: [(symbol: String, power: Int)], text: String) {
        self.factors = factors
        self.text = text
    }

    private static let atom = try! NSRegularExpression(pattern: #"^([A-Za-zµμΩ°Å]+)(?:\^(-?\d+))?$"#)

    /// Exponents beyond this are refused rather than risk overflow.
    static let maxPower = 1000

    /// Parses unit text. Returns nil for empty text and for text that can't be a unit
    /// (it must start with a letter or µ/Ω/°/Å, and can't hold `|`, `%` or line breaks),
    /// so whatever a unit renders as reads back the same.
    static func parse(_ raw: String) -> FormulaUnit? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, first.isLetter || "µμΩ°Å".contains(first),
              !text.contains(where: { "|%\n\r\t`".contains($0) }) else { return nil }
        let compact = text.replacingOccurrences(of: #"\s*([/·*⋅])\s*"#, with: "$1", options: .regularExpression)
        let parts = compact.components(separatedBy: "/")
        guard parts.count <= 2, !compact.contains(" ") else { return FormulaUnit(factors: [], text: text) }
        var factors: [(String, Int)] = []
        for (i, part) in parts.enumerated() {
            let sign = i == 0 ? 1 : -1
            var body = part
            if i == 1, body.hasPrefix("("), body.hasSuffix(")") { body = String(body.dropFirst().dropLast()) }
            if i == 0, body == "1", parts.count == 2 { continue }
            for piece in body.components(separatedBy: CharacterSet(charactersIn: "·*⋅")) {
                let ns = piece as NSString
                guard let m = atom.firstMatch(in: piece, range: NSRange(location: 0, length: ns.length)) else {
                    return FormulaUnit(factors: [], text: text)
                }
                let power = m.range(at: 2).location == NSNotFound ? 1 : Int(ns.substring(with: m.range(at: 2))) ?? 0
                guard power != 0, abs(power) <= maxPower else { return FormulaUnit(factors: [], text: text) }
                factors.append((ns.substring(with: m.range(at: 1)), sign * power))
            }
        }
        return factors.isEmpty ? FormulaUnit(factors: [], text: text) : FormulaUnit(factors: factors, text: compact)
    }

    /// The unit of `a·b^k` (k = 1 multiplies, -1 divides). `unit` nil with `defined`
    /// true means dimensionless (g/g). `defined` false means there's no honest answer
    /// (an opaque label times anything but a plain number, or an absurd exponent); the
    /// caller must report an error rather than drop the unit.
    static func combine(_ a: FormulaUnit?, _ b: FormulaUnit?, power k: Int) -> (unit: FormulaUnit?, defined: Bool) {
        switch (a, b) {
        case (nil, nil): return (nil, true)
        case let (u?, nil): return (u, true)
        case let (nil, u?): return u.raised(to: k)
        case let (x?, y?):
            if x.isOpaque || y.isOpaque {
                // Only an opaque unit divided by itself is well-defined (it cancels).
                return k == -1 && x == y ? (nil, true) : (nil, false)
            }
            var merged = x.factors
            for f in y.factors {
                if let i = merged.firstIndex(where: { $0.symbol == f.symbol }) { merged[i].power += k * f.power }
                else { merged.append((f.symbol, k * f.power)) }
            }
            merged.removeAll { $0.power == 0 }
            guard merged.allSatisfy({ abs($0.power) <= maxPower }) else { return (nil, false) }
            return (merged.isEmpty ? nil : FormulaUnit.render(merged), true)
        }
    }

    /// The unit to a whole power. Opaque labels only survive the first power.
    func raised(to k: Int) -> (unit: FormulaUnit?, defined: Bool) {
        if k == 1 { return (self, true) }
        if k == 0 { return (nil, true) }
        guard !isOpaque, abs(k) <= FormulaUnit.maxPower,
              factors.allSatisfy({ abs($0.power * k) <= FormulaUnit.maxPower }) else { return (nil, false) }
        return (FormulaUnit.render(factors.map { ($0.symbol, $0.power * k) }), true)
    }

    /// Half the exponents (sqrt of m^2 is m); undefined unless they're all even.
    func squareRoot() -> (unit: FormulaUnit?, defined: Bool) {
        guard !isOpaque, factors.allSatisfy({ $0.power % 2 == 0 }) else { return (nil, false) }
        return (FormulaUnit.render(factors.map { ($0.symbol, $0.power / 2) }), true)
    }

    private static func render(_ factors: [(symbol: String, power: Int)]) -> FormulaUnit {
        func term(_ f: (symbol: String, power: Int), _ p: Int) -> String { p == 1 ? f.symbol : "\(f.symbol)^\(p)" }
        let up = factors.filter { $0.power > 0 }.map { term($0, $0.power) }
        let down = factors.filter { $0.power < 0 }.map { term($0, -$0.power) }
        var text: String
        if up.isEmpty {
            // s^-1 rather than 1/s, so "5 s^-1" reads back as a number and a unit.
            text = factors.map { "\($0.symbol)^\($0.power)" }.joined(separator: "·")
        } else {
            text = up.joined(separator: "·")
            if !down.isEmpty { text += "/" + (down.count > 1 ? "(" + down.joined(separator: "·") + ")" : down[0]) }
        }
        return FormulaUnit(factors: factors, text: text)
    }
}

// MARK: - Precision

/// How precisely a value is known, following the significant-figure rules a
/// chemistry notebook uses: whole numbers and constants are exact; sums keep the
/// fewest decimal places; products, quotients, powers and functions keep the fewest
/// significant figures.
struct FormulaPrecision: Equatable {
    enum Style: Equatable { case decimals, significantFigures }
    /// Exact values (whole-number literals, pi, e, counts) don't limit precision.
    var isExact: Bool
    /// Digits after the decimal point (may be negative: 1.2e3 has -2).
    var decimals: Int
    var significantFigures: Int
    /// Which of the two the last operation set, and so how the value is written.
    var style: Style

    static let exact = FormulaPrecision(isExact: true, decimals: 0, significantFigures: 0, style: .decimals)

    /// From a numeric literal as written: `2.008` → 3 decimals, 4 figures; `100` → exact.
    static func of(literal text: String) -> FormulaPrecision {
        let lower = text.lowercased()
        let parts = lower.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        let mantissa = String(parts[0])
        // Bounded, so pathological input (1e99999999999999999999) can't overflow Int arithmetic.
        let exponent = parts.count > 1 ? max(-400, min(400, Int(parts[1]) ?? 0)) : 0
        guard mantissa.contains(".") || parts.count > 1 else { return .exact }
        let afterPoint = mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first.map { $0.count } ?? 0
        let digits = mantissa.filter(\.isNumber).drop { $0 == "0" }
        // Scientific notation states its figures even without a point (6e23: 1 figure).
        return FormulaPrecision(isExact: false, decimals: afterPoint - exponent,
                                significantFigures: min(max(digits.count, 1), maxFigures),
                                style: parts.count > 1 ? .significantFigures : .decimals)
    }

    /// A Double holds about 17 significant digits; claiming more is noise.
    static let maxFigures = 17

    static func magnitude(_ v: Double) -> Int { v == 0 || !v.isFinite ? 0 : Int(floor(log10(abs(v)))) }

    /// After `a ± b = value`.
    static func sum(_ ps: [FormulaPrecision], value: Double) -> FormulaPrecision {
        let measured = ps.filter { !$0.isExact }
        guard let places = measured.map(\.decimals).min() else { return .exact }
        return FormulaPrecision(isExact: false, decimals: places,
                                significantFigures: max(1, magnitude(value) + 1 + places), style: .decimals)
    }

    /// After `a × b`, `a ÷ b`, a power or a function, giving `value`.
    static func product(_ ps: [FormulaPrecision], value: Double) -> FormulaPrecision {
        let measured = ps.filter { !$0.isExact }
        guard let figures = measured.map(\.significantFigures).min() else { return .exact }
        return FormulaPrecision(isExact: false, decimals: figures - 1 - magnitude(value),
                                significantFigures: figures, style: .significantFigures)
    }
}

// MARK: - Quantity

/// A value with an optional unit and its precision: what every evaluation returns.
struct Quantity: Equatable {
    var value: Double
    var unit: FormulaUnit?
    var precision: FormulaPrecision

    init(_ value: Double, unit: FormulaUnit? = nil, precision: FormulaPrecision = .exact) {
        self.value = value
        self.unit = unit
        self.precision = precision
    }

    /// The number as the precision implies (`1.293`, `64.39`, `0.333333`),
    /// or with exactly `decimals` places when given (a `;%.2f` directive).
    func numberText(decimals: Int? = nil) -> String {
        Quantity.format(value, precision: precision, decimals: decimals)
    }

    /// `1.293 g`: the number, a space, then the unit if there is one.
    func formatted(decimals: Int? = nil) -> String {
        let n = numberText(decimals: decimals)
        return unit.map { "\(n) \($0.text)" } ?? n
    }

    // A number, optionally signed, with optional decimals and exponent.
    private static let numberPattern = #"[-+−]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"#
    private static let cellPattern = try! NSRegularExpression(pattern: "^(" + numberPattern + #")\s*(%|[^\d\s%].*)?$"#)

    /// Reads a stored value: `2.008`, `2.008 g`, `0.07177 mol`, `−3`, `64.4%` (→ 0.644),
    /// `**2.0 g**`. Returns nil for anything else (labels, dates, lists).
    static func parse(_ raw: String) -> Quantity? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        // Emphasis around a whole cell (`**12**`, `_3 g_`) is decoration.
        for mark in ["**", "__", "*", "_"] where t.count > 2 * mark.count && t.hasPrefix(mark) && t.hasSuffix(mark) {
            t = String(t.dropFirst(mark.count).dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let ns = t as NSString
        guard let m = cellPattern.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let number = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "−", with: "-")
        guard let v = Double(number.hasPrefix("+") ? String(number.dropFirst()) : number), v.isFinite else { return nil }
        var q = Quantity(v, precision: .of(literal: number.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))))
        if m.range(at: 2).location != NSNotFound {
            let suffix = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if suffix == "%" {
                q = Evaluator.percent(q)
            } else {
                // The suffix must read as a unit: letters first, no digits leading.
                guard let u = FormulaUnit.parse(suffix), suffix.first.map({ $0.isLetter || "µμΩ°Å".contains($0) }) == true else { return nil }
                q.unit = u
            }
        }
        return q
    }

    // MARK: Formatting

    static func format(_ value: Double, precision p: FormulaPrecision, decimals forced: Int? = nil) -> String {
        guard value.isFinite else { return "\(value)" }  // unreachable: the evaluator rejects non-finite values
        // Huge numbers in scientific notation, whatever the precision, so a cell never
        // fills with hundreds of digits (and it reads back: 1.2e+20).
        if abs(value) >= 1e15 {
            let figures = p.isExact ? 15 : max(1, min(p.significantFigures, FormulaPrecision.maxFigures))
            var s = String(format: "%.\(figures - 1)e", value)
            if p.isExact, let e = s.firstIndex(of: "e") {
                var mantissa = String(s[..<e])
                while mantissa.contains("."), mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
                s = mantissa + s[e...]
            }
            return s
        }
        if let forced { return fixed(value, places: max(0, forced)) }
        if p.isExact {
            // Exact arithmetic: up to 6 decimals, trailing zeros trimmed.
            var s = fixed(value, places: 6)
            while s.contains("."), s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        if p.style == .decimals { return fixed(value, places: max(0, p.decimals)) }
        let figures = max(1, min(p.significantFigures, FormulaPrecision.maxFigures))
        if value == 0 { return "0" }
        var magnitude = FormulaPrecision.magnitude(value)
        // 9.996 to 3 figures is 10.0, not 10.00: rounding can carry into a new digit.
        if FormulaPrecision.magnitude(roundHalfUp(value, places: figures - 1 - magnitude)) > magnitude { magnitude += 1 }
        if magnitude >= 9 || magnitude <= -6 { return String(format: "%.\(figures - 1)e", value) }
        let places = figures - 1 - magnitude
        if places >= 0 { return fixed(value, places: places) }
        return fixed(roundHalfUp(value, places: places), places: 0)
    }

    /// Rounds half away from zero in decimal (so 3.25 → 3.3 and 1.005 → 1.01),
    /// which is what people do by hand; binary floating point would say 3.2 and 1.00.
    static func roundHalfUp(_ value: Double, places: Int) -> Double {
        guard value.isFinite, abs(value) < 1e15, places <= 15, var d = Decimal(string: String(format: "%.15g", value)) else { return value }
        var r = Decimal()
        NSDecimalRound(&r, &d, places, .plain)
        return NSDecimalNumber(decimal: r).doubleValue
    }

    private static func fixed(_ value: Double, places rawPlaces: Int) -> String {
        let places = min(rawPlaces, 15)
        var s = String(format: "%.\(places)f", roundHalfUp(value, places: places))
        if s.hasPrefix("-"), !s.contains(where: { ("1"..."9").contains($0) }) { s.removeFirst() }
        return s
    }
}

// MARK: - Syntax tree

/// A table cell reference, TBLFM style. Rows: `@3` absolute (1 = header row, the
/// separator line is not counted), `@<` first, `@>` last, `@I` first body row,
/// `@-1`/`@+1` relative. Columns likewise with `$`. A missing part means "the
/// destination cell's own row/column".
struct CellReference: Equatable, CustomStringConvertible {
    enum Index: Equatable {
        case absolute(Int)   // 1-based
        case first           // <
        case last            // >
        case firstBody       // I (rows only)
        case relative(Int)   // +n / -n, 0 = same
    }
    var row: Index?
    var column: Index?

    var description: String {
        func text(_ i: Index) -> String {
            switch i {
            case .absolute(let n): "\(n)"
            case .first: "<"
            case .last: ">"
            case .firstBody: "I"
            case .relative(let n): n < 0 ? "\(n)" : "+\(n)"
            }
        }
        return (row.map { "@" + text($0) } ?? "") + (column.map { "$" + text($0) } ?? "")
    }

    var isAbsolute: Bool {
        if case .relative = row { return false }
        if case .relative = column { return false }
        return true
    }
}

indirect enum FormulaNode: Equatable {
    case number(String)
    case constant(String)                  // pi, e
    case variable(String)
    case reference(CellReference)
    case range(CellReference, CellReference)
    case negate(FormulaNode)
    case percent(FormulaNode)              // x% = x/100
    case unit(FormulaNode, String)         // 2.008 g, or 35.134\text{ g} in math source
    case binary(Character, FormulaNode, FormulaNode)  // + - * / ^
    case implicitProduct(FormulaNode, FormulaNode)    // 2pi, 2(3)
    case call(String, [FormulaNode])
    case group(FormulaNode)                // ( … ), kept so TBLFM can check its parenthesis rule

    /// True when the expression computes something (a lone number or variable doesn't).
    var hasOperation: Bool {
        switch self {
        case .number, .constant, .variable, .reference, .range: false
        case .negate(let n), .unit(let n, _), .group(let n): n.hasOperation
        case .percent, .binary, .implicitProduct, .call: true
        }
    }
}

// MARK: - Evaluator

enum Evaluator {
    struct Options {
        /// Read `@r$c` cell references and `..` ranges (table formulas).
        var allowsReferences = false
        /// Read a known unit word right after a number (`2.008 g`, `5 mL`). Units in
        /// `⟦…⟧` (what MathAnswers makes of `\text{…}`) are always read.
        var allowsUnitWords = true
        /// Allow `2pi` and `2(3)`. Never applies next to a variable: `2 mass` is an error.
        var allowsImplicitProducts = true
        /// Allow postfix `%`.
        var allowsPercent = true

        static let quickAnswer = Options()
        static let tableFormula = Options(allowsReferences: true, allowsUnitWords: false, allowsImplicitProducts: false, allowsPercent: false)
    }

    /// Where names and cells get their values.
    struct Environment {
        var variables: [String: Quantity] = [:]
        /// Resolves a single cell; required when references are allowed.
        var cell: ((CellReference) -> Result<Quantity, FormulaError>)? = nil
        /// Resolves a range to its non-blank cells, in row-major order.
        var range: ((CellReference, CellReference) -> Result<[Quantity], FormulaError>)? = nil

        init(variables: [String: Quantity] = [:]) { self.variables = variables }
    }

    /// Unary math functions, applied like `sqrt(2)` or `sqrt 2`.
    static let mathFunctions: Set<String> = ["sqrt", "sin", "cos", "tan", "log", "ln", "abs"]
    /// Aggregates over ranges and argument lists.
    static let aggregateFunctions: Set<String> = ["sum", "mean", "min", "max", "count"]
    static let constants: Set<String> = ["pi", "e", "π"]
    /// Names a variable can't take (compared case-insensitively).
    static func isReserved(_ name: String) -> Bool {
        let n = name.lowercased()
        return mathFunctions.contains(n) || aggregateFunctions.contains(n) || constants.contains(n) || n == "if"
    }

    /// Unit words recognised right after a number in prose (anything goes inside `\text{}`
    /// or in a table cell). A whitelist, so `3 x + 2` stays unrecognised instead of
    /// becoming "5 x".
    static let unitWords: Set<String> = [
        "g", "kg", "mg", "µg", "μg", "ug", "ng",
        "mol", "mmol", "µmol", "μmol", "kmol",
        "L", "mL", "µL", "μL", "dL", "l", "ml",
        "M", "mM", "µM", "μM",
        "m", "km", "cm", "mm", "µm", "μm", "nm",
        "s", "ms", "µs", "μs", "min", "h", "hr",
        "K", "°C", "°F", "J", "kJ", "cal", "kcal", "eV",
        "N", "kN", "Pa", "kPa", "MPa", "atm", "bar", "mbar", "torr", "mmHg",
        "V", "mV", "A", "mA", "W", "kW", "Hz", "kHz", "MHz",
    ]

    // MARK: Entry points

    /// Parses and evaluates `source`.
    static func evaluate(_ source: String, options: Options = .quickAnswer, environment: Environment = Environment()) -> Result<Quantity, FormulaError> {
        parse(source, options: options).flatMap { evaluate($0, environment: environment) }
    }

    static func parse(_ source: String, options: Options = .quickAnswer) -> Result<FormulaNode, FormulaError> {
        var p = Parser(source, options: options)
        do { return .success(try p.parseAll()) } catch let e as FormulaError { return .failure(e) } catch { return .failure(FormulaError(kind: .parse, message: "\(error)")) }
    }

    static func evaluate(_ node: FormulaNode, environment env: Environment) -> Result<Quantity, FormulaError> {
        do {
            let q = try value(node, env)
            // The boundary: nothing non-finite ever leaves the evaluator.
            guard q.value.isFinite else { throw FormulaError(kind: .notReal, message: "The result is too large to show") }
            return .success(q)
        } catch let e as FormulaError { return .failure(e) } catch { return .failure(FormulaError(kind: .parse, message: "\(error)")) }
    }

    /// Every variable name the expression uses.
    static func identifiers(in node: FormulaNode) -> [String] {
        switch node {
        case .variable(let n): [n]
        case .number, .constant, .reference, .range: []
        case .negate(let n), .percent(let n), .unit(let n, _), .group(let n): identifiers(in: n)
        case .binary(_, let a, let b), .implicitProduct(let a, let b): identifiers(in: a) + identifiers(in: b)
        case .call(_, let args): args.flatMap(identifiers(in:))
        }
    }

    // MARK: Arithmetic

    /// For an error about a label like `g Zn`: how to write it so it works, as plain `g`
    /// with the substance in the row's label. Empty when no unit is a label like that.
    static func labelHint(_ units: FormulaUnit?...) -> String {
        for case let u? in units where u.isOpaque {
            let symbol = u.text.split(separator: " ").first.map(String.init) ?? ""
            if let plain = FormulaUnit.parse(symbol), !plain.isOpaque {
                return ". Write the unit as plain “\(plain.text)” and name the substance in the row label"
            }
            return ". “\(u.text)” isn't a unit Indium can compute with"
        }
        return ""
    }

    static func percent(_ q: Quantity) -> Quantity {
        var p = q.precision
        p.decimals += 2
        return Quantity(q.value / 100, unit: q.unit, precision: p)
    }

    private static func checked(_ v: Double, _ what: String) throws -> Double {
        guard v.isFinite else { throw FormulaError(kind: .notReal, message: "\(what) has no real, finite value") }
        return v
    }

    static func add(_ a: Quantity, _ b: Quantity, subtract: Bool) throws -> Quantity {
        let unit: FormulaUnit?
        switch (a.unit, b.unit) {
        case let (x?, y?):
            guard x == y else {
                throw FormulaError(kind: .incompatibleUnits, message: "Can't \(subtract ? "subtract" : "add") \(y.text) \(subtract ? "from" : "to") \(x.text)" + labelHint(x, y))
            }
            unit = x
        // A plain number takes the other side's unit: 35.134 g − 34.794 = 0.340 g.
        default: unit = a.unit ?? b.unit
        }
        let v = try checked(subtract ? a.value - b.value : a.value + b.value, "The result")
        return Quantity(v, unit: unit, precision: .sum([a.precision, b.precision], value: v))
    }

    static func multiply(_ a: Quantity, _ b: Quantity, divide: Bool) throws -> Quantity {
        if divide, b.value == 0 { throw FormulaError(kind: .divisionByZero, message: "Division by zero") }
        let v = try checked(divide ? a.value / b.value : a.value * b.value, "The result")
        let combined = FormulaUnit.combine(a.unit, b.unit, power: divide ? -1 : 1)
        guard combined.defined else {
            throw FormulaError(kind: .incompatibleUnits,
                               message: "Can't \(divide ? "divide" : "multiply") \(a.unit?.text ?? "a plain number") by \(b.unit?.text ?? "a plain number"): the unit would be meaningless" + labelHint(a.unit, b.unit))
        }
        return Quantity(v, unit: combined.unit, precision: .product([a.precision, b.precision], value: v))
    }

    static func power(_ a: Quantity, _ b: Quantity) throws -> Quantity {
        if b.unit != nil { throw FormulaError(kind: .incompatibleUnits, message: "An exponent can't have a unit (\(b.unit!.text))") }
        let v = try checked(pow(a.value, b.value), "\(a.numberText())^\(b.numberText())")
        var unit: FormulaUnit? = nil
        if let base = a.unit {
            // Only a whole-number exponent has a unit to show (m^2); (4 m)^0.5 is an error.
            let whole = b.value.rounded() == b.value && abs(b.value) <= Double(FormulaUnit.maxPower)
            let raised: (unit: FormulaUnit?, defined: Bool) = whole ? base.raised(to: Int(b.value)) : (nil, false)
            guard raised.defined else {
                throw FormulaError(kind: .incompatibleUnits, message: "Can't raise \(base.text) to the power \(b.numberText())" + labelHint(base))
            }
            unit = raised.unit
        }
        // Precision follows the base; the exponent is taken as exact.
        return Quantity(v, unit: unit, precision: .product([a.precision], value: v))
    }

    // MARK: Tree walk

    private static func value(_ node: FormulaNode, _ env: Environment) throws -> Quantity {
        switch node {
        case .number(let text):
            guard let v = Double(text) else { throw FormulaError(kind: .parse, message: "“\(text)” isn't a number") }
            guard v.isFinite else { throw FormulaError(kind: .notReal, message: "“\(text)” is too large") }
            return Quantity(v, precision: .of(literal: text))
        case .constant(let name):
            return Quantity(name.lowercased() == "e" ? M_E : .pi)
        case .variable(let name):
            guard let q = env.variables[name] else {
                throw FormulaError(kind: .unknownVariable, message: "Unknown name “\(name)”")
            }
            return q
        case .reference(let ref):
            guard let cell = env.cell else { throw FormulaError(kind: .badReference, message: "Cell references only work in table formulas") }
            return try cell(ref).get()
        case .range(let a, let b):
            throw FormulaError(kind: .rangeMisuse, message: "The range \(a)..\(b) can only be used inside sum, mean, min, max or count")
        case .negate(let n):
            var q = try value(n, env)
            q.value = -q.value
            return q
        case .percent(let n):
            return percent(try value(n, env))
        case .unit(let n, let text):
            var q = try value(n, env)
            // An empty \text{} is just spacing.
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return q }
            guard let u = FormulaUnit.parse(text) else {
                throw FormulaError(kind: .parse, message: "“\(text.trimmingCharacters(in: .whitespaces))” isn't a unit")
            }
            if let existing = q.unit {
                throw FormulaError(kind: .incompatibleUnits, message: "\(q.numberText()) already has the unit \(existing.text)")
            }
            q.unit = u
            return q
        case .group(let n):
            return try value(n, env)
        case .binary(let op, let l, let r):
            let a = try value(l, env), b = try value(r, env)
            switch op {
            case "+": return try add(a, b, subtract: false)
            case "-": return try add(a, b, subtract: true)
            case "*": return try multiply(a, b, divide: false)
            case "/": return try multiply(a, b, divide: true)
            default: return try power(a, b)
            }
        case .implicitProduct(let l, let r):
            return try multiply(try value(l, env), try value(r, env), divide: false)
        case .call(let rawName, let args):
            let name = rawName.lowercased()
            if aggregateFunctions.contains(name) { return try aggregate(name, args, env) }
            guard mathFunctions.contains(name) else {
                throw FormulaError(kind: .unknownFunction, message: "Unknown function “\(rawName)”")
            }
            guard args.count == 1 else { throw FormulaError(kind: .parse, message: "\(name) takes one value") }
            let q = try value(args[0], env)
            let x = q.value
            let v: Double
            var unit: FormulaUnit? = nil
            // Trigonometry and logarithms need plain numbers: sin(3 g) means nothing.
            if let u = q.unit, name != "sqrt", name != "abs" {
                throw FormulaError(kind: .incompatibleUnits, message: "\(name) needs a plain number, not \(u.text)")
            }
            switch name {
            case "sqrt":
                guard x >= 0 else { throw FormulaError(kind: .notReal, message: "The square root of a negative number isn't real") }
                v = x.squareRoot()
                if let u = q.unit {
                    let root = u.squareRoot()
                    guard root.defined else { throw FormulaError(kind: .incompatibleUnits, message: "Can't take the square root of \(u.text)") }
                    unit = root.unit
                }
            case "abs": v = abs(x); unit = q.unit
            case "sin": v = sin(x)
            case "cos": v = cos(x)
            case "tan": v = tan(x)
            case "log", "ln":
                guard x > 0 else { throw FormulaError(kind: .notReal, message: "\(name) needs a positive number") }
                v = name == "log" ? log10(x) : log(x)
            default: v = x
            }
            return Quantity(try checked(v, "\(name)(\(q.numberText()))"), unit: unit, precision: .product([q.precision], value: v))
        }
    }

    private static func aggregate(_ name: String, _ args: [FormulaNode], _ env: Environment) throws -> Quantity {
        var items: [Quantity] = []
        for arg in args {
            if case .range(let a, let b) = arg {
                guard let range = env.range else { throw FormulaError(kind: .badReference, message: "Ranges only work in table formulas") }
                items += try range(a, b).get()
            } else {
                do { items.append(try value(arg, env)) } catch let e as FormulaError where e.kind == .blank {
                    continue  // a blank single cell counts as absent, like a blank cell in a range
                }
            }
        }
        if name == "count" { return Quantity(Double(items.count)) }
        guard let first = items.first else {
            if name == "sum" { return Quantity(0) }
            throw FormulaError(kind: .blank, message: "\(name) has no values")
        }
        for q in items.dropFirst() where q.unit != first.unit {
            let a = first.unit?.text ?? "plain numbers", b = q.unit?.text ?? "plain numbers"
            throw FormulaError(kind: .incompatibleUnits, message: "\(name) mixes \(a) and \(b)")
        }
        switch name {
        case "min": return items.min { $0.value < $1.value }!
        case "max": return items.max { $0.value < $1.value }!
        default:
            let total = items.dropFirst().reduce(first.value) { $0 + $1.value }
            var q = Quantity(try checked(total, "The sum"), unit: first.unit, precision: .sum(items.map(\.precision), value: total))
            if name == "mean" {
                q.value = total / Double(items.count)
                // The mean of measurements is known to the same decimal place as they are.
                q.precision = .sum(items.map(\.precision), value: q.value)
            }
            return q
        }
    }

    // MARK: - Parser

    /// Recursive descent with the usual precedence:
    ///   expression := term (('+' | '-') term)*
    ///   term       := unary (('*' | '/') unary | implicit-product)*
    ///   unary      := ('-' | '+') unary | power
    ///   power      := postfix ('^' unary)?        (right-associative: 2^3^2 = 2^9; -2^2 = -4)
    ///   postfix    := primary ('%' | unit)*
    ///   primary    := number | name | name '(' args ')' | function primary | '(' expression ')' | reference ['..' reference]
    private struct Parser {
        let chars: [Character]
        let options: Options
        var i = 0

        init(_ s: String, options: Options) {
            chars = Array(s)
            self.options = options
        }

        mutating func parseAll() throws -> FormulaNode {
            skipSpace()
            guard i < chars.count else { throw error("Nothing to calculate") }
            let node = try expression()
            skipSpace()
            if i < chars.count { throw error("Unexpected “\(chars[i])”") }
            return node
        }

        func error(_ message: String, at position: Int? = nil) -> FormulaError {
            FormulaError(kind: .parse, message: message, position: position ?? i)
        }

        mutating func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        mutating func peek() -> Character? {
            skipSpace()
            return i < chars.count ? chars[i] : nil
        }

        static func operatorChar(_ c: Character) -> Character? {
            switch c {
            case "+": "+"
            case "-", "−": "-"
            case "*", "×", "·", "⋅": "*"
            case "/", "÷": "/"
            default: nil
            }
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
            while let c = peek() {
                if let op = Parser.operatorChar(c), op == "*" || op == "/" {
                    i += 1
                    node = .binary(op, node, try unary())
                } else if options.allowsImplicitProducts, c == "(" || c.isLetter || c == "π" {
                    let at = i
                    if case .variable(let name) = node.strippingUnits {
                        throw error("Write * between “\(name)” and what follows", at: at)
                    }
                    let right = try power()
                    if case .variable(let name) = right.strippingUnits {
                        throw error("Write * before “\(name)”", at: at)
                    }
                    node = .implicitProduct(node, right)
                } else {
                    break
                }
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
            while true {
                guard let c = peek() else { break }
                if c == "%", options.allowsPercent {
                    i += 1
                    node = .percent(node)
                } else if c == "⟦" {
                    let start = i
                    guard let close = chars[i...].firstIndex(of: "⟧") else { throw error("Unclosed unit", at: start) }
                    let text = String(chars[(i + 1)..<close])
                    i = close + 1
                    node = .unit(node, text)
                } else {
                    break
                }
            }
            return node
        }

        mutating func primary() throws -> FormulaNode {
            guard let c = peek() else { throw error("Expected a value") }
            let start = i
            if c == "(" {
                i += 1
                let inner = try expression()
                guard peek() == ")" else { throw error("Missing “)”", at: i) }
                i += 1
                return .group(inner)
            }
            if c.isNumber || c == "." {
                let number = try readNumber()
                return try unitWord(after: .number(number))
            }
            if options.allowsReferences, c == "@" || c == "$" {
                let a = try readReference()
                if i + 1 < chars.count, chars[i] == ".", chars[i + 1] == "." {
                    i += 2
                    let b = try readReference()
                    if (a.row == nil) != (b.row == nil) {
                        throw error("A range must go row to row or column to column", at: start)
                    }
                    return .range(a, b)
                }
                return .reference(a)
            }
            if c == "π" { i += 1; return .constant("pi") }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_", chars[j].isASCII || chars[j].isLetter { j += 1 }
                let name = String(chars[i..<j])
                i = j
                let lower = name.lowercased()
                let callFollows = i < chars.count && chars[i] == "("
                if Evaluator.aggregateFunctions.contains(lower) || (callFollows && lower == "if") {
                    guard callFollows else { throw error("\(name) needs parentheses: \(name)(…)", at: start) }
                    if lower == "if" {
                        throw FormulaError(kind: .unsupported, message: "if() isn't supported yet", position: start)
                    }
                    i += 1
                    var args: [FormulaNode] = []
                    if peek() != ")" {
                        repeat {
                            if peek() == "," { i += 1 }
                            args.append(try expression())
                        } while peek() == ","
                    }
                    guard peek() == ")" else { throw error("Missing “)”") }
                    i += 1
                    return .call(lower, args)
                }
                if Evaluator.mathFunctions.contains(lower) {
                    // sqrt(16) or sqrt 16: the function takes the next power.
                    return .call(lower, [try power()])
                }
                if Evaluator.constants.contains(lower) { return .constant(lower) }
                if !(name.first!.isASCII) || name.contains(where: { !$0.isASCII }) {
                    throw error("“\(name)” isn't a name formulas understand", at: start)
                }
                if callFollows { throw FormulaError(kind: .unknownFunction, message: "Unknown function “\(name)”", position: start) }
                return .variable(name)
            }
            throw error("Unexpected “\(c)”", at: start)
        }

        mutating func readNumber() throws -> String {
            let start = i
            while i < chars.count, chars[i].isNumber, chars[i].isASCII { i += 1 }
            if i < chars.count, chars[i] == "." {
                i += 1
                while i < chars.count, chars[i].isNumber, chars[i].isASCII { i += 1 }
            }
            // 6.022e23 and 1e-3, but not `2e` (two times e) or `2e+3` spelled with spaces.
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                var j = i + 1
                if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                if j < chars.count, chars[j].isNumber, chars[j].isASCII {
                    while j < chars.count, chars[j].isNumber, chars[j].isASCII { j += 1 }
                    i = j
                }
            }
            let text = String(chars[start..<i])
            guard text != ".", Double(text) != nil else { throw error("“\(text)” isn't a number", at: start) }
            if i < chars.count, chars[i] == "." || (chars[i].isNumber && chars[i].isASCII) {
                throw error("“\(text)\(chars[i])…” isn't a number", at: start)
            }
            // Two numbers in a row ("1 2") is not arithmetic.
            let save = i
            if let c = peek(), c.isNumber || c == "." {
                throw error("Two numbers with nothing between them", at: i)
            }
            i = save
            return text
        }

        /// `2.008 g`, `5 mL`, `65.38 g/mol`: a whitelisted unit word right after a number.
        mutating func unitWord(after node: FormulaNode) throws -> FormulaNode {
            guard options.allowsUnitWords else { return node }
            let save = i
            skipSpace()
            func atom(from k: Int) -> (String, Int)? {
                var j = k
                while j < chars.count, chars[j].isLetter || "µμΩ°".contains(chars[j]) { j += 1 }
                guard j > k else { return nil }
                let word = String(chars[k..<j])
                guard Evaluator.unitWords.contains(word) else { return nil }
                // A word that continues (digits, _, a call) isn't a unit.
                if j < chars.count, chars[j].isNumber || chars[j] == "_" || chars[j] == "(" { return nil }
                // An exponent written onto the unit belongs to it: 16 m^2 is 16 (m^2).
                if j + 1 < chars.count, chars[j] == "^" {
                    var e = j + 1
                    if chars[e] == "-" { e += 1 }
                    let digits = e
                    while e < chars.count, chars[e].isNumber, chars[e].isASCII { e += 1 }
                    if e > digits { return (String(chars[k..<e]), e) }
                }
                return (word, j)
            }
            guard var (text, end) = atom(from: i) else { i = save; return node }
            // Compound units written without spaces: g/mol, mol/L, N·m.
            while end < chars.count, "/·".contains(chars[end]), let (next, e) = atom(from: end + 1) {
                text += String(chars[end]) + next
                end = e
            }
            i = end
            return .unit(node, text)
        }

        mutating func readReference() throws -> CellReference {
            var ref = CellReference()
            let start = i
            func index(rows: Bool) throws -> CellReference.Index {
                guard i < chars.count else { throw error("Incomplete reference", at: start) }
                let c = chars[i]
                if c == "<" { i += 1; return .first }
                if c == ">" { i += 1; return .last }
                if rows, c == "I" { i += 1; return .firstBody }
                var sign = 0
                if c == "+" || c == "-" { sign = c == "+" ? 1 : -1; i += 1 }
                let s = i
                while i < chars.count, chars[i].isNumber, chars[i].isASCII { i += 1 }
                guard i > s else { throw error("Expected a row or column number", at: start) }
                // Tables are small; a huge index is a typo, refused before any arithmetic.
                guard let n = Int(String(chars[s..<i])), n <= 100_000 else { throw error("“\(String(chars[start..<i]))” is far beyond any table", at: start) }
                if sign != 0 { return .relative(sign * n) }
                // @0 / $0 mean the current row / column, as upstream.
                return n == 0 ? .relative(0) : .absolute(n)
            }
            if i < chars.count, chars[i] == "@" { i += 1; ref.row = try index(rows: true) }
            if i < chars.count, chars[i] == "$" { i += 1; ref.column = try index(rows: false) }
            guard ref.row != nil || ref.column != nil else { throw error("Expected @row or $column", at: start) }
            return ref
        }
    }
}

private extension FormulaNode {
    var strippingUnits: FormulaNode {
        if case .unit(let n, _) = self { return n.strippingUnits }
        return self
    }
}
