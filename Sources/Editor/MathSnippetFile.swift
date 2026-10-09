import Foundation

/// Reading a math shortcuts file, written the way LaTeX Suite writes snippets.
extension MathSnippetConfig {
    struct Result {
        var snippets: [MathSnippet] = []
        var problems: [String] = []
    }

    /// The snippets in `text`: a list of `{trigger, replacement, options, priority}`, or
    /// LaTeX Suite's settings with that list as the string under `snippets`.
    static func parse(_ text: String) -> Result {
        var result = Result()
        var reader = Reader(text)
        let value: Value
        do {
            value = try reader.document()
        } catch let error as Reader.Failure {
            result.problems = ["Line \(error.line): \(error.message). None of your shortcuts are in use until it's fixed."]
            return result
        } catch {
            return result
        }
        var entries: [(Value, Int)]
        switch value.kind {
        case let .array(items):
            entries = items
        case let .object(fields):
            // LaTeX Suite's data.json: the list is a string of JavaScript under `snippets`.
            guard let snippets = fields.first(where: { $0.key == "snippets" })?.value else {
                result.problems = ["Line \(value.line): expected a list of shortcuts, [ … ], or LaTeX Suite's settings with \"snippets\"."]
                return result
            }
            switch snippets.kind {
            case let .array(items):
                entries = items
            case let .string(inner):
                let nested = parse(inner)
                result.snippets = nested.snippets
                result.problems = nested.problems.map { "In \"snippets\", " + $0.prefix(1).lowercased() + $0.dropFirst() }
                return result
            default:
                result.problems = ["Line \(snippets.line): \"snippets\" should be a list."]
                return result
            }
        default:
            result.problems = ["Line \(value.line): expected a list of shortcuts, [ … ]."]
            return result
        }
        for (n, entry) in entries.enumerated() {
            do {
                result.snippets.append(try snippet(from: entry.0))
            } catch let problem as Problem {
                result.problems.append("Line \(entry.1), shortcut \(n + 1)\(problem.trigger.map { " (\($0))" } ?? ""): \(problem.message).")
            } catch {}
        }
        return result
    }

    private struct Problem: Error {
        var trigger: String?
        let message: String
    }

    private static let variables: [String: String] = [
        "GREEK": MathSnippet.greek.joined(separator: "|"),
        "SYMBOL": MathSnippet.symbols.joined(separator: "|"),
    ]

