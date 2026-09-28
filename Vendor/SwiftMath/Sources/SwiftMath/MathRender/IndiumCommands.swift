//
//  IndiumCommands.swift
//  SwiftMath (Indium additions)
//
//  LaTeX that notes use every day but the typesetter didn't know: stacked labels
//  (\overset, \underbrace, \xrightarrow), boxes and cancels, phantoms, \mathop and
//  friends, lengths (\hspace, \kern), and a batch of AMS symbols.
//

import Foundation
import CoreGraphics
import CoreText

/// What an operator with a typeset base draws around it.
public enum MTDecoration {
    case none
    /// A horizontal brace stretched over (or under) the base.
    case braceAbove, braceBelow
    /// An arrow as wide as its labels: heads at either end, `fill` repeated between.
    case arrow(left: String?, right: String?, fill: String)
    /// A thin frame around the base (`\boxed`).
    case box
    /// Strokes through the base (`\cancel`, `\bcancel`, `\xcancel`).
    case cancel(forward: Bool, back: Bool)
    /// Takes the base's room without drawing it (`\phantom`, `\hphantom`, `\vphantom`).
    case phantom(width: Bool, height: Bool)
}

/// Straight strokes and frames, drawn in the text color.
final class MTStrokeDisplay: MTDisplay {
    var segments: [(CGPoint, CGPoint)] = []
    var frame: CGRect?
    var lineWidth: CGFloat = 0.5

    override public func draw(_ context: CGContext) {
        super.draw(context)
        context.saveGState()
        context.translateBy(x: position.x, y: position.y)
        if let color = textColor { context.setStrokeColor(color.cgColor) }
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        if let frame { context.stroke(frame) }
        for (a, b) in segments {
            context.move(to: a)
            context.addLine(to: b)
        }
        context.strokePath()
        context.restoreGState()
    }
}

/// Occupies space and draws nothing.
final class MTPhantomDisplay: MTDisplay {
    override public func draw(_ context: CGContext) {}
}

// MARK: - Typesetting

