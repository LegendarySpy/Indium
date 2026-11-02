/// Rewrites mhchem's `\ce{…}` and `\pu{…}` as LaTeX the typesetter can draw.
/// Anything it doesn't understand stays as written, so it fails like other bad math.
enum Mhchem {
    private enum Previous { case start, coefficient, formula }

    private static let arrows: [(token: String, command: String)] = [
        ("<=>", "rightleftharpoons"), ("<->", "xleftrightarrow"), ("->", "xrightarrow"), ("<-", "xleftarrow"),
    ]
    private static let states = ["(aq)", "(s)", "(l)", "(g)"]
    private static let dot = "\\,\\mathord{\\cdot}\\,"
    // The typesetter's cost and stack use grow quickly with nesting.
    private static let maxNesting = 8

    static func expand(_ latex: String) -> String {
        guard latex.contains("\\ce") || latex.contains("\\pu") else { return latex }
        let c = Array(latex)
        var out = ""
        var i = 0
        while i < c.count {
            guard c[i] == "\\" else { out.append(c[i]); i += 1; continue }
            var end = i + 1
            while end < c.count, isLetter(c[end]) { end += 1 }
            let name = String(c[(i + 1)..<end])
            var open = end
            while open < c.count, c[open].isWhitespace { open += 1 }
            if name == "ce" || name == "pu", open < c.count, c[open] == "{", let close = matching(c, open) {
                let body = Array(c[(open + 1)..<close])
                if nesting(body) <= maxNesting, let tex = name == "ce" ? ce(body) : pu(body) {
                    out += "\\mathrm{\(tex)}"
                    i = close + 1
                    continue
                }
            }
            end = min(max(end, i + 2), c.count)
            out += String(c[i..<end])
            i = end
        }
        return out
    }

    private static func ce(_ c: [Character]) -> String? {
        var out = ""
        var i = 0
        var previous = Previous.start
        var spaced = false

        func lead() {
            if previous == .coefficient { out += "\\," } else if previous == .formula, spaced { out += "\\ " }
            spaced = false
        }
        func finish(_ next: Previous) {
            previous = next
            spaced = false
        }

        while i < c.count {
            let ch = c[i]
            let attached = previous == .formula && !spaced
            let standalone = previous == .formula && spaced && (i + 1 == c.count || c[i + 1].isWhitespace)
            if ch.isWhitespace {
                spaced = true
                i += 1
            } else if let arrow = arrows.first(where: { c[i...].starts(with: $0.token) }) {
                i += arrow.token.count
                if i < c.count, "<>-=".contains(c[i]) { return nil }
                var labels: [String] = []
                while labels.count < 2, i < c.count, c[i] == "[" {
                    guard let close = matching(c, i), let label = ce(Array(c[(i + 1)..<close])) else { return nil }
                    labels.append(label)
                    i = close + 1
                }
                let above = labels.first ?? ""
                let below = labels.count > 1 ? labels[1] : ""
                if arrow.command.hasPrefix("x") {
                    out += "\\\(arrow.command)" + (below.isEmpty ? "" : "[{\(below)}]") + "{\(above)}"
                } else {
                    var stacked = "\\\(arrow.command)"
                    if !above.isEmpty { stacked = "\\overset{\(above)}{\(stacked)}" }
                    if !below.isEmpty { stacked = "\\underset{\(below)}{\(stacked)}" }
                    out += stacked + " "
                }
                finish(.start)
            } else if ch == "+" || ch == "-" {
                i += 1
                if !attached {
                    out.append(ch)
                    finish(.start)
                } else if ch == "-", i < c.count, isLetter(c[i]) || c[i].isNumber {
                    out += "\\mathord{-}"
                    finish(.start)
                } else {
                    out += "^{\(ch)}"
                }
            } else if ch == "=" || ch == "#" {
                i += 1
                if ch == "=", !attached { out.append(ch) } else { out += ch == "=" ? "\\mathord{=}" : "\\mathord{\\equiv}" }
                finish(.start)
            } else if ch == "*" || ch == "." || ch == "\u{B7}" {
                i += 1
                out += dot
                finish(.start)
            } else if ch == "," || ch == ";" {
                i += 1
                out += "\\mathord{\(ch)}\\mkern6mu "
                finish(.start)
            } else if ch == "^" || ch == "_" {
                if ch == "^", standalone {
                    i += 1
                    out += "\\uparrow "
                    finish(.formula)
                } else {
                    i += 1
                    guard attached, let argument = script(c, &i) else { return nil }
                    out += "\(ch){\(argument)}"
                }
            } else if ch == "v", standalone {
                i += 1
                out += "\\downarrow "
                finish(.formula)
            } else if ch == "(", let state = states.first(where: { c[i...].starts(with: $0) }) {
                i += state.count
                if previous == .formula { out += "\\mkern2mu " } else { lead() }
                out += state
                finish(.formula)
            } else if ch == "(" || ch == "[" {
                i += 1
                lead()
                out.append(ch)
                finish(.start)
            } else if ch == ")" || ch == "]" {
                i += 1
                out.append(ch)
                finish(.formula)
            } else if ch == "/" || ch == ":" || ch == "|" {
                i += 1
                out.append(ch)
                finish(.start)
            } else if ch == "{" {
                guard let close = matching(c, i), !c[i..<close].contains("$") else { return nil }
                lead()
                out += "\\text{\(String(c[(i + 1)..<close]))}"
                i = close + 1
                finish(.formula)
            } else if ch == "\\" {
                lead()
                guard let tex = command(c, &i) else { return nil }
                out += tex
                finish(.formula)
            } else if isDigit(ch) {
                if attached {
                    let digits = run(c, &i, while: isDigit)
                    out += "_{\(digits)}"
                } else {
                    lead()
                    out += coefficient(c, &i)
                    finish(.coefficient)
                }
            } else if isLetter(ch) {
                // A lone lowercase letter before a formula is a variable coefficient: `n H2O`.
                if !attached, ch.isLowercase, i + 2 < c.count, c[i + 1].isWhitespace, c[i + 2].isUppercase {
                    i += 1
                    lead()
                    out += "\\mathit{\(ch)}"
                    finish(.coefficient)
                } else {
                    i += 1
                    lead()
                    out.append(ch)
                    finish(.formula)
                }
            } else {
                return nil
            }
        }
        return out
    }

