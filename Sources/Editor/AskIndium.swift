import AppKit
import FoundationModels

// Ask Indium: say what to do with the selected text ("make these chemical formulas",
// "fix the grammar", "turn this into a table", "what does this mean?") and Apple's
// on-device model does it. Its instructions know how Indium writes things (Markdown,
// $math$, tables, lists, callouts), which Siri and Writing Tools can't be told. An edit
// replaces only the selection, as one Undo; an answer shows in the panel.

enum AskModel {
    struct Reply {
        enum Kind { case edit, answer }
        var kind: Kind
        var text: String
    }

    static let instructions = """
        You help someone working on a note in Indium, a Markdown notes app. They select some \
        text and ask for something. If they want the text changed (rewritten, fixed, \
        formatted, translated, shortened, made into a list or table, continued), reply with \
        kind edit and the new text that replaces the selection. If they ask a question about \
        it, answer it briefly.

        Start your reply with one word on a line of its own: EDIT, followed by the new text \
        that replaces the selection, or ANSWER, followed by your answer.

        Write edits in Indium's Markdown:
        - Emphasis: **bold**, *italic*, ~~strikethrough~~, ==highlight==, `code`.
        - Headings start with #. Lists use "- " or "1. ", nested one tab deeper. Tasks use "- [ ] ".
        - Quotes start with "> ". Callouts start with "> [!note]" (or tip, warning, info).
        - Tables: a header row, then | --- | under each column, then one row per line.
        - Math is LaTeX between dollar signs: inline $E = mc^2$, or $$...$$ on lines of its own. \
        When the selection is part of a sentence, keep it inline with single dollar signs.
        - Subscripts and superscripts are always math: H$_2$O, x$^2$, 10$^{-3}$. Never use \
        characters like ₂ or ², and never ~x~, ^x^, <sub>, <sup> or other HTML.
        - Links are [text](url); links to other notes are [[Note name]].

        When asked to format text, change only how it's written, never what it says: keep \
        every word, letter and number, in the same order. Don't correct facts or add anything \
        unless asked. Keep everything they didn't ask to change: wording, Markdown, math, \
        links and line breaks. Answer in the language of the note. Never wrap the reply in code fences or \
        add remarks about what you did.
        """

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case let .unavailable(reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Ask Indium needs Apple Intelligence. Turn it on in System Settings."
            case .deviceNotEligible: return "Ask Indium needs Apple Intelligence, which this Mac doesn't support."
            case .modelNotReady: return "Apple Intelligence is still getting ready. Try again in a little while."
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        }
    }

    /// `before` and `after` are the text on either side of the selection, for context only.
    /// Plain text rather than structured output: inside a structured reply, LaTeX's
    /// backslashes are read as escapes, and \\frac or \\nu would arrive as control characters.
    static func ask(_ request: String, selection: String, before: String, after: String) async throws -> Reply {
        let session = LanguageModelSession(instructions: instructions)
        var prompt = "Request: \(request)\n\nSelected text:\n\(selection)"
        if !before.isEmpty || !after.isEmpty {
            prompt += "\n\nText around the selection, for context only (not part of the reply):\n\(before)[selection]\(after)"
        }
        let raw = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2)).content
        return parse(raw)
    }

    /// The reply's EDIT or ANSWER line, then its text. Without one, it's taken as an edit.
    static func parse(_ raw: String) -> Reply {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind = Reply.Kind.edit
        for (word, k) in [("EDIT", Reply.Kind.edit), ("ANSWER", .answer)] {
            if let r = text.range(of: #"^\#(word)[:,.;\-–— \t]*\n?"#, options: [.regularExpression, .caseInsensitive]) {
                kind = k
                text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        text = cleaned(text)
        if kind == .edit { text = mathScripts(text) }
        return Reply(kind: kind, text: text)
    }

    private static let subscripts: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₒₓₙ", "0123456789+-=()aeoxn"))
    private static let superscripts: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱ", "0123456789+-=()ni"))

    /// Unicode sub- and superscript characters (₂, ²) as Indium writes them, in math:
    /// H₂O as H$_2$O, x² as x$^2$. Left alone inside math and code, where they're meant.
    static func mathScripts(_ text: String) -> String {
        guard text.contains(where: { subscripts[$0] != nil || superscripts[$0] != nil }) else { return text }
        var out = ""
        var inMath = false, inCode = false
        var chars = Array(text)[...]
        while let c = chars.first {
            if c == "`" { inCode.toggle() } else if c == "$", !inCode { inMath.toggle() }
            if !inMath, !inCode, let table = subscripts[c] != nil ? subscripts : superscripts[c] != nil ? superscripts : nil {
                let run = chars.prefix { table[$0] != nil }
                let plain = String(run.map { table[$0]! })
                out += "$\(table == subscripts ? "_" : "^")\(plain.count == 1 ? plain : "{\(plain)}")$"
                chars = chars.dropFirst(run.count)
                continue
            }
            out.append(c)
            chars = chars.dropFirst()
        }
        return out
    }

    /// The reply without a code fence wrapped around all of it.
    static func cleaned(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .newlines)
        if t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 {
            t = String(t.dropFirst(3).dropLast(3))
            if let newline = t.firstIndex(of: "\n"), !t[..<newline].contains(" ") { t = String(t[t.index(after: newline)...]) }
            t = t.trimmingCharacters(in: .newlines)
        }
        return t
    }

    /// Model errors in plain words.
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "Stopped." }
        guard let error = error as? LanguageModelSession.GenerationError else { return "Something went wrong. Try again." }
        switch error {
        case .guardrailViolation, .refusal: return "Apple Intelligence wouldn't do that with this text."
        case .exceededContextWindowSize: return "That's too much text at once. Select less and try again."
        case .assetsUnavailable: return "Apple Intelligence is still getting ready. Try again in a little while."
        case .rateLimited, .concurrentRequests: return "Apple Intelligence is busy. Try again in a moment."
        case .unsupportedLanguageOrLocale: return "Apple Intelligence doesn't support this language yet."
        default: return "Something went wrong. Try again."
        }
    }
}

