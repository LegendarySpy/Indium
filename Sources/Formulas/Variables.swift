import Foundation

/// Numbers a note defines in its frontmatter, usable by name in quick answers and
/// table formulas:
///
///     ---
///     hydrated: 2.008 g
///     anhydrous: 0.715 g
///     trials: 3
///     ---
///
/// Rules (see README.md):
/// - Frontmatter is YAML between a `---` first line and the next `---` (or `...`) line.
/// - Only top-level `name: value` lines count. Names match `[A-Za-z_][A-Za-z0-9_]*` and are
///   case-sensitive; other keys (`molar mass`, `molar-mass`, `ΔH`) are ignored.
/// - The value must be a number, optionally with a unit (`2.008 g`, `65.38 g/mol`) or `%`
///   (`85%` is 0.85). Quotes around it are allowed. Anything else (text, dates, lists,
///   nested maps, booleans) is ignored without error.
/// - Names of functions and constants (`sum`, `sqrt`, `pi`, `e`, …, any case) are ignored.
/// - If a name appears twice, the last one wins.
struct NoteVariables: Equatable {
    var values: [String: Quantity] = [:]

    static let empty = NoteVariables()

    private static let line = try! NSRegularExpression(pattern: #"^([A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t]*(.*?)[ \t]*$"#)

    /// Reads the frontmatter at the very top of `text`. Cheap for long notes: it stops at
    /// the closing `---` and never looks further than the first 400 lines.
    static func parse(noteText text: String) -> NoteVariables {
        guard text.hasPrefix("---") else { return .empty }
        var vars = NoteVariables()
        var first = true
        var count = 0
        var closed = false
        var pending: [(String, String)] = []
        text.enumerateLines { raw, stop in
            count += 1
            if count > 400 { stop = true; return }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if first {
                first = false
                if trimmed != "---" { stop = true }
                return
            }
            if trimmed == "---" || trimmed == "..." { closed = true; stop = true; return }
            // Indented lines belong to a list or map under an earlier key.
            guard let c = raw.first, c != " ", c != "\t" else { return }
            let ns = raw as NSString
            guard let m = line.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return }
            pending.append((ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))))
        }
        guard closed else { return .empty }
        for (name, rawValue) in pending where !Evaluator.isReserved(name) {
            var value = rawValue
            // A trailing YAML comment: `mass: 2.0 g # weighed twice`.
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            if let quantity = Quantity.parse(value), !value.hasPrefix("*"), !value.hasPrefix("_") {
                vars.values[name] = quantity
            } else {
                // A later non-numeric value replaces an earlier number, as YAML would.
                vars.values[name] = nil
            }
        }
        return vars
    }
}
