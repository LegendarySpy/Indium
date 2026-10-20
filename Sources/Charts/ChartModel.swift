import Foundation

/// A chart or graph as drawn: series of points, curves, markers and axes, read from a
/// fenced block in one of the two formats Obsidian plugins use, so a chart made in
/// either app draws in the other (see README.md):
///
/// - ```` ```chart ````: the Charts plugin's YAML (phibr0/obsidian-charts). Data inline
///   (`labels`, `series`) or from a table named by a `^id` line under it (`id`, `layout`,
///   `select`). Line and bar charts as the plugin draws them, plus `type: scatter` and
///   `plot:` curves, which only Indium reads.
/// - ```` ```desmos-graph ````: the Desmos plugin's equations (Nigecat/obsidian-desmos),
///   one LaTeX equation per line, with `key=value` settings before a `---` line.
///
/// Foundation only: the block's text and the note in, a model out. Drawing is
/// `ChartRender`'s.
struct ChartModel: Hashable {
    enum Kind: String, Hashable { case line, bar, scatter, graph }
    enum Dash: Hashable { case solid, dashed, dotted }
    enum Shape: Hashable { case point, open, cross }

    struct Point: Hashable {
        var x: Double
        var y: Double
    }
    struct Series: Hashable {
        var name: String
        var color: Int
        /// Points with a value; a gap in the data leaves a gap in the line.
        var segments: [[Point]]
    }
    struct Curve: Hashable {
        var name: String
        /// A palette index, or a color written in the block (`#42ddf5`).
        var color: ChartColor
        var dash: Dash
        var segments: [[Point]]
    }
    struct Marker: Hashable {
        var point: Point
        var label: String?
        var color: ChartColor
        var shape: Shape
    }

    var kind: Kind = .line
    /// Labels along the x axis when it isn't numeric (bar charts, text labels).
    var categories: [String]?
    var series: [Series] = []
    var curves: [Curve] = []
    var markers: [Marker] = []
    var title: String?
    var xTitle: String?
    var yTitle: String?
    var xDomain: ClosedRange<Double>?
    var yDomain: ClosedRange<Double>?
    var beginAtZero = false
    var legend = true
    var grid = true
    var stacked = false
    /// Share of the column (`width: 80%`) or points (`width: 400px`).
    var widthFraction: Double?
    var width: Double?
    var height: Double?
    /// Lines Indium couldn't draw, and why, shown under the chart.
    var problems: [String] = []
    /// For each equation of a graph (or `plot:` curve of a chart), in order: the color it's
    /// drawn in (nil when it draws nothing) and what's wrong with it, for the inspector.
    struct Row: Hashable {
        var color: ChartColor?
        var problem: String?
    }
    var rows: [Row] = []

    var isEmpty: Bool { series.allSatisfy { $0.segments.isEmpty } && curves.isEmpty && markers.isEmpty }

    /// Block languages Indium draws.
    static func handles(_ language: String) -> Bool {
        let l = language.lowercased()
        return l == "chart" || l == "desmos-graph"
    }

    /// Where a chart's data comes from in the note.
    struct Context {
        /// The table named `^id`, as its grid (header row first) and alignment; nil if none.
        var table: (String) -> [[String]]?
        var variables: NoteVariables
    }

    static func build(language: String, body: String, context: Context) -> ChartModel {
        language.lowercased() == "desmos-graph" ? graph(body, context: context) : chart(body, context: context)
    }

    // MARK: - Charts plugin

