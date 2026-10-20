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
