#if DEBUG
import AppKit
import SwiftMath

/// Development aid: `-IndiumSnapshot /tmp/out.png` renders the main window to a PNG
/// and quits. Optional: `-IndiumSize 1000x1100`, `-IndiumSelect 120`,
/// `-IndiumScroll 400`, `-IndiumPDF /tmp/out.pdf`, `-IndiumTemp YES`.
enum DebugSnapshot {
    static func runLayoutTests() {
        let doc = "# Title\n\nAlpha paragraph.\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nBeta paragraph.\n\nGamma.\n"
        func model(_ text: String) -> LayoutModel {
            let ns = text as NSString
            let blocks = MarkdownScanner.scan(ns)
            let styler = MarkdownStyler(config: .current)
            let storage = NSTextStorage(string: text)
            styler.styleAll(storage, selection: [])
            return LayoutModel.build(text: ns, blocks: blocks, validRegionStarts: Set(styler.regions.map(\.start)))
        }
        func apply(_ text: String, _ edit: (range: NSRange, text: String, movedOffset: Int)?) -> String {
            guard let edit else { return "<no-op>" }
            return (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
        }
        func group(_ m: LayoutModel, _ prefix: String) -> LayoutGroup { m.groups.first { $0.group.text.hasPrefix(prefix) }!.group }

        var m = model(doc)
        let t1 = apply(doc, m.move(group(m, "| a"), to: .beside(group(m, "Alpha"), leading: false)))
        print("=== table beside alpha ===\n" + t1)
        m = model(t1)
        let t2 = apply(t1, m.move(group(m, "Beta"), to: .after(group(m, "Alpha"))))
        print("=== beta into left column ===\n" + t2)
        m = model(t2)
        let t3 = apply(t2, m.move(group(m, "| a"), to: .after(group(m, "Gamma"))))
        print("=== table out to end ===\n" + t3)
        m = model(t3)
        let t4 = apply(t3, m.move(group(m, "Gamma"), to: .before(group(m, "# Title"))))
        print("=== gamma to top ===\n" + t4)

        // A table's formula lines belong to its block: they move with it.
        let f = "Intro.\n\n| Q | A |\n| - | - |\n| x | 2 |\n| y | 4 |\n<!-- TBLFM: @3$2=(@2$2*2) -->\n\nOutro.\n"
        m = model(f)
        let kinds = MarkdownScanner.scan(f as NSString).map { "\($0.kind)".components(separatedBy: "(").first! }
        print("=== formula blocks ===\n" + kinds.joined(separator: " "))
        let f1 = apply(f, m.move(group(m, "| Q"), to: .after(group(m, "Outro"))))
        print("=== table with formulas to end ===\n" + f1)
        m = model(f1)
        let f2 = apply(f1, m.move(group(m, "| Q"), to: .before(group(m, "Intro"))))
        print("=== table with formulas to top ===\n" + f2)
    }

    /// `-IndiumIconSteps "files;open:A.md;icon;suggest;wait:0.3;shot:/tmp/a.png;wait:2;dump"` drives
    /// icon suggestions (pair with `-IndiumIconStub` and `-IndiumIconStore`). Steps: `files` shows
    /// the sidebar, `open:rel` opens a note, `icon` clicks the title bar icon, `suggest` clicks the
    /// picker's Suggest/Try Again, `pick:symbol` picks one, `close` closes popovers, `menu:rel` is the
    /// sidebar's Suggest New Icon, `retry` presses Try Again in a notice, `frontmatter:symbol` gives the open note that icon in frontmatter and saves it, `suggestAt:/abs/path` asks
    /// for any file (vault = its folder), `wait:s`, `shot:path` (popovers included), `dump`.
    static func runIconSteps(_ steps: [String], controller: DocumentWindowController) {
        guard let window = controller.window, let frame = window.contentView?.superview else { exit(1) }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let v = view as? T { return v }
            for sub in view.subviews { if let v = find(type, in: sub) { return v } }
            return nil
        }
        func findAll(in view: NSView, _ match: (NSView) -> Bool) -> [NSView] {
            (match(view) ? [view] : []) + view.subviews.flatMap { findAll(in: $0, match) }
        }
        func popoverWindows() -> [NSWindow] {
            NSApp.windows.filter { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        }
        func picker() -> IconPickerController? {
            for w in popoverWindows() {
                if let v = w.contentView.map({ findAll(in: $0) { $0.nextResponder is IconPickerController } }), let p = v.first?.nextResponder as? IconPickerController { return p }
            }
            return nil
        }
        func button(titled titles: [String]) -> NSButton? {
            for w in popoverWindows() {
                if let b = w.contentView.flatMap({ findAll(in: $0) { ($0 as? NSButton).map { titles.contains($0.title) } ?? false }.first }) as? NSButton { return b }
            }
            return nil
        }
        let root = AppDelegate.shared.workspace?.root
        func url(_ rel: String) -> URL? { root?.appendingPathComponent(rel) }
        func dump() {
            let bar = find(TitleBarView.self, in: frame)
            print("  title bar:", bar?.debugIconState ?? "-", "note:", controller.note?.url?.lastPathComponent ?? "-")
            if let ws = AppDelegate.shared.workspace {
                for note in ws.notes.sorted(by: { $0.path < $1.path }) {
                    print("  \(ws.relativePath(note)): icon=\(NoteIcons.shared.icon(for: note, in: ws) ?? "nil") state=\(NoteIcons.shared.suggestion(for: note))")
                }
            }
            if let p = picker() {
                let texts = findAll(in: p.view) { $0 is NSTextField || $0 is NSButton && !($0 is SymbolCell) }.compactMap { v -> String? in
                    if let t = v as? NSTextField, !t.isHidden { return "label[\(t.stringValue)]" }
                    if let b = v as? NSButton { return "button[\(b.title) enabled=\(b.isEnabled)]" }
                    return nil
                }
                let selected = findAll(in: p.view) { ($0 as? SymbolCell)?.selected == true }.compactMap { ($0 as? SymbolCell)?.symbol }
                print("  picker:", texts.joined(separator: " "), "selected:", selected)
            }
            for w in popoverWindows() where picker().map({ $0.view.window !== w }) ?? true {
                let labels = w.contentView.map { findAll(in: $0) { $0 is NSTextField || $0 is NSButton }.map { ($0 as? NSTextField)?.stringValue ?? "[\(($0 as! NSButton).title)]" } } ?? []
                print("  notice:", labels.joined(separator: " "))
            }
        }
        func shot(_ path: String) {
            frame.layoutSubtreeIfNeeded()
            guard let base = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: base)
            // Popovers are their own windows: draw each where it sits over the main window.
            let pops = popoverWindows()
            var canvas = window.frame
            for w in pops { canvas = canvas.union(w.frame) }
            let image = NSImage(size: canvas.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: canvas.size).fill()
            base.draw(in: NSRect(x: window.frame.minX - canvas.minX, y: window.frame.minY - canvas.minY, width: window.frame.width, height: window.frame.height))
            for w in pops {
                // The popover's material doesn't render offscreen: its content on a plain backing.
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.controlBackgroundColor.setFill()
                v.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
                v.cacheDisplay(in: v.bounds, to: rep)
                let content = v.convert(v.bounds, to: nil)
                let r = content.offsetBy(dx: w.frame.minX - canvas.minX, dy: w.frame.minY - canvas.minY)
                let shape = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
                NSColor.controlBackgroundColor.setFill()
                shape.fill()
                NSColor.separatorColor.setStroke()
                shape.stroke()
                rep.draw(in: r)
            }
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            print("  shot:", path)
        }
        func run(_ i: Int) {
            guard i < steps.count else { exit(0) }
            let step = steps[i]
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            print("STEP", step)
            var delay = 0.25
            switch parts[0] {
            case "files": controller.toggleFiles(nil)
            case "open":
                if let sidebar = find(SidebarView.self, in: frame) { sidebar.debugStep("click:" + arg) }
                else { print("  no sidebar; use files first") }
            case "icon": find(TitleBarView.self, in: frame)?.debugClickIcon()
            case "suggest":
                if let b = button(titled: ["Suggest", "Try Again", "Suggest Again", "Suggesting…"]) { print("  pressing [\(b.title)] enabled=\(b.isEnabled)"); b.performClick(nil) }
                else { print("  no suggest button") }
                delay = 0.05
            case "pick":
                if let p = picker(), let cell = findAll(in: p.view, { ($0 as? SymbolCell)?.symbol == arg }).first as? SymbolCell { cell.performClick(nil) }
                else { print("  no cell", arg) }
            case "close": popoverWindows().forEach { $0.close() }
            case "menu":
                if let sidebar = find(SidebarView.self, in: frame), let u = url(arg) { sidebar.debugSuggestIcon(u) } else { print("  no sidebar") }
                delay = 0.05
            case "retry":
                if let b = button(titled: ["Try Again"]) { b.performClick(nil) } else { print("  no Try Again") }
                delay = 0.05
            case "frontmatter":
                // `frontmatter:symbol`: the open note gains `icon: symbol` and is saved, as if typed.
                if let u = controller.note?.url, let ws = AppDelegate.shared.workspace {
                    let text = "---\nicon: \(arg)\n---\n" + ((try? String(contentsOf: u, encoding: .utf8)) ?? "")
                    try? text.write(to: u, atomically: true, encoding: .utf8)
                    NoteIcons.shared.suggest(for: u, text: text, in: ws)
                }
                delay = 0.05
            case "suggestAt":
                let u = URL(fileURLWithPath: arg)
                let ws = Workspace(root: u.deletingLastPathComponent())
                let s = NoteIcons.shared.suggest(for: u, text: (try? String(contentsOf: u, encoding: .utf8)) ?? "", in: ws, force: true)
                print("  \(u.path): \(s)")
                delay = 0.05
            case "wait": delay = Double(arg) ?? 1
            case "shot": shot(arg); delay = 0.05
            case "dump": dump(); delay = 0.05
            default: print("  unknown step")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(i + 1) }
        }
        run(0)
    }

