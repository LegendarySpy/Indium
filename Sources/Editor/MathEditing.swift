import AppKit

/// Writing math the way Obsidian's LaTeX Suite does: shortcuts that expand as you type
/// (see `MathSnippet`), `/` that builds a fraction from what's before it, Tab to move
/// through the blanks a shortcut left (or out of a bracket or the equation), `&` and
/// `\\` on Tab and Return inside a matrix, and a live preview under inline math.
extension EditorController {
    /// The LaTeX of the equation around a position, between its `$` or `$$` delimiters.
    struct MathSpan {
        let content: NSRange
        /// `$$…$$`, typeset in display style.
        let display: Bool
        /// A display equation on lines of its own.
        let block: Bool
        var delimiter: Int { display ? 2 : 1 }
    }

    private var source: NSString { storage.string as NSString }

    /// The equation `location` sits in (between its delimiters, inclusive), if any.
    func mathSpan(at location: Int) -> MathSpan? {
        let text = source
        guard location <= text.length else { return nil }
        if let i = styler.blockIndex(containing: location) {
            switch styler.blocks[i].kind {
            case .code, .frontmatter, .table:
                return nil
            case .math:
                let range = styler.blocks[i].range
                let source = text.substring(with: range) as NSString
                let open = source.range(of: "$$")
                let close = source.range(of: "$$", options: .backwards)
                guard open.location != NSNotFound, close.location >= NSMaxRange(open) else { return nil }
                let content = NSRange(location: range.location + NSMaxRange(open), length: close.location - NSMaxRange(open))
                guard location >= content.location, location <= NSMaxRange(content) else { return nil }
                return MathSpan(content: content, display: true, block: true)
            default:
                break
            }
        }
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: location, length: 0))
        // `$‸$`, just opened with nothing in it yet (rather than a `$$`).
        if location > s, location < ce, text.character(at: location - 1) == 0x24, text.character(at: location) == 0x24,
           location < 2 || text.character(at: location - 2) != 0x24, location + 1 >= ce || text.character(at: location + 1) != 0x24,
           opensMath(dollarAt: location - 1, lineStart: s),
           text.substring(with: NSRange(location: s, length: location - s)).filter({ $0 == "`" }).count % 2 == 0 {
            return MathSpan(content: NSRange(location: location, length: 0), display: false, block: false)
        }
        var i = s
        var open: (at: Int, length: Int)?
        var ticks = 0
        func run(of c: unichar, at j: Int) -> Int {
            var k = j
            while k < ce, text.character(at: k) == c { k += 1 }
            return k - j
        }
        while i < ce {
            let c = text.character(at: i)
            if ticks > 0 {
                // Inside a code span: only its closing backticks matter.
                if c == 0x60 {
                    let n = run(of: 0x60, at: i)
                    if n == ticks { ticks = 0 }
                    i += n
                } else {
                    i += 1
                }
                continue
            }
            // `\$` is an escaped dollar, except for a backslash just typed (a command on its way).
            if c == 0x5C, i + 1 != location { i += 2; continue }
            if open == nil, c == 0x60 {
                ticks = run(of: 0x60, at: i)
                i += ticks
                continue
            }
            guard c == 0x24 else { i += 1; continue }
            let double = i + 1 < ce && text.character(at: i + 1) == 0x24
            if let o = open {
                // `$$` closes `$$`; inside `$…$` the next `$` closes.
                if o.length == 2 && !double { i += 1; continue }
                // A `$` before a digit is a price (`$5 and $10`). A space before the closing `$`
                // is allowed here, mid-typing (`$a + ‸$`); leaving the equation tidies it away.
                if o.length == 1, i + 1 < ce, (0x30...0x39).contains(text.character(at: i + 1)) { i += 1; continue }
                let content = NSRange(location: o.at + o.length, length: i - o.at - o.length)
                if location <= i { return location >= content.location ? MathSpan(content: content, display: o.length == 2, block: false) : nil }
                open = nil
                i += o.length
                continue
            }
            if double {
                open = (i, 2)
                i += 2
            } else if i + 1 < ce, let u = UnicodeScalar(text.character(at: i + 1)), !CharacterSet.whitespaces.contains(u) {
                open = (i, 1)
                i += 1
            } else {
                i += 1
            }
        }
        // An unclosed `$` is a price, not an equation.
        return nil
    }

    /// Whether `location` sits in `\text{…}` (or another argument that holds words, not
    /// math), or in a superscript or subscript.
    private func argument(in span: MathSpan, at location: Int) -> (words: Bool, script: Bool) {
        let text = source
        let wordy: Set<String> = ["text", "textbf", "textit", "textrm", "texttt", "textsf", "textnormal", "mathrm", "operatorname",
                                  "mbox", "hbox", "begin", "end", "label", "tag", "color", "textcolor"]
        enum Group { case words, script, plain }
        var stack: [Group] = []
        var command: String?
        var previous: unichar = 0
        var i = span.content.location
        while i < location {
            let c = text.character(at: i)
            if c == 0x5C {
                var j = i + 1
                while j < location, let u = UnicodeScalar(text.character(at: j)), CharacterSet.letters.contains(u) { j += 1 }
                if j == i + 1 { i += 2; previous = 0; command = nil; continue }
                command = text.substring(with: NSRange(location: i + 1, length: j - i - 1))
                i = j
                previous = 0
                continue
            }
            if c == 0x7B {
                if let command, wordy.contains(command) { stack.append(.words) }
                else if previous == 0x5E || previous == 0x5F { stack.append(.script) }
                else { stack.append(.plain) }
                command = nil
            } else if c == 0x7D {
                if !stack.isEmpty { stack.removeLast() }
                command = nil
            } else if c != 0x20 {
                command = nil
            }
            if c != 0x20 { previous = c }
            i += 1
        }
        return (stack.contains(.words), stack.contains(.script))
    }

    // MARK: Typing

    /// A key typed into the note. Returns true if a shortcut handled it.
    func handleMathInput(_ typed: String) -> Bool {
        guard AppSettings.shared.mathShortcuts, textView.isEditable, tableEditor == nil, typed.count == 1,
              let ch = typed.first, !ch.isNewline else { return false }
        let sel = textView.selectedRange()
        let paired = pairedDollarAt
        pairedDollarAt = nil
        if sel.length > 0 { return wrapSelection(in: sel, with: ch) }
        let caret = sel.location
        // Right after `$‸$` was closed for you: a second `$` makes `$$`, and a space
        // means it wasn't an equation after all.
        if paired == caret, caret < source.length, source.character(at: caret) == 0x24 {
            if ch == "$" {
                textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
                return true
            }
            if ch.isWhitespace {
                replace(NSRange(location: caret, length: 1), with: typed, select: NSRange(location: caret + 1, length: 0), actionName: "Typing")
                return true
            }
        }
        guard let span = mathSpan(at: caret) else { return typeInProse(ch, at: caret) }
        let text = source
        let next: unichar? = caret < text.length ? text.character(at: caret) : nil
        let end = NSMaxRange(span.content)

        // A closing bracket or `$` that's already there is typed over.
        if let next, caret < end, ")]}".contains(ch), next == ch.utf16.first {
            let past = enlargeBrackets(closingAt: caret, in: span) ?? caret + 1
            textView.setSelectedRange(NSRange(location: past, length: 0))
            return true
        }
        if ch == "$", !span.block, caret == end {
            leaveInline(span)
            return true
        }
        let arg = argument(in: span, at: caret)
        if arg.words { return false }
        let before = text.substring(with: NSRange(location: span.content.location, length: caret - span.content.location))
        if ch == "/" {
            guard !arg.script, !before.hasSuffix("\\") else { return false }
            return autoFraction(in: span, at: caret)
        }
        // Brackets pair up only where nothing follows them.
        if "([{".contains(ch), let next, let u = UnicodeScalar(next),
           CharacterSet.alphanumerics.contains(u) || next == 0x5C { return false }
        if let expansion = MathSnippet.expansion(before: before + typed, context: .math(display: span.display), auto: true) {
            expand(expansion, typed: typed, at: caret)
            return true
        }
        // `\alpha` then a letter: a new word, not `\alphax`.
        if ch.isLetter, let m = before.range(of: #"\\([A-Za-z]+)$"#, options: .regularExpression),
           MathSnippet.wantsSpace(after: String(before[m].dropFirst()), before: ch) {
            textView.insertTypedText(" " + typed)
            return true
        }
        return false
    }

    /// Outside math: `mk` and `dm` open an equation, and a `$` followed by anything but
    /// a digit or a space gets its closing `$` (so `$5` stays a price).
    private func typeInProse(_ ch: Character, at caret: Int) -> Bool {
        let text = source
        if let i = styler.blockIndex(containing: caret) {
            switch styler.blocks[i].kind {
            case .code, .frontmatter, .table, .math: return false
            default: break
            }
        }
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: caret, length: 0))
        let before = text.substring(with: NSRange(location: s, length: caret - s))
        let after = text.substring(with: NSRange(location: caret, length: ce - caret))
        guard before.filter({ $0 == "`" }).count % 2 == 0 else { return false }

        // `$` on an otherwise empty line is an equation starting: close it right away.
        if ch == "$", before.trimmingCharacters(in: .whitespaces).isEmpty, after.trimmingCharacters(in: .whitespaces).isEmpty {
            textView.insertTypedText("$$")
            textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
            pairedDollarAt = caret + 1
            return true
        }

        // (Not in front of a word: `$|word` is someone adding a `$` there, not opening math.)
        if caret > s, text.character(at: caret - 1) == 0x24, !ch.isNumber, !ch.isWhitespace, ch != "$",
           !after.contains("$"), !(after.first.map { $0.isLetter || $0.isNumber } ?? false),
           opensMath(dollarAt: caret - 1, lineStart: s) {
            replace(NSRange(location: caret, length: 0), with: "$", select: NSRange(location: caret, length: 0))
            if handleMathInput(String(ch)) { return true }
            textView.insertTypedText(String(ch))
            return true
        }
        guard var expansion = MathSnippet.expansion(before: before + String(ch), context: .text, auto: true) else { return false }
        if expansion.text.hasPrefix("$$\n") {
            // A display equation gets lines of its own.
            let lead = before.dropLast(expansion.length - 1).trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
            let trail = after.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
            let shift = (lead as NSString).length
            expansion = MathSnippet.Expansion(length: expansion.length, text: lead + expansion.text + trail,
                                              stops: expansion.stops.map { NSRange(location: $0.location + shift, length: $0.length) })
        }
        expand(expansion, typed: String(ch), at: caret)
        return true
    }

    /// The `$` at `index` starts an equation (rather than closing one or being a price).
    private func opensMath(dollarAt index: Int, lineStart: Int) -> Bool {
        let text = source
        if index > lineStart {
            let c = text.character(at: index - 1)
            if c == 0x24 || c == 0x5C { return false }
        }
        var count = 0
        var i = lineStart
        while i < index {
            let c = text.character(at: i)
            if c == 0x5C { i += 2; continue }
            if c == 0x24 { count += 1 }
            i += 1
        }
        return count % 2 == 0
    }

    /// Typing over a selection: in math, `(`, `U`, `/` and friends wrap it; in prose,
    /// `$` makes it an equation.
    private func wrapSelection(in sel: NSRange, with ch: Character) -> Bool {
        let text = source
        let selected = text.substring(with: sel)
        guard !selected.contains("\n") else { return false }
        if let span = mathSpan(at: sel.location), NSMaxRange(sel) <= NSMaxRange(span.content) {
            guard let template = MathSnippet.visual[ch], !argument(in: span, at: sel.location).words else { return false }
            let (expanded, stops) = MathSnippet.render(template, captures: [], visual: selected)
            textView.breakUndoCoalescing()
            applyExpansion(expanded, stops: stops, replacing: sel)
            return true
        }
        guard ch == "$", mathSpan(at: NSMaxRange(sel)) == nil else { return false }
        replace(sel, with: "$" + selected + "$", select: NSRange(location: sel.location + 1, length: sel.length), actionName: "Inline Math")
        return true
    }

    /// `x/` → `\frac{x}{}`: the term before the slash becomes the numerator.
    private func autoFraction(in span: MathSpan, at caret: Int) -> Bool {
        let text = source
        let start = span.content.location
        let breaks = Set(" \t\n$([{+-=<>,;:&".utf16)
        let pairs: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
        var i = caret - 1
        var numStart = start
        while i >= start {
            let c = text.character(at: i)
            if let opener = pairs[c] {
                // Jump back over a bracketed group, whatever is in it.
                var depth = 0
                var j = i
                while j >= start {
                    let d = text.character(at: j)
                    if d == c { depth += 1 } else if d == opener { depth -= 1; if depth == 0 { break } }
                    j -= 1
                }
                guard j >= start else { numStart = i + 1; break }
                i = j - 1
                continue
            }
            if breaks.contains(c) { numStart = i + 1; break }
            // `\\` ends a row and `\,` is a space; `\alpha` is part of the term.
            if c == 0x5C, i + 1 < caret, let u = UnicodeScalar(text.character(at: i + 1)), !CharacterSet.letters.contains(u) {
                numStart = i + 2
                break
            }
            i -= 1
        }
        var numerator = text.substring(with: NSRange(location: numStart, length: caret - numStart))
        if numerator.hasPrefix("("), numerator.hasSuffix(")"), Self.balanced(String(numerator.dropFirst().dropLast())) {
            numerator = String(numerator.dropFirst().dropLast())
        }
        let head = "\\frac{" + numerator + "}{"
        let expanded = head + "}"
        let length = (expanded as NSString).length
        let stops = numerator.isEmpty
            ? [NSRange(location: 6, length: 0), NSRange(location: 8, length: 0), NSRange(location: length, length: 0)]
            : [NSRange(location: (head as NSString).length, length: 0), NSRange(location: length, length: 0)]
        textView.insertTypedText("/")
        separateUndo()
        applyExpansion(expanded, stops: stops, replacing: NSRange(location: numStart, length: caret + 1 - numStart))
        return true
    }

    private static func balanced(_ s: String) -> Bool {
        var depth = 0
        for c in s {
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0
    }

    /// Types the key as usual (so Undo brings back what was typed), then expands it.
    private func expand(_ expansion: MathSnippet.Expansion, typed: String, at caret: Int) {
        textView.insertTypedText(typed)
        separateUndo()
        let end = caret + (typed as NSString).length
        applyExpansion(expansion.text, stops: expansion.stops, replacing: NSRange(location: end - expansion.length, length: expansion.length))
    }

    /// What comes next is its own Undo step, even within the same key press.
    private func separateUndo() {
        textView.breakUndoCoalescing()
        if let undo = textView.undoManager, undo.groupingLevel > 0 {
            undo.endUndoGrouping()
            undo.beginUndoGrouping()
        }
    }

    /// Past an inline equation's closing `$`, dropping spaces before it: Markdown (and
    /// Obsidian) don't count `$x $` as math.
    private func leaveInline(_ span: MathSpan) {
        let text = source
        var end = NSMaxRange(span.content)
        var trimmed = end
        while trimmed > span.content.location, [0x20, 0x09].contains(text.character(at: trimmed - 1)) { trimmed -= 1 }
        if trimmed < end {
            applyingMathEdit = true
            replace(NSRange(location: trimmed, length: end - trimmed), with: "", actionName: "Typing")
            applyingMathEdit = false
            end = trimmed
        }
        textView.setSelectedRange(NSRange(location: min(end + span.delimiter, source.length), length: 0))
    }

    private func applyExpansion(_ expanded: String, stops: [NSRange], replacing range: NSRange) {
        var expanded = expanded
        var stops = stops
        // Right before an inline equation's closing `$`, a trailing space would stop it
        // counting as math; the next word gets its space when it's typed.
        if let span = mathSpan(at: range.location), !span.block, NSMaxRange(range) == NSMaxRange(span.content) {
            while expanded.hasSuffix(" ") { expanded.removeLast() }
            let limit = (expanded as NSString).length
            stops = stops.map { NSRange(location: min($0.location, limit), length: min($0.length, max(0, limit - $0.location))) }
            var seen = Set<Int>()
            stops = stops.filter { seen.insert($0.location * 1000 + $0.length).inserted || $0.length > 0 }
        }
        let length = (expanded as NSString).length
        let placed = stops.map { NSRange(location: $0.location + range.location, length: $0.length) }
        let caret = placed.first ?? NSRange(location: range.location + length, length: 0)
        applyingMathEdit = true
        replace(range, with: expanded, select: caret, actionName: "Math Shortcut")
        applyingMathEdit = false
        guard !placed.isEmpty else { return }
        // A shortcut expanded inside another's blank goes first; the outer blanks follow.
        let bounds = NSRange(location: range.location, length: length)
        mathStops = Array(placed.dropFirst()) + mathStops
        mathStopBounds = mathStopBounds.map { NSUnionRange($0, bounds) } ?? bounds
        if mathStops.isEmpty { mathStopBounds = nil }
    }

    // MARK: Tab and Return

    /// Tab: the next blank a shortcut left, a Tab-triggered shortcut (`\sum`, `par`),
    /// a column in a matrix, or out past the next closing bracket or the equation's end.
    func handleMathTab() -> Bool {
        guard AppSettings.shared.mathShortcuts, tableEditor == nil else { return false }
        if let next = mathStops.first {
            mathStops.removeFirst()
            if mathStops.isEmpty { mathStopBounds = nil }
            applyingMathEdit = true
            textView.setSelectedRange(next)
            applyingMathEdit = false
            return true
        }
        let sel = textView.selectedRange()
        guard sel.length == 0, let span = mathSpan(at: sel.location) else { return false }
        let caret = sel.location
        let text = source
        let before = text.substring(with: NSRange(location: span.content.location, length: caret - span.content.location))
        if !argument(in: span, at: caret).words,
           let expansion = MathSnippet.expansion(before: before, context: .math(display: span.display), auto: false) {
            textView.breakUndoCoalescing()
            applyExpansion(expansion.text, stops: expansion.stops,
                           replacing: NSRange(location: caret - expansion.length, length: expansion.length))
            return true
        }
        if matrixEnvironment(in: span, at: caret) != nil {
            textView.insertText(" & ", replacementRange: sel)
            return true
        }
        tabOut(of: span, from: caret)
        return true
    }

    private func tabOut(of span: MathSpan, from caret: Int) {
        let text = source
        let end = NSMaxRange(span.content)
        let rest = text.substring(with: NSRange(location: caret, length: end - caret))
        let closer = try! NSRegularExpression(pattern: #"\\right\s*(?:\\[A-Za-z]+|\\\}|[^\s\\])|\\(?:rangle|rvert|rVert|rceil|rfloor|\})|[)\]}]"#)
        if let m = closer.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            let close = caret + NSMaxRange(m.range) - 1
            let past = m.range.length == 1 ? enlargeBrackets(closingAt: close, in: span) : nil
            textView.setSelectedRange(NSRange(location: past ?? close + 1, length: 0))
            return
        }
        // Out of the equation: past its closing `$`, or onto the line after a display block.
        guard span.block else {
            leaveInline(span)
            return
        }
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: end, length: 0))
        if e > ce {
            textView.setSelectedRange(NSRange(location: e, length: 0))
        } else {
            replace(NSRange(location: ce, length: 0), with: "\n", select: NSRange(location: ce + 1, length: 0), actionName: "Typing")
        }
    }

    /// Leaving `( … )` or `[ … ]` around something tall (a fraction, a sum, an integral)
    /// turns them into `\left( … \right)` so they grow to fit, as LaTeX Suite does.
    /// Returns the position just past the new closing bracket.
    private func enlargeBrackets(closingAt close: Int, in span: MathSpan) -> Int? {
        let text = source
        let c = text.character(at: close)
        guard let opener: unichar = [0x29: 0x28, 0x5D: 0x5B][c], close > span.content.location else { return nil }
        var depth = 0
        var open = close
        while open >= span.content.location {
            let d = text.character(at: open)
            if d == c { depth += 1 } else if d == opener { depth -= 1; if depth == 0 { break } }
            open -= 1
        }
        guard open >= span.content.location else { return nil }
        let inside = text.substring(with: NSRange(location: open + 1, length: close - open - 1))
        let before = text.substring(with: NSRange(location: span.content.location, length: open - span.content.location))
        let after = close > 0 ? text.substring(with: NSRange(location: max(span.content.location, close - 6), length: close - max(span.content.location, close - 6))) : ""
        guard inside.range(of: #"\\(?:[dt]?frac|sum|prod|int|iint|oint|lim|bigcup|bigcap)(?![A-Za-z])"#, options: .regularExpression) != nil,
              before.range(of: #"\\(?:left|big|Big|bigg|Bigg)[lr]?\s*$"#, options: .regularExpression) == nil,
              !after.hasSuffix("\\right"), before.last != "\\" else { return nil }
        let o = String(utf16CodeUnits: [opener], count: 1), cl = String(utf16CodeUnits: [c], count: 1)
        let replacement = "\\left" + o + inside + "\\right" + cl
        applyingMathEdit = true
        replace(NSRange(location: open, length: close - open + 1), with: replacement, actionName: "Typing")
        applyingMathEdit = false
        return open + (replacement as NSString).length
    }

    /// The matrix-like environment (`pmatrix`, `cases`, `aligned`…) the caret is in.
    private func matrixEnvironment(in span: MathSpan, at caret: Int) -> String? {
        let source = self.source.substring(with: NSRange(location: span.content.location, length: caret - span.content.location))
        let regex = try! NSRegularExpression(pattern: #"\\(begin|end)\{([A-Za-z*]+)\}"#)
        var open: [String] = []
        for m in regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) {
            let env = (source as NSString).substring(with: m.range(at: 2))
            if (source as NSString).substring(with: m.range(at: 1)) == "begin" { open.append(env) }
            else if let i = open.lastIndex(of: env) { open.removeSubrange(i...) }
        }
        let tabular: Set<String> = ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "cases",
                                    "align", "align*", "aligned", "alignat", "alignat*", "split", "array", "eqnarray", "eqnarray*"]
        return open.last.flatMap { tabular.contains($0) ? $0 : nil }
    }

    /// Return: a new row inside a matrix, and a `$$` typed on its own line gets its
    /// closing `$$`. Shift-Return always just breaks the line.
    func handleMathNewline() -> Bool {
        guard AppSettings.shared.mathShortcuts, tableEditor == nil else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let caret = sel.location
        if let span = mathSpan(at: caret), matrixEnvironment(in: span, at: caret) != nil {
            // A row already ended with `\\` just needs the line break.
            let row = source.substring(with: NSRange(location: span.content.location, length: caret - span.content.location))
            let ended = row.trimmingCharacters(in: .whitespaces).hasSuffix("\\\\")
            textView.insertText(span.block ? (ended ? "\n" : " \\\\\n") : (ended ? " " : " \\\\ "), replacementRange: sel)
            return true
        }
        let text = source
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: caret, length: 0))
        guard caret == ce, text.substring(with: NSRange(location: s, length: ce - s)).trimmingCharacters(in: .whitespaces) == "$$" else { return false }
        let fences = fenceCounts(line: s)
        guard fences.above % 2 == 0, fences.total % 2 == 1 else { return false }
        replace(NSRange(location: caret, length: 0), with: "\n\n$$", select: NSRange(location: caret + 1, length: 0), actionName: "Equation")
        return true
    }

    /// `$$` lines above `line` and in the whole note, outside code blocks.
    private func fenceCounts(line: Int) -> (above: Int, total: Int) {
        var above = 0, total = 0
        var inCode = false
        let text = source
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let t = text.substring(with: range).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inCode.toggle() }
            guard !inCode, t == "$$" else { return }
            total += 1
            if range.location < line { above += 1 }
        }
        return (above, total)
    }

    /// Backspace between an empty pair, `(|)` or `$|$`, removes both.
    func handleMathBackspace() -> Bool {
        guard AppSettings.shared.mathShortcuts, tableEditor == nil else { return false }
        let sel = textView.selectedRange()
        let text = source
        guard sel.length == 0, sel.location > 0, sel.location < text.length else { return false }
        let a = text.character(at: sel.location - 1), b = text.character(at: sel.location)
        let pairs: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D, 0x24: 0x24]
        guard pairs[a] == b else { return false }
        if a == 0x24 {
            // Only an empty inline equation, not the middle of `$$`.
            guard sel.location >= 1, sel.location + 1 >= text.length || text.character(at: sel.location + 1) != 0x24,
                  sel.location < 2 || text.character(at: sel.location - 2) != 0x24 else { return false }
            var s = 0, e = 0, ce = 0
            text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: sel.location, length: 0))
            guard opensMath(dollarAt: sel.location - 1, lineStart: s) else { return false }
        } else {
            guard let span = mathSpan(at: sel.location), sel.location > span.content.location,
                  sel.location - 1 < 1 || text.character(at: sel.location - 2) != 0x5C else { return false }
        }
        replace(NSRange(location: sel.location - 1, length: 2), with: "", select: NSRange(location: sel.location - 1, length: 0), actionName: "Typing")
        return true
    }

    // MARK: Blanks left by shortcuts

    /// Keeps the blanks on their text as the note changes around them.
    func shiftMathStops(editedRange: NSRange, delta: Int) {
        guard !mathStops.isEmpty else { return }
        let oldEnd = NSMaxRange(editedRange) - delta
        func shift(_ r: NSRange, grows: Bool) -> NSRange {
            if grows, editedRange.location >= r.location, oldEnd <= NSMaxRange(r) {
                return NSRange(location: r.location, length: max(0, r.length + delta))
            }
            if r.location >= oldEnd { return NSRange(location: r.location + delta, length: r.length) }
            if NSMaxRange(r) <= editedRange.location { return r }
            if editedRange.location >= r.location, oldEnd <= NSMaxRange(r) {
                return NSRange(location: r.location, length: max(0, r.length + delta))
            }
            return NSRange(location: NSMaxRange(editedRange), length: 0)
        }
        mathStops = mathStops.map { shift($0, grows: false) }
        mathStopBounds = mathStopBounds.map { shift($0, grows: true) }
    }

    /// The caret left the shortcut: its blanks are forgotten.
    func mathSelectionChanged() {
        guard !applyingMathEdit, !mathStops.isEmpty, let bounds = mathStopBounds else { return }
        let sel = textView.selectedRange()
        if sel.location < bounds.location || NSMaxRange(sel) > NSMaxRange(bounds) { clearMathStops() }
    }

    func clearMathStops() {
        mathStops = []
        mathStopBounds = nil
    }

    // MARK: Marks

    /// Where the pending blanks are (a thin bar, or a tint over placeholder text), and
    /// the pair of brackets around the caret.
    func drawMathMarks() {
        for rect in mathBracketMarks {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: 2), xRadius: 3, yRadius: 3)
            Palette.hoverFill.setFill()
            path.fill()
            Palette.quoteBar.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        guard !mathStops.isEmpty else { return }
        for stop in mathStops {
            guard let rect = markRect(stop) else { continue }
            if stop.length == 0 {
                let bar = NSRect(x: rect.minX - 1, y: rect.minY + rect.height * 0.18, width: 2, height: rect.height * 0.64)
                Palette.accentRing.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            } else {
                Palette.linkUnderline.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    /// A range's rectangle in view coordinates; an empty range is a caret-thin rectangle.
    private func markRect(_ r: NSRange) -> NSRect? {
        let text = source
        guard let container = textView.textContainer, text.length > 0, NSMaxRange(r) <= text.length else { return nil }
        let origin = textView.textContainerOrigin
        if r.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
        }
        let atEnd = r.location >= text.length || [0x0A, 0x0D].contains(text.character(at: r.location))
        guard !(atEnd && r.location == 0) else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: atEnd ? r.location - 1 : r.location)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSRect(x: (atEnd ? box.maxX : box.minX) + origin.x, y: box.minY + origin.y, width: 0, height: box.height)
    }

    /// The bracket beside the caret and its partner, when the caret is in math.
    private func updateBracketMarks(span: MathSpan?, caret: Int) {
        var marks: [NSRect] = []
        let text = source
        if let span {
            let pairs: [unichar: (partner: unichar, forward: Bool)] = [0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),
                                                                       0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false)]
            let lo = span.content.location, hi = NSMaxRange(span.content)
            let candidates = [caret - 1, caret].filter { $0 >= lo && $0 < hi }
            for i in candidates {
                guard let (partner, forward) = pairs[text.character(at: i)] else { continue }
                let c = text.character(at: i)
                var depth = 0
                var j = i
                while j >= lo && j < hi {
                    let d = text.character(at: j)
                    if d == c { depth += 1 } else if d == partner { depth -= 1; if depth == 0 { break } }
                    j += forward ? 1 : -1
                }
                guard j >= lo, j < hi else { continue }
                marks = [i, j].compactMap { markRect(NSRange(location: $0, length: 1)) }
                break
            }
        }
        guard marks != mathBracketMarks else { return }
        for r in mathBracketMarks + marks { textView.setNeedsDisplay(r.insetBy(dx: -3, dy: -3)) }
        mathBracketMarks = marks
    }

    // MARK: Preview

    /// Inline math being edited shows its source; the typeset result floats just below.
    func updateMathPreview() {
        let sel = textView.selectedRange()
        let text = source
        var span: MathSpan?
        if sel.length == 0, tableEditor == nil, textView.window != nil {
            let caret = sel.location
            span = mathSpan(at: caret)
            // Right beside a delimiter counts too: the source is showing.
            if span == nil, caret > 0, text.character(at: caret - 1) == 0x24 {
                span = mathSpan(at: caret - 1) ?? (caret > 1 ? mathSpan(at: caret - 2) : nil)
            }
            if span == nil, caret < text.length, text.character(at: caret) == 0x24 {
                span = mathSpan(at: caret + 1) ?? mathSpan(at: min(caret + 2, text.length))
            }
        } else if tableEditor == nil, textView.window != nil, let inside = mathSpan(at: sel.location),
                  NSMaxRange(sel) <= NSMaxRange(inside.content) {
            // A blank selected inside the equation (a shortcut's placeholder).
            span = inside
        }
        updateBracketMarks(span: sel.length == 0 ? mathSpan(at: sel.location) : nil, caret: sel.location)
        let latex = span.map { text.substring(with: $0.content) } ?? ""
        guard let span, !span.block, !latex.trimmingCharacters(in: .whitespaces).isEmpty else {
            mathPreview?.hide()
            return
        }
        let size = round(styler.config.typography.size * (span.display ? 1.12 : 1.06))
        let preview = mathPreview ?? {
            let v = MathPreviewView(frame: .zero)
            textView.addSubview(v)
            mathPreview = v
            return v
        }()
        if let render = MathRenderer.renderWhileTyping(latex, size: size, display: span.display) {
            preview.render = render
        } else if preview.isHidden {
            return
        }
        guard let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let start = span.content.location - span.delimiter
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: start, length: span.content.length + span.delimiter * 2))
        let startGlyph = layoutManager.glyphIndexForCharacter(at: start)
        let caretGlyph = layoutManager.glyphIndexForCharacter(at: max(0, min(sel.location, text.length - 1)))
        let startRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: startGlyph, length: 1), in: container)
        let line = layoutManager.lineFragmentRect(forGlyphAt: caretGlyph, effectiveRange: nil)
        let cardSize = preview.fittingSize(maxWidth: container.size.width)
        var x = origin.x + startRect.minX - MathPreviewView.inset.width
        x = max(origin.x, min(x, origin.x + container.size.width - cardSize.width))
        var y = origin.y + line.maxY + 4
        if y + cardSize.height > textView.visibleRect.maxY - 8 { y = origin.y + line.minY - cardSize.height - 4 }
        preview.frame = NSRect(x: round(x), y: round(y), width: cardSize.width, height: cardSize.height)
        preview.show()
    }
}

/// The typeset form of the equation being edited, on a small card below its line.
final class MathPreviewView: NSView {
    static let inset = NSSize(width: 10, height: 7)
    var render: MathRender? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.shadowColor = Palette.shadow.cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var scale: CGFloat = 1

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        guard let render else { return .zero }
        scale = min(1, (maxWidth - Self.inset.width * 2) / max(render.width, 1))
        return NSSize(width: ceil(render.width * scale + Self.inset.width * 2), height: ceil(render.height * scale + Self.inset.height * 2))
    }

    func show() {
        guard isHidden else { return }
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    func hide() {
        isHidden = true
        render = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let render else { return }
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Palette.surface.setFill()
        card.fill()
        Palette.separator.setStroke()
        card.lineWidth = 1
        card.stroke()
        render.draw(baselineAt: NSPoint(x: Self.inset.width, y: Self.inset.height + render.ascent * scale), color: Palette.text, scale: scale)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.shadowColor = Palette.shadow.cgColor
        needsDisplay = true
    }
}