    private static func pu(_ c: [Character]) -> String? {
        var out = ""
        var i = 0

        func skipSpaces() { while i < c.count, c[i].isWhitespace { i += 1 } }
        func number() -> Bool {
            let start = i
            if i < c.count, c[i] == "-" || c[i] == "+" { i += 1 }
            let sign = String(c[start..<i])
            guard i < c.count, isDigit(c[i]) else { i = start; return false }
            var digits = run(c, &i, while: isDigit)
            while i + 1 < c.count, c[i] == "." || c[i] == ",", isDigit(c[i + 1]) {
                let separator = c[i] == "," ? "\\mathord{,}" : "."
                i += 1
                digits += separator + run(c, &i, while: isDigit)
            }
            out += sign + digits
            return true
        }
        func exponent() -> String? {
            var j = i
            if j < c.count, c[j] == "-" || c[j] == "+" { j += 1 }
            let first = j
            while j < c.count, isDigit(c[j]) { j += 1 }
            guard j > first else { return nil }
            defer { i = j }
            return String(c[i..<j])
        }

        let hasNumber = number()
        if hasNumber {
            skipSpaces()
            if c[i...].starts(with: "+-") || c[i...].starts(with: "\u{B1}") {
                i += c[i] == "+" ? 2 : 1
                out += "\\pm "
                skipSpaces()
                guard number() else { return nil }
                skipSpaces()
            } else if i < c.count, c[i] == "-" {
                i += 1
                out += "-"
                guard number() else { return nil }
                skipSpaces()
            }
            if i < c.count, c[i] == "e" || c[i] == "E" {
                let times = c[i] == "E" ? "\\times" : "\\cdot"
                i += 1
                if let power = exponent() {
                    out += "\(times) 10^{\(power)}"
                } else {
                    i -= 1
                }
            } else if i < c.count, c[i] == "x" || c[i] == "*" {
                let start = i
                let times = c[i] == "x" ? "\\times" : "\\cdot"
                i += 1
                skipSpaces()
                if c[i...].starts(with: "10^") {
                    i += 3
                    guard let power = script(c, &i) else { return nil }
                    out += "\(times) 10^{\(power)}"
                } else {
                    i = start
                }
            }
            skipSpaces()
            if i < c.count { out += "\\ " }
        }

        var afterUnit = false
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace {
                skipSpaces()
                if i < c.count, c[i] != "/" { out += "\\mkern3mu " }
                afterUnit = false
            } else if ch == "*" || ch == "." || ch == "\u{B7}" {
                i += 1
                out += "\\mkern1mu\\mathord{\\cdot}\\mkern1mu "
                skipSpaces()
                afterUnit = false
            } else if ch == "^" {
                i += 1
                guard afterUnit, let argument = script(c, &i) else { return nil }
                out += "^{\(argument)}"
            } else if afterUnit, isDigit(ch) || (ch == "-" && i + 1 < c.count && isDigit(c[i + 1])) {
                i += ch == "-" ? 1 : 0
                let digits = run(c, &i, while: isDigit)
                out += "^{\(ch == "-" ? "-" : "")\(digits)}"
            } else if ch == "\\" {
                guard let tex = command(c, &i) else { return nil }
                out += tex + " "
                skipSpaces()
                afterUnit = true
            } else if ch == "/" || ch == "(" {
                i += 1
                out.append(ch)
                skipSpaces()
                afterUnit = false
            } else if isLetter(ch) || ch == ")" || ch == "%" {
                i += 1
                out.append(ch)
                afterUnit = true
            } else if let symbol = unitSymbols[ch] {
                i += 1
                out += symbol + " "
                afterUnit = true
            } else {
                return nil
            }
        }
        return out
    }

    private static let unitSymbols: [Character: String] = [
        "\u{B0}": "\\degree", "\u{B5}": "\\mu", "\u{3BC}": "\\mu", "\u{3A9}": "\\Omega",
    ]

    private static func nesting(_ c: [Character]) -> Int {
        var depth = 0
        var deepest = 0
        for ch in c {
            if ch == "{" || ch == "[" {
                depth += 1
                deepest = max(deepest, depth)
            } else if ch == "}" || ch == "]" {
                depth -= 1
            }
        }
        return deepest
    }

    private static func matching(_ c: [Character], _ start: Int) -> Int? {
        let open = c[start]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        var i = start
        while i < c.count {
            if c[i] == "\\" {
                i += 2
                continue
            }
            if c[i] == "{", open != "{" {
                guard let end = matching(c, i) else { return nil }
                i = end + 1
                continue
            }
            if c[i] == open { depth += 1 } else if c[i] == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func command(_ c: [Character], _ i: inout Int) -> String? {
        let start = i
        i += 1
        while i < c.count, isLetter(c[i]) { i += 1 }
        if i == start + 1 {
            guard i < c.count else { return nil }
            i += 1
        }
        while i < c.count, c[i] == "{" {
            guard let close = matching(c, i) else { return nil }
            i = close + 1
        }
        return String(c[start..<i])
    }

    private static func script(_ c: [Character], _ i: inout Int) -> String? {
        guard i < c.count else { return nil }
        if c[i] == "{" {
            guard let close = matching(c, i) else { return nil }
            defer { i = close + 1 }
            return String(c[(i + 1)..<close])
        }
        let start = i
        _ = run(c, &i, while: isDigit)
        if i == start, isLetter(c[i]) || c[i] == "*" { i += 1 }
        if i < c.count, c[i] == "+" || c[i] == "-" { i += 1 }
        return i > start ? String(c[start..<i]) : nil
    }

    private static func coefficient(_ c: [Character], _ i: inout Int) -> String {
        var number = run(c, &i, while: isDigit)
        if i + 1 < c.count, c[i] == ".", isDigit(c[i + 1]) {
            i += 1
            number += "." + run(c, &i, while: isDigit)
        } else if i + 1 < c.count, c[i] == "/", isDigit(c[i + 1]) {
            i += 1
            return "\\tfrac{\(number)}{\(run(c, &i, while: isDigit))}"
        }
        return number
    }

    private static func run(_ c: [Character], _ i: inout Int, while test: (Character) -> Bool) -> String {
        let start = i
        while i < c.count, test(c[i]) { i += 1 }
        return String(c[start..<i])
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    private static func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
}