extension MTTypesetter {
    /// The base of an operator built from a list, with its decoration applied.
    func makeDecoratedBase(_ op: MTLargeOperator, base: MTMathList) -> MTDisplay? {
        let em = styleFont.fontSize
        let rule = styleFont.mathTable?.fractionRuleThickness ?? em * 0.04
        let range = op.indexRange

        if case let .arrow(left, right, fill) = op.decoration {
            // As wide as the wider label plus a little, and never shorter than \longrightarrow.
            let scriptStyle = self.scriptStyle()
            let scriptFont = font.copy(withSize: MTTypesetter.getStyleSize(scriptStyle, font: font))
            var labels: CGFloat = 0
            for list in [op.superScript, op.subScript] {
                // Measured on a copy: typesetting merges a list's text in place, so the
                // labels themselves are typeset once, later, by the limits.
                if let list, let d = MTTypesetter.createLineForMathList(list.finalized, font: scriptFont, style: scriptStyle, cramped: true) {
                    labels = max(labels, d.width)
                }
            }
            return makeExtensibleArrow(width: max(labels + em * 0.6, em * 1.6), left: left, right: right, fill: fill, range: range)
        }

        guard let inner = MTTypesetter.createLineForMathList(base, font: font, style: style, cramped: cramped) else { return nil }
        inner.position = .zero
        // Space at the end draws nothing, so the display's width leaves it out; count it.
        let trailing = base.atoms.reversed().prefix { $0 is MTMathSpace }.reduce(CGFloat(0)) { $0 + ($1 as! MTMathSpace).space }
        if trailing > 0, let mu = styleFont.mathTable?.muUnit { inner.width += trailing * mu }
        var parts: [MTDisplay] = [inner]

        switch op.decoration {
        case .braceAbove, .braceBelow:
            let above: Bool
            if case .braceAbove = op.decoration { above = true } else { above = false }
            guard let brace = stretchedGlyph(above ? "\u{23DE}" : "\u{23DF}", width: inner.width, range: range) else { return inner }
            let gap = em * 0.1
            // The brace's ink sits `gap` clear of the base.
            brace.position = CGPoint(x: 0, y: above ? inner.ascent + gap + brace.descent : -(inner.descent + gap + brace.ascent))
            parts.append(brace)
        case .box:
            let pad = em * 0.25
            inner.position = CGPoint(x: pad, y: 0)
            let frame = MTStrokeDisplay()
            frame.lineWidth = rule
            frame.frame = CGRect(x: rule / 2, y: -(inner.descent + pad), width: inner.width + 2 * pad - rule,
                                 height: inner.ascent + inner.descent + 2 * pad)
            frame.width = inner.width + 2 * pad
            frame.ascent = inner.ascent + pad + rule / 2
            frame.descent = inner.descent + pad + rule / 2
            parts.append(frame)
        case let .cancel(forward, back):
            let over = em * 0.1
            let stroke = MTStrokeDisplay()
            stroke.lineWidth = rule
            let x0 = -over, x1 = inner.width + over, y0 = -inner.descent - over, y1 = inner.ascent + over
            if forward { stroke.segments.append((CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1))) }
            if back { stroke.segments.append((CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y0))) }
            stroke.width = inner.width
            stroke.ascent = inner.ascent
            stroke.descent = inner.descent
            parts.append(stroke)
        case let .phantom(keepWidth, keepHeight):
            let ghost = MTPhantomDisplay()
            ghost.range = range
            ghost.width = keepWidth ? inner.width : 0
            ghost.ascent = keepHeight ? inner.ascent : 0
            ghost.descent = keepHeight ? inner.descent : 0
            return ghost
        default:
            return inner
        }
        return MTMathListDisplay(withDisplays: parts, range: range)
    }

    /// A glyph at least `width` wide: the widest variant that fits, stretched the rest of the way.
    private func stretchedGlyph(_ character: String, width: CGFloat, range: NSRange) -> MTGlyphDisplay? {
        var glyph = findGlyphForCharacterAtIndex(character.startIndex, inString: character)
        guard glyph != 0 else { return nil }
        var ascent = CGFloat(0), descent = CGFloat(0), glyphWidth = CGFloat(0), minY = CGFloat(0)
        glyph = findVariantGlyph(glyph, withMaxWidth: width, maxWidth: &ascent, glyphDescent: &descent, glyphWidth: &glyphWidth, glyphMinY: &minY)
        guard glyphWidth > 0 else { return nil }
        let display = MTGlyphDisplay(withGlpyh: glyph, range: range, font: styleFont)
        display.ascent = ascent
        display.descent = descent
        if glyphWidth < width {
            display.scaleX = width / glyphWidth
            display.width = width
        } else {
            display.width = glyphWidth
        }
        return display
    }

    /// Built the way TeX builds \longrightarrow: a run of `fill` glyphs (a minus or an
    /// equals sign, whose bars match the arrow's shaft) with heads at the ends.
    private func makeExtensibleArrow(width: CGFloat, left: String?, right: String?, fill: String, range: NSRange) -> MTDisplay? {
        func glyph(_ character: String) -> (display: MTGlyphDisplay, ink: CGRect, advance: CGFloat)? {
            var g = findGlyphForCharacterAtIndex(character.startIndex, inString: character)
            guard g != 0 else { return nil }
            var box = CGRect.zero, advance = CGSize.zero
            CTFontGetBoundingRectsForGlyphs(styleFont.ctFont, .horizontal, &g, &box, 1)
            CTFontGetAdvancesForGlyphs(styleFont.ctFont, .horizontal, &g, &advance, 1)
            let d = MTGlyphDisplay(withGlpyh: g, range: range, font: styleFont)
            d.ascent = max(0, box.maxY)
            d.descent = max(0, -box.minY)
            d.width = advance.width
            return (d, box, advance.width)
        }
        guard let bar = glyph(fill) else { return nil }
        var parts: [MTDisplay] = []
        var start: CGFloat = 0, end = width
        if let left, let head = glyph(left) {
            head.display.position = CGPoint(x: -head.ink.minX, y: 0)
            parts.append(head.display)
            start = head.ink.width * 0.6
        }
        if let right, let head = glyph(right) {
            head.display.position = CGPoint(x: width - head.ink.maxX, y: 0)
            parts.append(head.display)
            end = width - head.ink.width * 0.6
        }
        // Bars overlap a little so the shaft reads as one line.
        let step = max(bar.ink.width * 0.8, 1)
        var x = start
        while x < end {
            let piece = glyph(fill)!.display
            piece.position = CGPoint(x: min(x, end - bar.ink.width) - bar.ink.minX, y: 0)
            parts.insert(piece, at: 0)
            x += step
        }
        let display = MTMathListDisplay(withDisplays: parts, range: range)
        display.width = width
        return display
    }
}