    /// `-IndiumAccessSteps "type:x;save;open:B.md;switch:/abs;close;openFile:/abs;grant;quit;wait:1;dump;exit"`
    /// drives saving, switching and folder access (works without `-IndiumSnapshot`, and in
    /// the sandboxed App Store build). `dump` prints the open note, its unsaved state and
    /// how many holders keep each folder open.
    static func runAccessSteps(_ steps: [String], controller main: DocumentWindowController) {
        var target = main
        func findButtons(in view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { findButtons(in: $0) }
        }
        func fileControllers() -> [DocumentWindowController] {
            NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }.filter { $0.kind == .file }
        }
        func dump() {
            let ws = AppDelegate.shared.workspace
            let note = target.note
            print("  vault:", ws?.root.path ?? "-", "holders:", ws.map { FolderAccess.holders(of: $0.root) } ?? 0,
                  "| note:", note?.url?.path ?? "-", "unsaved:", target.editor.hasUnsavedEdits,
                  "saveFailure:", target.editor.saveFailure.map { ($0 as NSError).code } as Any,
                  "sheet:", target.window?.attachedSheet != nil, "visible:", target.window?.isVisible ?? false)
            if let url = note?.url {
                print("  note holders:", FolderAccess.holders(of: url), "folder holders:", FolderAccess.holders(of: url.deletingLastPathComponent()),
                      "bar:", target.debugFolderAccessBarShown, "file windows:", fileControllers().count)
                print("  editor text:", target.editor.text.debugDescription)
                print("  disk text:  ", ((try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>").debugDescription)
            }
        }
        func run(_ i: Int) {
            guard i < steps.count else { return }
            let step = steps[i]
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            var delay = 0.4
            print("STEP \(step)")
            switch parts[0] {
            case "type":
                let tv = target.editor.textView
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                tv.insertText(arg, replacementRange: tv.selectedRange())
            case "save": print("  saveNow ->", target.editor.saveNow())
            case "open":
                if let root = AppDelegate.shared.workspace?.root { target.open(root.appendingPathComponent(arg)) }
            case "switch":
                let item = NSMenuItem()
                item.representedObject = URL(fileURLWithPath: arg, isDirectory: true)
                AppDelegate.shared.switchFolder(item)
            case "close": target.window?.performClose(nil)
            case "openFile":
                AppDelegate.shared.openDocument(URL(fileURLWithPath: arg))
                if let c = fileControllers().first(where: { $0.note?.url?.path == URL(fileURLWithPath: arg).standardizedFileURL.path }) { target = c }
            case "grant": target.debugGrantFolderAccess()
            case "file": if let c = fileControllers().first { target = c } else { print("  no file window") }
            case "trash": target.trashNote(nil)
            case "tempimage":
                // A temporary note holding a pasted (memory-only) image.
                AppDelegate.shared.newTemporaryNote(nil)
                if let c = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController }).last(where: { $0.kind == .temporary }),
                   let note = c.note {
                    target = c
                    let image = NSImage(size: NSSize(width: 80, height: 60), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
                    if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        note.memoryImages["attachments/pasted.png"] = png
                    }
                    c.editor.textView.insertText("# Scratch\n\n![](attachments/pasted.png)\n", replacementRange: NSRange(location: 0, length: 0))
                }
            case "savetemp": target.saveTemporaryToVault(closeAfter: false)
            case "iconstore":
                // What the note-icon store looks like from inside (the container, when sandboxed).
                let file = FileManager.indiumSupport.appendingPathComponent("icons.json")
                print("  icon store:", file.path, "exists:", FileManager.default.fileExists(atPath: file.path))
                print("  contents:", (try? String(contentsOf: file, encoding: .utf8)) ?? "-")
            case "external":
                // Another app appends to the open note (a plain, uncoordinated write).
                if let url = target.note?.url, let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(Data(arg.utf8)); try? h.close()
                }
            case "check": target.editor.checkForExternalChanges()
            case "forceopen":
                // Replaces the note the way only an explicit discard may (bypassing the save check).
                if let root = AppDelegate.shared.workspace?.root, let n = try? Note(url: root.appendingPathComponent(arg)) {
                    print("  forced load ->", target.editor.load(n, discardingEdits: true))
                }
            case "images":
                // Which image references in the note resolve to a picture right now.
                let ns = target.editor.text as NSString
                let re = try? NSRegularExpression(pattern: #"!\[\[([^\]]+)\]\]|!\[[^\]]*\]\(([^)]+)\)"#)
                for m in re?.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) ?? [] {
                    let wiki = m.range(at: 1).location != NSNotFound
                    let src = ns.substring(with: m.range(at: wiki ? 1 : 2))
                    let image = target.editor.image(for: ImageRef(source: src, alt: "", width: nil, isWiki: wiki, altRange: NSRange(location: 0, length: 0)))
                    print("  image \(src):", image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")
                }
            case "answer":
                // `answer:3` presses the third button of the window's sheet.
                if let window = target.window, let sheet = window.attachedSheet {
                    let title = (sheet.contentView.map { findButtons(in: $0) } ?? []).map(\.title)
                    print("  sheet buttons:", title)
                    window.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: 999 + (Int(arg) ?? 1)))
                } else { print("  no sheet") }
            case "about": AppDelegate.shared.showAbout(nil); print(Acknowledgements.text.string.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(12).joined(separator: "\n"))
            case "quit": DispatchQueue.main.async { NSApp.terminate(nil) }
            case "wait": delay = Double(arg) ?? 1
            case "dump": dump()
            case "exit": exit(0)
            default: print("  unknown step")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(i + 1) }
        }
        run(0)
    }

    /// The window and any popovers over it, as a PNG.
    static func debugShot(window: NSWindow, path: String) {
        guard let frame = window.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        guard let base = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: base)
        let pops = NSApp.windows.filter { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        var canvas = window.frame
        for w in pops { canvas = canvas.union(w.frame) }
        let image = NSImage(size: canvas.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        base.draw(in: NSRect(x: window.frame.minX - canvas.minX, y: window.frame.minY - canvas.minY, width: window.frame.width, height: window.frame.height))
        for w in pops {
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.controlBackgroundColor.setFill()
            v.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            v.cacheDisplay(in: v.bounds, to: rep)
            let r = v.convert(v.bounds, to: nil).offsetBy(dx: w.frame.minX - canvas.minX, dy: w.frame.minY - canvas.minY)
            let shape = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            NSColor.controlBackgroundColor.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            rep.draw(in: r)
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        print("  shot:", path)
    }

    /// Math typed in a table cell. Each case starts from a fresh note holding
    ///
    ///     | H1 | H2 |      the cell typed in is c1 (row 1, column 0), its text and
    ///     | -- | -- |      caret set from `before`. The result is that cell's text with
    ///     | c1 | c2 |      the caret (`‸`) or selection (`«»`); `@r,c:` in front when the
    ///     | d1 | d2 |      keys moved to another cell, `exited` when they left the table.
    ///
    /// An optional fourth column is the row as stored in the note, spaces squeezed. Every
    /// case also checks the table still has two columns in every row (a bare `|` splits one).
    /// Keys as for `-IndiumMathCases`, plus ⇤ Shift-Tab and ⎋ Escape.
    static func runMathCellCases(_ cases: String, editor: EditorController, window: NSWindow, realKeys: Bool) {
        let undo = editor.textView.undoManager
        func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        func send(_ chars: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
            }
            spin()
        }
        func unmark(_ s: String) -> (String, NSRange) {
            let ns = s as NSString
            let caret = ns.range(of: "‸")
            if caret.location != NSNotFound { return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0)) }
            let a = ns.range(of: "«"), b = ns.range(of: "»")
            let plain = ns.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
            return (plain, a.location == NSNotFound ? NSRange(location: (plain as NSString).length, length: 0)
                                                       : NSRange(location: a.location, length: b.location - a.location - 1))
        }
        if !realKeys {
            if let undo, undo.groupingLevel > 0 { undo.endUndoGrouping() }
            undo?.groupsByEvent = false
        }
        let note = "| H1 | H2 |\n| --- | --- |\n| c1 | c2 |\n| d1 | d2 |\n\nAfter the table.\n"
        var failed = 0, total = 0
        for line in cases.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("#") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3 || parts.count == 4 else { continue }
            total += 1
            let (start, sel) = unmark(parts[0])
            if !realKeys { undo?.beginUndoGrouping() }
            editor.endTableEditing()
            editor.replace(NSRange(location: 0, length: editor.storage.length), with: note)
            editor.beginTableEditing(at: 0, row: 1, column: 0)
            guard let cell = editor.tableEditor?.cellEditor as? CellTextView else {
                if !realKeys { undo?.endUndoGrouping() }
                failed += 1
                print("FAIL", parts[0], "· no cell editor")
                continue
            }
            let all = NSRange(location: 0, length: (cell.string as NSString).length)
            if cell.shouldChangeText(in: all, replacementString: start) {
                cell.textStorage?.replaceCharacters(in: all, with: start)
                cell.didChangeText()
            }
            cell.setSelectedRange(sel)
            cell.math.clearStops()
            if !realKeys { undo?.endUndoGrouping() }
            spin()
            // Each case starts with nothing to undo, so ↶ can't reach into the one before.
            undo?.removeAllActions()
            for key in parts[1] {
                if realKeys {
                    switch key {
                    case "⇥": send("\t", code: 48)
                    case "⇤": send("\u{19}", .shift, code: 48)
                    case "⏎": send("\r", code: 36)
                    case "⌫": send("\u{7f}", code: 51)
                    case "⎋": send("\u{1b}", code: 53)
                    case "↶": undo?.undo(); spin()
                    case "↷": undo?.redo(); spin()
                    default: send(String(key))
                    }
                    continue
                }
                guard let tv = editor.tableEditor?.cellEditor else { break }
                let isUndo = key == "↶" || key == "↷"
                if !isUndo { undo?.beginUndoGrouping() }
                switch key {
                case "⇥": tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
                case "⇤": tv.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
                case "⏎": tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                case "⌫": tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                case "⎋": tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                case "↶": undo?.undo()
                case "↷": undo?.redo()
                default: tv.insertText(String(key), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                if !isUndo { undo?.endUndoGrouping() }
                spin()
            }
            var result = "exited"
            if let table = editor.tableEditor, let tv = table.cellEditor {
                let text = tv.string as NSString
                let r = tv.selectedRange()
                result = text.replacingCharacters(in: r, with: r.length == 0 ? "‸" : "«" + text.substring(with: r) + "»")
                if table.focus.row != 1 || table.focus.column != 0 { result = "@\(table.focus.row),\(table.focus.column):" + result }
            }
            var ok = result == parts[2]
            let rows = editor.text.components(separatedBy: "\n").filter { $0.hasPrefix("|") }
            let stored = rows.count > 2 ? rows[2].replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression) : ""
            var notes: [String] = []
            if parts.count == 4, stored != parts[3] { ok = false; notes.append("stored \(stored.debugDescription), expected \(parts[3].debugDescription)") }
            if let broken = rows.first(where: { MarkdownScanner.splitRow($0).count != 2 }) { ok = false; notes.append("row split: \(broken)") }
            if !ok { failed += 1 }
            print(ok ? "PASS" : "FAIL", parts[0], "·", parts[1], "→", result, ok ? "" : "(expected \(parts[2])) " + notes.joined(separator: "; "))
        }
        print("MATH CELL CASES: \(total - failed)/\(total) passed")
    }

    /// `-IndiumClipboardCases file`: tables through the pasteboard (a private one) and back.
    /// A case is `### name`, then `<<< kind [arg]` sections that fill the board and `>>> kind`
    /// sections that check it; each section's body is the lines under it (`⇥` is a tab, `␠` a space).
    /// In: `table [r1,c1,r2,c2]` (a note's table copied whole, Copy Table, or a block of its
    /// cells), `tsv` (as Numbers and Excel put it), `string`, `html`, `cell` (text as typed).
    /// Out: `grid` (JSON, what a table pastes), `page` (Markdown pasted into the page, `nil`),
    /// `string`, `tsv`, `html~` (each line found in the HTML), `stored` (a typed cell's
    /// Markdown), `latex` (what a cell's math typesets), `noformulas`. Pasted cells must
    /// survive being written into a table and read back.
    static func runClipboardCases(_ text: String) {
        let pb = TableClipboard.board
        var cases: [(name: String, sections: [(kind: String, arg: String, body: [String])])] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("### ") { cases.append((String(line.dropFirst(4)), [])); continue }
            guard !cases.isEmpty else { continue }
            if line.hasPrefix("<<< ") || line.hasPrefix(">>> ") {
                let rest = line.dropFirst(4).split(separator: " ", maxSplits: 1).map(String.init)
                cases[cases.count - 1].sections.append((String(line.prefix(1)) + rest[0], rest.count > 1 ? rest[1] : "", []))
            } else if !cases[cases.count - 1].sections.isEmpty {
                cases[cases.count - 1].sections[cases[cases.count - 1].sections.count - 1].body.append(line.replacingOccurrences(of: "⇥", with: "\t").replacingOccurrences(of: "␠", with: " "))
            }
        }
        var passed = 0
        for c in cases {
            pb.clearContents()
            var notes: [String] = []
            var typed: String?
            func check(_ what: String, _ got: String?, _ want: String) {
                if (got ?? "nil") != want { notes.append("\(what): got \((got ?? "nil").debugDescription), want \(want.debugDescription)") }
            }
            for s in c.sections {
                var body = s.body
                while body.last == "" { body.removeLast() }
                let joined = body.joined(separator: "\n")
                switch s.kind {
                case "<table":
                    guard let block = MarkdownScanner.scan(joined as NSString).first, case let .table(spec) = block.kind else { notes.append("no table"); continue }
                    let columns = max(spec.alignments.count, spec.rows.map(\.count).max() ?? 0)
                    let all = spec.rows.map { row in (0..<columns).map { $0 < row.count ? TableSpec.unescapeCell(row[$0].text) : "" } }
                    let n = s.arg.split(separator: ",").compactMap { Int($0) }
                    if n.count == 4 {
                        let cells = all[n[0]...n[2]].map { Array($0[n[1]...n[3]]) }
                        TableClipboard.write(cells, header: n[0] == 0, markdown: nil, to: pb)
                    } else {
                        TableClipboard.write(all, header: true, markdown: joined, to: pb)
                    }
                case "<tsv":
                    pb.addTypes([TableClipboard.tabularType, .string], owner: nil)
                    pb.setString(joined, forType: TableClipboard.tabularType)
                    pb.setString(joined, forType: .string)
                case "<string":
                    pb.addTypes([.string], owner: nil)
                    pb.setString(joined, forType: .string)
                case "<html":
                    pb.addTypes([.html], owner: nil)
                    pb.setString(joined, forType: .html)
                case "<cell":
                    typed = joined
                case ">grid":
                    let grid = TableClipboard.grid(from: pb)
                    let want = joined == "null" ? nil : (try? JSONDecoder().decode([[String]].self, from: Data(joined.utf8))) ?? [["<bad json>"]]
                    if grid != want { notes.append("grid: got \(grid.map { "\($0)" } ?? "nil"), want \(want.map { "\($0)" } ?? "nil")") }
                    // Written into a table and read back, the cells are the same.
                    if let grid, let first = grid.first {
                        let md = TableSpec.markdown(header: first.map(TableSpec.escapeCell), body: grid.dropFirst().map { $0.map(TableSpec.escapeCell) },
                                                    alignments: [], dashes: nil)
                        if let back = TableClipboard.markdownTable(md), back.map({ $0.map { $0.trimmingCharacters(in: .whitespaces) } })
                            != grid.map({ $0.map { $0.trimmingCharacters(in: .whitespaces) } }) {
                            notes.append("table round trip: \(back) from \(md.debugDescription)")
                        }
                    }
                case ">page": check("page", TableClipboard.pageTable(from: pb), joined)
                case ">cell": check("cell into the page", TableClipboard.singleCell(from: pb), joined)
                case ">string": check("string", pb.string(forType: .string), joined)
                case ">tsv": check("tsv", pb.string(forType: TableClipboard.tabularType), joined)
                case ">html~":
                    let html = pb.string(forType: .html) ?? ""
                    for line in body where !html.contains(line) { notes.append("html lacks \(line.debugDescription) in \(html.debugDescription)") }
                case ">noformulas":
                    for type in pb.types ?? [] where (pb.string(forType: type) ?? pb.data(forType: type).flatMap { String(data: $0, encoding: .utf8) } ?? "").contains("TBLFM") {
                        notes.append("formulas in \(type.rawValue)")
                    }
                case ">stored":
                    guard let typed else { notes.append("no <cell"); continue }
                    let stored = TableSpec.escapeCell(typed)
                    check("stored", stored, joined)
                    check("seen again", TableSpec.unescapeCell(stored), typed)
                    // Through a whole table in a note and back.
                    let note = TableSpec.markdown(header: ["h"], body: [[stored]], alignments: [], dashes: nil)
                    if case let .table(spec)? = MarkdownScanner.scan(note as NSString).first?.kind {
                        check("scanned", spec.body.first?.first, joined)
                    }
                case ">latex":
                    guard let typed else { notes.append("no <cell"); continue }
                    let seen = typed as NSString
                    let maths = MarkdownScanner.inlineSpans(in: seen, range: NSRange(location: 0, length: seen.length)).compactMap { span -> String? in
                        if case let .math(latex, _) = span.kind { return latex }
                        return nil
                    }
                    check("latex", maths.joined(separator: " ; "), joined)
                    // The table draws stored text the way the cell editor draws what's typed.
                    let stored = TableSpec.escapeCell(typed)
                    let render = TableRender(spec: TableSpec(rows: [[.init(text: stored, offset: 0)]], alignments: [0]),
                                             typography: Typography.current, maxWidth: 600)
                    let editor = TableRender.render(typed, header: true, alignment: 0, typography: .current, size: round(Typography.current.size * 0.9))
                    let widths = render.columnWidths.first.map { Int($0) }
                    let natural = Int(ceil(editor.size().width) + TableRender.padX * 2)
                    print("  \(c.name): typeset \(maths) table cell width \(widths ?? -1), editor text width \(natural)")
                default:
                    notes.append("unknown section \(s.kind)")
                }
            }
            if notes.isEmpty { passed += 1 }
            print(notes.isEmpty ? "PASS" : "FAIL", c.name, notes.isEmpty ? "" : "\n    " + notes.joined(separator: "\n    "))
        }
        print("CLIPBOARD CASES: \(passed)/\(cases.count) passed")
    }

    /// `-IndiumDragSteps "hover:0;drag:0,Outro,after,/tmp/d.png;text;undo;text"`: moves tables by
    /// their grip with real mouse events. `hover:n` shows table n's grip; `drag:n,prefix,where[,shot]`
    /// drags it to the block starting with `prefix` (`before`, `after`, `left`, `right` = beside it),
    /// screenshotting the drop indicator mid-drag; `escape:n,prefix,where` drags and presses Escape;
    /// `text`, `undo`, `redo`, `shot:path`. Each mutating step is its own undo group.
    static func runDragSteps(_ steps: [String], editor: EditorController, window: NSWindow) {
        let tv = editor.textView
        let undo = tv.undoManager
        if let undo, undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo?.groupsByEvent = false
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: tv.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func hover(_ n: Int) -> BlockHandleView? {
            let tables = editor.visibleTables().sorted { $0.location < $1.location }
            guard n < tables.count else { print("  no table \(n)"); return nil }
            editor.hoverTableGrip(at: NSPoint(x: tables[n].content.midX, y: tables[n].content.minY + 4))
            print("  GRIP table \(n) at \(tables[n].content): \(editor.tableGrip.map { "\($0.frame)" } ?? "none")")
            return editor.tableGrip
        }
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let args = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
            switch parts[0] {
            case "hover": _ = hover(Int(args.first ?? "0") ?? 0)
            case "drag", "escape":
                guard args.count >= 3, let grip = hover(Int(args[0]) ?? 0),
                      let target = editor.visibleGroupFrames().first(where: { $0.group.text.hasPrefix(args[1]) }) else { print("  DRAG: nothing to drag or no target \(args)"); break }
                let r = target.rect
                let p: NSPoint = switch args[2] {
                case "before": NSPoint(x: r.midX, y: r.minY + min(6, r.height / 4))
                case "left": NSPoint(x: r.minX + 8, y: r.midY)
                case "right": NSPoint(x: r.maxX - 8, y: r.midY)
                default: NSPoint(x: r.midX, y: r.maxY - min(6, r.height / 4))
                }
                if args.count > 3 { EditorController.onDragStep = { debugShot(window: window, path: args[3]) } }
                let start = NSPoint(x: grip.frame.midX, y: grip.frame.midY)
                NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: (start.x + p.x) / 2, y: (start.y + p.y) / 2)), atStart: false)
                NSApp.postEvent(mouse(.leftMouseDragged, p), atStart: false)
                if parts[0] == "escape", let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                                     context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(esc, atStart: false)
                }
                NSApp.postEvent(mouse(.leftMouseUp, p), atStart: false)
                print("  DRAG table \(args[0]) to \(args[2]) \(args[1].debugDescription) at \(p), hit:", window.contentView?.superview?.hitTest(window.contentView!.superview!.convert(tv.convert(start, to: nil), from: nil)).map { "\(type(of: $0))" } ?? "nil")
                undo?.beginUndoGrouping()
                grip.mouseDown(with: mouse(.leftMouseDown, start))
                undo?.endUndoGrouping()
                EditorController.onDragStep = nil
                print("  undo name:", undo?.undoActionName ?? "-", "grip left:", editor.tableGrip == nil)
            case "undo": undo?.undo()
            case "redo": undo?.redo()
            case "text": print("NOTE TEXT:\n" + editor.text + "\nEND NOTE TEXT")
            case "shot": debugShot(window: window, path: parts.count > 1 ? parts[1] : "/tmp/drag.png")
            default: print("  unknown step \(step)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    static func runIfRequested(_ controller: DocumentWindowController) {
        let d = UserDefaults.standard
        // Harness runs copy and paste on a board of their own, never the real clipboard.
        if d.object(forKey: "IndiumSnapshot") != nil || d.object(forKey: "IndiumPDF") != nil {
            TableClipboard.board = NSPasteboard.withUniqueName()
            atexit { TableClipboard.board.releaseGlobally() }
        }
        if let path = d.string(forKey: "IndiumClipboardCases") {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("CLIPBOARD CASES: can't read \(path)"); exit(1) }
            runClipboardCases(text)
            exit(0)
        }
        if let steps = d.string(forKey: "IndiumAccessSteps") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                runAccessSteps(steps.split(separator: ";").map(String.init), controller: controller)
            }
            return
        }
        if let steps = d.string(forKey: "IndiumSidebarSteps") {
            if let size = d.string(forKey: "IndiumSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                controller.window?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                controller.debugSidebar(steps: steps.split(separator: ",").map(String.init), out: d.string(forKey: "IndiumSnapshot"))
            }
            return
        }
        if let steps = d.string(forKey: "IndiumIconSteps") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                runIconSteps(steps.split(separator: ";").map(String.init), controller: controller)
            }
            return
        }
        if let out = d.string(forKey: "IndiumPickerShot") {
            let picker = IconPickerController()
            picker.current = "atom"
            let view = picker.view
            view.layoutSubtreeIfNeeded()
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            exit(0)
        }
        if d.bool(forKey: "IndiumLayoutTest") { runLayoutTests(); exit(0) }
        if d.bool(forKey: "IndiumMathWidths") {
            for latex in ["x", "x^2", "HNO_3", "a+b", "Cu = 1 \\qquad N = 2"] {
                if let r = MathRenderer.render(latex, size: 17, display: false) {
                    print(latex, "width:", r.display.width, "ceil:", r.width)
                }
            }
            exit(0)
        }
        // `-IndiumMathCorpus /path`: one LaTeX expression per line; prints each that fails to typeset.
        if let path = d.string(forKey: "IndiumMathCorpus"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            var failed = 0
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            for latex in lines {
                let source = MathRenderer.normalize(latex)
                var error: NSError?
                let list = MTMathListBuilder.build(fromString: "\\textstyle " + source, error: &error)
                if list == nil || error != nil || MathRenderer.render(latex, size: 17, display: false) == nil {
                    failed += 1
                    print("FAIL", latex, "→", error?.localizedDescription ?? "no display")
                }
            }
            print("\(lines.count - failed)/\(lines.count) typeset")
            exit(0)
        }
        // `-IndiumMathSnippetRender YES`: every math shortcut's output (blanks filled in) must typeset.
        if d.bool(forKey: "IndiumMathSnippetRender") {
            var samples = MathSnippet.all.compactMap { s -> String? in if case let .literal(t) = s.trigger { return t }; return nil }
            samples += ["x1", "CO2", "x12", "\\alpha1", "\\sin2", "x_{1}2", "x_12", "\\hat{x}1", "\\vec{\\alpha}_{1}2", "xhat", "xbar",
                        "xdot", "xddot", "xtilde", "xund", "xvec", "x,.", "x.,", "\\alpha,.", "3rt", "par2", "pab", "iden3", "beg",
                        "\\alpha hat", "\\alpha bar", "\\alpha dot", "\\alpha vec", "\\alpha tilde", "\\alpha und", "\\alpha sr",
                        "\\infty cb", "\\alpha rd"]
            var failed = 0, total = 0
            for sample in samples {
                for display in [false, true] {
                    for auto in [true, false] {
                        let before = ("z " + sample) as NSString
                        guard let e = MathSnippet.expansion(before: before as String, context: .math(display: display), auto: auto) else { continue }
                        var text = e.text as NSString
                        let blanks = (e.stops + e.copies.flatMap { $0 }).filter { $0.length == 0 }.sorted { $0.location > $1.location }
                        for b in blanks {
                            let env = b.location >= 7 && ["\\begin{", "\\end{"].contains { text.substring(to: b.location).hasSuffix($0) }
                            let afterCommand = text.substring(to: b.location).range(of: #"\\[A-Za-z]+$"#, options: .regularExpression) != nil
                            text = text.replacingCharacters(in: b, with: env ? "matrix" : afterCommand ? " a" : "a") as NSString
                        }
                        let doc = before.substring(to: before.length - e.length) + (text as String)
                        total += 1
                        if MathRenderer.render(doc, size: 17, display: display) == nil {
                            failed += 1
                            print("FAIL", sample, display ? "display" : "inline", auto ? "auto" : "tab", "→", doc.debugDescription)
                        }
                    }
                }
            }
            for (key, template) in MathSnippet.visual {
                let r = MathSnippet.render(template, captures: [], visual: "x + y")
                let doc = (r.text as NSString).replacingOccurrences(of: "{  }", with: "{ a }")
                total += 1
                if MathRenderer.render(doc, size: 17, display: false) == nil { failed += 1; print("FAIL visual", key, "→", doc) }
            }
            print("SNIPPETS: \(total - failed)/\(total) typeset")
            exit(0)
        }
        // `-IndiumMathSnippetsFile path`: your math shortcuts from this file instead of the folder's.
        if let path = d.string(forKey: "IndiumMathSnippetsFile") {
            let config = MathSnippetConfig.shared
            config.overrideURL = URL(fileURLWithPath: path)
            config.refresh(force: true)
            print("SNIPPET CONFIG: \(config.loadedCount) loaded")
            for problem in config.problems { print("SNIPPET PROBLEM:", problem) }
            // `-IndiumMathSnippetsCreate YES`: what Edit Math Shortcuts… does before opening the file
            // (the alert it would show, printed instead).
            if d.bool(forKey: "IndiumMathSnippetsCreate") {
                print("SNIPPET CREATE:", config.prepareFile().map { "failed: " + $0.replacingOccurrences(of: "\n", with: " ") } ?? "ok")
                exit(0)
            }
            // `-IndiumMathSnippetsReference out.md`: the Math Shortcuts note, written out.
            if let out = d.string(forKey: "IndiumMathSnippetsReference") {
                try? config.reference.write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
        }
        // `-IndiumMathSnippetConfigCases cases.tsv`: `file<TAB>shortcuts loaded<TAB>problems`, the
        // problems as `¦`-separated pieces of text each one must contain (files relative to the cases).
        if let path = d.string(forKey: "IndiumMathSnippetConfigCases"), let cases = try? String(contentsOfFile: path, encoding: .utf8) {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            var failed = 0, total = 0
            for line in cases.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("#") {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { continue }
                total += 1
                let text = (try? String(contentsOf: dir.appendingPathComponent(parts[0]), encoding: .utf8)) ?? ""
                let result = MathSnippetConfig.parse(text)
                let expected = parts.count < 3 || parts[2].isEmpty ? [] : parts[2].components(separatedBy: "¦").map { $0.trimmingCharacters(in: .whitespaces) }
                let ok = String(result.snippets.count) == parts[1] && result.problems.count == expected.count
                    && zip(result.problems, expected).allSatisfy { $0.contains($1) }
                if !ok { failed += 1 }
                print(ok ? "PASS" : "FAIL", parts[0], "→", result.snippets.count, "loaded;", result.problems.isEmpty ? "no problems" : result.problems.joined(separator: " ¦ "))
            }
            print("SNIPPET CONFIG CASES: \(total - failed)/\(total) passed")
            exit(0)
        }
        // `-IndiumMathCellSnippets YES`: every math shortcut as a table cell writes it: one line,
        // no bare `|` (it would split the row), and it still typesets.
        if d.bool(forKey: "IndiumMathCellSnippets") {
            var samples = MathSnippet.all.compactMap { s -> String? in if case let .literal(t) = s.trigger { return t }; return nil }
            samples += ["x1", "CO2", "x_{1}2", "\\hat{x}1", "beg", "\\alpha sr"]
            var failed = 0, total = 0, declined = 0
            for sample in samples {
                for display in [false, true] {
                    for auto in [true, false] {
                        let before = "z " + sample
                        guard let e = MathSnippet.expansion(before: before, context: .math(display: display), auto: auto, pipes: false) else { continue }
                        if e.text.contains("\n") { declined += 1; continue }
                        var text = e.text as NSString
                        for b in (e.stops + e.copies.flatMap { $0 }).filter({ $0.length == 0 }).sorted(by: { $0.location > $1.location }) {
                            let env = ["\\begin{", "\\end{"].contains { text.substring(to: b.location).hasSuffix($0) }
                            let afterCommand = text.substring(to: b.location).range(of: #"\\[A-Za-z]+$"#, options: .regularExpression) != nil
                            text = text.replacingCharacters(in: b, with: env ? "matrix" : afterCommand ? " a" : "a") as NSString
                        }
                        let doc = String((before as NSString).substring(to: (before as NSString).length - e.length)) + (text as String)
                        total += 1
                        let piped = (text as String).contains("|")
                        if piped || MathRenderer.render(doc, size: 17, display: display) == nil {
                            failed += 1
                            print("FAIL", sample, display ? "display" : "inline", auto ? "auto" : "tab", piped ? "pipe" : "typeset", "→", doc.debugDescription)
                        }
                    }
                }
            }
            print("CELL SNIPPETS: \(total - failed)/\(total) fit a cell (\(declined) multi-line declined)")
            exit(0)
        }
        // `-IndiumEvalCases a.tsv,b.tsv,c.md`: formula regression cases (quick answers, evaluator,
        // table formulas; see FormulaSelfTest). `-IndiumEvalVerbose YES` prints every table result.
        if let paths = d.string(forKey: "IndiumEvalCases") {
            let failed = FormulaSelfTest.run(paths: paths.split(separator: ",").map(String.init), verbose: d.bool(forKey: "IndiumEvalVerbose"))
            exit(failed == 0 ? 0 : 1)
        }
        if d.bool(forKey: "IndiumMathTest") {
            let cases: [(String, Bool)] = [("1 + 2 =", false), ("1 + 2 = ", false), ("Mass is 2 + 3 =", false), ("x =", false),
                ("35.134\\text{ g} - 34.794\\text{ g} =", true), ("\\frac{0.147\\text{ g Zn}}{65.38\\text{ g/mol}} =", true),
                ("\\frac{2.4-2}{2}\\times100 =", true), ("\\frac{7.20\\times10^{24}}{6.022\\times10^{23}}=", true),
                ("7 / 2 =", false), ("2^10 =", false), ("sqrt(16) + 1 =", false), ("15% * 200 =", false), ("a = 3 * 4 =", false),
                ("$0.340 - 0.147 =", false)]
            for (line, math) in cases {
                let r = MathAnswer.suggest(lineBeforeCaret: line, inMath: math)
                print(line, "→", r.map { "[\($0.display)] insert=[\($0.insertion)]" } ?? "nil")
            }
            exit(0)
        }
        let pdfPath = d.string(forKey: "IndiumPDF")
        guard let out = d.string(forKey: "IndiumSnapshot") ?? pdfPath.map({ _ in "" }) else { return }
        var target = controller
        if d.bool(forKey: "IndiumTemp") {
            AppDelegate.shared.newTemporaryNote(nil)
            if let c = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController }).first(where: { $0.kind == .temporary }) {
                target = c
                // `-IndiumTempFile path`: the note's text verbatim (LaTeX's `\n…` commands survive).
                if let path = d.string(forKey: "IndiumTempFile"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    c.editor.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
                }
                if let text = d.string(forKey: "IndiumTempText") {
                    c.editor.textView.insertText(text.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: NSRange(location: 0, length: 0))
                }
            }
        }
        guard let window = target.window else { return }
        if let size = d.string(forKey: "IndiumSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if d.object(forKey: "IndiumSelect") != nil {
                let loc = d.integer(forKey: "IndiumSelect")
                window.makeFirstResponder(target.editor.textView)
                target.editor.textView.setSelectedRange(NSRange(location: loc, length: d.integer(forKey: "IndiumSelectLength")))
            }
            if d.object(forKey: "IndiumScroll") != nil {
                target.editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: d.double(forKey: "IndiumScroll")))
                target.editor.scrollView.reflectScrolledClipView(target.editor.scrollView.contentView)
            }
            if d.bool(forKey: "IndiumTableEdit"),
               let block = target.editor.styler.blocks.first(where: { if case .table = $0.kind { return true }; return false }) {
                let cell = (d.string(forKey: "IndiumTableCell") ?? "2,1").split(separator: ",").compactMap { Int($0) }
                target.editor.beginTableEditing(at: block.range.location, row: cell.first ?? 2, column: cell.last ?? 1)
                if d.bool(forKey: "IndiumTableAddRow") { target.editor.tableEditor?.addRow(below: nil) }
                // `-IndiumTableType "some text"`: types into the focused cell a key at a time,
                // printing the grid after each so any shifting shows as changing numbers.
                if let typed = d.string(forKey: "IndiumTableType") {
                    for ch in typed {
                        target.editor.tableEditor?.cellEditor?.insertText(String(ch), replacementRange: target.editor.tableEditor?.cellEditor?.selectedRange() ?? NSRange())
                        if let e = target.editor.tableEditor {
                            print("TYPED \(String(ch).debugDescription) widths:", e.render.columnWidths.map { Int($0) }, "rows:", e.render.rowHeights.map { Int($0) }, "x:", Int(e.frame.minX))
                        }
                    }
                }
                // `-IndiumTableSteps "select:1,0,2,1;copy;pb:a\tb\nc\td;paste;cut;key:moveRight:"`: each step
                // goes to the focused view through the responder chain, as a key or menu item would.
                // Each step its own undo group, as each key press would be.
                let undo = target.editor.textView.undoManager
                let steps = (d.string(forKey: "IndiumTableSteps") ?? "").split(separator: ";").map(String.init).filter { !$0.isEmpty }
                if !steps.isEmpty, let undo {
                    if undo.groupingLevel > 0 { undo.endUndoGrouping() }
                    undo.groupsByEvent = false
                }
                for step in steps {
                    // Steps that only look (and Tab, as a real key) open no explicit undo group: an empty
                    // explicit group stays on the stack, where a real key event's empty group is dropped.
                    let isUndo = ["undo", "redo", "noteundo", "tab", "text", "caption", "shot", "focus", "done", "notesel", "selectAll", "select", "pb", "pbhtml", "pbtsv", "copy", "copyTable", "keyev", "cmdev", "switchto", "idle", "cat", "tips", "list", "hint", "draft"].contains(step.split(separator: ":").first.map(String.init) ?? "")
                    if !isUndo { undo?.beginUndoGrouping() }
                    defer { if !isUndo { undo?.endUndoGrouping() } }
                    let e = target.editor.tableEditor
                    let arg = step.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    switch step.split(separator: ":").first.map(String.init) ?? "" {
                    case "select":
                        let n = arg.split(separator: ",").compactMap { Int($0) }
                        e?.select(from: (n[0], n[1]), to: (n[2], n[3]))
                    case "pb", "pbhtml", "pbtsv":
                        // `pb:text` plain text, `pbhtml:<table>…` a web page's HTML only, `pbtsv:a\tb`
                        // a spreadsheet's cells; on the harness's private board.
                        let board = TableClipboard.board
                        let value = arg.replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\n", with: "\n")
                        board.clearContents()
                        switch step.split(separator: ":").first {
                        case "pbhtml": board.setString(value, forType: .html)
                        case "pbtsv":
                            board.setString(value, forType: TableClipboard.tabularType)
                            board.setString(value, forType: .string)
                        default: board.setString(value, forType: .string)
                        }
                    case "type":
                        window.firstResponder?.insertText(arg)
                    case "captionclick":
                        // A click on the first caption offering Recalculate, through the note's mouseDown.
                        let tv = target.editor.textView, lm = target.editor.layoutManager, st = target.editor.storage
                        var spot: NSPoint?
                        st.enumerateAttribute(.mdCaption, in: NSRange(location: 0, length: st.length)) { v, r, stop in
                            // `captionclick:list` takes any caption, on its words (the formula list).
                            guard let c = v as? CaptionDecoration, c.action != nil || arg == "list" else { return }
                            let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: r.location), effectiveRange: nil)
                            // On the word Recalculate, or (`captionclick:text`) on the caption's own words.
                            let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
                            let col = lm.contentColumn(glyph: lm.glyphIndexForCharacter(at: r.location), container: tv.textContainer!, origin: tv.textContainerOrigin).x
                            let word = col + ((c.text + " · ") as NSString).size(withAttributes: font).width + 20
                            spot = NSPoint(x: arg == "text" || arg == "list" ? col + 20 : word, y: tv.textContainerOrigin.y + frag.midY)
                            stop.pointee = true
                        }
                        if let spot {
                            func mouse(_ type: NSEvent.EventType) -> NSEvent {
                                NSEvent.mouseEvent(with: type, location: tv.convert(spot, to: nil), modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                            }
                            NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
                            tv.mouseDown(with: mouse(.leftMouseDown))
                        } else { print("  no caption offers Recalculate") }
                    case "idle":
                        // `idle:1.5`: nothing happens for that long (timers such as autosave fire).
                        RunLoop.current.run(until: Date().addingTimeInterval(Double(arg) ?? 1))
                    case "cat":
                        print("FILE \(arg):\n" + ((try? String(contentsOfFile: arg, encoding: .utf8)) ?? "-"))
                    case "switchto":
                        // `switchto:/path.md`: opens another note in this editor, as the sidebar would,
                        // printing any change made to the note being left on the way out.
                        let editor = target.editor, old = editor.note
                        let watch = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: editor.textView, queue: nil) { _ in
                            print("CHANGED ON THE WAY OUT:\n" + editor.text)
                        }
                        if let next = try? Note(url: URL(fileURLWithPath: arg)) { editor.load(next) }
                        NotificationCenter.default.removeObserver(watch)
                        print("  left note undo level:", old?.undoManager.groupingLevel ?? -1, "registration on:", old?.undoManager.isUndoRegistrationEnabled ?? false,
                              "now showing:", editor.note?.url?.lastPathComponent ?? "-")
                    case "cmdev":
                        // `cmdev:deleteBackward:`: a command as its own key event, grouped as `keyev`.
                        target.editor.textView.undoManager?.groupsByEvent = true
                        window.firstResponder?.doCommand(by: NSSelectorFromString(arg))
                        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                        if let u = target.editor.textView.undoManager, u.groupingLevel > 0 { u.endUndoGrouping() }
                        target.editor.textView.undoManager?.groupsByEvent = false
                    case "keyev":
                        // `keyev:abc`: each character as its own event, grouped by the run loop as a real
                        // key press is (a press that records no undo leaves no group behind).
                        target.editor.textView.undoManager?.groupsByEvent = true
                        for ch in arg {
                            window.firstResponder?.insertText(String(ch))
                            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                            // A nested run loop doesn't reach the end-of-event observer: close the press's group.
                            if let u = target.editor.textView.undoManager, u.groupingLevel > 0 { u.endUndoGrouping() }
                        }
                        target.editor.textView.undoManager?.groupsByEvent = false
                    case "key":
                        window.firstResponder?.doCommand(by: NSSelectorFromString(arg))
                    case "click", "drag":
                        // `click:row,column,count,dx` / `drag:r1,c1,r2,c2`: real mouse events through the window.
                        guard let e else { break }
                        let n = arg.split(separator: ",").compactMap { Double($0) }
                        func point(_ r: Double, _ c: Double, dx: Double = 20) -> NSPoint {
                            let rect = e.render.cellRect(row: Int(r), column: Int(c), in: NSRect(x: 0, y: 0, width: e.render.width, height: e.render.height))
                            return e.convert(NSPoint(x: rect.minX + TableRender.padX + dx, y: rect.midY), to: nil)
                        }
                        func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent {
                            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
                        }
                        let from = step.hasPrefix("click") ? point(n[0], n[1], dx: n.count > 3 ? n[3] : 20) : point(n[0], n[1])
                        let to = step.hasPrefix("click") ? from : point(n[2], n[3])
                        let clicks = step.hasPrefix("click") && n.count > 2 ? Int(n[2]) : 1
                        if !step.hasPrefix("click") { NSApp.postEvent(mouse(.leftMouseDragged, to), atStart: false) }
                        NSApp.postEvent(mouse(.leftMouseUp, to, clicks: clicks), atStart: false)
                        // Straight to the view hit testing picks: a window in the background would
                        // take the first click as activation only.
                        let hit = window.contentView?.superview?.hitTest(window.contentView!.superview!.convert(from, from: nil))
                        print("  hit:", hit.map { String(describing: type(of: $0)) } ?? "nil")
                        // As the window does with a real click: the view takes the keys first if it accepts them.
                        if let hit, hit.acceptsFirstResponder, window.firstResponder !== hit { window.makeFirstResponder(hit) }
                        hit?.mouseDown(with: mouse(.leftMouseDown, from, clicks: clicks))
                    case "copyTable": e?.copyTable()
                    case "done":
                        target.editor.endTableEditing(caretAfter: true)
                    // Table formulas: `formula` is the toolbar's Formula (starts `=` in the focused cell),
                    // `fill:right` / `fill:down` its Fill Formula Right / Down, `hint` prints the hint under
                    // the cell, `draft` what the cell holds back and the cells it names; `text` prints the
                    // note, `caption` the captions drawn, `shot:path` a screenshot.
                    case "formula": e?.startFormula()
                    case "fill": target.editor.fillTableFormula(down: arg == "down")
                    case "hint":
                        print("  HINT:", target.editor.formulaHint.map { "\($0.text.debugDescription) frame \($0.frame)" } ?? "none")
                    case "draft":
                        let ruler = target.editor.textView.subviews.compactMap { $0 as? TableReferenceRuler }.first
                        print("  DRAFT:", e?.draft.map { "\($0.cell) original \($0.original.debugDescription)" } ?? "none",
                              "names:", e?.referencedAreas.map { "\($0.0)-\($0.1)" } ?? [],
                              "ruler:", ruler.map { "\($0.labels.columns.joined()) \($0.labels.rows.joined(separator: ",")) frame \($0.frame)" } ?? "none",
                              "table takes keys:", e?.acceptsFirstResponder ?? false)
                    // Structure, as the toolbar and cell menu do it: `focus:r,c`, `addrow` (below),
                    // `addrowabove`, `delrow`, `addcol` (right), `addcolleft`, `delcol`.
                    case "focus":
                        let n = arg.split(separator: ",").compactMap { Int($0) }
                        e?.focusCell(row: n[0], column: n[1])
                    case "addrow": e?.addRow(below: nil)
                    case "addrowabove": e?.addRow(above: nil)
                    case "delrow": e?.deleteRow()
                    case "addcol": e?.addColumn(right: nil)
                    case "addcolleft": e?.addColumn(left: nil)
                    case "delcol": e?.deleteColumn()
                    case "tab":
                        // Tab to the next cell outside an explicit undo group: a real key's
                        // event group that registers nothing is dropped, an explicit one isn't.
                        window.firstResponder?.doCommand(by: #selector(NSResponder.insertTab(_:)))
                    case "noteundo", "undo", "redo":
                        // The note's own undo, as Edit ▸ Undo in the note would.
                        let um = target.editor.textView.undoManager
                        print("  noteundo level:", um?.groupingLevel ?? -1, "name:", um?.undoActionName ?? "-", "same as note's:", um === target.editor.note?.undoManager)
                        if step == "redo" { um?.redo() } else { um?.undo() }
                    case "text":
                        let um = target.editor.textView.undoManager
                        print("NOTE TEXT (canUndo \(um?.canUndo ?? false) [\(um?.undoActionName ?? "-")] canRedo \(um?.canRedo ?? false)):\n" + target.editor.text)
                    case "caption":
                        let storage = target.editor.storage
                        storage.enumerateAttribute(.mdCaption, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                            if let c = v as? CaptionDecoration { print("  CAPTION at \(r.location) error=\(c.isError): \(c.text)") }
                        }
                    case "shot":
                        debugShot(window: window, path: arg)
                    // Computed cells: `tips` prints each one's tooltip (the open table's fields, or the
                    // rendered page's), `list` the caption popover's rows, `listedit:n` its Edit.
                    case "tips":
                        let ed = target.editor
                        if let open = e {
                            for f in open.subviews.compactMap({ $0 as? CellField }) where f.toolTip != nil {
                                print("  TIP field \(f.row),\(f.column): \(f.toolTip!.debugDescription)")
                            }
                        } else if let block = ed.styler.blocks.first(where: { if case .table = $0.kind { return true }; return false }),
                                  let rect = ed.layoutManager.blockRects(in: NSRange(location: block.range.location, length: 1), origin: ed.textView.textContainerOrigin).first,
                                  case let .table(t) = rect.decoration.content {
                            ed.updateCellTips()
                            for r in 0..<t.rowHeights.count {
                                for c in 0..<t.columnWidths.count {
                                    let box = t.cellRect(row: r, column: c, in: rect.content)
                                    if let tip = ed.cellTip(at: NSPoint(x: box.midX, y: box.midY)) { print("  TIP page \(r),\(c): \(tip.debugDescription)") }
                                }
                            }
                            print("  TIP rects on the page:", ed.cellTipCount)
                        }
                    case "list", "listedit":
                        let list = NSApp.windows.compactMap { $0.contentViewController as? TableFormulaListPopover }.first
                            ?? target.editor.formulaListPopover?.contentViewController as? TableFormulaListPopover
                        if !step.hasPrefix("listedit") { print("  LIST:", list.map { $0.rows.map(\.text) } ?? []) }
                        else { list?.debugEdit(Int(arg) ?? 0) }
                    case "notesel":
                        let n = arg.split(separator: ",").compactMap { Int($0) }
                        window.makeFirstResponder(target.editor.textView)
                        target.editor.textView.setSelectedRange(NSRange(location: n[0], length: n[1]))
                    default:
                        let action = NSSelectorFromString(step + ":")
                        var responder = window.firstResponder
                        while let r = responder, !r.responds(to: action) { responder = r.nextResponder }
                        let um = target.editor.textView.undoManager
                        print("  \(step) handled by:", responder.map { String(describing: type(of: $0)) } ?? "nobody", "level:", um?.groupingLevel ?? -1, "undoName:", um?.undoActionName ?? "-")
                        _ = responder?.perform(action, with: nil)
                    }
                    // Each step its own event, so undo groups fall as they would with real keys.
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    let pb = TableClipboard.board
                    print("STEP \(step) responder:", window.firstResponder.map { String(describing: type(of: $0)) } ?? "-",
                          "focus:", e.map { "\($0.focus)" } ?? "-", "selection:", e?.selection.map { "\($0.anchor)->\($0.head)" } ?? "none",
                          "cell:", e?.cellEditor.map { "\($0.string.debugDescription) sel \(NSStringFromRange($0.selectedRange()))" } ?? "-")
                    if let i = target.editor.styler.blocks.firstIndex(where: { if case .table = $0.kind { return true }; return false }) {
                        print("  NOTE TABLE:", (target.editor.text as NSString).substring(with: target.editor.styler.blocks[i].range).components(separatedBy: "\n").enumerated().filter { $0.offset != 1 }.map { $0.element.replacingOccurrences(of: " ", with: "") }.joined(separator: " "))
                    }
                    if step == "copy" || step == "cut" || step == "copyTable" {
                        print("  PB string:", (pb.string(forType: .string) ?? "nil").debugDescription)
                        print("  PB html:", pb.string(forType: .html) ?? "nil")
                        print("  PB cells:", TableClipboard.payload(pb).map { "\($0.cells) source: \(($0.source ?? "nil").debugDescription)" } ?? "nil")
                    }
                }
                if let side = d.string(forKey: "IndiumPlaceTable") {
                    target.editor.placeEditedTable(float: side == "full" ? nil : side == "right")
                }
                print("TABLE MD:\n" + ((target.editor.text as NSString).substring(with: target.editor.styler.blocks.first(where: { if case .table = $0.kind { return true }; return false })!.range)))
            }
            // `-IndiumPointerSteps "move:R,10,20;click:L,-30,40;scroll:300"`: the pointer, relative to a
            // corner of a table's grid (L top-left, R top-right, B bottom-left; `-IndiumPointerTable n`
            // picks the table). `move` hovers (entering whatever strip is there), `click` sends a
            // mouse-down to the view hit testing picks, `scroll` scrolls the note to a y offset.
            if let steps = d.string(forKey: "IndiumDragSteps") {
                runDragSteps(steps.split(separator: ";").map(String.init), editor: target.editor, window: window)
            }
            if let steps = d.string(forKey: "IndiumPointerSteps") {
                let editor = target.editor, tv = editor.textView
                func tableRect() -> NSRect? {
                    let tables = editor.styler.blocks.filter { if case .table = $0.kind { return true }; return false }
                    let n = d.integer(forKey: "IndiumPointerTable")
                    guard n < tables.count else { return nil }
                    if let open = editor.tableEditor, let loc = editor.styler.editingTableLocation, loc == tables[n].range.location {
                        return NSRect(origin: open.frame.origin, size: NSSize(width: open.render.width, height: open.render.height))
                    }
                    return editor.layoutManager.blockRects(in: NSRange(location: tables[n].range.location, length: 1), origin: tv.textContainerOrigin).first?.content
                }
                func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: tv.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                // Each step its own undo group, as each click or key would be.
                let undo = tv.undoManager
                if let undo, undo.groupingLevel > 0 { undo.endUndoGrouping() }
                undo?.groupsByEvent = false
                for step in steps.split(separator: ";").map(String.init) {
                    let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                    let args = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
                    let mutates = ["click", "stripkey", "divider"].contains(parts[0])
                    if mutates { undo?.beginUndoGrouping() }
                    defer { if mutates { undo?.endUndoGrouping() } }
                    if parts[0] == "undo" {
                        undo?.undo()
                    } else if parts[0] == "text" {
                        print("NOTE TEXT:", editor.text.debugDescription)
                    } else if parts[0] == "focus", args.count == 2, let r = Int(args[0]), let c = Int(args[1]) {
                        editor.tableEditor?.focusCell(row: r, column: c)
                    } else if parts[0] == "stripkey" {
                        // `stripkey:row|column`: focus a strip as keyboard navigation would, then press Space.
                        let strip = editor.tableEditor?.subviews.compactMap { $0 as? TableEdgeStrip }.first { "\($0.adds)" == args.first }
                        let took = strip.map { window.makeFirstResponder($0) } ?? false
                        print("STRIPKEY", args.first ?? "-", "keyView:", strip?.canBecomeKeyView ?? false, "focused:", took,
                              "reached from last cell:", editor.tableEditor?.subviews.compactMap { $0 as? CellField }.last?.nextKeyView === strip || strip?.adds == .row)
                        if let strip, let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                                     context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
                            strip.keyDown(with: space)
                        }
                    } else if parts[0] == "divider", args.count == 2, let c = Int(args[0]), let dx = Double(args[1]), let e = editor.tableEditor {
                        // `divider:column,dx`: drags the divider right of a column by dx points.
                        let x = e.render.columnWidths[...c].reduce(0, +), y = (e.render.rowHeights.first ?? 20) / 2
                        func event(_ type: NSEvent.EventType, _ px: CGFloat) -> NSEvent {
                            NSEvent.mouseEvent(with: type, location: e.convert(NSPoint(x: px, y: y), to: nil), modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        }
                        let before = e.render.columnWidths.map { Int($0) }
                        e.mouseDown(with: event(.leftMouseDown, x))
                        e.mouseDragged(with: event(.leftMouseDragged, x + dx))
                        e.mouseUp(with: event(.leftMouseUp, x + dx))
                        print("DIVIDER widths:", before, "->", e.render.columnWidths.map { Int($0) })
                    } else if parts[0] == "caret" {
                        // The caret's views (macOS draws it in an insertion indicator) and frames.
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(tv)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                        print("CARET window:", window.windowNumber, "key:", window.isKeyWindow)
                        let lm = editor.layoutManager, at = tv.selectedRange().location
                        if at < editor.storage.length {
                            let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: at), effectiveRange: nil)
                            let line = frag.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
                            print("CARET line:", line, "drawn:", tv.caretRect(clamping: NSRect(x: line.minX, y: line.minY, width: 1, height: line.height)))
                        }
                        for v in tv.subviews where String(describing: type(of: v)).contains("Insertion") {
                            print("CARET view:", type(of: v), v.frame, "hidden:", v.isHidden)
                        }
                    } else if parts[0] == "scroll", let y = Double(args.first ?? "") {
                        editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
                    } else if args.count == 3, let t = tableRect(), let dx = Double(args[1]), let dy = Double(args[2]) {
                        let corner = args[0] == "R" ? NSPoint(x: t.maxX, y: t.minY) : args[0] == "B" ? NSPoint(x: t.minX, y: t.maxY) : t.origin
                        let p = NSPoint(x: corner.x + dx, y: corner.y + dy)
                        let hit = window.contentView?.superview?.hitTest(window.contentView!.superview!.convert(tv.convert(p, to: nil), from: nil))
                        if parts[0] == "move" {
                            tv.mouseMoved(with: mouse(.mouseMoved, p))
                            let now = window.contentView?.superview?.hitTest(window.contentView!.superview!.convert(tv.convert(p, to: nil), from: nil))
                            if let strip = now as? TableEdgeStrip { strip.mouseEntered(with: mouse(.mouseMoved, p)) }
                        } else if parts[0] == "click" {
                            NSApp.postEvent(mouse(.leftMouseUp, p), atStart: false)
                            hit?.mouseDown(with: mouse(.leftMouseDown, p))
                        }
                        print("POINTER \(step) at:", p, "hit:", hit.map { String(describing: type(of: $0)) } ?? "nil")
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    print("  table:", tableRect().map { "\($0)" } ?? "-", "caret:", NSStringFromRange(tv.selectedRange()),
                          "editing:", editor.tableEditor.map { "\($0.focus)" } ?? "no", "cell:", editor.tableEditor?.cellEditor.map { NSStringFromRange($0.selectedRange()) } ?? "-",
                          "toolbar:", editor.tableToolbar.map { "\($0.frame)" } ?? "-", "visible:", tv.visibleRect,
                          "strips:", tv.subviews.compactMap { $0 as? TableEdgeStrip }.map { "\($0.adds) \($0.frame) inside=\($0.inside)" })
                }
            }
            // `-IndiumFormat bold,undo,strike,done`: each command walks the responder chain from
            // the focused view, as a menu item or ⌘-key would. `-IndiumTableCellSelect` selects in the cell.
            if let steps = d.string(forKey: "IndiumFormat") {
                if d.object(forKey: "IndiumTableCellSelect") != nil {
                    target.editor.tableEditor?.cellEditor?.setSelectedRange(NSRange(location: d.integer(forKey: "IndiumTableCellSelect"),
                                                                                    length: d.integer(forKey: "IndiumTableCellSelectLength")))
                }
                typealias W = DocumentWindowController
                let actions: [String: Selector] = ["bold": #selector(W.toggleBold(_:)), "italic": #selector(W.toggleItalic(_:)),
                    "strike": #selector(W.toggleStrikethrough(_:)), "highlight": #selector(W.toggleHighlight(_:)),
                    "code": #selector(W.toggleInlineCode(_:)), "link": #selector(W.insertLink(_:)), "undo": Selector(("undo:"))]
                for step in steps.split(separator: ",").map(String.init) {
                    if let action = actions[step] {
                        var responder = window.firstResponder
                        while let r = responder, !r.responds(to: action) { responder = r.nextResponder }
                        let handler: AnyObject? = responder ?? window.delegate
                        _ = handler?.perform(action, with: nil)
                        print("STEP \(step) handled by:", handler.map { String(describing: type(of: $0)) } ?? "nobody")
                    } else if step == "pipe" {
                        target.editor.tableEditor?.cellEditor?.insertText("a|b", replacementRange: target.editor.tableEditor?.cellEditor?.selectedRange() ?? NSRange())
                    } else if step == "done" {
                        target.editor.endTableEditing(caretAfter: true)
                    }
                    let editor = target.editor.tableEditor?.cellEditor
                    print("STEP \(step) cell:", editor?.string.debugDescription ?? "-", "sel:", editor.map { NSStringFromRange($0.selectedRange()) } ?? "-")
                }
                DispatchQueue.main.async {
                    target.editor.saveNow()
                    print("NOTE:\n" + target.editor.text)
                }
            }
            // `-IndiumMathCases /path`: one case per line, `before<TAB>keys<TAB>expected`. `‸` marks the
            // caret and `«…»` a selection; in keys, ⇥ is Tab, ⏎ Return, ⌫ Backspace and ↶ Undo.
            if let path = d.string(forKey: "IndiumMathCases"), let cases = try? String(contentsOfFile: path, encoding: .utf8) {
                let editor = target.editor
                let tv = editor.textView
                window.makeFirstResponder(tv)
                let undo = tv.undoManager
                // `-IndiumMathRealKeys YES`: keys go in as NSEvents, one run-loop turn each, so
                // undo groups by event exactly as it does for someone typing.
                let realKeys = d.bool(forKey: "IndiumMathRealKeys")
                func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
                func send(_ chars: String, _ flags: NSEvent.ModifierFlags = []) {
                    let codes: [String: UInt16] = ["\t": 48, "\r": 36, "\u{7f}": 51]
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: codes[chars] ?? 0) {
                            window.sendEvent(e)
                        }
                    }
                    spin()
                }
                if let undo, undo.groupingLevel > 0, !realKeys { undo.endUndoGrouping() }
                if !realKeys { undo?.groupsByEvent = false }
                var failed = 0, total = 0
                func unmark(_ s: String) -> (String, NSRange) {
                    let ns = s.replacingOccurrences(of: "↵", with: "\n") as NSString
                    let caret = ns.range(of: "‸")
                    if caret.location != NSNotFound { return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0)) }
                    let a = ns.range(of: "«"), b = ns.range(of: "»")
                    let plain = ns.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
                    return (plain, a.location == NSNotFound ? NSRange(location: (plain as NSString).length, length: 0)
                                                               : NSRange(location: a.location, length: b.location - a.location - 1))
                }
                for line in cases.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("#") {
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count == 3 else { continue }
                    total += 1
                    let (start, sel) = unmark(parts[0])
                    editor.endTableEditing()
                    editor.clearMathStops()
                    if realKeys {
                        editor.replace(NSRange(location: 0, length: editor.storage.length), with: start)
                        tv.setSelectedRange(sel)
                        spin()
                        // Each case starts with nothing to undo, so ↶ can't reach into the one before.
                        undo?.removeAllActions()
                        for key in parts[1] {
                            switch key {
                            case "⇥": send("\t")
                            case "⏎": send("\r")
                            case "⇧": send("\r", .shift)
                            case "⌫": send("\u{7f}")
                            case "↶": undo?.undo(); spin()
                            case "↷": undo?.redo(); spin()
                            default: send(String(key))
                            }
                        }
                    } else {
                    undo?.beginUndoGrouping()
                    editor.replace(NSRange(location: 0, length: editor.storage.length), with: start)
                    tv.setSelectedRange(sel)
                    undo?.endUndoGrouping()
                    for key in parts[1] {
                        let isUndo = key == "↶" || key == "↷"
                        if !isUndo { undo?.beginUndoGrouping() }
                        switch key {
                        case "⇥": tv.insertTab(nil)
                        case "⏎": tv.insertNewline(nil)
                        case "⇧": if !editor.handleMathNewline(shift: true) { tv.insertLineBreak(nil) }
                        case "⌫": tv.deleteBackward(nil)
                        case "↶": undo?.undo()
                        case "↷": undo?.redo()
                        default: tv.insertText(String(key), replacementRange: NSRange(location: NSNotFound, length: 0))
                        }
                        if !isUndo { undo?.endUndoGrouping() }
                    }
                    }
                    let r = tv.selectedRange()
                    let result = (editor.text as NSString).replacingCharacters(in: r, with: r.length == 0 ? "‸" : "«" + (editor.text as NSString).substring(with: r) + "»")
                        .replacingOccurrences(of: "\n", with: "↵")
                    let ok = result == parts[2]
                    if !ok { failed += 1 }
                    print(ok ? "PASS" : "FAIL", parts[0], "·", parts[1], "→", result, ok ? "" : "(expected \(parts[2]))")
                }
                print("MATH CASES: \(total - failed)/\(total) passed")
            }
            // `-IndiumMathCellCases /path`: the same kind of cases, typed into a table cell (see runMathCellCases).
            if let path = d.string(forKey: "IndiumMathCellCases"), let cases = try? String(contentsOfFile: path, encoding: .utf8) {
                runMathCellCases(cases, editor: target.editor, window: window, realKeys: d.bool(forKey: "IndiumMathRealKeys"))
            }
            if d.bool(forKey: "IndiumSlashAccept") {
                _ = target.editor.handleSlashKey(#selector(NSResponder.insertTab(_:)))
                print("SLASH RESULT:", target.editor.text.debugDescription)
            }
            if let action = d.string(forKey: "IndiumSelectionAction") {
                target.editor.performSelectionAction(action == "left" ? .left : action == "full" ? .fullWidth : action == "wrap" ? .wrap : .right)
            }
            if let size = d.string(forKey: "IndiumResizeTo")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                print("RESIZED content:", window.contentView!.frame.size, "text:", target.editor.textView.frame.size)
            }
            if let name = d.string(forKey: "IndiumRename") {
                target.debugRename(name)
                print("RENAMED url:", target.note?.url?.path ?? "nil")
            }
            if d.bool(forKey: "IndiumZoom") { window.zoom(nil) }
            for (i, path) in (d.string(forKey: "IndiumSwitchFolders") ?? "").split(separator: ",").enumerated() {
                let item = NSMenuItem()
                item.representedObject = URL(fileURLWithPath: String(path), isDirectory: true)
                AppDelegate.shared.switchFolder(item)
                print("SWITCH \(i):", AppDelegate.shared.workspace?.name ?? "-", "note:", target.note?.title ?? "none")
            }
            if d.bool(forKey: "IndiumFolderMenu") {
                let m = NSMenu(); AppDelegate.shared.fillFolderMenu(m)
                print("MENU:", m.items.map { ($0.state == .on ? "✓" : "") + $0.title })
            }
            if d.bool(forKey: "IndiumReturn") {
                target.editor.textView.insertNewline(nil)
                print("RETURN text:", target.editor.text.debugDescription, "caret:", target.editor.textView.selectedRange().location)
            }
            if let find = d.string(forKey: "IndiumExternalFind"), let url = target.note?.url {
                // Plays another app editing the open note on disk.
                let replace = d.string(forKey: "IndiumExternalReplace") ?? ""
                if let typed = d.string(forKey: "IndiumTypeFirst") { target.editor.textView.insertText(typed, replacementRange: target.editor.textView.selectedRange()) }
                let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? disk.replacingOccurrences(of: find, with: replace).write(to: url, atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    let now = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    print("EXTERNAL applied:", target.editor.text.contains(replace), "typed kept:", target.editor.text.contains("MY TYPING"), "matchesDisk:", target.editor.text == now,
                          "canUndo:", target.editor.textView.undoManager?.canUndo ?? false, "caret:", target.editor.textView.selectedRange())
                }
            }
            if d.bool(forKey: "IndiumFullScreen") {
                window.toggleFullScreen(nil)
                for t in stride(from: 1.0, through: 14, by: 1.0) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { print("FS t=\(t)", window.frame, window.styleMask.contains(.fullScreen)) }
                }
            }
            if d.bool(forKey: "IndiumFiles") { target.toggleFiles(nil) }
            if d.bool(forKey: "IndiumQuick") { target.openQuickly(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if d.bool(forKey: "IndiumDumpLayout") {
                    let lm = target.editor.layoutManager
                    let ns = target.editor.text as NSString
                    lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: min(lm.numberOfGlyphs, 900))) { rect, used, _, glyphs, _ in
                        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                        let text = ns.substring(with: chars).replacingOccurrences(of: "\n", with: "⏎").prefix(30)
                        let ps = target.editor.storage.attribute(.paragraphStyle, at: chars.location, effectiveRange: nil) as? NSParagraphStyle
                        print(String(format: "x=%5.1f..%5.1f usedx=%5.1f..%5.1f y=%6.1f h=%5.1f used=%5.1f..%5.1f min=%.1f loc=%d len=%d ", rect.minX, rect.maxX, used.minX, used.maxX, rect.minY, rect.height, used.minY, used.maxY, ps?.minimumLineHeight ?? -1, chars.location, chars.length), text.debugDescription)
                    }
                }
                if let pdfPath {
                    let data = PDFExporter.makePDF(text: target.editor.text, title: "Snapshot", resolver: target.editor)
                    try? data.write(to: URL(fileURLWithPath: pdfPath))
                }
                if !out.isEmpty, let view = window.contentView?.superview {
                    view.layoutSubtreeIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                }
                if !d.bool(forKey: "IndiumKeepOpen") { exit(0) }
            }
        }
    }
}
#endif
