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
