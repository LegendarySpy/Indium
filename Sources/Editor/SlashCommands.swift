import AppKit

/// `/` commands: type a slash and the best match appears as soft ghost text after the
/// caret. Tab or Return inserts it, ↑/↓ cycles, Esc dismisses.
struct SlashCommand {
    enum Insertion {
        /// Text replacing the typed command; `select` is relative to the inserted text.
        case text(String, select: NSRange, block: Bool)
        case image
    }
    let name: String
    let insertion: Insertion

    static let all: [SlashCommand] = [
        .init(name: "title", insertion: .text("# ", select: NSRange(location: 2, length: 0), block: true)),
        .init(name: "subtitle", insertion: .text("## ", select: NSRange(location: 3, length: 0), block: true)),
        .init(name: "heading", insertion: .text("## ", select: NSRange(location: 3, length: 0), block: true)),
        .init(name: "heading 3", insertion: .text("### ", select: NSRange(location: 4, length: 0), block: true)),
        .init(name: "table", insertion: .text("| Column | Column |\n| --- | --- |\n|  |  |\n", select: NSRange(location: 2, length: 6), block: true)),
        .init(name: "bullet list", insertion: .text("- ", select: NSRange(location: 2, length: 0), block: true)),
        .init(name: "numbered list", insertion: .text("1. ", select: NSRange(location: 3, length: 0), block: true)),
        .init(name: "todo", insertion: .text("- [ ] ", select: NSRange(location: 6, length: 0), block: true)),
        .init(name: "quote", insertion: .text("> ", select: NSRange(location: 2, length: 0), block: true)),
        .init(name: "code", insertion: .text("```\n\n```\n", select: NSRange(location: 4, length: 0), block: true)),
        .init(name: "equation", insertion: .text("$$\n\n$$\n", select: NSRange(location: 3, length: 0), block: true)),
        .init(name: "math", insertion: .text("$$", select: NSRange(location: 1, length: 0), block: false)),
        .init(name: "divider", insertion: .text("---\n", select: NSRange(location: 4, length: 0), block: true)),
        .init(name: "page break", insertion: .text("<!-- pagebreak -->\n", select: NSRange(location: 19, length: 0), block: true)),
        .init(name: "columns", insertion: .text("<!-- columns -->\n\n<!-- column -->\n\n<!-- /columns -->\n", select: NSRange(location: 17, length: 0), block: true)),
        .init(name: "image", insertion: .image),
        .init(name: "date", insertion: .text(Self.today, select: NSRange(location: (Self.today as NSString).length, length: 0), block: false)),
    ]

    private static var today: String {
        let f = DateFormatter()
        f.dateStyle = .long
        return f.string(from: Date())
    }

    static func matches(_ query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        let prefix = all.filter { $0.name.hasPrefix(q) }
        let words = all.filter { cmd in !cmd.name.hasPrefix(q) && cmd.name.split(separator: " ").contains { $0.hasPrefix(q) } }
        return prefix + words
    }
}

extension EditorController {
    struct SlashState {
        var range: NSRange
        var query: String
        var matches: [SlashCommand]
        var index: Int
        var current: SlashCommand { matches[index] }
    }

    func updateSlashSuggestion() {
        guard let state = computeSlashState(), state.range.location != slashDismissedAt else {
            if computeSlashState() == nil { slashDismissedAt = nil }
            clearSlash()
            return
        }
        slash = state
        refreshGhost()
    }

