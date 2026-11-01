import AppKit

/// Liquid Glass surfaces for the few transient panels.
enum Glass {
    static func make(cornerRadius: CGFloat, content: NSView, interactive: Bool = false) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        // The interactive glass response is a macOS 27 SDK addition; older SDKs (CI) skip it.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
        #endif
        return glass
    }
}

/// A progressive blur under the title bar, with a light wash so the controls stay readable.
final class ScrollEdgeBlurView: NSView {
    static let height: CGFloat = TitleBarView.height + 12
    private let backdrop = VariableBackdropView(maxRadius: 8)
    private let washView = NSView()
    private let wash = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(backdrop)
        washView.wantsLayer = true
        washView.layer?.addSublayer(wash)
        addSubview(washView)
        wash.startPoint = CGPoint(x: 0.5, y: 1)
        wash.endPoint = CGPoint(x: 0.5, y: 0)
        wash.locations = [0, 0.4, 1]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        washView.frame = bounds
        wash.frame = bounds
        updateWash()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateWash()
    }

    private func updateWash() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.colors = [0.6, 0.3, 0].map { Palette.background.withAlphaComponent($0).cgColor }
        }
    }
}

/// Blurs what's behind it, most at the top and none at the bottom, using the private
/// CABackdropLayer and variableBlur filter. Without them it draws nothing.
private final class VariableBackdropView: NSView {
    init(maxRadius: CGFloat) {
        super.init(frame: .zero)
        guard let layerType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filter = Self.makeFilter(maxRadius: maxRadius) else { return }
        wantsLayer = true
        layer = layerType.init()
        layer?.filters = [filter]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func makeFilter(maxRadius: CGFloat) -> NSObject? {
        let create = Selector(("filterWithType:"))
        guard let filterType = NSClassFromString("CAFilter") as AnyObject as? NSObject, filterType.responds(to: create),
              let filter = filterType.perform(create, with: "variableBlur")?.takeUnretainedValue() as? NSObject,
              let gradient = CIFilter(name: "CILinearGradient") else { return nil }
        gradient.setValue(CIVector(x: 0, y: 100), forKey: "inputPoint0")
        gradient.setValue(CIColor.black, forKey: "inputColor0")
        gradient.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint1")
        gradient.setValue(CIColor.clear, forKey: "inputColor1")
        guard let ramp = gradient.outputImage,
              let mask = CIContext().createCGImage(ramp, from: CGRect(x: 0, y: 0, width: 1, height: 100)) else { return nil }
        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue(maxRadius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        return filter
    }
}