    private static func chart(_ body: String, context: Context) -> ChartModel {
        var m = ChartModel()
        let yaml = MiniYAML.parse(body)
        let type = yaml["type"]?.text?.lowercased() ?? "line"
        switch type {
        case "line": m.kind = .line
        case "bar": m.kind = .bar
        case "scatter": m.kind = .scatter
        default:
            m.problems.append("Indium draws line, bar and scatter charts, not \(type) charts. Obsidian’s Charts plugin still can.")
            return m
        }
        m.title = yaml["title"]?.text
        m.xTitle = yaml["xTitle"]?.text
        m.yTitle = yaml["yTitle"]?.text
        m.beginAtZero = yaml["beginAtZero"]?.bool ?? false
        m.legend = yaml["legend"]?.bool ?? true
        m.stacked = yaml["stacked"]?.bool ?? false
        if let w = yaml["width"]?.text {
            if w.hasSuffix("%"), let p = Double(w.dropLast()) { m.widthFraction = min(max(p / 100, 0.2), 1) }
            else if let px = Double(w.replacingOccurrences(of: "px", with: "")) { m.width = px }
        }
        if let h = yaml["height"]?.text.flatMap({ Double($0.replacingOccurrences(of: "px", with: "")) }) { m.height = h }

        // The data: a table by id, or written inline.
        var labels: [String] = []
        var columns: [(name: String, cells: [String])] = []
        var xUnit: String?
        if let id = yaml["id"]?.text {
            guard let grid = context.table(id), let header = grid.first, header.count >= 2, grid.count >= 2 else {
                m.problems.append("No table named ^\(id) in this note. Put a line with ^\(id) under the table, after a blank line.")
                return m
            }
            let body = Array(grid.dropFirst())
            if yaml["layout"]?.text?.lowercased() == "rows" {
                labels = Array(header.dropFirst())
                columns = body.map { row in (row.first ?? "", Array(row.dropFirst())) }
            } else {
                labels = body.map { $0.first ?? "" }
                columns = (1..<header.count).map { c in (header[c], body.map { c < $0.count ? $0[c] : "" }) }
                if m.xTitle == nil, !header[0].isEmpty { m.xTitle = header[0] }
            }
        } else {
            labels = yaml["labels"]?.list ?? []
            for item in yaml["series"]?.items ?? [] {
                columns.append((item["title"]?.text ?? "", item["data"]?.list ?? []))
            }
        }
        if let select = yaml["select"]?.list, !select.isEmpty {
            columns = columns.filter { select.contains($0.name) }
        }
        guard !columns.isEmpty else {
            m.problems.append("Nothing to plot. Give the chart an id: matching a ^id under a table, or labels: and series:.")
            return m
        }

        // Numbers along x when every label is one (and it isn't a bar chart): spaced by value.
        let xs = labels.map { Quantity.parse($0) }
        let numericX = m.kind != .bar && !labels.isEmpty && xs.allSatisfy { $0 != nil }
        if numericX {
            xUnit = xs.compactMap { $0?.unit?.text }.first
        } else {
            m.categories = labels
            if m.kind == .scatter { m.kind = .line }
        }
        if let xUnit, let t = m.xTitle, !t.contains(xUnit) { m.xTitle = "\(t) (\(xUnit))" }

        var yUnits: [String] = []
        for (i, column) in columns.enumerated() {
            var segments: [[Point]] = [], current: [Point] = []
            for (j, cell) in column.cells.enumerated() where j < max(labels.count, column.cells.count) {
                let x = numericX ? (j < xs.count ? xs[j]?.value : nil) : Double(j)
                if let x, let q = Quantity.parse(cell), q.value.isFinite {
                    current.append(Point(x: x, y: q.value))
                    if let u = q.unit?.text { yUnits.append(u) }
                } else if !current.isEmpty, yaml["spanGaps"]?.bool != true {
                    segments.append(current)
                    current = []
                }
            }
            if !current.isEmpty { segments.append(current) }
            m.series.append(Series(name: column.name, color: i, segments: segments))
        }
        if m.yTitle == nil, columns.count == 1 { m.yTitle = columns[0].name.isEmpty ? nil : columns[0].name }
        if let unit = Set(yUnits).count == 1 ? yUnits.first : nil, let t = m.yTitle, !t.contains(unit) { m.yTitle = "\(t) (\(unit))" }

        // Axis limits, as the plugin names them.
        let xMin = yaml["xMin"]?.number, xMax = yaml["xMax"]?.number
        let yMin = yaml["yMin"]?.number, yMax = yaml["yMax"]?.number
        if numericX {
            let all = m.series.flatMap { $0.segments.flatMap { $0.map(\.x) } }
            if let lo = xMin ?? all.min(), let hi = xMax ?? all.max(), hi > lo { m.xDomain = lo...hi }
        }
        if yMin != nil || yMax != nil {
            let all = m.series.flatMap { $0.segments.flatMap { $0.map(\.y) } }
            if let lo = yMin ?? all.min(), let hi = yMax ?? all.max(), hi > lo { m.yDomain = lo...hi }
        }

        // A line of best fit through one series.
        if yaml["bestFit"]?.bool == true {
            let n = Int(yaml["bestFitNumber"]?.number ?? 0)
            if n >= 0, n < m.series.count, let fit = LinearFit(m.series[n].segments.flatMap { $0 }) {
                let xs = m.series[n].segments.flatMap { $0.map(\.x) }
                let name = (yaml["bestFitTitle"]?.text ?? "Line of Best Fit") + (numericX ? ": " + fit.description : "")
                let lo = m.xDomain?.lowerBound ?? xs.min() ?? 0, hi = m.xDomain?.upperBound ?? xs.max() ?? 1
                m.curves.append(Curve(name: name, color: .palette(n), dash: .dashed,
                                      segments: [[Point(x: lo, y: fit.y(lo)), Point(x: hi, y: fit.y(hi))]]))
            } else {
                m.problems.append("A line of best fit needs at least two points.")
            }
        }

        // Curves over the data (Indium only): `plot: y = k x` or a list of them.
        let plots = yaml["plot"]?.list ?? yaml["plot"]?.text.map { [$0] } ?? []
        if !plots.isEmpty {
            guard numericX, let domain = m.xDomain else {
                m.problems.append("Curves need numbers along the x axis.")
                m.rows = plots.map { _ in Row(problem: "Curves need numbers along the x axis") }
                return m
            }
            var functions = GraphMath.Functions(variables: context.variables)
            for (i, plot) in plots.enumerated() {
                switch functions.line(plot) {
                case let .curve(expression):
                    m.curves.append(Curve(name: plot, color: .palette(columns.count + i), dash: .solid,
                                          segments: GraphMath.sample(expression, functions: functions, x: domain, y: nil)))
                    m.rows.append(Row(color: .palette(columns.count + i)))
                case let .problem(why):
                    m.problems.append("\(plot): \(why)")
                    m.rows.append(Row(problem: why))
                default:
                    m.problems.append("\(plot): write it as y = …")
                    m.rows.append(Row(problem: "Write it as y = …"))
                }
            }
        }
        return m
    }

