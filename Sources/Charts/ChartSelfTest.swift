#if DEBUG
import Foundation

/// Regression cases for charts, driven from the DEBUG harness (`-IndiumChartCases
/// Tests/Charts/cases.tsv`). One case per line, tab-separated, `↵` for a line break in a
/// block:
///
/// - `model<TAB>block body<TAB>frontmatter or table<TAB>expected`: what the block draws, as
///   `summary` writes it.
/// - `points<TAB>typed<TAB><TAB>expected`: the points read from text, then `! problem` if any.
/// - `setpoints<TAB>block body<TAB>typed points<TAB>expected body`: the block with its
///   `points:` set to those read from `typed`, as the inspector writes them.
/// - `name<TAB>equation<TAB><TAB>expected`: a curve as the legend names it.
/// - `setdata<TAB>block body<TAB>labels|title=values|…<TAB>expected body`: the block with its
///   `labels:` and `series:` set from those fields, as the inspector writes them.
/// - `legend<TAB>block body<TAB><TAB>expected`: the legend's names, ` | ` between them.
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
                    // The third field is the note's frontmatter, or a table any `id:` finds.
                    let third = p[2].replacingOccurrences(of: "↵", with: "\n")
                    let table = third.hasPrefix("|")
                        ? third.components(separatedBy: "\n").enumerated().filter { $0.offset != 1 }
                            .map { MarkdownScanner.splitRow($0.element).map { TableSpec.unescapeCell($0.text) } }
                        : nil
                    let variables = NoteVariables.parse(noteText: table == nil ? third : "")
                    got = summary(ChartModel.build(language: "chart", body: input, context: .init(table: { _ in table }, variables: variables)))
                case "points":
                    let parsed = ChartPoints.parse(input)
                    got = ChartPoints.text(parsed.entries) + (parsed.problem.map { " ! " + $0 } ?? "")
                case "setpoints":
                    got = ChartBlockEditing.settingPoints(ChartPoints.parse(p[2]).entries, in: input).replacingOccurrences(of: "\n", with: "↵")
                case "name":
                    got = ChartModel.readable(input)
                case "setdata":
                    var fields = p[2].components(separatedBy: "|")
                    let labels = ChartBlockEditing.splitTyped(fields.removeFirst())
                    let series = fields.map { f in
                        let kv = f.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                        return ChartBlockEditing.InlineSeries(title: kv[0], data: ChartBlockEditing.splitTyped(kv.count > 1 ? kv[1] : ""))
                    }
                    got = ChartBlockEditing.settingInlineData(labels: labels, series: series, in: input).replacingOccurrences(of: "\n", with: "↵")
                case "legend":
                    let m = ChartModel.build(language: "chart", body: input, context: .init(table: { _ in nil }, variables: NoteVariables.parse(noteText: "")))
                    got = m.legendItems.map(\.name).joined(separator: " | ")
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
        var parts = ["\(m.kind)" + (m.donut ? " donut" : "")]
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
