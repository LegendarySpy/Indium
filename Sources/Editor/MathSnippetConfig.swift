import AppKit

/// Your own math shortcuts, from `.indium/snippets.json` in the open folder (so they travel
/// with the notes, as Obsidian's settings travel in `.obsidian`), or from Indium's folder in
/// Application Support when no folder is open.
///
/// The file is a list in LaTeX Suite's own format, so snippets can be pasted straight from
/// Obsidian (or the whole of LaTeX Suite's `data.json` used as it is):
///
///     [
///         {trigger: "ce", replacement: "\\mathrm{$0}$1", options: "mA"},
///         {trigger: /([A-Z][a-z]?)(\d)/, replacement: "[[0]]_{[[1]]}", options: "rmA", priority: 1},
///     ]
///
/// Strict JSON works too. Options: `m` math, `M` display math, `n` inline math, `t` text
/// (none: everywhere), `A` as you type (otherwise on Tab), `r` regex, `w` whole word.
/// Function replacements and visual (`v`) snippets need LaTeX Suite's JavaScript and are
/// skipped with a note. A file that can't be read leaves the built-in shortcuts as they are.
final class MathSnippetConfig: NSObject {
    static let shared = MathSnippetConfig()

    /// What was wrong with the file when it was last read, one line per problem.
    private(set) var problems: [String] = []
    private(set) var loadedCount = 0
    /// Set by the debug harness to read another file.
    var overrideURL: URL?
    private var stamp: (url: URL, modified: Date?)?
    private var checkedAt = Date.distantPast
    /// The problems last shown, so the same ones aren't shown twice.
    private var reported: [String] = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    var url: URL {
        if let overrideURL { return overrideURL }
        if let root = AppDelegate.shared.workspace?.root {
            return root.appendingPathComponent(".indium", isDirectory: true).appendingPathComponent("snippets.json")
        }
        return FileManager.indiumSupport.appendingPathComponent("snippets.json")
    }

