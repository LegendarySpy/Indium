import Foundation

/// Rows and columns inserted or deleted through the table editor, and the formula lines
/// rewritten to follow them.
extension TableFormulas {
    /// What the table editor did to the table's shape, in TBLFM numbering (row 1 the header).
    enum ShapeChange: Equatable {
        case insertRows(at: Int, count: Int)
        case deleteRows(at: Int, count: Int)
        case insertColumns(at: Int, count: Int)
        case deleteColumns(at: Int, count: Int)
    }

    /// Written in place of a reference to a row or column that was deleted. The formula
    /// no longer parses, so the table isn't recalculated until it's fixed or removed.
    static let deletedMark = "#REF"

    private static let reference = try! NSRegularExpression(pattern: #"(@(?:[<>I]|[-+]?\d+))?(\$(?:[<>]|[-+]?\d+))?"#)

    /// Keeps absolute references (`@4`, `$2`) pointing at the same rows and columns after
    /// the table editor inserted or deleted some, as a spreadsheet does. A formula whose
    /// destination was deleted is removed; one that reads a deleted row or column gets
    /// `#REF` there. Relative references and `<`, `>`, `I` are left alone. A line holding
    /// a formula the engine doesn't parse (unsupported, or mistyped) stays byte for byte.
    static func adjust(_ formulaLines: [String], for change: ShapeChange) -> [String] {
        var out: [String] = []
        for line in formulaLines {
            guard let body = formulaText(ofLine: line) else { out.append(line); continue }
            let pieces = body.components(separatedBy: "::").map { $0.trimmingCharacters(in: .whitespaces) }
            let parses = pieces.allSatisfy { if case .success = parseFormula($0) { return true }; return false }
            guard parses, let adjusted = try? pieces.map({ try adjust(formula: $0, for: change) }) else { out.append(line); continue }
            let kept = adjusted.compactMap { $0 }
            if kept == pieces { out.append(line); continue }
            if !kept.isEmpty { out.append(formulaLine(kept)) }
        }
        return out
    }

    private struct Overflow: Error {}

    /// One formula adjusted, or nil when its destination is gone. Throws when an index
    /// would overflow; the line then stays as it was.
    private static func adjust(formula: String, for change: ShapeChange) throws -> String? {
        guard let eq = formula.firstIndex(of: "=") else { return formula }
        let dest = String(formula[..<eq]), source = String(formula[formula.index(after: eq)...])
        guard let newDest = try adjust(references: dest, for: change, destination: true) else { return nil }
        return try newDest + "=" + (adjust(references: source, for: change, destination: false) ?? source)
    }

    private enum Role { case single, start, end }

    private static func adjust(references text: String, for change: ShapeChange, destination: Bool) throws -> String? {
        let ns = text as NSString
        let matches = reference.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { $0.range.length > 0 }
        let rows: Bool, at: Int, count: Int, inserting: Bool
        switch change {
        case let .insertRows(a, c): (rows, at, count, inserting) = (true, a, c, true)
        case let .deleteRows(a, c): (rows, at, count, inserting) = (true, a, c, false)
        case let .insertColumns(a, c): (rows, at, count, inserting) = (false, a, c, true)
        case let .deleteColumns(a, c): (rows, at, count, inserting) = (false, a, c, false)
        }
        // Checked: an index that would overflow leaves the formula alone.
        func plus(_ a: Int, _ b: Int) throws -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            if overflow { throw Overflow() }
            return sum
        }
        // The new index, or nil when a single reference's row or column was deleted.
        func shifted(_ n: Int, _ role: Role) throws -> Int? {
            if inserting { return n >= at ? try plus(n, count) : n }
            if n >= (try plus(at, count)) { return n - count }
            guard n >= at else { return n }
            switch role {
            case .single: return nil
            case .start: return at          // the next one moves up into its place
            case .end: return at - 1
            }
        }
        // The index in `@4` or `$2`; nil for relative ones and `<`, `>`, `I`.
        func absolute(_ r: NSRange) throws -> Int? {
            guard r.location != NSNotFound else { return nil }
            let digits = ns.substring(with: NSRange(location: r.location + 1, length: r.length - 1))
            guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
            guard let n = Int(digits) else { throw Overflow() }
            return n
        }
        var edits: [(range: NSRange, text: String)] = []
        var start: (edit: Int, value: Int?)?
        for m in matches {
            let before = ns.substring(to: m.range.location), after = ns.substring(from: NSMaxRange(m.range))
            let role: Role = after.hasPrefix("..") ? .start : before.hasSuffix("..") ? .end : .single
            let part = m.range(at: rows ? 1 : 2)
            var unit = ns.substring(with: m.range)
            var value = try absolute(part)
            if let n = value {
                guard let s = try shifted(n, role) else {
                    if destination { return nil }
                    edits.append((m.range, deletedMark))
                    continue
                }
                let local = NSRange(location: part.location - m.range.location, length: part.length)
                unit = (unit as NSString).replacingCharacters(in: local, with: (rows ? "@" : "$") + "\(s)")
                value = s
            }
            edits.append((m.range, unit))
            switch role {
            case .start: start = (edits.count - 1, value)
            case .end:
                // A range whose rows (or columns) were all deleted is gone too.
                if let s = start, let a = s.value, let b = value ?? s.value, a > b {
                    if destination { return nil }
                    let whole = NSUnionRange(edits[s.edit].range, m.range)
                    edits.removeLast(edits.count - s.edit)
                    edits.append((whole, deletedMark))
                }
                start = nil
            case .single: break
            }
        }
        var result = text
        for e in edits.reversed() { result = (result as NSString).replacingCharacters(in: e.range, with: e.text) }
        return result
    }
}