    // MARK: - Desmos plugin

    private static func graph(_ body: String, context: Context) -> ChartModel {
        var m = ChartModel()
        m.kind = .graph
        m.legend = false
        var lines = body.components(separatedBy: .newlines)
        var settings: [String: String] = [:]
        if let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for pair in lines[..<sep].joined(separator: ";").split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { settings[kv[0].lowercased()] = kv[1] }
            }
            lines = Array(lines[(sep + 1)...])
        }
        let left = settings["left"].flatMap(Double.init) ?? -10, right = settings["right"].flatMap(Double.init) ?? 10
        let bottom = settings["bottom"].flatMap(Double.init) ?? -7, top = settings["top"].flatMap(Double.init) ?? 7
        guard right > left, top > bottom else {
            m.problems.append("left must be less than right, and bottom less than top.")
            return m
        }
        m.xDomain = left...right
        m.yDomain = bottom...top
        m.grid = settings["grid"]?.lowercased() != "false"
        if let w = settings["width"].flatMap(Double.init) { m.width = w }
        if let h = settings["height"].flatMap(Double.init) { m.height = h }
        let defaultColor = settings["defaultcolor"].flatMap(ChartColor.named)

        var functions = GraphMath.Functions(variables: context.variables, degrees: settings["degreemode"]?.lowercased() == "degrees")
        var colorIndex = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let equation = parts.removeFirst()
            var color: ChartColor?, dash = Dash.solid, shape = Shape.point, hidden = false, label: String?
            var restrictions: [String] = []
            for flag in parts where !flag.isEmpty {
                let f = flag.lowercased()
                if let c = ChartColor.named(flag) { color = c }
                else if f == "solid" { dash = .solid } else if f == "dashed" { dash = .dashed } else if f == "dotted" { dash = .dotted }
                else if f == "point" { shape = .point } else if f == "open" { shape = .open } else if f == "cross" { shape = .cross }
                else if f == "hidden" { hidden = true }
                else if f.hasPrefix("label:") { label = String(flag.dropFirst(6)) }
                else { restrictions.append(flag) }
            }
            let parsed = functions.line(equation)
            if case .definition = parsed { m.rows.append(Row()); continue }
            if hidden {
                if case let .problem(why) = parsed { m.rows.append(Row(problem: why)) } else { m.rows.append(Row()) }
                continue
            }
            let resolved = color ?? defaultColor ?? .palette(colorIndex)
            switch parsed {
            case let .curve(expression):
                colorIndex += color == nil ? 1 : 0
                m.rows.append(Row(color: resolved))
                m.curves.append(Curve(name: equation, color: resolved, dash: dash,
                                      segments: GraphMath.sample(expression, functions: functions, x: m.xDomain!, y: m.yDomain,
                                                                 restrictions: restrictions)))
            case let .vertical(x):
                colorIndex += color == nil ? 1 : 0
                m.rows.append(Row(color: resolved))
                m.curves.append(Curve(name: equation, color: resolved, dash: dash,
                                      segments: [[Point(x: x, y: bottom), Point(x: x, y: top)]]))
            case let .point(x, y):
                colorIndex += color == nil ? 1 : 0
                m.rows.append(Row(color: resolved))
                m.markers.append(Marker(point: Point(x: x, y: y), label: label, color: resolved, shape: shape))
            case let .problem(why):
                m.problems.append("\(equation): \(why)")
                m.rows.append(Row(problem: why))
            case .definition:
                break
            }
        }
        return m
    }
}