    /// Reads the file again if it changed (looked at no more than once a second while typing).
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(checkedAt) > 1 else { return }
        checkedAt = Date()
        let url = self.url
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || stamp?.url != url || stamp?.modified != modified else { return }
        stamp = (url, modified)
        guard modified != nil, let text = try? String(contentsOf: url, encoding: .utf8) else {
            MathSnippet.custom = []
            problems = []
            loadedCount = 0
            return
        }
        let result = Self.parse(text)
        MathSnippet.custom = result.snippets
        loadedCount = result.snippets.count
        problems = result.problems
    }

    /// Back from editing the file: say what's wrong with it, once.
    @objc private func appBecameActive() {
        refresh(force: true)
        guard overrideURL == nil, !problems.isEmpty, problems != reported else {
            if problems.isEmpty { reported = [] }
            return
        }
        reported = problems
        showProblems()
    }

    private func showProblems() {
        let alert = NSAlert()
        alert.messageText = problems.count == 1 ? "A math shortcut couldn't be used" : "\(problems.count) math shortcuts couldn't be used"
        alert.informativeText = problems.prefix(8).joined(separator: "\n") + (problems.count > 8 ? "\n…" : "")
            + "\n\nThe built-in shortcuts and the rest of yours work as usual."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Edit Math Shortcuts…")
        if alert.runModal() == .alertSecondButtonReturn { editMathShortcuts(nil) }
    }

    // MARK: Menu

    /// Opens the file in the app that edits JSON (TextEdit if none), creating it first.
    @objc func editMathShortcuts(_ sender: Any?) {
        if let problem = prepareFile() {
            report("Indium couldn't create your math shortcuts file", problem)
            return
        }
        let url = self.url
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        guard let app else {
            report("No app can open your math shortcuts file", "Open \(url.path) in a text editor.")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self.report("Indium couldn't open your math shortcuts file", "\(url.path)\n\n\(error.localizedDescription)")
            }
        }
    }

    /// Creates the file (and its folder) from the template if it isn't there yet.
    /// Returns what went wrong, if anything.
    func prepareFile() -> String? {
        let url = self.url
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.template.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "\(url.path)\n\n\(error.localizedDescription)"
        }
    }

    private func report(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// Every shortcut, built-in and yours, in a new temporary note.
    @objc func showMathShortcuts(_ sender: Any?) {
        refresh(force: true)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        AppDelegate.shared.newTemporaryNote(nil)
        guard let window = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) }),
              let controller = window.windowController as? DocumentWindowController else { return }
        controller.editor.textView.insertText(reference, replacementRange: NSRange(location: 0, length: 0))
        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.editor.textView.scrollToBeginningOfDocument(nil)
    }

    static let template = """
    [
        // Your math shortcuts, in Obsidian LaTeX Suite's format: paste snippets from its
        // settings (or its whole data.json) here. Format ▸ Math Shortcuts lists them all.
        //
        // options: m math, M display math, n inline math, t text (none: everywhere),
        //          A as you type (otherwise on Tab), r regex, w whole word.
        // replacement: $0, $1… are blanks Tab moves through; ${1:text} starts selected;
        //              [[0]], [[1]]… are a regex's groups. priority: higher wins.
        //
        // {trigger: "ce", replacement: "\\\\mathrm{$0}$1", options: "mA"},
        // {trigger: /([A-Z][a-z]?)(\\d)/, replacement: "[[0]]_{[[1]]}", options: "rmA", priority: 1},
    ]

    """

    // MARK: Reference

    /// The shortcut list as a note.
    var reference: String {
        // (Pipes stay as they are: a table row isn't split inside a code span.)
        func code(_ s: String) -> String {
            var flat = s.replacingOccurrences(of: "\n", with: "↵")
            if flat.count > 48 { flat = String(flat.prefix(47)) + "…" }
            let ticks = flat.contains("`") ? "``" : "`"
            return ticks + (ticks.count > 1 ? " " : "") + flat + (ticks.count > 1 ? " " : "") + ticks
        }
        func row(_ s: MathSnippet) -> String {
            var where_: [String] = []
            if s.text { where_.append("text") }
            if s.math { where_.append(s.displayOnly ? "display math" : s.inlineOnly ? "inline math" : "math") }
            let trigger: String
            if case .regex = s.trigger { trigger = code(s.written) + " (regex)" } else { trigger = code(s.written) }
            let replacement = s.compute != nil ? "(worked out from what's typed)" : code(s.replacement)
            return "| " + [trigger, replacement, where_.joined(separator: ", "), s.auto ? "auto" : "Tab"].joined(separator: " | ") + " |"
        }
        let head = "| Type | Becomes | Where | Expands |\n| --- | --- | --- | --- |"
        var out = "# Math Shortcuts\n\n"
        out += "Shortcuts as in Obsidian's LaTeX Suite: *auto* ones expand as you type, the others on Tab. In the replacements, `$0`, `$1`… are the blanks Tab moves through and `[[0]]`, `[[1]]`… what a regex trigger matched. "
        out += "`/` after a term makes a fraction of it, Tab leaves a bracket or the equation, and in a table cell bars are written `\\lvert`, `\\rvert`, `\\mid` so they can't split the row.\n\n"
        out += "Not supported: mhchem's `\\ce{…}` and `\\pu{…}` don't typeset. Write formulas with subscripts instead: `$CuSO_{4}\\cdot 5H_{2}O$`.\n\n"
        out += "## Yours\n\n"
        out += "From `\(url.path)` (Format ▸ Edit Math Shortcuts…). A shortcut of yours wins over a built-in with the same trigger and priority.\n\n"
        if !problems.isEmpty {
            out += "Couldn't be used:\n\n" + problems.map { "- " + $0.replacingOccurrences(of: "`", with: "'") }.joined(separator: "\n") + "\n\n"
        }
        out += MathSnippet.custom.isEmpty ? "None yet.\n\n" : head + "\n" + MathSnippet.custom.map(row).joined(separator: "\n") + "\n\n"
        out += "## Built in\n\n" + head + "\n" + MathSnippet.all.map(row).joined(separator: "\n") + "\n"
        return out
    }
}
