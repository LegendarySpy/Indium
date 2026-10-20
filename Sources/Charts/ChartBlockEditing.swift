import Foundation

/// Changing one setting of a chart block for the inspector, leaving every other line as
/// written. Works on the block's body: the lines between its fences.
enum ChartBlockEditing {
    // MARK: ```chart (YAML)

    /// The top-level `key: value` lines of a chart block, as written.
    static func chartSettings(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in MiniYAML.parse(body) { if let t = value.text { out[key] = t } }
        return out
    }

    /// `key: value` set (or taken out, for nil) among the top-level keys, at their indent.
    static func settingChart(_ key: String, to value: String?, in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }
        let base = indents.min() ?? 0
        let pad = String(repeating: " ", count: base)
        let written = value.map { Self.yamlScalar($0) }
        if let i = lines.firstIndex(where: { line in
            line.prefix { $0 == " " }.count == base && line.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":")
        }) {
            // A list under the key (`- (1, 2)` lines) goes with it: the new value is on its line.
            while i + 1 < lines.count, !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                  lines[i + 1].prefix(while: { $0 == " " }).count > base || lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                lines.remove(at: i + 1)
            }
            if let written { lines[i] = "\(pad)\(key): \(written)" } else { lines.remove(at: i) }
        } else if let written {
            // After the last line, so a `series:` list above keeps its items.
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.append("\(pad)\(key): \(written)")
        }
        return lines.joined(separator: "\n")
    }

    /// Quoted when YAML would read it as something else (`a: b`, `#`, a leading `[`).
    private static func yamlScalar(_ s: String) -> String {
        let risky = s.contains(": ") || s.contains(" #") || s.hasPrefix("[") || s.hasPrefix("{") || s.hasPrefix("\"") || s.hasPrefix("'")
            || s.hasPrefix("-") && Double(s) == nil
        return risky ? "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
    }

    // MARK: ```desmos-graph (key=value before ---)

    static func graphSettings(_ body: String) -> [String: String] {
        let lines = body.components(separatedBy: "\n")
        guard let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return [:] }
        var out: [String: String] = [:]
        for pair in lines[..<sep].joined(separator: ";").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0].lowercased()] = kv[1] }
        }
        return out
    }

    /// `key=value` set (or taken out) in the settings above `---`, which it adds if needed.
    static func settingGraph(_ key: String, to value: String?, in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        guard let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            guard let value else { return body }
            return "\(key)=\(value)\n---\n" + body
        }
        let pattern = #"(?i)(^|;)\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*[^;]*;?"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for i in 0..<sep {
            let ns = lines[i] as NSString
            guard let m = regex.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) else { continue }
            let lead = ns.substring(with: m.range(at: 1))
            let had = ns.substring(with: m.range).hasSuffix(";")
            var replacement = value.map { "\(lead)\(lead.isEmpty ? "" : " ")\(key)=\($0)\(had ? ";" : "")" } ?? lead
            if value == nil, lead.isEmpty, !had { replacement = "" }
            lines[i] = ns.replacingCharacters(in: m.range, with: replacement).trimmingCharacters(in: .whitespaces)
            if lines[i].hasPrefix(";") { lines[i] = String(lines[i].dropFirst()).trimmingCharacters(in: .whitespaces) }
            if lines[i].isEmpty { lines.remove(at: i) }
            return lines.joined(separator: "\n")
        }
        guard let value else { return body }
        if sep == 0 {
            lines.insert("\(key)=\(value)", at: 0)
        } else {
            let last = lines[sep - 1].trimmingCharacters(in: .whitespaces)
            lines[sep - 1] = last.isEmpty ? "\(key)=\(value)" : last + (last.hasSuffix(";") ? " " : "; ") + "\(key)=\(value)"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: A graph's equations

    /// One equation line of a graph: `y=x^2|red|dashed`.
    struct GraphLine: Equatable {
        var expression: String
        var flags: [String] = []

        init(expression: String, flags: [String] = []) {
            self.expression = expression
            self.flags = flags
        }

        init(_ line: String) {
            var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            expression = parts.removeFirst()
            flags = parts.filter { !$0.isEmpty }
        }

        var text: String { ([expression] + flags).joined(separator: "|") }

        /// A color written on the line (a name or `#rrggbb`), or nil for the next automatic one.
        var color: String? {
            get { flags.first { ChartColor.named($0) != nil } }
            set {
                flags.removeAll { ChartColor.named($0) != nil }
                if let newValue { flags.insert(newValue, at: 0) }
            }
        }

        /// `dashed`, `dotted`, or nil for solid.
        var dash: String? {
            get { flags.first { ["dashed", "dotted"].contains($0.lowercased()) }?.lowercased() }
            set {
                flags.removeAll { ["solid", "dashed", "dotted"].contains($0.lowercased()) }
                if let newValue { flags.append(newValue) }
            }
        }

        var hidden: Bool {
            get { flags.contains { $0.lowercased() == "hidden" } }
            set {
                flags.removeAll { $0.lowercased() == "hidden" }
                if newValue { flags.append("hidden") }
            }
        }
    }

    /// Where a graph's equations are: after its `---`, or all of it without one.
    private static func equationStart(_ lines: [String]) -> Int {
        (lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "---" }).map { $0 + 1 } ?? 0
    }

    static func graphLines(_ body: String) -> [GraphLine] {
        let lines = body.components(separatedBy: "\n")
        return lines[equationStart(lines)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(GraphLine.init)
    }

    /// The equations replaced by `equations`, the settings above them as they were.
    static func settingGraphLines(_ equations: [GraphLine], in body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        return (lines[..<equationStart(lines)] + equations.map(\.text)).joined(separator: "\n")
    }

    // MARK: A chart's curves and columns

    /// `plot:` curves, in order.
    static func plots(_ body: String) -> [String] {
        let v = MiniYAML.parse(body)["plot"]
        return v?.list ?? v?.text.map { [$0] } ?? []
    }

    /// `plot:` written as one curve, a list, or taken out when empty.
    static func settingPlots(_ plots: [String], in body: String) -> String {
        let kept = plots.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let value: String? = kept.isEmpty ? nil : kept.count == 1 ? kept[0] : "[" + kept.joined(separator: ", ") + "]"
        return settingChart("plot", raw: value, in: body)
    }

    /// `points:` as written, the ones Indium can read.
    static func points(_ body: String) -> [ChartPoints.Entry] {
        ChartPoints.parse(ChartPoints.written(MiniYAML.parse(body)["points"])).entries
    }

    /// `points: (1, 2), (2, 4)` on one line, or taken out when there are none.
    static func settingPoints(_ points: [ChartPoints.Entry], in body: String) -> String {
        settingChart("points", raw: points.isEmpty ? nil : ChartPoints.text(points), in: body)
    }

    // MARK: Values written in the chart

    /// One of the plugin's `series:` items: a name and a value for each label.
    struct InlineSeries: Equatable {
        var title: String
        var data: [String]
    }

    /// The chart's own `labels:` and `series:`, as written.
    static func inlineData(_ body: String) -> (labels: [String], series: [InlineSeries]) {
        let yaml = MiniYAML.parse(body)
        let series = (yaml["series"]?.items ?? []).map { InlineSeries(title: $0["title"]?.text ?? "", data: $0["data"]?.list ?? []) }
        return (yaml["labels"]?.list ?? [], series)
    }

    /// `labels: [A, B]` and the `series:` list rewritten in the plugin's own layout, each
    /// taken out when empty:
    ///
    ///     series:
    ///       - title: Trial 1
    ///         data: [3, 5]
    static func settingInlineData(labels: [String], series: [InlineSeries], in body: String) -> String {
        var out = settingChart("labels", raw: labels.isEmpty ? nil : yamlList(labels), in: body)
        guard !series.isEmpty else { return settingChart("series", to: nil, in: out) }
        let marker = "\u{1}"
        out = settingChart("series", raw: marker, in: out)
        var lines = out.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains(marker) }) else { return out }
        let pad = String(lines[i].prefix { $0 == " " })
        lines[i] = pad + "series:"
        let items = series.flatMap { s in
            ["\(pad)  - title: \(s.title.isEmpty ? "\"\"" : yamlScalar(s.title))", "\(pad)    data: \(yamlList(s.data))"]
        }
        lines.insert(contentsOf: items, at: i + 1)
        return lines.joined(separator: "\n")
    }

    /// `[a, "b, c", 3]`: quoted where a comma, bracket or quote would split it.
    static func yamlList(_ values: [String]) -> String {
        "[" + values.map { v in
            v.contains(where: { ",[]\"'#:".contains($0) }) || v != v.trimmingCharacters(in: .whitespaces)
                ? "\"" + v.replacingOccurrences(of: "\"", with: "'") + "\"" : v
        }.joined(separator: ", ") + "]"
    }

    /// `a, b, c` as typed into one field: split at commas, outside quotes.
    static func splitTyped(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let inner = trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
        return MiniYAML.list(inner)
    }

    /// `select:` the columns to draw; taken out when it's all of them.
    static func settingSelected(_ selected: [String], of all: [String], in body: String) -> String {
        let quoted = selected.map { $0.contains(",") || $0.contains("]") ? "\"\($0)\"" : $0 }
        return settingChart("select", raw: Set(selected) == Set(all) ? nil : "[" + quoted.joined(separator: ", ") + "]", in: body)
    }

    /// As `settingChart`, with the value written exactly as given (a `[list]`).
    static func settingChart(_ key: String, raw value: String?, in body: String) -> String {
        guard let value else { return settingChart(key, to: nil, in: body) }
        let marker = "\u{1}"
        return settingChart(key, to: marker, in: body).replacingOccurrences(of: marker, with: value)
    }
}
