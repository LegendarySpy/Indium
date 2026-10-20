import AppKit
import Charts
import SwiftUI

/// A chart laid out for the page: its model drawn with Swift Charts into a vector image,
/// once for light and once for dark, so it's crisp on screen, in PDFs and in Quick Look.
/// Renders are shared by model and size, so restyling a note doesn't draw its charts again.
final class ChartRender {
    let model: ChartModel
    let size: NSSize
    private var images: [Bool: NSImage] = [:]

    private init(model: ChartModel, size: NSSize) {
        self.model = model
        self.size = size
    }

    private struct Key: Hashable {
        let model: ChartModel
        let width: CGFloat
        let height: CGFloat
    }
    private static var cache: [Key: ChartRender] = [:]
    private static var order: [Key] = []

    /// The render of `model` at a size for a column `column` points wide.
    static func make(_ model: ChartModel, column: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude) -> ChartRender {
        let size = layoutSize(model, column: column, maxHeight: maxHeight)
        let key = Key(model: model, width: size.width, height: size.height)
        if let hit = cache[key] { return hit }
        let render = ChartRender(model: model, size: size)
        cache[key] = render
        order.append(key)
        if order.count > 48 { cache[order.removeFirst()] = nil }
        return render
    }

    /// As wide as the column (or the share `width:` asks for), about 3:5, never taller
    /// than the page allows. A graph keeps the shape its `width`/`height` give it.
    private static func layoutSize(_ m: ChartModel, column: CGFloat, maxHeight: CGFloat) -> NSSize {
        var width = column * CGFloat(m.widthFraction ?? 1)
        if let w = m.width { width = min(CGFloat(w), column) }
        var height: CGFloat
        if let h = m.height {
            height = CGFloat(h) * (m.width.map { width / CGFloat($0) } ?? 1)
        } else if m.kind == .graph {
            height = width * (m.width == nil ? 0.62 : 400 / 600)
        } else {
            height = min(max(width * 0.58, 220), 420)
        }
        height += chromeHeight(m)
        return NSSize(width: floor(width), height: floor(min(height, maxHeight)))
    }

    /// Room for the title, legend and problems above and below the plot.
    private static func chromeHeight(_ m: ChartModel) -> CGFloat {
        var h: CGFloat = 0
        if m.title != nil { h += 22 }
        if m.showsLegend { h += 22 }
        if m.xTitle != nil { h += 18 }
        h += CGFloat(min(m.problems.count, 4)) * 16
        return h
    }

    func draw(in rect: NSRect) {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        image(dark: dark).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    func image(dark: Bool) -> NSImage {
        if let image = images[dark] { return image }
        let image = MainActor.assumeIsolated { Self.render(ChartView(model: model, dark: dark), size: size) }
        images[dark] = image
        return image
    }

    /// Draws `view` into a one-page PDF and wraps it in an image, so it stays vectors.
    @MainActor
    private static func render(_ view: some View, size: NSSize) -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)
        let data = NSMutableData()
        renderer.render { rendered, draw in
            var box = CGRect(origin: .zero, size: rendered)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return NSImage(data: data as Data) ?? NSImage(size: size)
    }
}

extension ChartModel {
    /// A legend for two or more things drawn; one series is named by its axis title.
    var showsLegend: Bool { legend && legendItems.count >= 2 }

    /// What the legend lists: series as a dot (scatter) or a line, then curves.
    var legendItems: [(name: String, color: ChartColor, dash: Dash, dot: Bool)] {
        series.map { ($0.name, .palette($0.color), .solid, kind == .scatter) } + curves.map { ($0.name, $0.color, $0.dash, false) }
    }
}

// MARK: - Drawing

