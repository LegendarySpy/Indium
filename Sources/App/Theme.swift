import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Warm paper in light mode, soft charcoal in dark mode. Nothing saturated.
enum Palette {
    private static let ink: UInt32 = 0x2A2826
    private static let paper: UInt32 = 0xE7E3DC

    static let background = NSColor.dynamic(light: NSColor(hex: 0xFAF8F4), dark: NSColor(hex: 0x1F1E1C))
    static let surface = NSColor.dynamic(light: NSColor(hex: 0xF4F1EB), dark: NSColor(hex: 0x272624))
    static let text = NSColor.dynamic(light: NSColor(hex: ink), dark: NSColor(hex: paper))
    static let secondaryText = NSColor.dynamic(light: NSColor(hex: ink, alpha: 0.56), dark: NSColor(hex: paper, alpha: 0.56))
    static let tertiaryText = NSColor.dynamic(light: NSColor(hex: ink, alpha: 0.38), dark: NSColor(hex: paper, alpha: 0.36))
    static let syntax = NSColor.dynamic(light: NSColor(hex: ink, alpha: 0.30), dark: NSColor(hex: paper, alpha: 0.30))
    static let quoteText = NSColor.dynamic(light: NSColor(hex: ink, alpha: 0.78), dark: NSColor(hex: paper, alpha: 0.78))
    static let fill = NSColor.dynamic(light: NSColor(hex: ink, alpha: 0.045), dark: NSColor(hex: 0xFFFFFF, alpha: 0.055))
    static let hoverFill = NSColor.dynamic(light: NSColor(hex: ink, alpha: 0.07), dark: NSColor(hex: 0xFFFFFF, alpha: 0.08))
    static let separator = NSColor.dynamic(light: NSColor(hex: ink, alpha: 0.09), dark: NSColor(hex: 0xFFFFFF, alpha: 0.08))
    static let quoteBar = NSColor.dynamic(light: NSColor(hex: ink, alpha: 0.16), dark: NSColor(hex: 0xFFFFFF, alpha: 0.17))
    static let link = NSColor.dynamic(light: NSColor(hex: 0x2F5C87), dark: NSColor(hex: 0x93B7DA))
    static let linkUnderline = NSColor.dynamic(light: NSColor(hex: 0x2F5C87, alpha: 0.3), dark: NSColor(hex: 0x93B7DA, alpha: 0.35))
    static let highlight = NSColor.dynamic(light: NSColor(hex: 0xF2D16B, alpha: 0.42), dark: NSColor(hex: 0xC7A13A, alpha: 0.32))
    static let error = NSColor.dynamic(light: NSColor(hex: 0xA8452F), dark: NSColor(hex: 0xE0907C))
    static let accentRing = NSColor.dynamic(light: NSColor(hex: 0x2F5C87, alpha: 0.55), dark: NSColor(hex: 0x93B7DA, alpha: 0.6))
    static let shadow = NSColor.dynamic(light: NSColor(hex: 0x000000, alpha: 0.12), dark: NSColor(hex: 0x000000, alpha: 0.45))
}

/// Resolved fonts and metrics for one font choice at one size.
/// Everything that depends on the typography setting flows from here.
final class Typography {
    let choice: FontChoice
    let size: CGFloat
    let body: NSFont
    let code: NSFont
    private var cache: [String: NSFont] = [:]

    init(choice: FontChoice, size: CGFloat) {
        self.choice = choice
        self.size = size
        body = Typography.baseFont(choice, size: size, weight: .regular)
        code = NSFont.monospacedSystemFont(ofSize: round(size * 0.84 * 2) / 2, weight: .regular)
    }

    static var current: Typography {
        Typography(choice: AppSettings.shared.font, size: CGFloat(AppSettings.shared.textSize))
    }

    /// Extra space between wrapped lines, as a fraction of the font size.
    var lineSpacing: CGFloat {
        switch choice {
        case .sans: size * 0.52
        case .serif: size * 0.50
        case .editorial: size * 0.46
        case .mono: size * 0.56
        }
    }

    var paragraphSpacing: CGFloat { round(size * 0.3) }

    var headingKern: CGFloat { choice == .sans ? -0.25 : 0 }

    func headingSize(_ level: Int) -> CGFloat {
        let scale: [CGFloat] = [1.62, 1.34, 1.14, 1.0, 0.94, 0.88]
        return round(size * scale[min(max(level, 1), 6) - 1])
    }

    func heading(_ level: Int, italic: Bool = false) -> NSFont {
        let key = "h\(level)\(italic)"
        if let f = cache[key] { return f }
        let weight: NSFont.Weight = choice == .mono ? .bold : (level <= 2 ? .semibold : .semibold)
        var f = Typography.baseFont(choice, size: headingSize(level), weight: weight)
        if italic { f = f.adding(.italic) }
        cache[key] = f
        return f
    }

    /// Body font with bold / italic applied.
    func text(bold: Bool, italic: Bool, size: CGFloat? = nil) -> NSFont {
        let s = size ?? self.size
        let key = "t\(bold)\(italic)\(s)"
        if let f = cache[key] { return f }
        var f = Typography.baseFont(choice, size: s, weight: bold ? .bold : .regular)
        if italic { f = f.adding(.italic) }
        cache[key] = f
        return f
    }

    func codeVariant(bold: Bool, italic: Bool) -> NSFont {
        var f = bold ? NSFont.monospacedSystemFont(ofSize: code.pointSize, weight: .semibold) : code
        if italic { f = f.adding(.italic) }
        return f
    }

    func small(_ scale: CGFloat = 0.8) -> NSFont {
        text(bold: false, italic: false, size: round(size * scale))
    }

    static func baseFont(_ choice: FontChoice, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let bold = weight >= .semibold
        switch choice {
        case .sans:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .serif:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        case .editorial:
            let name = bold ? "IowanOldStyle-Bold" : "IowanOldStyle-Roman"
            if let f = NSFont(name: name, size: size) { return f }
            if let f = NSFont(name: bold ? "Charter-Bold" : "Charter-Roman", size: size) { return f }
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size * 0.94, weight: weight == .regular ? .regular : .semibold)
        }
    }
}

extension NSFont {
    func adding(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        if let f = NSFont(descriptor: d, size: pointSize), f.fontDescriptor.symbolicTraits.contains(traits) { return f }
        var f = self
        if traits.contains(.italic) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        if traits.contains(.bold) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        return f
    }

    var lineHeight: CGFloat { ceil(ascender - descender + leading) }
}
