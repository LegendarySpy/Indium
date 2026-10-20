import Foundation

/// Changing a note's frontmatter variables (see `NoteVariables`) one line at a time, for
/// the inspector. Every edit touches only the line it's about: the order of the other
/// properties, their quotes and comments, lists and maps, and the line endings all stay
/// byte for byte. Each function takes the whole note and returns it changed, or nil when
/// the change can't be made safely (a frontmatter that never closes, an invalid name).
enum VariableEditing {
    /// A top-level `name: value` line of the frontmatter.
    struct Entry: Equatable {
        enum Status: Equatable {
            /// A variable formulas and quick answers can use.
            case variable(Quantity)
            /// Read as a property, but not a variable: why, in a few words.
            case skipped(String)
            /// Named again further down, where that line wins.
            case overridden
        }
        let name: String
        /// The value as written, without quotes or a trailing comment.
        let value: String
        let status: Status
        /// Line index in the note (0 is the opening `---`).
        let line: Int

        var quantity: Quantity? {
            if case let .variable(q) = status { return q }
            return nil
        }
    }

    private static let keyLine = try! NSRegularExpression(pattern: #"^([^\s:#\-][^:]*?)[ \t]*:[ \t]*(.*?)[ \t]*$"#)
    private static let namePattern = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#)

    /// True for a name the frontmatter can hold as a variable: `[A-Za-z_][A-Za-z0-9_]*`,
    /// and not a function or constant (`sum`, `pi`).
    static func isValidName(_ name: String) -> Bool {
        namePattern.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
            && !Evaluator.isReserved(name)
    }

    // MARK: Reading

    /// The lines of `text` and where its frontmatter's body is: the lines between the
    /// opening `---` and the closing `---` or `...`. Nil when there's no frontmatter, or it
    /// never closes (in the first 400 lines, as `NoteVariables` reads it).
    private static func layout(_ text: String) -> (lines: [String], newline: String, body: Range<Int>)? {
        guard text.hasPrefix("---") else { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: newline)
        guard lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for i in 1..<min(lines.count, 400) {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { return (lines, newline, 1..<i) }
        }
        return nil
    }

    /// The value part of a key line: as written, then without its quotes and comment.
    private static func split(_ line: String) -> (name: String, raw: String, valueRange: NSRange?)? {
        guard let c = line.first, c != " ", c != "\t" else { return nil }
        let ns = line as NSString
        guard let m = keyLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(at: 1))
        let valueRange = m.range(at: 2).length == 0 ? nil : m.range(at: 2)
        return (name, valueRange.map { ns.substring(with: $0) } ?? "", valueRange)
    }

    /// The value without a trailing ` # comment` and surrounding quotes, as `NoteVariables` reads it.
    private static func unwrap(_ raw: String) -> (value: String, quote: Character?, comment: String) {
        var value = raw, comment = ""
        if let hash = value.range(of: " #") {
            comment = String(value[hash.lowerBound...])
            value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
            return (String(value.dropFirst().dropLast()), q, comment)
        }
        return (value, nil, comment)
    }

