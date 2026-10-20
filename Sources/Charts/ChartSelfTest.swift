#if DEBUG
import Foundation

/// Regression cases for charts, driven from the DEBUG harness (`-IndiumChartCases
/// Tests/Charts/cases.tsv`). Foundation only, like the models it checks. One case per
/// line, tab-separated, `↵` for a line break in a block:
///
/// - `model<TAB>block body<TAB>frontmatter<TAB>expected`: what the block draws, as `summary`
///   writes it.
/// - `points<TAB>typed<TAB><TAB>expected`: the points read from text, then `! problem` if any.
/// - `setpoints<TAB>block body<TAB>typed points<TAB>expected body`: the block with its
///   `points:` set to those read from `typed`, as the inspector writes them.
/// - `name<TAB>equation<TAB><TAB>expected`: a curve as the legend names it.
enum ChartSelfTest {
    static func run(paths: [String]) -> Int {
        var failed = 0, total = 0
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); failed += 1; continue }
            print("== \(path)")
            for raw in text.components(separatedBy: "\n") where !raw.isEmpty && !raw.hasPrefix("#") {
                let p = raw.components(separatedBy: "\t")
                guard p.count >= 4 else { print("SKIP", raw); continue }
                total += 1
                let input = p[1].replacingOccurrences(of: "↵", with: "\n")
                let got: String
                switch p[0] {
                case "model":
                    let variables = NoteVariables.parse(noteText: p[2].replacingOccurrences(of: "↵", with: "\n"))
                    got = summary(ChartModel.build(language: "chart", body: input, context: .init(table: { _ in nil }, variables: variables)))
                case "points":
                    let parsed = ChartPoints.parse(input)
                    got = ChartPoints.text(parsed.entries) + (parsed.problem.map { " ! " + $0 } ?? "")
                case "setpoints":
                    got = ChartBlockEditing.settingPoints(ChartPoints.parse(p[2]).entries, in: input).replacingOccurrences(of: "\n", with: "↵")
                case "name":
                    got = ChartModel.readable(input)
                default:
                    got = "unknown case kind \(p[0])"
                }
                let ok = got == p[3]
                if !ok { failed += 1 }
                print(ok ? "PASS" : "FAIL", p[0], p[1], ok ? "" : "\n    got      \(got)\n    expected \(p[3])")
            }
        }
        print("CHART CASES: \(total - failed)/\(total) passed")
        return failed
    }

    /// A model in one line: its kind and x axis, then each thing drawn and each problem,
    /// ` | ` between them. Curves show where they start and end, or the x of an upright one.
    static func summary(_ m: ChartModel) -> String {
        func n(_ v: Double) -> String { LinearFit.short(v) }
        func pt(_ p: ChartModel.Point) -> String { "(\(n(p.x)), \(n(p.y)))" }
        var parts = ["\(m.kind)"]
        if let c = m.categories { parts[0] += " labels " + c.joined(separator: ",") }
        if let x = m.xDomain { parts[0] += " x \(n(x.lowerBound))..\(n(x.upperBound))" }
        if let y = m.yDomain { parts[0] += " y \(n(y.lowerBound))..\(n(y.upperBound))" }
        for s in m.series { parts.append("series \(s.name) " + s.segments.map { $0.map(pt).joined(separator: " ") }.joined(separator: " / ")) }
        for c in m.curves {
            if let x = c.vertical { parts.append("curve \(c.name) upright at \(n(x))"); continue }
            let all = c.segments.flatMap { $0 }
            parts.append("curve \(c.name) " + (all.first.map(pt) ?? "none") + ".." + (all.last.map(pt) ?? "none"))
        }
        for k in m.markers { parts.append("point " + pt(k.point)) }
        for p in m.problems { parts.append("problem " + p) }
        return parts.joined(separator: " | ")
    }
}
#endif