// MARK: - Parsing

extension MTMathListBuilder {
    /// Heads and fill of the extensible arrows.
    static let extensibleArrows: [String: MTDecoration] = [
        "xrightarrow": .arrow(left: nil, right: "\u{2192}", fill: "\u{2212}"),
        "xleftarrow": .arrow(left: "\u{2190}", right: nil, fill: "\u{2212}"),
        "xleftrightarrow": .arrow(left: "\u{2190}", right: "\u{2192}", fill: "\u{2212}"),
        "xRightarrow": .arrow(left: nil, right: "\u{21D2}", fill: "="),
        "xLeftarrow": .arrow(left: "\u{21D0}", right: nil, fill: "="),
        "xLeftrightarrow": .arrow(left: "\u{21D0}", right: "\u{21D2}", fill: "="),
        "xmapsto": .arrow(left: "\u{22A2}", right: "\u{2192}", fill: "\u{2212}"),
        "xlongequal": .arrow(left: nil, right: nil, fill: "="),
    ]

    /// Atom types the \mathXXX class commands give their argument.
    static let classCommands: [String: MTMathAtomType] = [
        "mathord": .ordinary, "mathbin": .binaryOperator, "mathrel": .relation, "mathopen": .open,
        "mathclose": .close, "mathpunct": .punctuation, "mathinner": .inner,
    ]

    /// How a stacked base spaces: like its only atom (`=` stays a relation), else as a letter.
    static func spacingType(of list: MTMathList?) -> MTMathAtomType {
        guard let list, list.atoms.count == 1, let atom = list.atoms.first else { return .ordinary }
        if let op = atom as? MTLargeOperator { return op.spacingType }
        switch atom.type {
        case .relation, .binaryOperator, .largeOperator, .punctuation: return atom.type
        default: return .ordinary
        }
    }

