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

/// Blurs what's behind it, most at the top and none at the bottom. Uses the private
/// CABackdropLayer and variableBlur CAFilter, adapted from Haze (MrKai77/Haze, Apache-2.0).
private final class VariableBackdropView: NSView {
    private let filter: NSObject?

    init(maxRadius: CGFloat) {
        filter = Self.makeFilter(maxRadius: maxRadius)
        super.init(frame: .zero)
        guard let type = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }
        wantsLayer = true
        let backdrop = type.init()
        layer = backdrop
        backdrop.masksToBounds = true
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(true, forKey: "allowsInPlaceFiltering")
        backdrop.setValue(true, forKey: "allowsGroupBlending")
        backdrop.setValue(true, forKey: "allowsGroupOpacity")
        backdrop.setValue(false, forKey: "allowsEdgeAntialiasing")
        backdrop.setValue(true, forKey: "disablesOccludedBackdropBlurs")
        backdrop.setValue(true, forKey: "ignoresOffscreenGroups")
        backdrop.setValue(12.0, forKey: "bleedAmount")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let filter else { return }
        layer?.filters = []
        layer?.filters = [filter]
    }

    private static func makeFilter(maxRadius: CGFloat) -> NSObject? {
        let selector = Selector(("filterWithType:"))
        guard let type = NSClassFromString("CAFilter") as AnyObject as? NSObject, type.responds(to: selector),
              let made = type.perform(selector, with: "variableBlur")?.takeUnretainedValue() as? NSObject,
              let gradient = CIFilter(name: "CILinearGradient") else { return nil }
        gradient.setValue(CIVector(x: 0, y: 100), forKey: "inputPoint0")
        gradient.setValue(CIColor.black, forKey: "inputColor0")
        gradient.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint1")
        gradient.setValue(CIColor.clear, forKey: "inputColor1")
        guard let output = gradient.outputImage,
              let mask = CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: 100, height: 100)) else { return nil }
        made.setValue(true, forKey: "inputNormalizeEdges")
        made.setValue(maxRadius, forKey: "inputRadius")
        made.setValue(mask, forKey: "inputMaskImage")
        return made
    }
}