    /// Every top-level property in the frontmatter, in order, with what Indium makes of it.
    static func entries(noteText text: String) -> [Entry] {
        guard let (lines, _, body) = layout(text) else { return [] }
        var found: [Entry] = []
        for i in body {
            guard let (name, raw, _) = split(lines[i]) else { continue }
            let (value, _, _) = unwrap(raw)
            let status: Entry.Status
            if namePattern.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) == nil {
                status = .skipped("Names use letters, digits and _")
            } else if Evaluator.isReserved(name) {
                status = .skipped("“\(name)” is a function or constant")
            } else if value.isEmpty {
                status = .skipped(i + 1 < body.upperBound && lines[i + 1].first.map { $0 == " " || $0 == "\t" || $0 == "-" } == true
                                  ? "A list or group, not a number" : "No value")
            } else if let q = Quantity.parse(value), !value.hasPrefix("*"), !value.hasPrefix("_") {
                status = .variable(q)
            } else {
                status = .skipped("Not a number")
            }
            found.append(Entry(name: name, value: value, status: status, line: i))
        }
        // The last of a name wins, as in `NoteVariables` and YAML.
        var seen = Set<String>()
        for i in found.indices.reversed() where !seen.insert(found[i].name).inserted {
            found[i] = Entry(name: found[i].name, value: found[i].value, status: .overridden, line: found[i].line)
        }
        return found
    }

    // MARK: Writing

    /// Sets `name` to `value` (`2.008 g`, `85%`). The line that counts (the last with that
    /// name) keeps its quotes and comment; a new name goes at the end of the frontmatter,
    /// and a note without frontmatter gets one.
    static func setting(_ name: String, to value: String, in text: String) -> String? {
        guard isValidName(name) else { return nil }
        let value = value.trimmingCharacters(in: .whitespaces)
        guard let (lines, newline, body) = layout(text) else {
            // A `---` first line that never closes is something else; leave it alone.
            if text.hasPrefix("---") { return nil }
            let n = newline(of: text)
            return "---" + n + "\(name): \(value)" + n + "---" + n + text
        }
        var out = lines
        if let i = body.reversed().first(where: { split(lines[$0])?.name == name }), let (_, raw, range) = split(lines[i]) {
            let (_, quote, comment) = unwrap(raw)
            let written = quote.map { "\($0)\(value)\($0)" } ?? value
            // `tags:` heading a list or map: not a value to overwrite.
            if raw.isEmpty, i + 1 < body.upperBound, let c = lines[i + 1].first, c == " " || c == "\t" || c == "-" { return nil }
            if let range {
                out[i] = (lines[i] as NSString).replacingCharacters(in: range, with: written + comment)
            } else {
                out[i] = lines[i].trimmingCharacters(in: .whitespaces) + " " + written
            }
        } else {
            out.insert("\(name): \(value)", at: body.upperBound)
        }
        return out.joined(separator: newline)
    }

    /// Renames every top-level `old:` line, and the variable wherever a table formula
    /// (`<!-- TBLFM: … -->`) reads it. Nil when `new` isn't a valid name or is taken.
    static func renaming(_ old: String, to new: String, in text: String) -> String? {
        guard isValidName(new), old != new, let (lines, newline, body) = layout(text) else { return nil }
        guard !body.contains(where: { split(lines[$0])?.name == new }) else { return nil }
        var out = lines
        for i in body {
            guard let (name, _, _) = split(lines[i]), name == old, let colon = lines[i].firstIndex(of: ":") else { continue }
            out[i] = new + lines[i][colon...]
        }
        for i in body.upperBound..<out.count where TableFormulas.isFormulaLine(out[i]) {
            out[i] = renamingReference(old, to: new, in: out[i])
        }
        return out.joined(separator: newline)
    }

    /// Takes away every top-level `name:` line that holds a single value.
    static func removing(_ name: String, in text: String) -> String? {
        guard let (lines, newline, body) = layout(text) else { return nil }
        let drop = Set(body.filter { i in
            guard let (n, raw, _) = split(lines[i]), n == name, !raw.isEmpty else { return false }
            return true
        })
        guard !drop.isEmpty else { return nil }
        return lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element).joined(separator: newline)
    }

    /// How many table formula lines read `name`.
    static func uses(of name: String, in text: String) -> Int {
        var count = 0
        text.enumerateLines { line, _ in
            if TableFormulas.isFormulaLine(line), renamingReference(name, to: "\u{0}", in: line) != line { count += 1 }
        }
        return count
    }

    private static func newline(of text: String) -> String { text.contains("\r\n") ? "\r\n" : "\n" }

    /// `old` as a whole name (not part of `@2`, `$3`, another name or a decimal) becomes `new`.
    private static func renamingReference(_ old: String, to new: String, in line: String) -> String {
        let pattern = #"(?<![A-Za-z0-9_@$.])"# + NSRegularExpression.escapedPattern(for: old) + #"(?![A-Za-z0-9_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let ns = line as NSString
        // Only inside the comment's formula text, never the `TBLFM:` word around it.
        guard let start = line.range(of: "TBLFM:").map({ NSRange($0, in: line).upperBound }) else { return line }
        let range = NSRange(location: start, length: ns.length - start)
        return regex.stringByReplacingMatches(in: line, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: new))
    }
}