/// A chart color: one of the palette's, or one written in the block.
enum ChartColor: Hashable {
    case palette(Int)
    case hex(UInt32)

    /// Desmos plugin color names (case-insensitive) and `#rrggbb`.
    static func named(_ name: String) -> ChartColor? {
        let n = name.lowercased()
        if n.hasPrefix("#"), n.count == 7, let v = UInt32(n.dropFirst(), radix: 16) { return .hex(v) }
        let names: [String: UInt32] = ["red": 0xC74440, "green": 0x388C46, "blue": 0x2D70B3, "yellow": 0xD4B32B, "magenta": 0xC03BA0,
                                       "cyan": 0x2BA6B8, "purple": 0x6042A6, "orange": 0xFA7E19, "black": 0x000000, "white": 0xFFFFFF]
        return names[n].map { .hex($0) }
    }
}

/// Least squares through points: `y = slope·x + intercept`.
struct LinearFit {
    let slope: Double
    let intercept: Double
    let r2: Double

    init?(_ points: [ChartModel.Point]) {
        let n = Double(points.count)
        guard points.count >= 2 else { return nil }
        let mx = points.map(\.x).reduce(0, +) / n, my = points.map(\.y).reduce(0, +) / n
        let sxx = points.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let sxy = points.map { ($0.x - mx) * ($0.y - my) }.reduce(0, +)
        slope = sxy / sxx
        intercept = my - slope * mx
        let ssTot = points.map { ($0.y - my) * ($0.y - my) }.reduce(0, +)
        let (m, b) = (slope, intercept)
        let ssRes = points.map { (p: ChartModel.Point) -> Double in let e = p.y - (m * p.x + b); return e * e }.reduce(0, +)
        r2 = ssTot > 0 ? 1 - ssRes / ssTot : 1
    }

