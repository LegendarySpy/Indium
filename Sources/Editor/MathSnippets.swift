import Foundation

/// Shortcuts for writing LaTeX quickly, after Obsidian's LaTeX Suite: `sr` → `^{2}`,
/// `@a` → `\alpha`, `x1` → `x_{1}`, `alpha` → `\alpha`, `mk` → `$…$`, and so on.
///
/// A replacement can hold tabstops: `$0`, `$1`… (Tab moves through them in order) or
/// `${1:text}` (text that starts selected). `[[0]]`, `[[1]]`… are a regex trigger's
/// captured groups, and `${VISUAL}` is the text that was selected.
struct MathSnippet {
    enum Trigger {
        case literal(String)
        case regex(NSRegularExpression)
    }
    let trigger: Trigger
    let replacement: String
    /// Where it applies: math (`m`), display math only (`M`), inline math only (`n`), or prose (`t`).
    let math: Bool, text: Bool, displayOnly: Bool, inlineOnly: Bool
    /// Expands as you type (`A`); otherwise on Tab.
    let auto: Bool
    /// Can't follow a letter or a backslash (`w`): `sq` fires in `2sq`, not in `\sq` or `csq`.
    let word: Bool
    let priority: Int

    /// Options as LaTeX Suite writes them: `m`/`M`/`n`/`t` for mode, `A` auto, `w` word, `r` regex.
    init(_ trigger: String, _ replacement: String, _ options: String, priority: Int = 0) {
        if options.contains("r") {
            self.trigger = .regex(try! NSRegularExpression(pattern: "(?:" + trigger + ")$"))
        } else {
            self.trigger = .literal(trigger)
        }
        self.replacement = replacement
        math = options.contains("m") || options.contains("M") || options.contains("n")
        displayOnly = options.contains("M")
        inlineOnly = options.contains("n")
        text = options.contains("t")
        auto = options.contains("A")
        word = options.contains("w")
        self.priority = priority
    }

    struct Expansion {
        /// UTF-16 length of the trigger, ending at the caret.
        let length: Int
        let text: String
        /// Tabstops in the expanded text, in the order Tab visits them.
        let stops: [NSRange]
    }

    enum Context {
        case text
        case math(display: Bool)
    }

    /// The snippet whose trigger ends `before` (the text up to the caret), if any.
    static func expansion(before: String, context: Context, auto: Bool) -> Expansion? {
        let ns = before as NSString
        // Triggers are short; regexes only need the tail.
        let tailStart = max(0, ns.length - 64)
        let tail = ns.substring(from: tailStart)
        let tailNS = tail as NSString
        var best: (snippet: MathSnippet, length: Int, captures: [String])?
        for snippet in all where snippet.auto == auto && snippet.applies(in: context) {
            var found: (Int, [String])?
            switch snippet.trigger {
            case let .literal(t):
                let length = (t as NSString).length
                guard before.hasSuffix(t) else { continue }
                if ns.length > length {
                    let c = ns.character(at: ns.length - length - 1)
                    let afterBackslash = c == 0x5C
                    if snippet.word, afterBackslash || (UnicodeScalar(c).map { CharacterSet.letters.contains($0) } ?? false) { continue }
                    // `\_`, `\{`, `\(` are characters of their own, not shortcuts.
                    if afterBackslash, let first = t.first, !first.isLetter, first != "\\" { continue }
                }
                found = (length, [])
            case let .regex(regex):
                guard let m = regex.firstMatch(in: tail, range: NSRange(location: 0, length: tailNS.length)) else { continue }
                let captures = (1..<max(1, m.numberOfRanges)).map { i in
                    m.range(at: i).location == NSNotFound ? "" : tailNS.substring(with: m.range(at: i))
                }
                found = (m.range.length, captures)
            }
            guard let (length, captures) = found, length > 0 else { continue }
            if let b = best, (b.snippet.priority, b.length) >= (snippet.priority, length) { continue }
            best = (snippet, length, captures)
        }
        guard let best else { return nil }
        let (text, stops) = render(best.snippet.replacement, captures: best.captures, visual: "")
        return Expansion(length: best.length, text: text, stops: stops)
    }

    private func applies(in context: Context) -> Bool {
        switch context {
        case .text: return text
        case let .math(display): return math && !(displayOnly && !display) && !(inlineOnly && display)
        }
    }