extension EditorController {
    /// The selection Ask Indium works on: the selected text, or with nothing selected the
    /// paragraph the caret is in. Nil on a blank line.
    func askRange() -> NSRange? {
        let sel = textView.selectedRange()
        if sel.length > 0 { return sel }
        let paragraph = (storage.string as NSString).paragraphRange(for: sel)
        var r = paragraph
        while r.length > 0, let last = (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)).first,
              last.isNewline { r.length -= 1 }
        return (storage.string as NSString).substring(with: r).trimmingCharacters(in: .whitespaces).isEmpty ? nil : r
    }

    /// Opens the Ask Indium panel under the selection.
    func showAsk() {
        guard textView.isEditable, let range = askRange(), let container = textView.textContainer else { NSSound.beep(); return }
        textView.setSelectedRange(range)
        // One thing over the selection at a time.
        selectionBarWork?.cancel()
        selectionBar.dismiss()
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        // A long selection: point at its last line, where the eye is.
        if rect.height > 80 { rect = NSRect(x: rect.minX, y: rect.maxY - 20, width: rect.width, height: 20) }
        let panel = AskPanel(editor: self, range: range, original: (storage.string as NSString).substring(with: range))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panel
        panel.popover = popover
        popover.show(relativeTo: rect.intersection(textView.visibleRect).isEmpty ? textView.visibleRect : rect, of: textView, preferredEdge: .maxY)
    }

    /// Puts an edit in place of `range` if the text there is still `original`; false when
    /// it changed while the model was working.
    func applyAsk(_ text: String, at range: NSRange, original: String) -> Bool {
        let ns = storage.string as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == original else { return false }
        return replace(range, with: text, select: NSRange(location: range.location, length: (text as NSString).length), actionName: "Ask Indium")
    }

    /// An answer as its own paragraph after the one the selection ends in.
    func insertAskAnswer(_ text: String, after range: NSRange) {
        let ns = storage.string as NSString
        let end = NSMaxRange(ns.paragraphRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0)))
        let atEnd = end == ns.length && !(ns.length > 0 && ns.substring(from: ns.length - 1) == "\n")
        let insert = (atEnd ? "\n\n" : "\n") + text + (atEnd ? "" : "\n")
        let start = end + (atEnd ? 2 : 1)
        _ = replace(NSRange(location: end, length: 0), with: insert,
                    select: NSRange(location: start, length: (text as NSString).length), actionName: "Insert Answer")
    }

    /// The text on either side of `range`, up to `limit` characters each, for context.
    func askContext(around range: NSRange, limit: Int = 800) -> (before: String, after: String) {
        let ns = storage.string as NSString
        let start = max(0, range.location - limit)
        let end = min(ns.length, NSMaxRange(range) + limit)
        return (ns.substring(with: NSRange(location: start, length: range.location - start)),
                ns.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))))
    }
}