    /// Commands handled here; `handled` is false for anything else.
    mutating func indiumAtom(forCommand command: String) -> (handled: Bool, atom: MTMathAtom?) {
        switch command {
        case "overset", "stackrel", "underset":
            let label = buildInternal(true)
            let base = buildInternal(true)
            let op = MTLargeOperator(base: base, spacingType: Self.spacingType(of: base))
            if command == "underset" { op.subScript = label } else { op.superScript = label }
            return (true, op)
        case "overbrace", "underbrace":
            let op = MTLargeOperator(base: buildInternal(true), spacingType: .ordinary)
            op.decoration = command == "overbrace" ? .braceAbove : .braceBelow
            return (true, op)
        case "boxed":
            let op = MTLargeOperator(base: buildInternal(true), spacingType: .ordinary)
            op.decoration = .box
            return (true, op)
        case "cancel", "bcancel", "xcancel", "sout":
            let op = MTLargeOperator(base: buildInternal(true), spacingType: .ordinary)
            op.decoration = .cancel(forward: command != "bcancel", back: command == "bcancel" || command == "xcancel")
            return (true, op)
        case "cancelto":
            // The value sits up and to the right of the struck-through term.
            let value = buildInternal(true)
            let op = MTLargeOperator(base: buildInternal(true), spacingType: .ordinary)
            op.decoration = .cancel(forward: true, back: false)
            op.limits = false
            op.alwaysLimits = false
            op.superScript = value
            return (true, op)
        case "phantom", "hphantom", "vphantom":
            let op = MTLargeOperator(base: buildInternal(true), spacingType: .ordinary)
            op.decoration = .phantom(width: command != "vphantom", height: command != "hphantom")
            op.limits = false
            op.alwaysLimits = false
            return (true, op)
        case "mathop":
            let op = MTLargeOperator(base: buildInternal(true), spacingType: .largeOperator)
            op.alwaysLimits = false  // limits in display style, like \sum
            return (true, op)
        case "bmod":
            // TeX's \bmod: "mod" with 5mu either side, whatever is around it.
            let list = MTMathList()
            list.add(MTMathSpace(space: 5))
            list.add(MTLargeOperator(value: "mod", limits: false))
            list.add(MTMathSpace(space: 5))
            let op = MTLargeOperator(base: list, spacingType: .ordinary)
            op.limits = false
            op.alwaysLimits = false
            return (true, op)
        case "dbinom", "tbinom":
            let frac = MTFraction(hasRule: false)
            let style = MTMathStyle(style: command == "dbinom" ? .display : .text)
            let top = buildInternal(true), bottom = buildInternal(true)
            top?.insert(style, at: 0)
            bottom?.insert(MTMathStyle(style: style.style), at: 0)
            frac.numerator = top
            frac.denominator = bottom
            frac.leftDelimiter = "("
            frac.rightDelimiter = ")"
            return (true, frac)
        case "hspace", "hspace*", "kern", "mkern", "hskip", "mskip":
            guard let mu = readLength() else {
                setError(.invalidCommand, message: "Missing length for \\\(command)")
                return (true, nil)
            }
            return (true, MTMathSpace(space: mu))
        default:
            break
        }
        if let arrow = Self.extensibleArrows[command] {
            // \xrightarrow[below]{above}
            skipSpaces()
            var below: MTMathList?
            if hasCharacters, string[currentCharIndex] == "[" {
                _ = getNextCharacter()
                below = buildInternal(false, stopChar: "]")
            }
            let above = buildInternal(true)
            let op = MTLargeOperator(base: MTMathList(), spacingType: .relation)
            op.decoration = arrow
            if let above, !above.atoms.isEmpty { op.superScript = above }
            if let below, !below.atoms.isEmpty { op.subScript = below }
            return (true, op)
        }
        if let type = Self.classCommands[command] {
            let list = buildInternal(true)
            // A lone atom just changes kind; anything longer spaces as one unit.
            if let list, list.atoms.count == 1, let atom = list.atoms.first, atom.subScript == nil, atom.superScript == nil,
               !(atom is MTLargeOperator), atom.type != .fraction, atom.type != .radical, atom.type != .inner {
                atom.type = type
                return (true, atom)
            }
            let op = MTLargeOperator(base: list, spacingType: type)
            op.limits = false
            op.alwaysLimits = false
            return (true, op)
        }
        return (false, nil)
    }

    /// `\not` before a symbol with no negated form of its own: overlay a slash.
    mutating func negatedAtom() -> MTMathAtom? {
        skipSpaces()
        guard hasCharacters else { return nil }
        let next = string[currentCharIndex]
        let chars: [Character: String] = ["=": "\u{2260}", "<": "\u{226E}", ">": "\u{226F}", "|": "\u{2224}", "~": "\u{2241}"]
        if let negated = chars[next] {
            _ = getNextCharacter()
            return MTMathAtom(type: .relation, value: negated)
        }
        let command = peekNextCommand()
        if !command.isEmpty, let atom = MTMathAtomFactory.atom(forLatexSymbol: command), !atom.nucleus.isEmpty {
            consumeNextCommand()
            return MTMathAtom(type: atom.type == .ordinary ? .ordinary : .relation, value: atom.nucleus + "\u{0338}")
        }
        return nil
    }

