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
    }

    static func runIfRequested(_ controller: DocumentWindowController) {
        let d = UserDefaults.standard
        if let steps = d.string(forKey: "IndiumSidebarSteps") {
            if let size = d.string(forKey: "IndiumSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                controller.window?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                controller.debugSidebar(steps: steps.split(separator: ",").map(String.init), out: d.string(forKey: "IndiumSnapshot"))
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
                    let isUndo = step == "undo" || step == "redo"
                    if !isUndo { undo?.beginUndoGrouping() }
                    defer { if !isUndo { undo?.endUndoGrouping() } }
                    let e = target.editor.tableEditor
                    let arg = step.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    switch step.split(separator: ":").first.map(String.init) ?? "" {
                    case "select":
                        let n = arg.split(separator: ",").compactMap { Int($0) }
                        e?.select(from: (n[0], n[1]), to: (n[2], n[3]))
                    case "pb":
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(arg.replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
                    case "type":
                        window.firstResponder?.insertText(arg)
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
                        hit?.mouseDown(with: mouse(.leftMouseDown, from, clicks: clicks))
                    case "done":
                        target.editor.endTableEditing(caretAfter: true)
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
                    let pb = NSPasteboard.general
                    print("STEP \(step) responder:", window.firstResponder.map { String(describing: type(of: $0)) } ?? "-",
                          "focus:", e.map { "\($0.focus)" } ?? "-", "selection:", e?.selection.map { "\($0.anchor)->\($0.head)" } ?? "none",
                          "cell:", e?.cellEditor.map { "\($0.string.debugDescription) sel \(NSStringFromRange($0.selectedRange()))" } ?? "-")
                    if let i = target.editor.styler.blocks.firstIndex(where: { if case .table = $0.kind { return true }; return false }) {
                        print("  NOTE TABLE:", (target.editor.text as NSString).substring(with: target.editor.styler.blocks[i].range).components(separatedBy: "\n").enumerated().filter { $0.offset != 1 }.map { $0.element.replacingOccurrences(of: " ", with: "") }.joined(separator: " "))
                    }
                    if step == "copy" || step == "cut" {
                        print("  PB string:", (pb.string(forType: .string) ?? "nil").debugDescription)
                        print("  PB html:", pb.string(forType: .html) ?? "nil")
                    }
                }
                if let side = d.string(forKey: "IndiumPlaceTable") {
                    target.editor.placeEditedTable(float: side == "full" ? nil : side == "right")
                }
                print("TABLE MD:\n" + ((target.editor.text as NSString).substring(with: target.editor.styler.blocks.first(where: { if case .table = $0.kind { return true }; return false })!.range)))
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
                func send(_ chars: String) {
                    let codes: [String: UInt16] = ["\t": 48, "\r": 36, "\u{7f}": 51]
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
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
                        for key in parts[1] {
                            switch key {
                            case "⇥": send("\t")
                            case "⏎": send("\r")
                            case "⌫": send("\u{7f}")
                            case "↶": undo?.undo(); spin()
                            default: send(String(key))
                            }
                        }
                    } else {
                    undo?.beginUndoGrouping()
                    editor.replace(NSRange(location: 0, length: editor.storage.length), with: start)
                    tv.setSelectedRange(sel)
                    undo?.endUndoGrouping()
                    for key in parts[1] {
                        let isUndo = key == "↶"
                        if !isUndo { undo?.beginUndoGrouping() }
                        switch key {
                        case "⇥": tv.insertTab(nil)
                        case "⏎": tv.insertNewline(nil)
                        case "⌫": tv.deleteBackward(nil)
                        case "↶": undo?.undo()
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
