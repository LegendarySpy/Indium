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
        /// Its words are in the note's font.
        let font: FontChoice
    }
    private static var cache: [Key: ChartRender] = [:]
    private static var order: [Key] = []

    /// The render of `model` at a size for a column `column` points wide.
    static func make(_ model: ChartModel, column: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude) -> ChartRender {
        let size = layoutSize(model, column: column, maxHeight: maxHeight)
        let key = Key(model: model, width: size.width, height: size.height, font: AppSettings.shared.font)
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
        } else if m.kind == .pie {
            height = min(max(width * 0.4, 180), 260)
        } else if m.kind == .graph {
            height = width * (m.width == nil ? 0.62 : 400 / 600)
        } else {
            height = min(max(width * 0.58, 220), 420)
        }
        height += chromeHeight(m, width: floor(width))
        return NSSize(width: floor(width), height: floor(min(height, maxHeight)))
    }

    /// Room for the title, legend and problems above and below the plot.
    private static func chromeHeight(_ m: ChartModel, width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        if m.title != nil { h += 30 }
        if m.showsLegend { h += CGFloat(m.legendRows(width: width).count) * legendRowHeight + 8 }
        if m.xTitle != nil { h += 22 }
        h += CGFloat(min(m.problems.count, 4)) * 16
        return h
    }

    static let legendRowHeight: CGFloat = 20
    /// The title, legend and axis titles are set in the note's own font.
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        Typography.baseFont(AppSettings.shared.font, size: size, weight: weight)
    }
    static var legendFont: NSFont { font(12) }

    func draw(in rect: NSRect) {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        image(dark: dark).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    func image(dark: Bool) -> NSImage {
        if let image = images[dark] { return image }
        let image = MainActor.assumeIsolated { Self.render(ChartView(model: model, dark: dark, width: size.width), size: size) }
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

    /// What the legend lists: series as a dot (scatter, and a bar's block) or a line, then curves. A pie's
    /// slices, each with its share.
    var legendItems: [(name: String, color: ChartColor, dash: Dash, dot: Bool, index: Int)] {
        if kind == .pie, let labels = categories, let slices = series.first?.segments.first {
            let total = slices.map(\.y).reduce(0, +)
            return slices.enumerated().map { i, p in
                let share = total > 0 ? p.y / total * 100 : 0
                let percent = share < 10 && share.rounded() != share ? String(format: "%.1f", share) : String(format: "%.0f", share)
                return ("\(i < labels.count ? labels[i] : "")  \(percent)%", .palette(i), .solid, true, i)
            }
        }
        return series.map { ($0.name.isEmpty ? "Untitled" : $0.name, .palette($0.color), seriesDash($0.color), kind == .scatter || kind == .bar, $0.color) }
            + curves.map { ($0.name, $0.color, $0.dash, false, -1) }
    }

    /// Lines told apart without color, in the styles meant to print in grey: solid, then
    /// dashed, then dotted.
    func seriesDash(_ index: Int) -> Dash {
        guard style == .mono || style == .hatched else { return .solid }
        return [Dash.solid, .dashed, .dotted][index % 3]
    }

    /// The legend's items, a row at a time, wrapped to `width` as words wrap.
    func legendRows(width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]], used: CGFloat = 0
        for (i, item) in legendItems.enumerated() {
            let w = 23 + ceil((item.name as NSString).size(withAttributes: [.font: ChartRender.legendFont]).width)
            if !rows[rows.count - 1].isEmpty, used + 16 + w > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : 16) + w
            rows[rows.count - 1].append(i)
        }
        return rows
    }
}

// MARK: - Drawing