    /// A length as `{2em}`, `3pt` or `-7mu`, in mu (1/18 em). Points assume a 10pt em.
    mutating func readLength() -> CGFloat? {
        skipSpaces()
        var braced = false
        if hasCharacters, string[currentCharIndex] == "{" { _ = getNextCharacter(); braced = true; skipSpaces() }
        var number = ""
        while hasCharacters, "+-.0123456789".contains(string[currentCharIndex]) { number.append(getNextCharacter()) }
        skipSpaces()
        var unit = ""
        while hasCharacters, string[currentCharIndex].isLetter, unit.count < 2 { unit.append(getNextCharacter()) }
        if braced {
            while hasCharacters, getNextCharacter() != "}" {}
        }
        guard let value = Double(number.isEmpty || number == "-" || number == "+" ? number + "1" : number) else { return nil }
        let perUnit: [String: Double] = ["mu": 1, "em": 18, "ex": 7.74, "pt": 1.8, "px": 1.8, "bp": 1.8, "mm": 5.12, "cm": 51.2, "in": 130, "pc": 21.6]
        return CGFloat(value * (perUnit[unit] ?? 18))
    }

    /// The argument of `^` or `_`. Written plainly, a run of digits (with a leading minus
    /// or a decimal point) is taken whole, the way the answer suggestions read it:
    /// `x^10` is x to the tenth, `x^-1` its inverse, `x_12` subscript twelve, and
    /// `e^-x` is e to the minus x.
    mutating func scriptArgument() -> MTMathList? {
        let start = currentCharIndex
        var run = ""
        var i = start
        if i < string.endIndex, string[i] == "-" { run.append("-"); i = string.index(after: i) }
        while i < string.endIndex, string[i].isASCII, string[i].isNumber || (string[i] == "." && !run.isEmpty) {
            run.append(string[i])
            i = string.index(after: i)
        }
        if run.hasSuffix(".") { run.removeLast(); i = string.index(before: i) }
        if run == "-", i < string.endIndex, string[i].isLetter, string[i].isASCII {
            run.append(string[i])
            i = string.index(after: i)
        }
        let digits = run.filter(\.isNumber).count
        // One digit alone is what LaTeX reads anyway; a lone minus is a script minus.
        guard digits > 1 || (run.hasPrefix("-") && run.count == 2) else { return buildInternal(true) }
        currentCharIndex = i
        let list = MTMathList()
        for ch in run {
            if let atom = MTMathAtomFactory.atom(forCharacter: ch) {
                atom.fontStyle = currentFontStyle
                list.add(atom)
            }
        }
        return list
    }
}

// MARK: - Symbols