    private func computeSlashState() -> SlashState? {
        let sel = textView.selectedRange()
        guard textView.isEditable, sel.length == 0, !textView.hasMarkedText(), sel.location > 0 else { return nil }
        if let i = styler.blockIndex(containing: sel.location) {
            switch styler.blocks[i].kind {
            case .code, .math, .frontmatter: return nil
            default: break
            }
        }
        let text = storage.string as NSString
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: sel.location, length: 0))
        let before = text.substring(with: NSRange(location: s, length: sel.location - s))
        guard let match = before.range(of: #"(?:^|\s)/([A-Za-z0-9]+(?: [A-Za-z0-9]*)?)?$"#, options: .regularExpression) else { return nil }
        let slashOffset = (before[match] as Substring).firstIndex(of: "/").map { before.distance(from: before.startIndex, to: $0) } ?? 0
        let slashLocation = s + (String(before.prefix(slashOffset)) as NSString).length
        let query = text.substring(with: NSRange(location: slashLocation + 1, length: sel.location - slashLocation - 1))
        let matches = SlashCommand.matches(query)
        guard !matches.isEmpty else { return nil }
        let keep = slash.map { old in matches.firstIndex { $0.name == old.current.name } } ?? nil
        return SlashState(range: NSRange(location: slashLocation, length: sel.location - slashLocation),
                          query: query, matches: matches, index: keep ?? 0)
    }

    private func refreshGhost() {
        guard let state = slash else { return }
        let name = state.current.name
        let q = state.query.lowercased()
        let suffix: String
        if name.hasPrefix(q) {
            suffix = String(name.dropFirst(q.count))
        } else {
            suffix = " → " + name
        }
        textView.ghost = suffix.isEmpty ? "  ⇥" : suffix + "  ⇥"
    }

    func clearSlash() {
        guard slash != nil || textView.ghost != nil else { return }
        slash = nil
        textView.ghost = nil
    }

    // MARK: Answers

    func updateAnswerSuggestion() {
        guard slash == nil else { answer = nil; textView.ghostIsAnswer = false; return }
        let sel = textView.selectedRange()
        guard textView.isEditable, sel.length == 0, !textView.hasMarkedText(), sel.location > 0 else { clearAnswer(); return }
        var inMath = false
        if let i = styler.blockIndex(containing: sel.location) {
            switch styler.blocks[i].kind {
            case .code, .frontmatter: clearAnswer(); return
            case .math: inMath = true
            default: break
            }
        }
        let text = storage.string as NSString
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: sel.location, length: 0))
        let before = text.substring(with: NSRange(location: s, length: sel.location - s))
        let after = text.substring(with: NSRange(location: sel.location, length: ce - sel.location))
        // Only at the end of what's being written (a closing $ may follow).
        guard after.trimmingCharacters(in: .whitespaces).isEmpty || after.hasPrefix("$") else { clearAnswer(); return }
        if !inMath { inMath = before.filter { $0 == "$" }.count % 2 == 1 }
        guard let result = MathAnswer.suggest(lineBeforeCaret: before, inMath: inMath) else {
            answerDismissedAt = nil
            clearAnswer()
            return
        }
        guard sel.location != answerDismissedAt else { clearAnswer(); return }
        answer = (sel.location, result)
        textView.ghostIsAnswer = true
        textView.ghost = (result.insertion.hasPrefix(" ") ? " " : "") + result.display
    }

    func clearAnswer() {
        guard answer != nil else { return }
        answer = nil
        textView.ghostIsAnswer = false
        textView.ghost = nil
    }

    /// Key handling while a suggestion is showing. Returns true if the key was used.
    func handleSlashKey(_ selector: Selector) -> Bool {
        if let answer {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                clearAnswer()
                textView.insertText(answer.result.insertion, replacementRange: NSRange(location: answer.location, length: 0))
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                answerDismissedAt = answer.location
                clearAnswer()
                return true
            default:
                return false
            }
        }
        guard var state = slash else { return false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
            acceptSlash(state)
            return true
        case #selector(NSResponder.moveDown(_:)):
            state.index = (state.index + 1) % state.matches.count
            slash = state
            refreshGhost()
            return true
        case #selector(NSResponder.moveUp(_:)):
            state.index = (state.index - 1 + state.matches.count) % state.matches.count
            slash = state
            refreshGhost()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            clearSlash()
            slashDismissedAt = state.range.location
            return true
        default:
            return false
        }
    }

    private func acceptSlash(_ state: SlashState) {
        clearSlash()
        let text = storage.string as NSString
        var s = 0, e = 0, ce = 0
        text.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: state.range.location, length: 0))
        switch state.current.insertion {
        case .image:
            replace(state.range, with: "", select: NSRange(location: state.range.location, length: 0), actionName: "Image")
            (textView.window?.windowController as? DocumentWindowController)?.insertImage(nil)
        case let .text(insert, select, block):
            // Block commands start their own line.
            let lineBefore = text.substring(with: NSRange(location: s, length: state.range.location - s))
            let needsBreak = block && !lineBefore.trimmingCharacters(in: .whitespaces).isEmpty
            let replaceRange = needsBreak ? state.range : NSRange(location: s, length: NSMaxRange(state.range) - s)
            let prefix = needsBreak ? "\n" : (block ? "" : lineBefore)
            let full = prefix + insert
            let offset = (prefix as NSString).length
            replace(replaceRange, with: full,
                    select: NSRange(location: replaceRange.location + offset + select.location, length: select.length),
                    actionName: state.current.name.capitalized)
        }
    }
}