/// A chart's colors, light and dark, for each style.
enum ChartPalette {
    /// Soft: inks from the app's own colors (its link blue, its warning amber and error
    /// terracotta) and quiet greens and plums beside them, lightened for dark mode.
    static let softLight: [UInt32] = [0x3F6E9A, 0xC2694A, 0x6E9A6B, 0xC9A13E, 0x8C5E8C, 0x4E9196, 0xC98584, 0x6F7782]
    static let softDark: [UInt32] = [0x8FB3D6, 0xE0937A, 0x9CC197, 0xE2C06A, 0xC195C0, 0x86C1C4, 0xE6A9A6, 0xA5ADB8]
    /// Vivid: far apart and bright (validated for color-vision deficiency against Indium's
    /// paper in both modes; see the dataviz reference palette).
    static let vividLight: [UInt32] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100, 0xE87BA4, 0x008300, 0x6250D6, 0xE34948]
    static let vividDark: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181, 0x008300, 0x9085E9, 0xE66767]
    /// Mono: the text color mixed into the paper, darkest first.
    private static let monoShares: [Double] = [0.78, 0.5, 0.32, 0.2, 0.64, 0.42, 0.26, 0.14]

    static func hex(_ c: ChartColor, style: ChartModel.Style, dark: Bool) -> UInt32 {
        guard case let .palette(i) = c else { if case let .hex(h) = c { return h }; return 0 }
        switch style {
        case .soft, .hatched, .gradient, .dotted: let p = dark ? softDark : softLight; return p[i % p.count]
        case .vivid: let p = dark ? vividDark : vividLight; return p[i % p.count]
        case .mono: return mix(dark ? 0xE7E3DC : 0x2A2826, into: dark ? 0x1F1E1C : 0xFAF8F4, monoShares[i % monoShares.count])
        }
    }

    /// `ink` laid over `paper` at `share`, as one solid color.
    private static func mix(_ ink: UInt32, into paper: UInt32, _ share: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((ink >> shift) & 0xFF), b = Double((paper >> shift) & 0xFF)
            return UInt32((a * share + b * (1 - share)).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    static func nsColor(_ c: ChartColor, style: ChartModel.Style = .soft, dark: Bool) -> NSColor {
        let v = hex(c, style: style, dark: dark)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func color(_ c: ChartColor, style: ChartModel.Style = .soft, dark: Bool) -> Color {
        Color(hex: hex(c, style: style, dark: dark))
    }
}

/// Small tiles that repeat across a bar or slice: lines at an angle (a different one for
/// each set of values, as a textbook figure tells them apart) or a stipple of dots, in
/// the mark's color over a pale wash of it.
enum ChartPattern: Hashable {
    case hatch(Int)
    case dots
    /// The color from one strength to another, top to bottom, over `height` points.
    case fade(from: Double, to: Double, height: Int)

    private static var cache: [String: NSImage] = [:]

    static func paint(_ pattern: ChartPattern, color: NSColor, dark: Bool) -> ImagePaint {
        ImagePaint(image: Image(nsImage: image(pattern, color: color, dark: dark)), scale: 1 / 3)
    }

    /// The tile, at three times its size.
    static func image(_ pattern: ChartPattern, color: NSColor, dark: Bool) -> NSImage {
        let key = "\(pattern)-\(color.hexKey)-\(dark)"
        if let hit = cache[key] { return hit }
        let made = tile(pattern, color: color, dark: dark)
        cache[key] = made
        return made
    }

    /// Three little bars in a style, for the inspector's menu of them.
    static func preview(_ style: ChartModel.Style, dark: Bool) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 14), flipped: true) { _ in
            for (i, height) in [8.0, 13.0, 10.0].enumerated() {
                let bar = NSRect(x: CGFloat(i) * 8, y: 14 - height, width: 6, height: height)
                let shape = NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5)
                let color = ChartPalette.nsColor(.palette(i), style: style, dark: dark)
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                switch style {
                case .hatched, .dotted:
                    // The tile at its real size, lined up with the bar.
                    let tile = image(style == .hatched ? .hatch(i) : .dots, color: color, dark: dark)
                    let small = NSImage(size: NSSize(width: tile.size.width / 3, height: tile.size.height / 3), flipped: false) { r in
                        tile.draw(in: r)
                        return true
                    }
                    NSColor(patternImage: small).setFill()
                    bar.fill()
                case .gradient:
                    NSGradient(starting: color, ending: color.withAlphaComponent(0.36))?.draw(in: bar, angle: 90)
                default:
                    color.setFill()
                    bar.fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    /// Drawn at three times its size, so the lines stay sharp.
    private static func tile(_ pattern: ChartPattern, color: NSColor, dark: Bool) -> NSImage {
        let scale: CGFloat = 3
        if case let .fade(from, to, height) = pattern {
            let size = NSSize(width: 2 * scale, height: CGFloat(height) * scale)
            let image = NSImage(size: size, flipped: true) { rect in
                NSGradient(starting: color.withAlphaComponent(from), ending: color.withAlphaComponent(to))?.draw(in: rect, angle: 90)
                return true
            }
            return image
        }
        let side: CGFloat = pattern == .dots ? 6 : 7
        let px = Int(side * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let s = CGFloat(px)
        color.withAlphaComponent(dark ? 0.2 : 0.16).setFill()
        NSRect(x: 0, y: 0, width: s, height: s).fill()
        color.setFill()
        color.setStroke()
        switch pattern {
        case .dots:
            for c in [CGPoint(x: s * 0.25, y: s * 0.25), CGPoint(x: s * 0.75, y: s * 0.75)] {
                NSBezierPath(ovalIn: NSRect(x: c.x - scale * 1.05, y: c.y - scale * 1.05, width: scale * 2.1, height: scale * 2.1)).fill()
            }
        case .fade:
            break
        case let .hatch(index):
            let path = NSBezierPath()
            path.lineWidth = scale * 1.25
            // Rising, falling, upright, flat, then crossed: each set its own way.
            let kind = index % 5
            for k in -1...1 {
                let o = CGFloat(k) * s
                if kind == 0 || kind == 4 { path.move(to: NSPoint(x: o, y: 0)); path.line(to: NSPoint(x: o + s, y: s)) }
                if kind == 1 || kind == 4 { path.move(to: NSPoint(x: o, y: s)); path.line(to: NSPoint(x: o + s, y: 0)) }
            }
            if kind == 2 { path.move(to: NSPoint(x: s / 2, y: 0)); path.line(to: NSPoint(x: s / 2, y: s)) }
            if kind == 3 { path.move(to: NSPoint(x: 0, y: s / 2)); path.line(to: NSPoint(x: s, y: s / 2)) }
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: px, height: px))
        image.addRepresentation(rep)
        return image
    }
}

private extension NSColor {
    var hexKey: String {
        guard let c = usingColorSpace(.sRGB) else { return description }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
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
    let width: CGFloat

    // The note's ink and its shades, as Palette has them.
    private var ink: Color { dark ? Color(hex: 0xE7E3DC) : Color(hex: 0x2A2826) }
    /// Axis titles and the legend, as quoted text is.
    private var labelInk: Color { ink.opacity(0.78) }
    /// Numbers along the axes, in the app's secondary text color.
    private var secondary: Color { ink.opacity(0.56) }
    private var gridColor: Color { ink.opacity(dark ? 0.08 : 0.07) }
    private var axisColor: Color { ink.opacity(dark ? 0.26 : 0.22) }

    private func paint(_ c: ChartColor) -> Color { ChartPalette.color(c, style: model.style, dark: dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = model.title {
                Text(title).font(Font(ChartRender.font(15, weight: .semibold))).foregroundStyle(ink).lineLimit(1)
                    .frame(height: 22)
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
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if let y = model.yTitle {
                    Text(y).font(Font(ChartRender.font(12))).foregroundStyle(labelInk).lineLimit(1)
                        .fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(width: 15)
                }
                // Room for the top tick's label and the last one on the right.
                plot.padding(.top, 8).padding(.trailing, 14)
            }
            if let x = model.xTitle {
                Text(x).font(Font(ChartRender.font(12))).foregroundStyle(labelInk).lineLimit(1)
                    .padding(.leading, model.yTitle == nil ? 0 : 21)
            }
        }
    }

    /// What each color is, wrapped onto more rows when it won't fit on one.
    private var legend: some View {
        let items = model.legendItems
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.legendRows(width: width).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.self) { i in
                        let item = items[i]
                        HStack(spacing: 5) {
                            if item.dot, model.kind == .bar || model.kind == .pie {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(fill(item.color, item.index))
                                    .frame(width: 11, height: 11).frame(width: 18, height: 11)
                            } else if item.dot {
                                marker(item.index).frame(width: 9, height: 9).frame(width: 18, height: 10)
                                    .foregroundStyle(paint(item.color))
                            } else {
                                Path { p in
                                    p.move(to: CGPoint(x: 1, y: 5))
                                    p.addLine(to: CGPoint(x: 17, y: 5))
                                }
                                .stroke(paint(item.color),
                                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dash(item.dash, width: 2)))
                                .frame(width: 18, height: 10)
                            }
                            Text(item.name).font(Font(ChartRender.legendFont)).foregroundStyle(labelInk).lineLimit(1)
                        }
                    }
                }
                .frame(height: ChartRender.legendRowHeight)
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
                .overlay(Text(model.problems.isEmpty ? "Nothing to draw yet" : "Nothing to draw").font(.system(size: 12)).foregroundStyle(secondary))
        } else if model.kind == .pie {
            pieChart
        } else if let categories = model.categories {
            categoryChart(categories)
        } else {
            numericChart
        }
    }

    // MARK: Pies

    /// Slices in the palette's order, a hairline apart; the legend says what each is.
    private var pieChart: some View {
        let slices = model.series.first?.segments.first ?? []
        return Chart {
            ForEach(Array(slices.enumerated()), id: \.offset) { i, p in
                SectorMark(angle: .value("Value", p.y), innerRadius: .ratio(model.donut ? 0.58 : 0), angularInset: 1.5)
                    .foregroundStyle(fill(.palette(i), i))
                    .cornerRadius(3)
            }
        }
        .chartLegend(.hidden)
    }

    // MARK: Text labels along x (bar charts, labels that aren't numbers)

    private func categoryChart(_ categories: [String]) -> some View {
        Chart {
            ForEach(Array(model.series.enumerated()), id: \.offset) { i, s in
                let color = paint(.palette(s.color))
                ForEach(Array(s.segments.joined().enumerated()), id: \.offset) { _, p in
                    let label = categories.indices.contains(Int(p.x)) ? categories[Int(p.x)] : ""
                    if model.kind == .bar {
                        if model.stacked {
                            BarMark(x: .value("Label", label), y: .value("Value", p.y))
                                .foregroundStyle(fill(.palette(s.color), s.color))
                        } else {
                            // Rounded at the top, square where it stands.
                            BarMark(x: .value("Label", label), y: .value("Value", p.y))
                                .foregroundStyle(fill(.palette(s.color), s.color))
                                .position(by: .value("Series", "\(i)"))
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous))
                        }
                    } else {
                        LineMark(x: .value("Label", label), y: .value("Value", p.y), series: .value("Series", "s\(i)"))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash(model.seriesDash(s.color), width: 2)))
                        PointMark(x: .value("Label", label), y: .value("Value", p.y))
                            .foregroundStyle(color)
                            .symbol(symbol(series: s.color))
                            .symbolSize(36)
                    }
                }
            }
            ForEach(Array(model.curves.enumerated()), id: \.offset) { i, c in
                if let x = c.vertical.map({ Int($0) }), categories.indices.contains(x) {
                    RuleMark(x: .value("Label", categories[x]))
                        .foregroundStyle(paint(c.color))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash(c.dash, width: 2)))
                }
                if let y = flatY(c) {
                    RuleMark(y: .value("Value", y))
                        .foregroundStyle(paint(c.color))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash(c.dash, width: 2)))
                } else {
                    ForEach(Array(c.segments.enumerated()), id: \.offset) { j, segment in
                        ForEach(Array(segment.enumerated()), id: \.offset) { _, p in
                            let label = categories.indices.contains(Int(p.x.rounded())) ? categories[Int(p.x.rounded())] : ""
                            LineMark(x: .value("Label", label), y: .value("Value", p.y), series: .value("Series", "c\(i)-\(j)"))
                                .foregroundStyle(paint(c.color))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash(c.dash, width: 2)))
                        }
                    }
                }
            }
            ForEach(Array(model.markers.enumerated()), id: \.offset) { _, m in
                if categories.indices.contains(Int(m.point.x)) {
                    PointMark(x: .value("Label", categories[Int(m.point.x)]), y: .value("Value", m.point.y))
                        .foregroundStyle(paint(m.color))
                        .symbol(symbol(m.shape))
                        .symbolSize(64)
                }
            }
        }
        .modifier(YScale(domain: yDomain, includesZero: model.beginAtZero || model.kind == .bar))
        .chartXAxis { axis(grid: false, ticks: false) }
        .chartYAxis { axis(grid: true, leading: true) }
    }

    /// A flat line across a chart (`y = 3`): drawn edge to edge, as a rule, rather than
    /// stopping short where its samples end. Graphs draw theirs as sampled.
    private func flatY(_ c: ChartModel.Curve) -> Double? {
        guard model.kind != .graph, c.vertical == nil, c.segments.count == 1, let first = c.segments[0].first,
              c.segments[0].count >= 2, c.segments[0].allSatisfy({ $0.y == first.y }) else { return nil }
        return first.y
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
                let color = paint(.palette(s.color))
                ForEach(Array(s.segments.enumerated()), id: \.offset) { j, segment in
                    ForEach(Array(segment.enumerated()), id: \.offset) { _, p in
                        if model.kind != .scatter, model.style == .gradient, let floor = areaFloor {
                            // A wash under the line, fading to nothing at the bottom.
                            AreaMark(x: .value("x", p.x), yStart: .value("y", floor), yEnd: .value("y", p.y), series: .value("Area", "a\(i)-\(j)"))
                                .foregroundStyle(ChartPattern.paint(.fade(from: 0.28, to: 0, height: fadeHeight),
                                                                    color: ChartPalette.nsColor(.palette(s.color), style: model.style, dark: dark), dark: dark))
                        }
                        if model.kind != .scatter {
                            LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("Series", "s\(i)-\(j)"))
                                .foregroundStyle(color)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash(model.seriesDash(s.color), width: 2)))
                        }
                        PointMark(x: .value("x", p.x), y: .value("y", p.y))
                            .foregroundStyle(color)
                            .symbol(symbol(series: s.color))
                            .symbolSize(model.kind == .scatter ? 48 : 36)
                    }
                }
            }
            ForEach(Array(model.curves.enumerated()), id: \.offset) { i, c in
                let color = paint(c.color)
                if let x = c.vertical {
                    RuleMark(x: .value("x", x))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash(c.dash, width: 2)))
                }
                if let y = flatY(c) {
                    RuleMark(y: .value("y", y))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash(c.dash, width: 2)))
                } else {
                    ForEach(Array(c.segments.enumerated()), id: \.offset) { j, segment in
                        ForEach(Array(segment.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("Series", "c\(i)-\(j)"))
                                .foregroundStyle(color)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash(c.dash, width: 2)))
                        }
                    }
                }
            }
            ForEach(Array(model.markers.enumerated()), id: \.offset) { _, m in
                let color = paint(m.color)
                PointMark(x: .value("x", m.point.x), y: .value("y", m.point.y))
                    .foregroundStyle(color)
                    .symbol(symbol(m.shape))
                    .symbolSize(64)
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        if let label = m.label { Text(label).font(Font(ChartRender.font(12))).foregroundStyle(labelInk) }
                    }
            }
        }
        .modifier(XScale(domain: xDomain))
        .modifier(YScale(domain: yDomain, includesZero: model.beginAtZero))
        .chartXAxis { xAxis }
        .chartYAxis { axis(grid: model.grid, leading: true) }
        .chartOverlay { proxy in xNumbers(proxy) }
        // A range set by hand cuts off what's past it; one fitted to the data leaves a point
        // on the edge whole.
        .chartPlotStyle { $0.clipShape(Rectangle().inset(by: model.kind == .graph || model.yDomain != nil ? 0 : -8)) }
    }

    // MARK: Styles

    /// How bars and slices are filled: flat, lined, faded or stippled.
    private func fill(_ c: ChartColor, _ index: Int) -> AnyShapeStyle {
        let color = paint(c)
        switch model.style {
        case .hatched: return AnyShapeStyle(ChartPattern.paint(.hatch(index), color: ChartPalette.nsColor(c, style: model.style, dark: dark), dark: dark))
        case .dotted: return AnyShapeStyle(ChartPattern.paint(.dots, color: ChartPalette.nsColor(c, style: model.style, dark: dark), dark: dark))
        // A gradient drawn as a picture: the PDF the chart renders into keeps only a gradient's first color.
        case .gradient: return AnyShapeStyle(ChartPattern.paint(.fade(from: 1, to: dark ? 0.3 : 0.36, height: fadeHeight),
                                                                color: ChartPalette.nsColor(c, style: model.style, dark: dark), dark: dark))
        default: return AnyShapeStyle(color)
        }
    }

    /// A series' markers: a shape of its own where color alone won't tell them apart in
    /// print, open rings in the dotted style, dots otherwise.
    private func symbol(series index: Int) -> AnyChartSymbolShape {
        switch model.style {
        case .mono, .hatched:
            let shapes: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond, .pentagon]
            return AnyChartSymbolShape(shapes[index % shapes.count])
        case .dotted: return AnyChartSymbolShape(BasicChartSymbolShape.circle.strokeBorder(lineWidth: 1.6))
        default: return AnyChartSymbolShape(BasicChartSymbolShape.circle)
        }
    }

    /// The same marker for the legend.
    @ViewBuilder private func marker(_ index: Int) -> some View {
        switch model.style {
        case .mono, .hatched:
            let shapes: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond, .pentagon]
            shapes[index % shapes.count].path(in: CGRect(x: 0, y: 0, width: 9, height: 9)).fill()
        case .dotted: Circle().strokeBorder(lineWidth: 1.6)
        default: Circle()
        }
    }

    /// How far a fade runs: about the plot's height.
    private var fadeHeight: Int { Int(min(max(width * 0.5, 200), 400)) }

    /// Where a line's wash starts: the bottom of the plot, zero when the values sit well
    /// above it, as the axis then starts there too.
    private var areaFloor: Double? {
        if model.beginAtZero { return 0 }
        if let d = model.yDomain { return d.lowerBound }
        let ys = model.series.flatMap { $0.segments.flatMap { $0.map(\.y) } }
        guard let lo = ys.min(), let hi = ys.max() else { return nil }
        return lo > 0 && lo < hi * 0.5 ? 0 : lo
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

    /// Numbers (or labels) along an axis, y's to the left. Labels along x have no ticks;
    /// they sit under their bars and points.
    /// Only faint lines across, for reading values off; ticks only on a graph, as on graph paper.
    private func axis(grid: Bool, leading: Bool = false, ticks: Bool = true) -> some AxisContent {
        AxisMarks(position: leading ? .leading : .bottom) { value in
            if grid { AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(gridColor) }
            if ticks && model.kind == .graph { AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.75)).foregroundStyle(axisColor) }
            if leading {
                AxisValueLabel(horizontalSpacing: 6) {
                    if let v = value.as(Double.self) { Text(Self.number(v)).font(.system(size: 11).monospacedDigit()).foregroundStyle(secondary) }
                }
            } else {
                AxisValueLabel().font(.system(size: 11)).foregroundStyle(secondary)
            }
        }
    }

    // MARK: Numbers along x

    /// Grid lines and ticks along a numeric x, at `xTicks`. Their numbers are drawn over
    /// the chart by `xNumbers`: Swift Charts starts each at its tick rather than centering
    /// it, and drops the last one at the right edge (`/graph`'s 10). The blank label here
    /// keeps their room below the plot.
    private var xAxis: some AxisContent {
        AxisMarks(position: .bottom, values: xTicks) { _ in
            // Upright grid lines on a graph only; data reads across.
            if model.grid && model.kind == .graph {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(gridColor)
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.75)).foregroundStyle(axisColor)
            }
            AxisValueLabel { Text("0").font(.system(size: 11)).hidden() }
        }
    }

    /// The x numbers, each centered under its tick, the last one at the right edge too.
    private func xNumbers(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame {
                let plot = geo[anchor]
                ForEach(xTicks, id: \.self) { v in
                    if let x = proxy.position(forX: v) {
                        Text(Self.number(v)).font(.system(size: 11).monospacedDigit()).foregroundStyle(secondary)
                            .fixedSize()
                            .position(x: plot.minX + x, y: plot.maxY + 13)
                    }
                }
            }
        }
    }

    /// Round steps (1, 2 or 5 times a power of ten) across the x range, about one per
    /// 90 points, ends included when they fall on a step.
    private var xTicks: [Double] {
        guard let d = xDomain, d.upperBound > d.lowerBound else { return [] }
        let span = d.upperBound - d.lowerBound
        let rough = span / max(2, Double(width) / 90)
        let power = pow(10, floor(log10(rough)))
        let step = [1.0, 2, 5, 10].map { $0 * power }.first { $0 >= rough } ?? 10 * power
        let first = (d.lowerBound / step).rounded(.up), last = (d.upperBound / step).rounded(.down)
        guard last >= first, last - first < 100 else { return [] }
        // As multiples of the step, so 0.1 · 3 comes out 0.3 and not 0.30000000000000004.
        return stride(from: first, through: last, by: 1).map { ($0 * step * 1e9).rounded() / 1e9 }
    }

    /// An axis number with a real minus sign: −5.
    private static func number(_ v: Double) -> String {
        (v == 0 ? 0 : v).formatted().replacingOccurrences(of: "-", with: "−")
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