    private static func snippet(from entry: Value) throws -> MathSnippet {
        guard case let .object(fields) = entry.kind else { throw Problem(message: "expected { trigger: …, replacement: …, options: … }") }
        func field(_ name: String) -> Value? { fields.first { $0.key == name }?.value }
        var regexOptions: NSRegularExpression.Options = []
        var trigger: String
        var isRegex = false
        switch field("trigger")?.kind {
        case let .string(s)?: trigger = s
        case let .regex(pattern, flags)?:
            trigger = pattern
            isRegex = true
            for f in flags {
                switch f {
                case "i": regexOptions.insert(.caseInsensitive)
                case "u", "g", "y": break
                case "s": regexOptions.insert(.dotMatchesLineSeparators)
                case "m": regexOptions.insert(.anchorsMatchLines)
                default: throw Problem(trigger: "/\(pattern)/", message: "regex flag \"\(f)\" isn't supported")
                }
            }
        case nil: throw Problem(message: "it has no trigger")
        default: throw Problem(message: "the trigger should be text in quotes or a /regex/")
        }
        let shown = isRegex ? "/\(trigger)/" : "\"\(trigger)\""
        guard !trigger.isEmpty else { throw Problem(message: "the trigger is empty") }
        let replacement: String
        switch field("replacement")?.kind {
        case let .string(s)?: replacement = s
        case .unsupported?: throw Problem(trigger: shown, message: "function replacements need LaTeX Suite's JavaScript, which Indium doesn't run")
        case nil: throw Problem(trigger: shown, message: "it has no replacement")
        default: throw Problem(trigger: shown, message: "the replacement should be text in quotes")
        }
        var options = ""
        switch field("options")?.kind {
        case let .string(s)?: options = s
        case nil: break
        default: throw Problem(trigger: shown, message: "options should be letters in quotes, like \"mA\"")
        }
        if let flags = field("flags"), case let .string(f) = flags.kind, f.contains("i") { regexOptions.insert(.caseInsensitive) }
        if options.contains("v") { throw Problem(trigger: shown, message: "visual shortcuts (option v) aren't supported yet") }
        let unknown = options.filter { !"tmMnArw".contains($0) }
        if !unknown.isEmpty { throw Problem(trigger: shown, message: "unknown option \"\(unknown)\" (use m, M, n, t, A, r, w)") }
        // No mode: LaTeX Suite uses it everywhere.
        if !options.contains(where: { "tmMn".contains($0) }) { options += "mt" }
        if isRegex { options += "r" }
        if options.contains("r") {
            // LaTeX Suite's ${GREEK} and ${SYMBOL} stand for the names of Greek letters and symbols.
            let vars = try NSRegularExpression(pattern: #"\$\{([A-Z_]+)\}"#)
            for m in vars.matches(in: trigger, range: NSRange(location: 0, length: (trigger as NSString).length)).reversed() {
                let name = (trigger as NSString).substring(with: m.range(at: 1))
                guard let value = variables[name] else { throw Problem(trigger: shown, message: "unknown variable ${\(name)} (Indium knows ${GREEK} and ${SYMBOL})") }
                trigger = (trigger as NSString).replacingCharacters(in: m.range, with: "(?:" + value + ")")
            }
        }
        var priority = 0
        switch field("priority")?.kind {
        case let .number(n)?:
            // (`Int(n)` would stop the app on 1e999 or 1e300.)
            guard let whole = Int(exactly: n), abs(whole) <= 10_000 else {
                throw Problem(trigger: shown, message: "priority must be a whole number from -10000 to 10000")
            }
            priority = whole
        case nil: break
        default: throw Problem(trigger: shown, message: "priority should be a number")
        }
        do {
            return try MathSnippet(validating: trigger, replacement, options, priority: priority, regexOptions: regexOptions)
        } catch {
            throw Problem(trigger: shown, message: "the regex isn't valid (check its brackets and backslashes)")
        }
    }

    // MARK: A JavaScript literal, as far as snippets go

    /// JSON, plus what LaTeX Suite's list uses of JavaScript: unquoted keys, 'single quotes',
    /// /regex/ literals, comments and trailing commas. Anything else (a function) is read
    /// past and marked unsupported, so one such entry doesn't spoil the rest.
    struct Value {
        indirect enum Kind {
            case string(String), number(Double), bool(Bool), null
            case regex(String, String)
            case array([(Value, Int)])
            case object([(key: String, value: Value)])
            case unsupported
        }
        let kind: Kind
        let line: Int
    }

    struct Reader {
        struct Failure: Error {
            let line: Int
            let message: String
        }

        private let chars: [Character]
        private var i = 0
        private var line = 1

        init(_ text: String) { chars = Array(text) }

        mutating func document() throws -> Value {
            let v = try value()
            skipSpace()
            guard i == chars.count else { throw fail("unexpected \(describe(chars[i])) after the end of the list") }
            return v
        }

        private func fail(_ message: String) -> Failure { Failure(line: line, message: message) }

        private func describe(_ c: Character) -> String { "\"\(c)\"" }

        private mutating func advance() {
            if chars[i] == "\n" { line += 1 }
            i += 1
        }

        private mutating func skipSpace() {
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace {
                    advance()
                } else if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { advance() }
                } else if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    advance(); advance()
                    while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { advance() }
                    if i < chars.count { advance(); advance() }
                } else {
                    return
                }
            }
        }

        private mutating func value() throws -> Value {
            skipSpace()
            guard i < chars.count else { throw fail("the file ends too soon") }
            let at = line
            let c = chars[i]
            switch c {
            case "[":
                advance()
                var items: [(Value, Int)] = []
                while true {
                    skipSpace()
                    guard i < chars.count else { throw fail("a list isn't closed with ]") }
                    if chars[i] == "]" { advance(); break }
                    let itemLine = line
                    items.append((try value(), itemLine))
                    skipSpace()
                    guard i < chars.count else { throw fail("a list isn't closed with ]") }
                    if chars[i] == "," { advance() } else if chars[i] != "]" { throw fail("expected a comma or ], found \(describe(chars[i]))") }
                }
                return Value(kind: .array(items), line: at)
            case "{":
                advance()
                var fields: [(key: String, value: Value)] = []
                while true {
                    skipSpace()
                    guard i < chars.count else { throw fail("a { isn't closed with }") }
                    if chars[i] == "}" { advance(); break }
                    let key = try self.key()
                    skipSpace()
                    guard i < chars.count, chars[i] == ":" else { throw fail("expected a colon after \(key)") }
                    advance()
                    fields.append((key, try value()))
                    skipSpace()
                    guard i < chars.count else { throw fail("a { isn't closed with }") }
                    if chars[i] == "," { advance() } else if chars[i] != "}" { throw fail("expected a comma or }, found \(describe(chars[i]))") }
                }
                return Value(kind: .object(fields), line: at)
            case "\"", "'", "`":
                return Value(kind: .string(try string()), line: at)
            case "/":
                return Value(kind: try regex(), line: at)
            default:
                if c == "-" || c == "+" || c.isNumber {
                    var s = ""
                    while i < chars.count, chars[i].isNumber || "+-.eE".contains(chars[i]) { s.append(chars[i]); advance() }
                    guard let n = Double(s) else { throw fail("\(s) isn't a number") }
                    return Value(kind: .number(n), line: at)
                }
                let word = identifier()
                switch word {
                case "true": return Value(kind: .bool(true), line: at)
                case "false": return Value(kind: .bool(false), line: at)
                case "null", "undefined": return Value(kind: .null, line: at)
                case "":
                    if c == "(" { try skipUnsupported(); return Value(kind: .unsupported, line: at) }
                    throw fail("unexpected \(describe(c))")
                default:
                    // `function (…) {…}`, `match => …`: JavaScript Indium doesn't run.
                    try skipUnsupported()
                    return Value(kind: .unsupported, line: at)
                }
            }
        }

        private mutating func identifier() -> String {
            var s = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" { s.append(chars[i]); advance() }
            return s
        }

        private mutating func key() throws -> String {
            if chars[i] == "\"" || chars[i] == "'" { return try string() }
            let k = identifier()
            guard !k.isEmpty else { throw fail("expected a name like trigger:, found \(describe(chars[i]))") }
            return k
        }

        private mutating func string() throws -> String {
            let quote = chars[i]
            let start = line
            advance()
            var s = ""
            while i < chars.count, chars[i] != quote {
                if chars[i] == "\\" {
                    advance()
                    guard i < chars.count else { break }
                    let e = chars[i]
                    switch e {
                    case "n": s.append("\n")
                    case "t": s.append("\t")
                    case "r": s.append("\r")
                    case "b": s.append("\u{8}")
                    case "f": s.append("\u{c}")
                    case "u":
                        let hex = String(chars[min(i + 1, chars.count)..<min(i + 5, chars.count)])
                        guard hex.count == 4, let code = UInt32(hex, radix: 16), let u = Unicode.Scalar(code) else { throw fail("bad \\u escape") }
                        s.unicodeScalars.append(u)
                        for _ in 0..<4 { advance() }
                    case "\n": break
                    default: s.append(e)
                    }
                    advance()
                    continue
                }
                if chars[i] == "\n", quote != "`" { throw fail("a string isn't closed (it starts on line \(start))") }
                s.append(chars[i])
                advance()
            }
            guard i < chars.count else { throw Failure(line: start, message: "a string isn't closed") }
            advance()
            return s
        }

        private mutating func regex() throws -> Value.Kind {
            advance()
            var pattern = ""
            var inClass = false
            while i < chars.count {
                let c = chars[i]
                if c == "\n" { throw fail("a /regex/ isn't closed") }
                if c == "\\", i + 1 < chars.count {
                    pattern.append(c)
                    advance()
                    pattern.append(chars[i])
                    advance()
                    continue
                }
                if c == "[" { inClass = true } else if c == "]" { inClass = false }
                if c == "/", !inClass { break }
                pattern.append(c)
                advance()
            }
            guard i < chars.count else { throw fail("a /regex/ isn't closed") }
            advance()
            return .regex(pattern, identifier())
        }

        /// Past a value Indium can't use, to the comma or bracket that ends it.
        private mutating func skipUnsupported() throws {
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\"" || c == "'" || c == "`" { _ = try string(); continue }
                if "([{".contains(c) { depth += 1 } else if ")]}".contains(c) {
                    if depth == 0 { return }
                    depth -= 1
                } else if c == ",", depth == 0 { return }
                advance()
            }
        }
    }
}
