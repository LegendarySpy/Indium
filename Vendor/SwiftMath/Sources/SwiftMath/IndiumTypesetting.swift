import CoreGraphics
import Foundation

/// Public entry point used by Indium: typeset LaTeX into a drawable display list
/// without going through a view or a rasterized image, so output stays vector.
public enum MathTypesetting {
    public static func display(latex: String, fontSize: CGFloat, displayStyle: Bool) -> MTMathListDisplay? {
        var error: NSError?
        guard let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil else { return nil }
        let font = MathFont.latinModernFont.mtfont(size: fontSize)
        return MTTypesetter.createLineForMathList(list, font: font, style: displayStyle ? .display : .text)
    }
}

public extension MTMathListDisplay {
    /// Draws with the baseline at `baseline` in a y-up (Core Text) coordinate space.
    func draw(in context: CGContext, baseline: CGPoint, color: MTColor) {
        textColor = color
        position = baseline
        draw(context)
    }
}
