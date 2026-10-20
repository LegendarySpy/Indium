import AppKit

// Writing Tools, and Siri editing through them, on a selection.
//
// The text view hands Writing Tools the whole note as context (with the selection
// marked) and applies whatever range it sends back, so a rewrite of "this part" could
// replace the entire note. Here the text around the selection is marked as not to be
// touched, an edit reaching past the selection is cut down to the part that actually
// changed or refused, and lists and tables come back as Markdown.

extension EditorController {
    /// Text Writing Tools leaves alone: everything outside the selection it started on,
    /// and inside it the source that isn't prose (frontmatter, code, math, tables).
    func textView(_ textView: NSTextView, writingToolsIgnoredRangesInEnclosingRange enclosing: NSRange) -> [NSValue] {
        let selection = textView.selectedRange()
        if writingToolsSpan == nil, selection.length > 0 { writingToolsSpan = selection }
        SiriLog.write("ignoredRanges enclosing=\(enclosing) selection=\(selection) span=\(String(describing: writingToolsSpan)) length=\(storage.length)")
        var ignored = writingToolsProtectedRanges(in: enclosing)
        if let span = writingToolsSpan {
            if span.location > enclosing.location {
                ignored.append(NSRange(location: enclosing.location, length: span.location - enclosing.location))
            }
            if NSMaxRange(span) < NSMaxRange(enclosing) {
                ignored.append(NSRange(location: NSMaxRange(span), length: NSMaxRange(enclosing) - NSMaxRange(span)))
            }
        }
        return ignored.map { NSValue(range: $0) }
    }

    func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        SiriLog.write("willBegin selection=\(textView.selectedRange()) length=\(storage.length)")
    }

    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        SiriLog.write("didEnd")
        writingToolsSpan = nil
    }

    private func writingToolsProtectedRanges(in enclosing: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        for block in styler.blocks where NSIntersectionRange(block.range, enclosing).length > 0 {
            switch block.kind {
            case .frontmatter, .code, .math, .table, .tableFormulas, .image, .embed, .comment:
                ranges.append(NSIntersectionRange(block.range, enclosing))
            default:
                break
            }
        }
        let text = storage.string as NSString
        storage.enumerateAttributes(in: enclosing) { attrs, range, _ in
            if attrs[.mdInlineMath] != nil {
                ranges.append(range)
            } else if let box = attrs[.mdInlineBox] as? InlineBox, box.kind == .code {
                // The box covers only the code when its backticks are hidden.
                var r = range
                while r.location > enclosing.location, text.character(at: r.location - 1) == 0x60 { r.location -= 1; r.length += 1 }
                while NSMaxRange(r) < NSMaxRange(enclosing), text.character(at: NSMaxRange(r)) == 0x60 { r.length += 1 }
                ranges.append(r)
            }
        }
        return ranges
    }

    /// What of a Writing Tools replacement to apply, in the context's own coordinates:
    /// lists and tables as Markdown, and only inside the selection it started on.
    /// Nil refuses the change, leaving the text as it was.
    func writingToolsEdit(range: NSRange, context: NSWritingToolsCoordinator.Context,
                          proposed: NSAttributedString) -> (range: NSRange, text: NSAttributedString)? {
        // The context's range is the selection; edits before it are refused, so the
        // selection's start doesn't move. With no selection, the context is the note.
        let offset = writingToolsSpan.map { $0.location - context.range.location } ?? 0
        let target = NSRange(location: range.location + offset, length: range.length)
        var text = proposed
        if var markdown = WritingToolsMarkdown.markdown(from: proposed) {
            // A list or table ends its last line; text that didn't, still doesn't.
            let old = storage.string as NSString
            if markdown.hasSuffix("\n"), NSMaxRange(target) <= old.length, target.length > 0,
               old.character(at: NSMaxRange(target) - 1) != 0x0A { markdown.removeLast() }
            text = NSAttributedString(string: markdown)
        }
        guard let span = writingToolsSpan else { return (range, text) }
        func inside(_ r: NSRange) -> Bool { r.location >= span.location && NSMaxRange(r) <= NSMaxRange(span) }
        if inside(target) { return (range, text) }
        guard target.location >= 0, NSMaxRange(target) <= storage.length else { return nil }
        // A rewrite of more than the selection that left the rest as it was.
        let old = storage.string as NSString
        let new = text.string as NSString
        let limit = min(target.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: target.location + prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix > 0, prefix < new.length { prefix = new.rangeOfComposedCharacterSequence(at: prefix).location }
        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: NSMaxRange(target) - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, suffix < new.length - prefix {
            suffix = new.length - NSMaxRange(new.rangeOfComposedCharacterSequence(at: new.length - suffix - 1))
        }
        let changed = NSRange(location: target.location + prefix, length: target.length - prefix - suffix)
        guard inside(changed) else { return nil }
        return (NSRange(location: changed.location - offset, length: changed.length),
                text.attributedSubstring(from: NSRange(location: prefix, length: new.length - prefix - suffix)))
    }

    /// A Writing Tools edit went in: the selection it may change grew or shrank with it.
    func writingToolsReplaced(contextRange range: NSRange, context: NSWritingToolsCoordinator.Context, with length: Int) {
        guard let span = writingToolsSpan else { return }
        writingToolsSpan = NSRange(location: span.location, length: max(0, span.length + length - range.length))
    }
}

extension EditorTextView {
    private typealias WritingToolsReplace = @convention(c) (
        NSTextView, Selector, NSWritingToolsCoordinator, NSRange, NSWritingToolsCoordinator.Context, NSAttributedString, Int,
        NSWritingToolsCoordinator.AnimationParameters?, @escaping @convention(block) (NSAttributedString?) -> Void) -> Void