    /// Expands `$n`, `${n:text}`, `[[n]]` and `${VISUAL}`.
    static func render(_ replacement: String, captures: [String], visual: String) -> (String, [NSRange]) {
        var out = ""
        var length = 0
        var stops: [Int: NSRange] = [:]
        let chars = Array(replacement)
        var i = 0
        func append(_ s: String) {
            out += s
            length += (s as NSString).length
        }
        func number(at j: Int) -> (Int, Int)? {
            var k = j
            while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
            guard k > j, let n = Int(String(chars[j..<k])) else { return nil }
            return (n, k)
        }
        while i < chars.count {
            let c = chars[i]
            if c == "[", i + 1 < chars.count, chars[i + 1] == "[", let (n, k) = number(at: i + 2),
               k + 1 < chars.count, chars[k] == "]", chars[k + 1] == "]" {
                append(n < captures.count ? captures[n] : "")
                i = k + 2
                continue
            }
            if c == "$" {
                if let (n, k) = number(at: i + 1) {
                    if stops[n] == nil { stops[n] = NSRange(location: length, length: 0) }
                    i = k
                    continue
                }
                if i + 1 < chars.count, chars[i + 1] == "{" {
                    let rest = String(chars[(i + 2)...])
                    if rest.hasPrefix("VISUAL}") {
                        append(visual)
                        i += 2 + 7
                        continue
                    }
                    if let (n, k) = number(at: i + 2), k < chars.count, chars[k] == ":",
                       let close = chars[(k + 1)...].firstIndex(of: "}") {
                        let placeholder = String(chars[(k + 1)..<close])
                        let start = length
                        append(placeholder)
                        if stops[n] == nil { stops[n] = NSRange(location: start, length: length - start) }
                        i = close + 1
                        continue
                    }
                }
            }
            append(String(c))
            i += 1
        }
        return (out, stops.keys.sorted().map { stops[$0]! })
    }

    // MARK: Words that become commands

    static let greek = ["alpha", "beta", "gamma", "Gamma", "delta", "Delta", "epsilon", "varepsilon", "zeta", "eta", "theta",
                        "vartheta", "Theta", "iota", "kappa", "lambda", "Lambda", "mu", "nu", "xi", "Xi", "pi", "Pi", "rho",
                        "varrho", "sigma", "Sigma", "tau", "upsilon", "Upsilon", "phi", "varphi", "Phi", "chi", "psi", "Psi",
                        "omega", "Omega"]
    /// LaTeX Suite's symbol list, less the words another shortcut starts with
    /// (`sq`uare, `para`llel, `dag`ger, `set`minus).
    static let symbols = ["perp", "partial", "nabla", "hbar", "ell", "infty", "oplus", "ominus", "otimes", "oslash", "star",
                          "vee", "wedge", "subseteq", "subset", "supseteq", "supset", "emptyset", "exists", "nexists", "forall",
                          "implies", "impliedby", "iff", "neg", "lor", "land", "bigcup", "bigcap", "cdot", "times", "simeq",
                          "approx"]
    static let functions = ["arcsin", "sin", "arccos", "cos", "arctan", "tan", "csc", "sec", "cot", "sinh", "cosh", "tanh",
                            "coth", "exp", "log", "ln", "det", "min", "max", "int"]
    /// After these, a letter starts a new word: `\alpha` then `x` makes `\alpha x`.
    static let spaceAfter = Set(greek + symbols + functions + ["leq", "geq", "neq", "gg", "ll", "equiv", "sim", "propto", "to",
                                                                "mapsto", "cap", "cup", "in", "sum", "prod", "dots", "pm", "mp",
                                                                "iint", "iiint", "oint", "lim", "setminus", "parallel", "dagger"])
    /// Commands that start with one of those words, so typing on doesn't split them.
    private static let longerCommands = ["int", "infty", "inf", "injlim", "intercal", "top", "simeq", "subseteq", "subsetneq",
                                         "supseteq", "supsetneq", "cdots", "dotsc", "dotsb", "dotsm", "dotsi", "dotso", "lnot",
                                         "sinh", "cosh", "tanh", "coth", "sech", "csch", "liminf", "limsup", "approxeq",
                                         "leqslant", "geqslant", "leqq", "geqq", "veebar", "negthinspace", "negmedspace",
                                         "negthickspace", "notin", "nexists", "mapsto", "implies", "impliedby", "Pi", "Phi",
                                         "Psi", "Xi", "exists", "emptyset", "equiv", "ell", "iint", "iiint", "sumlimits",
                                         "dagger", "parallel", "setminus", "lg", "argmax", "argmin", "wedge", "vee"]

    /// True when `\word` followed by `letter` should become `\word letter`.
    static func wantsSpace(after word: String, before letter: Character) -> Bool {
        guard spaceAfter.contains(word) else { return false }
        let longer = word + String(letter)
        return !(longerCommands + greek + symbols + functions).contains { $0.hasPrefix(longer) }
    }

