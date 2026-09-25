import AppKit
import FoundationModels

/// Per-note SF Symbols, suggested on device by Apple Intelligence.
///
/// Icons are stored by Indium (Application Support), never written into notes.
/// A note's own frontmatter `icon:` (an SF Symbol name) always wins.
final class NoteIcons {
    static let shared = NoteIcons()
    static let didChange = Notification.Name("IndiumNoteIconsDidChange")

    /// Curated so every choice looks deliberate at small sizes.
    static let palette: [String] = [
        "doc.text", "text.book.closed", "book", "books.vertical", "graduationcap", "lightbulb", "brain",
        "flask", "testtube.2", "atom", "function", "sum", "chart.bar", "chart.line.uptrend.xyaxis", "chart.pie",
        "list.bullet", "checklist", "calendar", "clock", "alarm", "person", "person.2", "briefcase", "building.2",
        "house", "cart", "fork.knife", "cup.and.saucer", "airplane", "car", "map", "globe.americas", "leaf",
        "tree", "sun.max", "moon", "cloud", "drop", "flame", "bolt", "heart", "cross.case", "pills",
        "figure.run", "dumbbell", "music.note", "headphones", "camera", "film", "paintbrush", "paintpalette",
        "pencil.and.outline", "quote.bubble", "envelope", "phone", "newspaper", "hammer", "wrench.and.screwdriver",
        "gearshape", "cpu", "terminal", "chevron.left.forwardslash.chevron.right", "server.rack", "lock",
        "dollarsign.circle", "creditcard", "banknote", "gift", "tag", "flag", "target", "star", "sparkles",
        "puzzlepiece", "gamecontroller", "archivebox", "tray", "signature", "scroll",
    ]

    @Generable
    struct Pick {
        @Guide(description: "The SF Symbol that best represents the note", .anyOf(NoteIcons.palette))
        var symbol: String
    }

    private var store: [String: [String: String]] = [:]
    private var inFlight = Set<String>()
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Indium")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("icons.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            store = decoded
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case let .unavailable(reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to use this."
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .modelNotReady: return "Apple Intelligence is still getting ready."
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        }
    }

    // MARK: Lookup

    func icon(for url: URL, in workspace: Workspace?) -> String? {
        guard let workspace else { return nil }
        return store[workspace.root.path]?[workspace.relativePath(url)]
    }

    func set(_ symbol: String?, for url: URL, in workspace: Workspace) {
        store[workspace.root.path, default: [:]][workspace.relativePath(url)] = symbol
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

    func moved(from: URL, to: URL, in workspace: Workspace) {
        let old = workspace.relativePath(from), new = workspace.relativePath(to)
        guard var vault = store[workspace.root.path] else { return }
        for (key, value) in vault where key == old || key.hasPrefix(old + "/") {
            vault.removeValue(forKey: key)
            vault[new + key.dropFirst(old.count)] = value
        }
        store[workspace.root.path] = vault
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: Suggestion

    /// Picks an icon for a note that doesn't have one yet (or when `force` is set).
    func suggest(for url: URL, text: String, in workspace: Workspace, force: Bool = false) {
        let key = workspace.relativePath(url)
        if let own = Self.frontmatterIcon(text) {
            if icon(for: url, in: workspace) != own { set(own, for: url, in: workspace) }
            return
        }
        guard AppSettings.shared.suggestIcons, Self.isAvailable, !inFlight.contains(key) else { return }
        guard force || icon(for: url, in: workspace) == nil else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 24 else { return }
        inFlight.insert(key)
        let title = url.deletingPathExtension().lastPathComponent
        let opening = Self.digest(body)
        Task.detached(priority: .utility) {
            let session = LanguageModelSession(instructions: """
                You choose one SF Symbol for a personal note. Judge by the note's subject matter \
                (for example chemistry, a trip, a recipe, money, a workout), never by its formatting: \
                lists, tables, and headings say nothing about the subject. Prefer the most specific \
                symbol for that subject. Only answer with one of the allowed symbols.
                """)
            let pick = try? await session.respond(to: "Note title: \(title)\n\nNote:\n\(opening)", generating: Pick.self,
                                                  options: GenerationOptions(temperature: 0.2))
            await MainActor.run {
                self.inFlight.remove(key)
                guard let symbol = pick?.content.symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else { return }
                self.set(symbol, for: url, in: workspace)
            }
        }
    }

    /// Fills in icons for notes that don't have one, a few at a time.
    func backfill(_ workspace: Workspace) {
        guard AppSettings.shared.suggestIcons, Self.isAvailable else { return }
        if workspace.isScanning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.backfill(workspace) }
            return
        }
        let missing = Array(workspace.notes.filter { icon(for: $0, in: workspace) == nil }.prefix(40))
        // Off the main thread, and only notes already on this Mac: reading one that
        // iCloud hasn't downloaded would fetch it just to pick an icon.
        DispatchQueue.global(qos: .utility).async {
            var texts: [(URL, String)] = []
            for url in missing {
                let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                if let status, status != .current { continue }
                if let text = try? Note.read(url) { texts.append((url, text)) }
            }
            DispatchQueue.main.async {
                for (url, text) in texts { self.suggest(for: url, text: text, in: workspace) }
            }
        }
    }

    /// Headings and the first prose, without Markdown noise: what the note is about.
    static func digest(_ text: String) -> String {
        var headings: [String] = []
        var prose: [String] = []
        var inFence = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("$$") { inFence.toggle(); continue }
            if inFence || line.hasPrefix("|") || line.hasPrefix("---") || line.hasPrefix("<!--") { continue }
            if line.hasPrefix("#") {
                headings.append(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
            } else if !line.isEmpty, prose.joined().count < 500 {
                prose.append(line.replacingOccurrences(of: #"[*_`>\[\]]"#, with: "", options: .regularExpression))
            }
        }
        return "Headings: " + headings.prefix(12).joined(separator: "; ") + "\n\nText: " + prose.joined(separator: " ").prefix(600)
    }

    static func frontmatterIcon(_ text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().prefix(40) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { break }
            if t.lowercased().hasPrefix("icon:") {
                let value = t.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if NSImage(systemSymbolName: value, accessibilityDescription: nil) != nil { return value }
            }
        }
        return nil
    }
}