extension MTMathAtomFactory {
    /// Registers the extra symbols once; names the typesetter already knows are left alone.
    static let indiumSymbols: Void = {
        func op(_ type: MTMathAtomType, _ value: String) -> MTMathAtom { MTMathAtom(type: type, value: value) }
        let symbols: [String: MTMathAtom] = [
            // Punctuation-named spaces and escapes.
            ":": MTMathSpace(space: 4), "&": op(.ordinary, "&"),
            "enspace": MTMathSpace(space: 9), "thinspace": MTMathSpace(space: 3), "medspace": MTMathSpace(space: 4),
            "thickspace": MTMathSpace(space: 5), "negthinspace": MTMathSpace(space: -3),
            "negmedspace": MTMathSpace(space: -4), "negthickspace": MTMathSpace(space: -5),
            // Dots.
            "dots": op(.ordinary, "\u{2026}"), "dotso": op(.ordinary, "\u{2026}"), "dotsc": op(.ordinary, "\u{2026}"),
            "dotsb": op(.ordinary, "\u{22EF}"), "dotsm": op(.ordinary, "\u{22EF}"), "dotsi": op(.ordinary, "\u{22EF}"),
            // Logic and relations.
            "impliedby": op(.relation, "\u{27F8}"), "therefore": op(.relation, "\u{2234}"), "because": op(.relation, "\u{2235}"),
            "coloneqq": op(.relation, "\u{2254}"), "coloneq": op(.relation, "\u{2254}"), "eqqcolon": op(.relation, "\u{2255}"),
            "Coloneqq": op(.relation, "\u{2A74}"), "leqslant": op(.relation, "\u{2A7D}"), "geqslant": op(.relation, "\u{2A7E}"),
            "lesssim": op(.relation, "\u{2272}"), "gtrsim": op(.relation, "\u{2273}"), "lessgtr": op(.relation, "\u{2276}"),
            "gtrless": op(.relation, "\u{2277}"), "nleq": op(.relation, "\u{2270}"), "ngeq": op(.relation, "\u{2271}"),
            "nless": op(.relation, "\u{226E}"), "ngtr": op(.relation, "\u{226F}"), "nsubseteq": op(.relation, "\u{2288}"),
            "nsupseteq": op(.relation, "\u{2289}"), "subsetneq": op(.relation, "\u{228A}"), "supsetneq": op(.relation, "\u{228B}"),
            "triangleq": op(.relation, "\u{225C}"), "doteq": op(.relation, "\u{2250}"), "asymp": op(.relation, "\u{224D}"),
            "bowtie": op(.relation, "\u{22C8}"), "vDash": op(.relation, "\u{22A8}"), "Vdash": op(.relation, "\u{22A9}"),
            "nparallel": op(.relation, "\u{2226}"), "ncong": op(.relation, "\u{2247}"), "nsim": op(.relation, "\u{2241}"),
            "nmid": op(.relation, "\u{2224}"), "nvdash": op(.relation, "\u{22AC}"), "nvDash": op(.relation, "\u{22AD}"),
            "approxeq": op(.relation, "\u{224A}"), "backsim": op(.relation, "\u{223D}"), "eqsim": op(.relation, "\u{2242}"),
            "prec": op(.relation, "\u{227A}"), "succ": op(.relation, "\u{227B}"),
            // Arrows.
            "rightleftharpoons": op(.relation, "\u{21CC}"), "leftrightharpoons": op(.relation, "\u{21CB}"),
            "leftharpoonup": op(.relation, "\u{21BC}"), "rightharpoonup": op(.relation, "\u{21C0}"),
            "leftharpoondown": op(.relation, "\u{21BD}"), "rightharpoondown": op(.relation, "\u{21C1}"),
            "nearrow": op(.relation, "\u{2197}"), "searrow": op(.relation, "\u{2198}"), "swarrow": op(.relation, "\u{2199}"),
            "nwarrow": op(.relation, "\u{2196}"), "twoheadrightarrow": op(.relation, "\u{21A0}"),
            "twoheadleftarrow": op(.relation, "\u{219E}"), "rightsquigarrow": op(.relation, "\u{21DD}"),
            "leadsto": op(.relation, "\u{21DD}"), "longmapsto": op(.relation, "\u{27FC}"),
            "longleftrightarrow": op(.relation, "\u{27F7}"), "Longleftrightarrow": op(.relation, "\u{27FA}"),
            "Longleftarrow": op(.relation, "\u{27F8}"), "longleftarrow": op(.relation, "\u{27F5}"),
            "hookleftarrow": op(.relation, "\u{21A9}"), "leftleftarrows": op(.relation, "\u{21C7}"),
            "rightrightarrows": op(.relation, "\u{21C9}"), "circlearrowleft": op(.relation, "\u{21BA}"),
            "circlearrowright": op(.relation, "\u{21BB}"), "curvearrowleft": op(.relation, "\u{21B6}"),
            "curvearrowright": op(.relation, "\u{21B7}"), "Uparrow": op(.relation, "\u{21D1}"),
            "Downarrow": op(.relation, "\u{21D3}"), "updownarrow": op(.relation, "\u{2195}"),
            "Updownarrow": op(.relation, "\u{21D5}"),
            // Binary operators.
            "uplus": op(.binaryOperator, "\u{228E}"), "amalg": op(.binaryOperator, "\u{2A3F}"),
            "wr": op(.binaryOperator, "\u{2240}"), "diamond": op(.binaryOperator, "\u{22C4}"), "bigcirc": op(.binaryOperator, "\u{25EF}"),
            "ltimes": op(.binaryOperator, "\u{22C9}"), "rtimes": op(.binaryOperator, "\u{22CA}"), "boxplus": op(.binaryOperator, "\u{229E}"),
            "boxminus": op(.binaryOperator, "\u{229F}"), "boxtimes": op(.binaryOperator, "\u{22A0}"), "boxdot": op(.binaryOperator, "\u{22A1}"),
            "intercal": op(.binaryOperator, "\u{22BA}"), "barwedge": op(.binaryOperator, "\u{22BC}"), "veebar": op(.binaryOperator, "\u{22BB}"),
            "curlyvee": op(.binaryOperator, "\u{22CE}"), "curlywedge": op(.binaryOperator, "\u{22CF}"),
            "circledast": op(.binaryOperator, "\u{229B}"), "circledcirc": op(.binaryOperator, "\u{229A}"),
            "circleddash": op(.binaryOperator, "\u{229D}"), "smallsetminus": op(.binaryOperator, "\u{2216}"),
            "divideontimes": op(.binaryOperator, "\u{22C7}"), "dotplus": op(.binaryOperator, "\u{2214}"),
            "centerdot": op(.binaryOperator, "\u{22C5}"), "sqcup": op(.binaryOperator, "\u{2294}"), "sqcap": op(.binaryOperator, "\u{2293}"),
            "triangleleft": op(.binaryOperator, "\u{25C1}"), "triangleright": op(.binaryOperator, "\u{25B7}"),
            // Letters and shapes.
            "square": op(.ordinary, "\u{25A1}"), "Box": op(.ordinary, "\u{25A1}"), "blacksquare": op(.ordinary, "\u{25A0}"),
            "checkmark": op(.ordinary, "\u{2713}"), "lozenge": op(.ordinary, "\u{25CA}"), "blacklozenge": op(.ordinary, "\u{29EB}"),
            "complement": op(.ordinary, "\u{2201}"), "mho": op(.ordinary, "\u{2127}"), "eth": op(.ordinary, "\u{00F0}"),
            "beth": op(.ordinary, "\u{2136}"), "gimel": op(.ordinary, "\u{2137}"), "daleth": op(.ordinary, "\u{2138}"),
            "digamma": op(.ordinary, "\u{03DD}"), "varkappa": op(.ordinary, "\u{03F0}"), "backprime": op(.ordinary, "\u{2035}"),
            "vartriangle": op(.ordinary, "\u{25B3}"), "triangledown": op(.ordinary, "\u{25BD}"),
            "blacktriangle": op(.ordinary, "\u{25B2}"), "blacktriangledown": op(.ordinary, "\u{25BC}"),
            "measuredangle": op(.ordinary, "\u{2221}"), "sphericalangle": op(.ordinary, "\u{2222}"),
            "diagup": op(.ordinary, "\u{2571}"), "diagdown": op(.ordinary, "\u{2572}"), "Finv": op(.ordinary, "\u{2132}"),
            "Game": op(.ordinary, "\u{2141}"), "hslash": op(.ordinary, "\u{210F}"), "imath": op(.ordinary, "\u{0131}"),
            "jmath": op(.ordinary, "\u{0237}"), "flat": op(.ordinary, "\u{266D}"), "natural": op(.ordinary, "\u{266E}"),
            "sharp": op(.ordinary, "\u{266F}"), "clubsuit": op(.ordinary, "\u{2663}"), "diamondsuit": op(.ordinary, "\u{2662}"),
            "heartsuit": op(.ordinary, "\u{2661}"), "spadesuit": op(.ordinary, "\u{2660}"),
            // Large operators.
            "bigsqcup": MTLargeOperator(value: "\u{2A06}", limits: true), "biguplus": MTLargeOperator(value: "\u{2A04}", limits: true),
            "bigodot": MTLargeOperator(value: "\u{2A00}", limits: true), "bigoplus": MTLargeOperator(value: "\u{2A01}", limits: true),
            "bigotimes": MTLargeOperator(value: "\u{2A02}", limits: true), "coprod": MTLargeOperator(value: "\u{2210}", limits: true),
            "iiiint": MTLargeOperator(value: "\u{2A0C}", limits: false), "oiint": MTLargeOperator(value: "\u{222F}", limits: false),
            "oiiint": MTLargeOperator(value: "\u{2230}", limits: false),
            "lcm": MTLargeOperator(value: "lcm", limits: false), "sgn": MTLargeOperator(value: "sgn", limits: false),
            "tr": MTLargeOperator(value: "tr", limits: false), "Tr": MTLargeOperator(value: "Tr", limits: false),
            "rank": MTLargeOperator(value: "rank", limits: false), "diag": MTLargeOperator(value: "diag", limits: false),
            "span": MTLargeOperator(value: "span", limits: false), "Var": MTLargeOperator(value: "Var", limits: false),
            "Cov": MTLargeOperator(value: "Cov", limits: false), "Res": MTLargeOperator(value: "Res", limits: false),
            "arccot": MTLargeOperator(value: "arccot", limits: false), "sech": MTLargeOperator(value: "sech", limits: false),
            "csch": MTLargeOperator(value: "csch", limits: false), "coth": MTLargeOperator(value: "coth", limits: false),
            "argmax": MTLargeOperator(value: "arg\u{2009}max", limits: true), "argmin": MTLargeOperator(value: "arg\u{2009}min", limits: true),
            "injlim": MTLargeOperator(value: "inj\u{2009}lim", limits: true), "projlim": MTLargeOperator(value: "proj\u{2009}lim", limits: true),
        ]
        for (name, atom) in symbols where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            add(latexSymbol: name, value: atom)
        }
    }()
}