    // MARK: The defaults

    static let all: [MathSnippet] = {
        var s: [MathSnippet] = [
            // Into math from prose.
            .init("mk", "$$0$", "tAw"),
            .init("dm", "$$\n$0\n$$", "tAw"),

            // Greek letters.
            .init("@a", "\\alpha", "mA"), .init("@b", "\\beta", "mA"), .init("@g", "\\gamma", "mA"), .init("@G", "\\Gamma", "mA"),
            .init("@d", "\\delta", "mA"), .init("@D", "\\Delta", "mA"), .init("@e", "\\epsilon", "mA"), .init(":e", "\\varepsilon", "mA"),
            .init("@z", "\\zeta", "mA"), .init("@t", "\\theta", "mA"), .init("@T", "\\Theta", "mA"), .init(":t", "\\vartheta", "mA"),
            .init("@i", "\\iota", "mA"), .init("@k", "\\kappa", "mA"), .init("@l", "\\lambda", "mA"), .init("@L", "\\Lambda", "mA"),
            .init("@s", "\\sigma", "mA"), .init("@S", "\\Sigma", "mA"), .init("@u", "\\upsilon", "mA"), .init("@U", "\\Upsilon", "mA"),
            .init("@o", "\\omega", "mA"), .init("@O", "\\Omega", "mA"), .init("@p", "\\phi", "mA"), .init("@P", "\\Phi", "mA"),
            .init("@r", "\\rho", "mA"), .init("@m", "\\mu", "mA"),

            // Text.
            .init("text", "\\text{$0}$1", "mAw"),
            .init("\"", "\\text{$0}$1", "mA"),

            // Basic operations.
            .init("sr", "^{2}", "mA"),
            .init("cb", "^{3}", "mA"),
            .init("rd", "^{$0}$1", "mA"),
            .init("_", "_{$0}$1", "mA"),
            .init("sts", "_\\text{$0}$1", "mA"),
            .init("sq", "\\sqrt{ $0 }$1", "mAw"),
            .init("//", "\\frac{$0}{$1}$2", "mA"),
            .init("ee", "e^{ $0 }$1", "mAw"),
            .init("invs", "^{-1}", "mA"),
            .init("conj", "^{*}", "mA"),
            .init("Re", "\\mathrm{Re}", "mAw"),
            .init("Im", "\\mathrm{Im}", "mAw"),
            .init("bf", "\\mathbf{$0}$1", "mAw"),
            .init("rm", "\\mathrm{$0}$1", "mAw"),
            .init("trace", "\\mathrm{Tr}", "mAw"),

            // A lone letter and a digit: x1 → x_{1}; a second digit joins it.
            .init(#"(?<![\\A-Za-z])([A-Za-z])(\d)"#, "[[0]]_{[[1]]}", "rmA", priority: -1),
            .init(#"(?<![\\A-Za-z])([A-Za-z])_\{(\d+)\}(\d)"#, "[[0]]_{[[1]][[2]]}", "rmA"),
            .init(#"(?<![\\A-Za-z])([A-Za-z])_(\d\d)"#, "[[0]]_{[[1]]}", "rmA"),
            .init(#"\\(hat|vec|bar|mathbf)\{([A-Za-z])\}(\d)"#, "\\[[0]]{[[1]]}_{[[2]]}", "rmA"),

            // Accents, after a letter (xhat) or on their own (hat, then the letter).
            .init(#"(?<![\\A-Za-z])([A-Za-z])hat"#, "\\hat{[[0]]}", "rmA"),
            .init(#"(?<![\\A-Za-z])([A-Za-z])bar"#, "\\bar{[[0]]}", "rmA"),
            .init(#"(?<![\\A-Za-z])([A-Za-z])dot"#, "\\dot{[[0]]}", "rmA", priority: -1),
            .init(#"(?<![\\A-Za-z])([A-Za-z])ddot"#, "\\ddot{[[0]]}", "rmA", priority: 1),
            .init(#"(?<![\\A-Za-z])([A-Za-z])tilde"#, "\\tilde{[[0]]}", "rmA"),
            .init(#"(?<![\\A-Za-z])([A-Za-z])und"#, "\\underline{[[0]]}", "rmA"),
            .init(#"(?<![\\A-Za-z])([A-Za-z])vec"#, "\\vec{[[0]]}", "rmA"),
            .init(#"(?<![\\A-Za-z])([A-Za-z]),\."#, "\\mathbf{[[0]]}", "rmA"),
            .init(#"(?<![\\A-Za-z])([A-Za-z])\.,"#, "\\mathbf{[[0]]}", "rmA"),
            .init("hat", "\\hat{$0}$1", "mAw"),
            .init("bar", "\\bar{$0}$1", "mAw"),
            .init("dot", "\\dot{$0}$1", "mAw", priority: -1),
            .init("ddot", "\\ddot{$0}$1", "mAw"),
            .init("tilde", "\\tilde{$0}$1", "mAw"),
            .init("und", "\\underline{$0}$1", "mAw"),
            .init("vec", "\\vec{$0}$1", "mAw"),

            .init("xnn", "x_{n}", "mAw"), .init("\\xii", "x_{i}", "mA", priority: 1), .init("xjj", "x_{j}", "mAw"),
            .init("xp1", "x_{n+1}", "mAw"), .init("ynn", "y_{n}", "mAw"), .init("yii", "y_{i}", "mAw"), .init("yjj", "y_{j}", "mAw"),

            // Symbols.
            .init("ooo", "\\infty", "mA"),
            .init("sum", "\\sum", "mAw"),
            .init("prod", "\\prod", "mAw"),
            .init("\\sum", "\\sum_{${0:i}=${1:1}}^{${2:N}} $3", "m"),
            .init("\\prod", "\\prod_{${0:i}=${1:1}}^{${2:N}} $3", "m"),
            .init("lim", "\\lim_{ ${0:n} \\to ${1:\\infty} } $2", "mAw"),
            .init("+-", "\\pm", "mA"),
            .init("-+", "\\mp", "mA"),
            .init("...", "\\dots", "mA"),
            .init("xx", "\\times", "mAw"),
            .init("**", "\\cdot", "mA"),
            .init("para", "\\parallel", "mAw"),
            .init("===", "\\equiv", "mA"),
            .init("!=", "\\neq", "mA"),
            .init(">=", "\\geq", "mA"),
            .init("<=", "\\leq", "mA"),
            .init(">>", "\\gg", "mA"),
            .init("<<", "\\ll", "mA"),
            .init("simm", "\\sim", "mAw"),
            .init("sim=", "\\simeq", "mAw"),
            .init("prop", "\\propto", "mAw"),
            .init("<->", "\\leftrightarrow ", "mA"),
            .init("->", "\\to", "mA"),
            .init("!>", "\\mapsto", "mA"),
            .init("=>", "\\implies", "mA"),
            .init("=<", "\\impliedby", "mA"),
            .init("and", "\\cap", "mAw"),
            .init("orr", "\\cup", "mAw"),
            .init("inn", "\\in", "mAw"),
            .init("notin", "\\not\\in", "mAw"),
            .init("\\\\\\", "\\setminus", "mA"),
            .init("sub=", "\\subseteq", "mAw"),
            .init("sup=", "\\supseteq", "mAw"),
            .init("eset", "\\emptyset", "mAw"),
            .init("set", "\\{ $0 \\}$1", "mAw"),
            .init("LL", "\\mathcal{L}", "mAw"),
            .init("HH", "\\mathcal{H}", "mAw"),
            .init("CC", "\\mathbb{C}", "mAw"),
            .init("RR", "\\mathbb{R}", "mAw"),
            .init("ZZ", "\\mathbb{Z}", "mAw"),
            .init("NN", "\\mathbb{N}", "mAw"),
            .init("QQ", "\\mathbb{Q}", "mAw"),

            // Derivatives and integrals.
            .init("par", "\\frac{ \\partial ${0:y} }{ \\partial ${1:x} } $2", "mw"),
            .init(#"(?<![\\A-Za-z])pa([A-Za-z])([A-Za-z])"#, "\\frac{ \\partial [[0]] }{ \\partial [[1]] } ", "rm"),
            .init("ddt", "\\frac{d}{dt} ", "mAw"),
            .init("\\int", "\\int $0 \\, d${1:x} $2", "m"),
            .init("dint", "\\int_{${0:0}}^{${1:1}} $2 \\, d${3:x} $4", "mAw"),
            .init("oint", "\\oint", "mAw"),
            .init("iint", "\\iint", "mAw", priority: 1),
            .init("iiint", "\\iiint", "mAw", priority: 1),
            .init("oinf", "\\int_{0}^{\\infty} $0 \\, d${1:x} $2", "mAw"),
            .init("infi", "\\int_{-\\infty}^{\\infty} $0 \\, d${1:x} $2", "mAw"),

            // Physics.
            .init("kbt", "k_{B}T", "mAw"),
            .init("dag", "^{\\dagger}", "mAw"),
            .init("o+", "\\oplus ", "mA"),
            .init("ox", "\\otimes ", "mAw"),

            // Environments: on their own lines in display math, on one line inline.
            .init("pmat", "\\begin{pmatrix}\n$0\n\\end{pmatrix}", "MAw"),
            .init("bmat", "\\begin{bmatrix}\n$0\n\\end{bmatrix}", "MAw"),
            .init("Bmat", "\\begin{Bmatrix}\n$0\n\\end{Bmatrix}", "MAw"),
            .init("vmat", "\\begin{vmatrix}\n$0\n\\end{vmatrix}", "MAw"),
            .init("Vmat", "\\begin{Vmatrix}\n$0\n\\end{Vmatrix}", "MAw"),
            .init("matrix", "\\begin{matrix}\n$0\n\\end{matrix}", "MAw"),
            .init("pmat", "\\begin{pmatrix}$0\\end{pmatrix}", "nAw"),
            .init("bmat", "\\begin{bmatrix}$0\\end{bmatrix}", "nAw"),
            .init("Bmat", "\\begin{Bmatrix}$0\\end{Bmatrix}", "nAw"),
            .init("vmat", "\\begin{vmatrix}$0\\end{vmatrix}", "nAw"),
            .init("Vmat", "\\begin{Vmatrix}$0\\end{Vmatrix}", "nAw"),
            .init("matrix", "\\begin{matrix}$0\\end{matrix}", "nAw"),
            .init("cases", "\\begin{cases}\n$0\n\\end{cases}", "MAw"),
            .init("cases", "\\begin{cases}$0\\end{cases}", "nAw"),
            .init("align", "\\begin{aligned}\n$0\n\\end{aligned}", "MAw"),

            // Brackets.
            .init("avg", "\\langle $0 \\rangle $1", "mAw"),
            .init("norm", "\\lvert $0 \\rvert $1", "mAw", priority: 1),
            .init("Norm", "\\lVert $0 \\rVert $1", "mAw", priority: 1),
            .init("ceil", "\\lceil $0 \\rceil $1", "mAw"),
            .init("floor", "\\lfloor $0 \\rfloor $1", "mAw"),
            .init("mod", "|$0|$1", "mAw"),
            .init("(", "($0)$1", "mA"),
            .init("{", "{$0}$1", "mA"),
            .init("[", "[$0]$1", "mA"),
            .init("\\{", "\\{ $0 \\}$1", "mA"),
            .init("lr(", "\\left( $0 \\right) $1", "mA"),
            .init("lr{", "\\left\\{ $0 \\right\\} $1", "mA"),
            .init("lr[", "\\left[ $0 \\right] $1", "mA"),
            .init("lr|", "\\left| $0 \\right| $1", "mA"),
            .init("lra", "\\left< $0 \\right> $1", "mA"),
        ]
        // Greek letters, symbols and functions by name: alpha → \alpha.
        for name in greek + symbols + functions {
            s.append(.init(name, "\\" + name, "mAw"))
        }
        // An accent after a Greek letter: \alpha hat → \hat{\alpha}.
        let letters = greek.joined(separator: "|")
        for (word, command) in [("hat", "hat"), ("bar", "bar"), ("dot", "dot"), ("vec", "vec"), ("tilde", "tilde"), ("und", "underline")] {
            s.append(.init(#"\\("# + letters + #") "# + word, "\\\(command){\\[[0]]}", "rmA", priority: 1))
        }
        s.append(.init(#"\\("# + letters + #") sr"#, "\\[[0]]^{2}", "rmA", priority: 1))
        s.append(.init(#"\\("# + letters + #") cb"#, "\\[[0]]^{3}", "rmA", priority: 1))
        return s
    }()

    /// Wrapping a selection in math: the key typed and what surrounds the selection.
    static let visual: [Character: String] = [
        "U": "\\underbrace{ ${VISUAL} }_{ $0 }$1",
        "O": "\\overbrace{ ${VISUAL} }^{ $0 }$1",
        "B": "\\underset{ $0 }{ ${VISUAL} }$1",
        "C": "\\cancel{ ${VISUAL} }$0",
        "K": "\\cancelto{ $0 }{ ${VISUAL} }$1",
        "S": "\\sqrt{ ${VISUAL} }$0",
        "(": "(${VISUAL})$0",
        "[": "[${VISUAL}]$0",
        "{": "{${VISUAL}}$0",
        "/": "\\frac{${VISUAL}}{$0}$1",
    ]
}