/// The Ask Indium popover: one row to type the request in, a few common ones to click,
/// then the answer or what went wrong.
final class AskPanel: NSViewController, NSTextFieldDelegate {
    weak var popover: NSPopover?
    private weak var editor: EditorController?
    private let range: NSRange
    private let original: String
    private var answer = ""
    private var task: Task<Void, Never>?

    private static let width: CGFloat = 360
    private static let inset: CGFloat = 14
    /// Common requests, offered before anything's typed. General on purpose: anything else
    /// can be typed.
    private static let suggestions: [(title: String, request: String)] = [
        ("Fix Grammar", "Fix the spelling and grammar"),
        ("List", "Make this a bulleted list"),
        ("Table", "Make this a table"),
        ("Shorter", "Make this shorter"),
    ]

    private let field = NSTextField()
    private let send = NSButton()
    private let spinner = IconSpinner()
    private let divider = NSBox()
    private let chips = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let answerLabel = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()

    init(editor: EditorController, range: NSRange, original: String) {
        self.editor = editor
        self.range = range
        self.original = original
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { task?.cancel() }

    override func loadView() {
        let inner = Self.width - Self.inset * 2

        // The row: sparkle, the request, and send, as in Spotlight.
        let sparkle = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? NSImage())
        sparkle.contentTintColor = .controlAccentColor
        field.placeholderString = "Ask Indium…"
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityLabel("Ask Indium")
        send.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Ask")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        send.isBordered = false
        send.target = self
        send.action = #selector(sendClicked)
        send.toolTip = "Ask (Return)"
        spinner.setAccessibilityLabel("Thinking")
        let row = NSView()
        for v in [sparkle, field, send, spinner] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: inner),
            row.heightAnchor.constraint(equalToConstant: 24),
            sparkle.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            sparkle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: sparkle.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            send.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            send.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            send.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: send.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: send.centerYAnchor),
        ])
        send.setContentHuggingPriority(.required, for: .horizontal)

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: inner).isActive = true

        // A few common requests, as plain words, until something's typed or asked.
        for (title, request) in Self.suggestions {
            chips.addArrangedSubview(Self.textButton(title, color: .secondaryLabelColor, target: self, action: #selector(chipClicked(_:)), id: request))
        }
        chips.spacing = 16

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = inner
        status.isHidden = true

        answerLabel.font = .systemFont(ofSize: 13)
        answerLabel.isSelectable = true
        answerLabel.preferredMaxLayoutWidth = inner
        answerLabel.isHidden = true
        for (title, action) in [("Insert Below", #selector(insertAnswer)), ("Copy", #selector(copyAnswer))] {
            buttons.addArrangedSubview(Self.textButton(title, color: .controlAccentColor, target: self, action: action, id: nil))
        }
        buttons.spacing = 16
        buttons.isHidden = true

        let stack = NSStackView(views: [row, divider, chips, status, answerLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(8, after: answerLabel)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: 12, right: Self.inset)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
        updateSend()
        if let reason = AskModel.unavailableReason {
            field.isEnabled = false
            send.isEnabled = false
            chips.isHidden = true
            show(status: reason)
        }
        refreshDivider()
        resize()
    }

    /// A borderless word that acts as a button.
    private static func textButton(_ title: String, color: NSColor, target: AnyObject, action: Selector, id: String?) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color])
        if let id { b.identifier = NSUserInterfaceItemIdentifier(id) }
        return b
    }

    /// Send is lit only when there's something to send.
    private func updateSend() {
        let ready = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        send.contentTintColor = ready ? .controlAccentColor : .tertiaryLabelColor
    }

    /// The hairline shows only when something sits under the row.
    private func refreshDivider() {
        divider.isHidden = chips.isHidden && status.isHidden && answerLabel.isHidden
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        #if DEBUG
        AskPanel.current = self
        #endif
        view.window?.makeFirstResponder(field)
    }

    private func resize() {
        refreshDivider()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        popover?.contentSize = view.fittingSize
    }

    private func show(status text: String?) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
        if let text { NSAccessibility.post(element: status, notification: .announcementRequested, userInfo: [.announcement: text]) }
        resize()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Typing your own request: the suggestions step aside.
        updateSend()
        let typing = !field.stringValue.isEmpty
        if chips.isHidden != typing, answerLabel.isHidden {
            chips.isHidden = typing
            resize()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { run(); return true }
        return false
    }

    @objc private func sendClicked() { run() }

    @objc private func chipClicked(_ sender: NSButton) {
        field.stringValue = sender.identifier?.rawValue ?? sender.title
        run()
    }

    private func setWorking(_ working: Bool) {
        field.isEnabled = !working
        send.isHidden = working
        if working { spinner.start() } else { spinner.stop() }
        if working { chips.isHidden = true }
    }

    private func run() {
        let request = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, task == nil, let editor else { return }
        let around = editor.askContext(around: range)
        answerLabel.isHidden = true
        buttons.isHidden = true
        show(status: nil)
        setWorking(true)
        resize()
        let original = original
        task = Task { @MainActor [weak self] in
            let result: Result<AskModel.Reply, Error>
            do {
                result = .success(try await AskModel.ask(request, selection: original, before: around.before, after: around.after))
            } catch {
                result = .failure(error)
            }
            self?.finish(result)
        }
    }

    private func finish(_ result: Result<AskModel.Reply, Error>) {
        task = nil
        setWorking(false)
        switch result {
        case let .failure(error):
            show(status: AskModel.describe(error))
        case let .success(reply) where reply.kind == .edit:
            var text = reply.text
            // The model sometimes spaces out punctuation ("H$_2$O , CO$_2$"); not where the
            // text it replaces never did.
            for mark in [",", ".", ";", ":"] where !original.contains(" " + mark) {
                text = text.replacingOccurrences(of: " " + mark, with: mark)
            }
            if text == original {
                show(status: "No changes needed.")
            } else if editor?.applyAsk(text, at: range, original: original) == true {
                popover?.performClose(nil)
            } else {
                show(status: "The text changed while Indium was working. Try again.")
            }
        case let .success(reply):
            answer = reply.text
            answerLabel.stringValue = reply.text
            answerLabel.isHidden = false
            buttons.isHidden = false
            show(status: nil)
        }
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    #if DEBUG
    /// The panel last opened, for the harness.
    static weak var current: AskPanel?

    /// Types `request` and asks, as Return would.
    func debugAsk(_ request: String) {
        field.stringValue = request
        run()
    }
    #endif

    @objc private func insertAnswer() {
        editor?.insertAskAnswer(answer, after: range)
        popover?.performClose(nil)
    }

    @objc private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        popover?.performClose(nil)
    }
}
