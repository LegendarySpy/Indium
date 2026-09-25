import AppKit
import Combine

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable {
    case sans, serif, editorial, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        case .editorial: "Editorial"
        case .mono: "Mono"
        }
    }
}

enum LineWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .narrow: "Narrow"
        case .medium: "Medium"
        case .wide: "Wide"
        }
    }
    var points: CGFloat {
        switch self {
        case .narrow: 620
        case .medium: 700
        case .wide: 780
        }
    }
}

enum SyntaxVisibility: String, CaseIterable, Identifiable {
    case whileEditing, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whileEditing: "While Editing"
        case .always: "Always"
        }
    }
}

/// The whole preference surface of the app. Deliberately tiny.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let textSizes: ClosedRange<Double> = 14...22

    private let defaults = UserDefaults.standard

    @Published var appearance: AppearanceSetting { didSet { save(appearance.rawValue, "appearance"); applyAppearance() } }
    @Published var font: FontChoice { didSet { save(font.rawValue, "font") } }
    @Published var textSize: Double { didSet { save(textSize, "textSize") } }
    @Published var lineWidth: LineWidth { didSet { save(lineWidth.rawValue, "lineWidth") } }
    @Published var syntax: SyntaxVisibility { didSet { save(syntax.rawValue, "syntax") } }
    @Published var spellcheck: Bool { didSet { save(spellcheck, "spellcheck") } }
    @Published var suggestIcons: Bool { didSet { save(suggestIcons, "suggestIcons") } }

    private init() {
        appearance = AppearanceSetting(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        font = FontChoice(rawValue: defaults.string(forKey: "font") ?? "") ?? .serif
        let size = defaults.double(forKey: "textSize")
        textSize = size == 0 ? 17 : min(max(size, Self.textSizes.lowerBound), Self.textSizes.upperBound)
        lineWidth = LineWidth(rawValue: defaults.string(forKey: "lineWidth") ?? "") ?? .medium
        syntax = SyntaxVisibility(rawValue: defaults.string(forKey: "syntax") ?? "") ?? .whileEditing
        spellcheck = defaults.object(forKey: "spellcheck") as? Bool ?? true
        suggestIcons = defaults.object(forKey: "suggestIcons") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func applyAppearance() {
        NSApp.appearance = appearance.appearance
    }

    func adjustTextSize(by delta: Double) {
        textSize = min(max(textSize + delta, Self.textSizes.lowerBound), Self.textSizes.upperBound)
    }
}