    func y(_ x: Double) -> Double { slope * x + intercept }

    /// `y = 0.342x + 94.4, R² = 0.998`
    var description: String {
        let b = intercept < 0 ? " − \(Self.short(-intercept))" : " + \(Self.short(intercept))"
        return "y = \(Self.short(slope))x\(b), R² = \(String(format: "%.3f", r2))"
    }

    /// Four significant figures, without trailing zeros.
    static func short(_ v: Double) -> String {
        guard v != 0, v.isFinite else { return "0" }
        let digits = max(0, 3 - Int(floor(log10(abs(v)))))
        var s = String(format: "%.\(min(digits, 8))f", v)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s
    }
}

// MARK: - A little YAML

/// The YAML the Charts plugin's blocks use: top-level `key: value` lines, inline lists
/// (`[a, "b c", 3]`), and `series:` as a list of small maps. Indentation decides what
/// belongs to what, as in the plugin's own examples (which indent their keys oddly).
enum MiniYAML {
    indirect enum Value: Hashable {
        case scalar(String)
        case list([String])
        case items([[String: Value]])

        var text: String? { if case let .scalar(s) = self { return s.isEmpty ? nil : s }; return nil }
        var list: [String]? {
            switch self {
            case let .list(l): return l
            case let .scalar(s) where !s.isEmpty: return [s]
            default: return nil
            }
        }
        var items: [[String: Value]]? { if case let .items(i) = self { return i }; return nil }
        var bool: Bool? { text.map { $0.lowercased() == "true" || $0.lowercased() == "yes" } }
        var number: Double? { text.flatMap { Double($0) } }
    }

    static func parse(_ text: String) -> [String: Value] {
        let lines = text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        guard let base = lines.map(indent).min() else { return [:] }
        var result: [String: Value] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard indent(line) == base, let (key, value) = pair(line) else { continue }
            // Lines indented under the key: a list of maps or of plain values.
            var nested: [String] = []
            while i < lines.count, indent(lines[i]) > base || lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                nested.append(lines[i])
                i += 1
            }
            if !nested.isEmpty, value.isEmpty {
                result[key] = block(nested)
            } else {
                result[key] = scalarOrList(value)
            }
        }
        return result
    }

    /// Items under a key: `- title: A` starts a map, `- a` is a plain value.
    private static func block(_ lines: [String]) -> Value {
        var maps: [[String: Value]] = [], plain: [String] = []
        for line in lines {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t == "-" {
                t = String(t.dropFirst(min(2, t.count))).trimmingCharacters(in: .whitespaces)
                if let (k, v) = pair(t) { maps.append([k: scalarOrList(v)]) } else { plain.append(unquote(t)) }
            } else if let (k, v) = pair(t), !maps.isEmpty {
                maps[maps.count - 1][k] = scalarOrList(v)
            }
        }
        return maps.isEmpty ? .list(plain) : .items(maps)
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func pair(_ line: String) -> (String, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(of: ":"), colon != t.startIndex else { return nil }
        let key = t[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.contains(" ") || key.hasPrefix("\"") else { return nil }
        return (unquote(key), t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func scalarOrList(_ v: String) -> Value {
        if v.hasPrefix("["), v.hasSuffix("]") { return .list(splitList(String(v.dropFirst().dropLast()))) }
        return .scalar(unquote(v))
    }

    /// `a, "b, c", 'd'` → [a, b, c, d], respecting quotes.
    private static func splitList(_ s: String) -> [String] {
        var out: [String] = [], current = "", quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "," {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !out.isEmpty { out.append(last) }
        return out
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let q = s.first, q == "\"" || q == "'", s.last == q { return String(s.dropFirst().dropLast()) }
        return s
    }
}