// MARK: - Colors

extension MTColor {
    /// `#rrggbb`, bare hex, or a color name as in xcolor and MathJax. Names map to the
    /// system palette so they stay legible in dark mode; black means the text color.
    static func indium(named name: String) -> MTColor? {
        let key = name.lowercased()
        if let hex = MTColor(fromHexString: key.hasPrefix("#") ? key : "#" + key),
           key.trimmingCharacters(in: CharacterSet(charactersIn: "#")).count == 6,
           key.trimmingCharacters(in: CharacterSet(charactersIn: "#0123456789abcdef")).isEmpty {
            return hex
        }
        #if os(macOS)
        let named: [String: MTColor] = [
            "red": .systemRed, "green": .systemGreen, "blue": .systemBlue, "orange": .systemOrange,
            "purple": .systemPurple, "violet": .systemPurple, "magenta": .systemPink, "pink": .systemPink,
            "cyan": .systemTeal, "teal": .systemTeal, "yellow": .systemYellow, "brown": .systemBrown,
            "gray": .systemGray, "grey": .systemGray, "darkgray": .secondaryLabelColor, "lightgray": .tertiaryLabelColor,
            "olive": MTColor(red: 0.5, green: 0.5, blue: 0, alpha: 1), "lime": .systemGreen,
            "white": .white, "black": .labelColor,
        ]
        #else
        let named: [String: MTColor] = [
            "red": .systemRed, "green": .systemGreen, "blue": .systemBlue, "orange": .systemOrange,
            "purple": .systemPurple, "violet": .systemPurple, "magenta": .systemPink, "pink": .systemPink,
            "cyan": .systemTeal, "teal": .systemTeal, "yellow": .systemYellow, "brown": .systemBrown,
            "gray": .systemGray, "grey": .systemGray, "white": .white, "black": .label,
        ]
        #endif
        return named[key]
    }
}