/// The categorical palette, light and dark (validated for color-vision deficiency and
/// against Indium's paper in both modes; see the dataviz reference palette).
enum ChartPalette {
    static let light: [UInt32] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100, 0xE87BA4, 0x008300, 0x6250D6, 0xE34948]
    static let dark: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181, 0x008300, 0x9085E9, 0xE66767]

    static func nsColor(_ c: ChartColor, dark: Bool) -> NSColor {
        let v: UInt32
        switch c {
        case let .palette(i): let p = dark ? Self.dark : light; v = p[i % p.count]
        case let .hex(h): v = h
        }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func color(_ c: ChartColor, dark: Bool) -> Color {
        switch c {
        case let .palette(i): let p = dark ? Self.dark : light; return Color(hex: p[i % p.count])
        case let .hex(v): return Color(hex: v)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private struct ChartView: View {
    let model: ChartModel
    let dark: Bool

    private var ink: Color { dark ? Color(hex: 0xE7E3DC) : Color(hex: 0x2A2826) }
    private var secondary: Color { ink.opacity(0.62) }
    private var gridColor: Color { ink.opacity(dark ? 0.12 : 0.09) }
    private var axisColor: Color { ink.opacity(0.35) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = model.title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
            }
            if model.showsLegend { legend }
            titled(plot)
            ForEach(Array(model.problems.prefix(4).enumerated()), id: \.offset) { _, problem in
                Text(problem).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// The axis titles around the plot: y turned up the left side, x centered below.
    private func titled(_ plot: some View) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let y = model.yTitle {
                    Text(y).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                        .fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(width: 14)
                }
                // Room for the top tick's label and the last one on the right.
                plot.padding(.top, 8).padding(.trailing, 12)
            }
            if let x = model.xTitle {
                Text(x).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                    .padding(.leading, model.yTitle == nil ? 0 : 18)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(Array(model.legendItems.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    if item.dot {
                        Circle().fill(ChartPalette.color(item.color, dark: dark)).frame(width: 8, height: 8).frame(width: 18, height: 10)
                    } else {
                        Path { p in
                            p.move(to: CGPoint(x: 1, y: 5))
                            p.addLine(to: CGPoint(x: 17, y: 5))
                        }
                        .stroke(ChartPalette.color(item.color, dark: dark),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dash(item.dash, width: 2)))
                        .frame(width: 18, height: 10)
                    }
                    Text(item.name).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                }
            }
        }
    }

    private func dash(_ d: ChartModel.Dash, width: CGFloat) -> [CGFloat] {
        switch d {
        case .solid: []
        case .dashed: [width * 3, width * 2.5]
        case .dotted: [0.1, width * 2]
        }
    }

    @ViewBuilder private var plot: some View {
        if model.isEmpty {
            RoundedRectangle(cornerRadius: 8).fill(gridColor.opacity(0.6))
                .overlay(Text(model.problems.isEmpty ? "Nothing to plot yet" : "Nothing to plot").font(.system(size: 12)).foregroundStyle(secondary))
        } else if let categories = model.categories {
            categoryChart(categories)
        } else {
            numericChart
        }
    }

    // MARK: Text labels along x (bar charts, labels that aren't numbers)

    private func categoryChart(_ categories: [String]) -> some View {
        Chart {
            ForEach(Array(model.series.enumerated()), id: \.offset) { i, s in
                let color = ChartPalette.color(.palette(s.color), dark: dark)
                ForEach(Array(s.segments.joined().enumerated()), id: \.offset) { _, p in
                    let label = categories.indices.contains(Int(p.x)) ? categories[Int(p.x)] : ""
                    if model.kind == .bar {
                        if model.stacked {
                            BarMark(x: .value("Label", label), y: .value("Value", p.y))
                                .foregroundStyle(color)
                        } else {
                            BarMark(x: .value("Label", label), y: .value("Value", p.y))
                                .foregroundStyle(color)
                                .position(by: .value("Series", "\(i)"))
                                .cornerRadius(3)
                        }
                    } else {
                        LineMark(x: .value("Label", label), y: .value("Value", p.y), series: .value("Series", "s\(i)"))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("Label", label), y: .value("Value", p.y))
                            .foregroundStyle(color)
                            .symbolSize(36)
                    }
                }
            }
            ForEach(Array(model.curves.enumerated()), id: \.offset) { i, c in
                ForEach(Array(c.segments.joined().enumerated()), id: \.offset) { _, p in
                    let label = categories.indices.contains(Int(p.x.rounded())) ? categories[Int(p.x.rounded())] : ""
                    LineMark(x: .value("Label", label), y: .value("Value", p.y), series: .value("Series", "c\(i)"))
                        .foregroundStyle(ChartPalette.color(c.color, dark: dark))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash(c.dash, width: 2)))
                }
            }
        }
        .modifier(YScale(domain: yDomain, includesZero: model.beginAtZero || model.kind == .bar))
        .chartXAxis { axis(grid: false) }
        .chartYAxis { axis(grid: true, leading: true) }

    }

    // MARK: Numbers along x (lines, scatter, curves, graphs)

    private var numericChart: some View {
        Chart {
            if model.kind == .graph, let x = model.xDomain, let y = model.yDomain {
                // The axes through the origin, as a graphing calculator draws them.
                if x.contains(0) { RuleMark(x: .value("x", 0)).foregroundStyle(axisColor).lineStyle(StrokeStyle(lineWidth: 1)) }
                if y.contains(0) { RuleMark(y: .value("y", 0)).foregroundStyle(axisColor).lineStyle(StrokeStyle(lineWidth: 1)) }
            }
            ForEach(Array(model.series.enumerated()), id: \.offset) { i, s in
                let color = ChartPalette.color(.palette(s.color), dark: dark)
                ForEach(Array(s.segments.enumerated()), id: \.offset) { j, segment in
                    ForEach(Array(segment.enumerated()), id: \.offset) { _, p in
                        if model.kind != .scatter {
                            LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("Series", "s\(i)-\(j)"))
                                .foregroundStyle(color)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                        PointMark(x: .value("x", p.x), y: .value("y", p.y))
                            .foregroundStyle(color)
                            .symbolSize(model.kind == .scatter ? 48 : 36)
                    }
                }
            }
            ForEach(Array(model.curves.enumerated()), id: \.offset) { i, c in
                let color = ChartPalette.color(c.color, dark: dark)
                ForEach(Array(c.segments.enumerated()), id: \.offset) { j, segment in
                    ForEach(Array(segment.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("Series", "c\(i)-\(j)"))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash(c.dash, width: 2)))
                    }
                }
            }
            ForEach(Array(model.markers.enumerated()), id: \.offset) { _, m in
                let color = ChartPalette.color(m.color, dark: dark)
                PointMark(x: .value("x", m.point.x), y: .value("y", m.point.y))
                    .foregroundStyle(color)
                    .symbol(symbol(m.shape))
                    .symbolSize(64)
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        if let label = m.label { Text(label).font(.system(size: 11)).foregroundStyle(ink) }
                    }
            }
        }
        .modifier(XScale(domain: xDomain))
        .modifier(YScale(domain: yDomain, includesZero: model.beginAtZero))
        .chartXAxis { axis(grid: model.grid) }
        .chartYAxis { axis(grid: model.grid, leading: true) }
        .chartPlotStyle { $0.clipped() }

    }

    private func symbol(_ shape: ChartModel.Shape) -> AnyChartSymbolShape {
        switch shape {
        case .point: AnyChartSymbolShape(BasicChartSymbolShape.circle)
        case .open: AnyChartSymbolShape(BasicChartSymbolShape.circle.strokeBorder(lineWidth: 2))
        case .cross: AnyChartSymbolShape(BasicChartSymbolShape.cross)
        }
    }

    /// A graph shows exactly its range; data gets a little room so points at the ends show whole.
    private var xDomain: ClosedRange<Double>? {
        guard let d = model.xDomain, model.kind != .graph else { return model.xDomain }
        let pad = (d.upperBound - d.lowerBound) * 0.04
        return (d.lowerBound - pad)...(d.upperBound + pad)
    }

    private var yDomain: ClosedRange<Double>? {
        model.yDomain.map { d in model.beginAtZero ? min(0, d.lowerBound)...max(0, d.upperBound) : d }
    }

    private func axis(grid: Bool, leading: Bool = false) -> some AxisContent {
        AxisMarks(position: leading ? .leading : .automatic) { _ in
            if grid { AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(gridColor) }
            AxisTick(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(axisColor)
            AxisValueLabel().font(.system(size: 10)).foregroundStyle(secondary)
        }
    }
}

/// The x range given, or fitted to the data without stretching to zero (lab data rarely starts there).
private struct XScale: ViewModifier {
    let domain: ClosedRange<Double>?
    func body(content: Content) -> some View {
        if let domain { content.chartXScale(domain: domain) } else { content.chartXScale(domain: .automatic(includesZero: false)) }
    }
}

private struct YScale: ViewModifier {
    let domain: ClosedRange<Double>?
    let includesZero: Bool
    func body(content: Content) -> some View {
        if let domain { content.chartYScale(domain: domain) } else { content.chartYScale(domain: .automatic(includesZero: includesZero)) }
    }
}