    /// NSTextView's own Writing Tools delegate method, which applies a suggested change.
    /// Not declared to Swift, so it's reached by selector; the change is vetted first.
    @objc(writingToolsCoordinator:replaceRange:inContext:proposedText:reason:animationParameters:completion:)
    func writingToolsCoordinator(_ coordinator: NSWritingToolsCoordinator, replaceRange range: NSRange,
                                 in context: NSWritingToolsCoordinator.Context, proposedText: NSAttributedString,
                                 reason: NSWritingToolsCoordinator.TextReplacementReason,
                                 animationParameters: NSWritingToolsCoordinator.AnimationParameters?,
                                 completion: @escaping (NSAttributedString?) -> Void) {
        let selector = #selector(writingToolsCoordinator(_:replaceRange:in:proposedText:reason:animationParameters:completion:))
        // Should a later AppKit stop implementing it, refuse the change rather than crash.
        SiriLog.write("replace range=\(range) context=\(context.range) contextLength=\(context.attributedString.length) reason=\(reason.rawValue) proposed=\(proposedText.string.prefix(200).debugDescription) span=\(String(describing: editor?.writingToolsSpan))")
        guard NSTextView.instancesRespond(to: selector),
              let editor, let edit = editor.writingToolsEdit(range: range, context: context, proposed: proposedText),
              let imp = class_getMethodImplementation(NSTextView.self, selector) else {
            SiriLog.write("  refused")
            NSSound.beep()
            completion(nil)
            return
        }
        let replace = unsafeBitCast(imp, to: WritingToolsReplace.self)
        SiriLog.write("  applying range=\(edit.range) text=\(edit.text.string.prefix(200).debugDescription)")
        replace(self, selector, coordinator, edit.range, context, edit.text, reason.rawValue, animationParameters) { [weak editor] result in
            SiriLog.write("  applied result=\(result.map { "\($0.length) chars" } ?? "nil")")
            if let result { editor?.writingToolsReplaced(contextRange: edit.range, context: context, with: result.length) }
            completion(result)
        }
    }
}

/// Lists and tables from Writing Tools (Make List, Make Table) as Markdown source.
enum WritingToolsMarkdown {
    /// The text as Markdown, or nil when it has no list or table to convert.
    static func markdown(from text: NSAttributedString) -> String? {
        let string = text.string as NSString
        guard string.length > 0 else { return nil }
        var lines: [String] = []
        var converted = false
        var numbers: [ObjectIdentifier: Int] = [:]
        var table: (id: ObjectIdentifier, columns: Int, rows: [[Int: String]])?

        func flushTable() {
            guard let t = table else { return }
            table = nil
            let count = max(t.columns, t.rows.map { ($0.keys.max() ?? 0) + 1 }.max() ?? 0)
            for (i, row) in t.rows.enumerated() {
                let cells = (0..<count).map { (row[$0] ?? "").replacingOccurrences(of: "|", with: "\\|") }
                lines.append("| " + cells.joined(separator: " | ") + " |")
                if i == 0 { lines.append("|" + String(repeating: " --- |", count: count)) }
            }
        }

        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var line = string.substring(with: paragraph)
            while let last = line.last, last.isNewline { line.removeLast() }
            let style = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle

            if let block = style?.textBlocks.last as? NSTextTableBlock {
                let id = ObjectIdentifier(block.table)
                if table?.id != id {
                    flushTable()
                    table = (id, block.table.numberOfColumns, [])
                }
                while table!.rows.count <= block.startingRow { table!.rows.append([:]) }
                let cell = line.trimmingCharacters(in: .whitespaces)
                let old = table!.rows[block.startingRow][block.startingColumn]
                table!.rows[block.startingRow][block.startingColumn] = old.map { $0 + " " + cell } ?? cell
                converted = true
                continue
            }
            flushTable()

            if let lists = style?.textLists, let list = lists.last {
                let item = strippingMarker(line)
                let marker: String
                if list.isOrdered {
                    let n = numbers[ObjectIdentifier(list)] ?? list.startingItemNumber
                    numbers[ObjectIdentifier(list)] = n + 1
                    marker = "\(n). "
                } else {
                    marker = "- "
                }
                lines.append(String(repeating: "\t", count: lists.count - 1) + marker + item)
                converted = true
            } else if let range = line.range(of: #"^\t*[•◦▪‣⁃][ \t]+"#, options: .regularExpression) {
                // A plain-text list with bullet characters.
                let depth = line[range].prefix { $0 == "\t" }.count
                lines.append(String(repeating: "\t", count: depth) + "- " + line[range.upperBound...])
                converted = true
            } else {
                lines.append(line)
            }
        }
        flushTable()
        guard converted else { return nil }
        var result = lines.joined(separator: "\n")
        if string.length > 0, CharacterSet.newlines.contains(Unicode.Scalar(string.character(at: string.length - 1)) ?? " ") { result += "\n" }
        return result
    }

    /// A list item's text without the marker some exports put in front of it ("\t•\t").
    private static func strippingMarker(_ line: String) -> String {
        guard let range = line.range(of: #"^\t*([•◦▪‣⁃\-*]|\d+[.)])\t"#, options: .regularExpression) else { return line }
        return String(line[range.upperBound...])
    }
}

/// DEBUG only: what Siri and Writing Tools ask of the editor, appended to
/// /tmp/indium-siri.log, to see which way they reach the text and where it fails.
enum SiriLog {
    static func write(_ line: String) {
        #if DEBUG
        let url = URL(fileURLWithPath: "/tmp/indium-siri.log")
        let entry = Data("\(Date().formatted(date: .omitted, time: .standard)) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(entry); try? h.close()
        } else {
            try? entry.write(to: url)
        }
        #endif
    }
}
