import AppKit
import SwiftMath

/// A typeset equation. Drawn directly with Core Graphics so it stays vector
/// in the editor, when printing, and in exported PDFs.
final class MathRender {
    let display: MTMathListDisplay
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    var height: CGFloat { ascent + descent }

    init(display: MTMathListDisplay) {
        self.display = display
        width = ceil(display.width)
        ascent = ceil(display.ascent)
        descent = ceil(display.descent)
    }

    /// Draws with the baseline at `point` in a flipped (AppKit view) coordinate space.
    func draw(baselineAt point: NSPoint, color: NSColor, scale: CGFloat = 1, flippedContext: Bool = true) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let resolved = color.usingColorSpace(.sRGB) ?? color
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.scaleBy(x: scale, y: flippedContext ? -scale : scale)
        ctx.textMatrix = .identity
        display.draw(in: ctx, baseline: .zero, color: resolved)
        ctx.restoreGState()
    }
}

enum MathRenderer {
    private final class Entry {
        let render: MathRender?
        init(_ r: MathRender?) { render = r }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 600
        return c
    }()

    /// Returns nil when the LaTeX cannot be parsed; callers then show the source.
    static func render(_ latex: String, size: CGFloat, display: Bool) -> MathRender? {
        let key = "\(display ? "D" : "T")\(size)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.render }
        // The typesetter's style argument doesn't reach every path; state it in the source.
        let source = (display ? "" : "\\textstyle ") + normalize(latex)
        var result: MathRender?
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let d = MathTypesetting.display(latex: source, fontSize: size, displayStyle: display) {
            result = MathRender(display: d)
        }
        cache.setObject(Entry(result), forKey: key)
        return result
    }

    /// Maps common MathJax / Obsidian environments onto what the typesetter knows,
    /// without touching the source stored in the file.
    static func normalize(_ latex: String) -> String {
        var s = latex
        let envMap = [
            "align*": "aligned", "align": "aligned", "alignat*": "aligned", "alignat": "aligned",
            "eqnarray*": "aligned", "eqnarray": "aligned", "flalign*": "aligned", "flalign": "aligned",
            "gather*": "gather", "gathered": "gather", "multline*": "gather", "multline": "gather",
        ]
        for (from, to) in envMap {
            s = s.replacingOccurrences(of: "\\begin{\(from)}", with: "\\begin{\(to)}")
            s = s.replacingOccurrences(of: "\\end{\(from)}", with: "\\end{\(to)}")
        }
        for env in ["equation*", "equation", "displaymath"] {
            s = s.replacingOccurrences(of: "\\begin{\(env)}", with: "")
            s = s.replacingOccurrences(of: "\\end{\(env)}", with: "")
        }
        // Column specs of array are layout hints the typesetter doesn't need.
        s = s.replacingOccurrences(of: #"\\begin\{array\}\{[^}]*\}"#, with: "\\\\begin{matrix}", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\end{array}", with: "\\end{matrix}")
        s = s.replacingOccurrences(of: #"\\(?:tag\*?|label)\{[^}]*\}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(?:nonumber|notag)\b"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\\\\[[^\]]*\]"#, with: "\\\\\\\\", options: .regularExpression)
        return s
    }
}
