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
    private let fileURL: URL = {
        #if DEBUG
        // `-IndiumIconStore /tmp/icons.json`: test runs keep their icons out of the real store.
        if let path = UserDefaults.standard.string(forKey: "IndiumIconStore") { return URL(fileURLWithPath: path) }
        #endif
        let dir = FileManager.indiumSupport
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
        #if DEBUG
        if let stub = Stub.current { return stub.mode != .unavailable }
        #endif
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String? {
        #if DEBUG
        if let stub = Stub.current { return stub.mode == .unavailable ? "Icon suggestions need Apple Intelligence. Turn it on in System Settings." : nil }
        #endif
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case let .unavailable(reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Icon suggestions need Apple Intelligence. Turn it on in System Settings."
            case .deviceNotEligible: return "Icon suggestions need Apple Intelligence, which this Mac doesn't support."
            case .modelNotReady: return "Apple Intelligence is still getting ready. Try again in a little while."
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        }
    }

    // MARK: Lookup

    func icon(for url: URL, in workspace: Workspace?) -> String? {
        guard let workspace else { return nil }
        return store[workspace.root.path]?[workspace.relativePath(url)]
    }

    /// Sets (or clears) a note's icon. This is a deliberate choice, so a suggestion
    /// still running for the note is dropped: its late answer never overrides this.
    func set(_ symbol: String?, for url: URL, in workspace: Workspace) {
        cancelSuggestion(for: url)
        save(symbol, for: url, in: workspace)
    }

    private func save(_ symbol: String?, for url: URL, in workspace: Workspace) {
        store[workspace.root.path, default: [:]][workspace.relativePath(url)] = symbol
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

    func moved(from: URL, to: URL, in workspace: Workspace) {
        // A suggestion for the old name would land on a path that no longer exists.
        let oldPath = Self.key(from).path
        for key in requests.keys where key.path == oldPath || key.path.hasPrefix(oldPath + "/") { cancelSuggestion(for: key) }
        let old = workspace.relativePath(from), new = workspace.relativePath(to)
        guard var vault = store[workspace.root.path] else { return }
        for (key, value) in vault where key == old || key.hasPrefix(old + "/") {
            vault.removeValue(forKey: key)
            vault[new + key.dropFirst(old.count)] = value
        }
        store[workspace.root.path] = vault
        persist()
    }

    /// Adds icons from another copy of the store (the direct-download build's), keeping
    /// every icon already chosen here. Returns how many were added once they're saved;
    /// if saving fails, nothing changes and the error says why.
    func merge(_ other: [String: [String: String]]) throws -> Int {
        let before = store
        var added: [URL] = []
        for (vault, icons) in other {
            for (note, symbol) in icons where store[vault]?[note] == nil {
                store[vault, default: [:]][note] = symbol
                added.append(URL(fileURLWithPath: vault).appendingPathComponent(note))
            }
        }
        guard !added.isEmpty else { return 0 }
        do {
            try write()
        } catch {
            store = before
            throw error
        }
        for url in added { NotificationCenter.default.post(name: Self.didChange, object: url) }
        return added.count
    }

    private func persist() { try? write() }

    private func write() throws {
        #if DEBUG
        // `-IndiumFailIconWrites YES`: the store can't be saved.
        if UserDefaults.standard.bool(forKey: "IndiumFailIconWrites") { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: fileURL.path]) }
        #endif
        try JSONEncoder().encode(store).write(to: fileURL, options: .atomic)
    }

    // MARK: Suggestion state

    /// What an asked-for suggestion is doing. Only requests someone asked for (the
    /// picker's Suggest, the sidebar's Suggest New Icon) get a state; the automatic
    /// background pass stays silent.
    enum Suggestion: Equatable {
        case idle
        case suggesting
        /// The model picked a different icon, now applied.
        case changed(String)
        /// The model picked the icon the note already had.
        case unchanged(String)
        case failed(Failure)
    }

    enum Failure: Error, Equatable {
        /// Apple Intelligence is off, unsupported, or not ready; the message says which.
        case unavailable(String)
        case tooShort
        /// The note's frontmatter `icon:` decides.
        case frontmatter(String)
        /// The model couldn't answer; worth trying again.
        case model(String)

        var message: String {
            switch self {
            case let .unavailable(reason): return reason
            case .tooShort: return "Write a little more first. Suggestions need at least \(NoteIcons.minimumLength) characters."
            case let .frontmatter(symbol): return "This note's frontmatter sets its icon (icon: \(symbol)). Change it there."
            case let .model(message): return message
            }
        }

        var canRetry: Bool {
            if case .model = self { return true }
            return false
        }
    }

    /// Posted with the note's standardized URL whenever an asked-for suggestion changes state.
    static let suggestionDidChange = Notification.Name("IndiumNoteIconSuggestionDidChange")
    static let minimumLength = 24

    private struct Request {
        let id: UUID
        /// Someone asked for it, so it reports progress and errors.
        let forced: Bool
        let task: Task<Void, Never>
    }

    /// Keyed by the note's full standardized URL, so the same relative name in two
    /// vaults is two different notes.
    private var requests: [URL: Request] = [:]
    private var states: [URL: Suggestion] = [:]
    /// Notes whose asked-for suggestion failed, so Try Again can ask again.
    private var retryable: [URL: WeakWorkspace] = [:]
    private struct WeakWorkspace { weak var value: Workspace? }

    static func key(_ url: URL) -> URL { url.standardizedFileURL }

    func suggestion(for url: URL) -> Suggestion { states[Self.key(url)] ?? .idle }

    private func setState(_ state: Suggestion, for url: URL) {
        let key = Self.key(url)
        states[key] = state
        NotificationCenter.default.post(name: Self.suggestionDidChange, object: key)
    }

    /// Drops a running suggestion for the note, quietly.
    func cancelSuggestion(for url: URL) {
        let key = Self.key(url)
        retryable.removeValue(forKey: key)
        guard let request = requests.removeValue(forKey: key) else { return }
        request.task.cancel()
        if request.forced { setState(.idle, for: key) }
    }

    /// Asks again after a failure, with the note as it is now (the editor saves within a moment).
    func retry(for url: URL) {
        guard let workspace = retryable[Self.key(url)]?.value, let text = try? Note.read(url) else { return }
        suggest(for: url, text: text, in: workspace, force: true)
    }

    // MARK: Suggestion

    /// Picks an icon for a note that doesn't have one yet. With `force` (someone asked),
    /// it always asks the model and reports progress and the outcome through
    /// `suggestion(for:)` and `suggestionDidChange`; without it, it stays silent.
    @discardableResult
    func suggest(for url: URL, text: String, in workspace: Workspace, force: Bool = false) -> Suggestion {
        let key = Self.key(url)
        if let own = Self.frontmatterIcon(text) {
            // The note's own icon wins even when it matches the stored one: a suggestion
            // still running must not land on top of it later.
            cancelSuggestion(for: key)
            if icon(for: url, in: workspace) != own { save(own, for: url, in: workspace) }
            if force { setState(.failed(.frontmatter(own)), for: key) }
            return suggestion(for: key)
        }
        if let running = requests[key] {
            // Asking again while it's thinking changes nothing; asking takes over a quiet
            // background request so its progress shows.
            if running.forced || !force { return suggestion(for: key) }
            cancelSuggestion(for: key)
        }
        guard force || AppSettings.shared.suggestIcons else { return .idle }
        guard Self.isAvailable else {
            if force { setState(.failed(.unavailable(Self.unavailableReason ?? "Apple Intelligence isn't available right now.")), for: key) }
            return suggestion(for: key)
        }
        guard force || icon(for: url, in: workspace) == nil else { return .idle }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= Self.minimumLength else {
            if force { setState(.failed(.tooShort), for: key) }
            return suggestion(for: key)
        }
        retryable.removeValue(forKey: key)
        let title = url.deletingPathExtension().lastPathComponent
        let opening = Self.digest(body)
        let current = icon(for: url, in: workspace)
        let id = UUID()
        let task = Task.detached(priority: force ? .userInitiated : .utility) {
            let result: Result<String, Failure>
            do {
                result = .success(try await Self.ask(title: title, opening: opening, current: current))
            } catch {
                result = .failure(.model(Self.describe(error)))
            }
            await MainActor.run { self.finish(id: id, url: url, workspace: workspace, current: current, result: result) }
        }
        requests[key] = Request(id: id, forced: force, task: task)
        if force { setState(.suggesting, for: key) }
        return suggestion(for: key)
    }

    private func finish(id: UUID, url: URL, workspace: Workspace, current: String?, result: Result<String, Failure>) {
        let key = Self.key(url)
        // Superseded: a manual pick, a rename, or a newer request owns the note now.
        guard let request = requests[key], request.id == id else { return }
        requests.removeValue(forKey: key)
        switch result {
        case let .success(symbol) where NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil:
            let same = symbol == (current ?? "doc.text")
            // A first pick is kept even when it's the default look, so it isn't asked for again.
            if !same || current == nil { save(symbol, for: url, in: workspace) }
            if request.forced { setState(same ? .unchanged(symbol) : .changed(symbol), for: key) }
        case .success:
            fail(.model("Couldn't suggest an icon."))
        case let .failure(failure):
            fail(failure)
        }
        func fail(_ failure: Failure) {
            guard request.forced else { return }
            retryable[key] = WeakWorkspace(value: workspace)
            setState(.failed(failure), for: key)
        }
    }

    private struct ModelError: Error {}

    private static func ask(title: String, opening: String, current: String?) async throws -> String {
        #if DEBUG
        if let stub = Stub.current { return try await stub.answer(current: current) }
        #endif
        let session = LanguageModelSession(instructions: """
            You choose one SF Symbol for a personal note. Judge by the note's subject matter \
            (for example chemistry, a trip, a recipe, money, a workout), never by its formatting: \
            lists, tables, and headings say nothing about the subject. Prefer the most specific \
            symbol for that subject. Only answer with one of the allowed symbols.
            """)
        let pick = try await session.respond(to: "Note title: \(title)\n\nNote:\n\(opening)", generating: Pick.self,
                                             options: GenerationOptions(temperature: 0.2))
        return pick.content.symbol
    }

    /// Model errors in plain words.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else { return "Couldn't suggest an icon." }
        switch error {
        case .guardrailViolation, .refusal: return "Apple Intelligence wouldn't suggest an icon for this note."
        case .assetsUnavailable: return "Apple Intelligence is still getting ready. Try again in a little while."
        case .rateLimited, .concurrentRequests: return "Apple Intelligence is busy. Try again in a moment."
        case .unsupportedLanguageOrLocale: return "Apple Intelligence doesn't support this note's language yet."
        default: return "Couldn't suggest an icon."
        }
    }

    #if DEBUG
    /// `-IndiumIconStub success:star|same|fail|unavailable|slow[:star]` stands in for the
    /// model so every state can be exercised without Apple Intelligence.
    /// `-IndiumIconStubDelay 2` sets how long it "thinks" (default 1s, slow 4s).
    struct Stub {
        enum Mode { case success, same, fail, unavailable, slow }
        let mode: Mode
        let symbol: String

        static let current: Stub? = {
            guard let spec = UserDefaults.standard.string(forKey: "IndiumIconStub") else { return nil }
            let parts = spec.split(separator: ":").map(String.init)
            let modes: [String: Mode] = ["success": .success, "same": .same, "fail": .fail, "unavailable": .unavailable, "slow": .slow]
            guard let first = parts.first, let mode = modes[first] else { return nil }
            return Stub(mode: mode, symbol: parts.count > 1 ? parts[1] : "star")
        }()

        func answer(current: String?) async throws -> String {
            print("  STUB asked (\(mode)), current icon:", current ?? "nil")
            let d = UserDefaults.standard
            let delay = d.object(forKey: "IndiumIconStubDelay") != nil ? d.double(forKey: "IndiumIconStubDelay") : (mode == .slow ? 4 : 1)
            try? await Task.sleep(for: .seconds(delay))
            switch mode {
            case .fail: throw ModelError()
            case .same: return current ?? "doc.text"
            default: return symbol
            }
        }
    }
    #endif

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

extension FileManager {
    /// Indium's folder in Application Support. Debug builds keep their own, so test runs
    /// never touch the icons and shortcuts of the Indium you use.
    static var indiumSupport: URL {
        #if DEBUG
        let name = "Indium Debug"
        #else
        let name = "Indium"
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
    }
}
