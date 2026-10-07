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

    private static let isQuickLook = Bundle.main.bundleURL.pathExtension == "appex"

    /// The App Group the App Store build shares with its Quick Look preview (set from the
    /// team in project.yml; empty in local test builds, which have no team).
    static let appGroup: String? = {
        #if APPSTORE
        guard let id = Bundle.main.object(forInfoDictionaryKey: "IndiumAppGroup") as? String,
              !id.isEmpty, !id.contains("$(") else { return nil }
        return id
        #else
        return nil
        #endif
    }()

    /// Where the Quick Look preview finds Indium's look. The direct-download preview reads
    /// the app's own preferences through a sandbox exception; the App Store preview reads
    /// the App Group suite the app keeps in step (or uses the defaults without one).
    private static let quickLookSuite: UserDefaults? = {
        #if APPSTORE
        return appGroup.flatMap { UserDefaults(suiteName: $0) }
        #else
        return UserDefaults(suiteName: "dev.garon.Indium")
        #endif
    }()

    /// The Quick Look preview reads the app's preferences (it can't write them).
    private let defaults = isQuickLook ? quickLookSuite ?? .standard : UserDefaults.standard

    /// Settings the Quick Look preview draws with.
    private static let sharedKeys = ["appearance", "font", "textSize", "lineWidth", "syntax", "showPageLines"]

    @Published var appearance: AppearanceSetting { didSet { save(appearance.rawValue, "appearance"); applyAppearance() } }
    @Published var font: FontChoice { didSet { save(font.rawValue, "font") } }
    @Published var textSize: Double { didSet { save(textSize, "textSize") } }
    @Published var lineWidth: LineWidth { didSet { save(lineWidth.rawValue, "lineWidth") } }
    @Published var syntax: SyntaxVisibility { didSet { save(syntax.rawValue, "syntax") } }
    @Published var spellcheck: Bool { didSet { save(spellcheck, "spellcheck") } }
    @Published var suggestIcons: Bool { didSet { save(suggestIcons, "suggestIcons") } }
    @Published var showPageLines: Bool { didSet { save(showPageLines, "showPageLines") } }
    @Published var mathShortcuts: Bool { didSet { save(mathShortcuts, "mathShortcuts") } }

    private init() {
        appearance = AppearanceSetting(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        font = FontChoice(rawValue: defaults.string(forKey: "font") ?? "") ?? .serif
        let size = defaults.double(forKey: "textSize")
        textSize = size == 0 ? 17 : min(max(size, Self.textSizes.lowerBound), Self.textSizes.upperBound)
        lineWidth = LineWidth(rawValue: defaults.string(forKey: "lineWidth") ?? "") ?? .medium
        syntax = SyntaxVisibility(rawValue: defaults.string(forKey: "syntax") ?? "") ?? .whileEditing
        spellcheck = defaults.object(forKey: "spellcheck") as? Bool ?? true
        suggestIcons = defaults.object(forKey: "suggestIcons") as? Bool ?? true
        showPageLines = defaults.bool(forKey: "showPageLines")
        mathShortcuts = defaults.object(forKey: "mathShortcuts") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        if !Self.isQuickLook, Self.appGroup != nil, Self.sharedKeys.contains(key) { Self.quickLookSuite?.set(value, forKey: key) }
    }

    /// Copies the preview's settings into the App Group suite at launch, so it matches
    /// from the first launch (including preferences carried over from the direct build).
    func shareWithQuickLook() {
        guard !Self.isQuickLook, Self.appGroup != nil, let suite = Self.quickLookSuite else { return }
        for key in Self.sharedKeys {
            if let value = defaults.object(forKey: key) { suite.set(value, forKey: key) } else { suite.removeObject(forKey: key) }
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearance.appearance
    }

    func adjustTextSize(by delta: Double) {
        textSize = min(max(textSize + delta, Self.textSizes.lowerBound), Self.textSizes.upperBound)
    }
}
