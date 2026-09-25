#if DEBUG
import AppKit

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
                target.editor.beginTableEditing(at: block.range.location, row: 2, column: 1)
                if d.bool(forKey: "IndiumTableAddRow") { target.editor.tableEditor?.addRow() }
                if let side = d.string(forKey: "IndiumPlaceTable") {
                    target.editor.placeEditedTable(float: side == "full" ? nil : side == "right")
                }
                print("TABLE MD:\n" + ((target.editor.text as NSString).substring(with: target.editor.styler.blocks.first(where: { if case .table = $0.kind { return true }; return false })!.range)))
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
