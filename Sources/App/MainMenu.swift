import AppKit

/// Standard Mac menu bar, built in code. Items target the responder chain so the
/// text view, window controller and app delegate each handle what they own.
enum MainMenu {
    typealias W = DocumentWindowController

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        menu.addItem(item)
        return item
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "Indium")
        add(m, "About Indium", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(m, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        m.addItem(.separator())
        add(m, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        add(m, "Services", nil).submenu = services
        NSApp.servicesMenu = services
        m.addItem(.separator())
        add(m, "Hide Indium", #selector(NSApplication.hide(_:)), "h")
        add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        m.addItem(.separator())
        add(m, "Quit Indium", #selector(NSApplication.terminate(_:)), "q")
        return m
    }

    static let switchFolderMenu = NSUserInterfaceItemIdentifier("SwitchFolder")

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: "File")
        add(m, "New Note", #selector(W.newNote(_:)), "n")
        add(m, "New Temporary Note", #selector(AppDelegate.newTemporaryNote(_:)), "n", [.command, .shift])
        m.addItem(.separator())
        add(m, "Open Note…", #selector(W.openQuickly(_:)), "o")
        add(m, "Open Folder…", #selector(AppDelegate.openFolder(_:)), "o", [.command, .shift])
        let folders = NSMenu(title: "Switch Folder")
        folders.identifier = switchFolderMenu
        folders.delegate = NSApp.delegate as? NSMenuDelegate
        add(m, "Switch Folder", nil).submenu = folders
        m.addItem(.separator())
        add(m, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(m, "Save", #selector(W.saveNote(_:)), "s")
        add(m, "Rename…", #selector(W.renameNote(_:)))
        add(m, "Show in Finder", #selector(W.revealInFinder(_:)), "r", [.command, .shift])
        add(m, "Move to Trash", #selector(W.trashNote(_:)), "\u{8}", .command)
        m.addItem(.separator())
        add(m, "Export as PDF…", #selector(W.exportPDF(_:)), "e", [.command, .shift])
        add(m, "Print…", #selector(W.printNote(_:)), "p")
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        add(m, "Undo", Selector(("undo:")), "z")
        add(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
        m.addItem(.separator())
        add(m, "Cut", #selector(NSText.cut(_:)), "x")
        add(m, "Copy", #selector(NSText.copy(_:)), "c")
        add(m, "Paste", #selector(NSText.paste(_:)), "v")
        add(m, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(m, "Delete", #selector(NSText.delete(_:)))
        add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
        m.addItem(.separator())

        let find = NSMenu(title: "Find")
        add(find, "Find…", #selector(NSTextView.performFindPanelAction(_:)), "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        add(find, "Find and Replace…", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command, .option]).tag = 12
        add(find, "Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g").tag = Int(NSFindPanelAction.next.rawValue)
        add(find, "Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift]).tag = Int(NSFindPanelAction.previous.rawValue)
        add(find, "Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e").tag = Int(NSFindPanelAction.setFindString.rawValue)
        add(find, "Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
        find.addItem(.separator())
        add(find, "Search All Notes…", #selector(W.searchNotes(_:)), "f", [.command, .shift])
        add(m, "Find", nil).submenu = find

        let spelling = NSMenu(title: "Spelling and Grammar")
        add(spelling, "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":")
        add(spelling, "Check Document Now", #selector(NSText.checkSpelling(_:)), ";")
        spelling.addItem(.separator())
        add(spelling, "Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)))
        add(spelling, "Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)))
        add(spelling, "Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)))
        add(m, "Spelling and Grammar", nil).submenu = spelling

        let subs = NSMenu(title: "Substitutions")
        add(subs, "Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:)))
        subs.addItem(.separator())
        add(subs, "Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:)))
        add(subs, "Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)))
        add(subs, "Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:)))
        add(subs, "Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)))
        add(m, "Substitutions", nil).submenu = subs

        let transforms = NSMenu(title: "Transformations")
        add(transforms, "Make Upper Case", #selector(NSResponder.uppercaseWord(_:)))
        add(transforms, "Make Lower Case", #selector(NSResponder.lowercaseWord(_:)))
        add(transforms, "Capitalize", #selector(NSResponder.capitalizeWord(_:)))
        add(m, "Transformations", nil).submenu = transforms

        let speech = NSMenu(title: "Speech")
        add(speech, "Start Speaking", #selector(NSTextView.startSpeaking(_:)))
        add(speech, "Stop Speaking", #selector(NSTextView.stopSpeaking(_:)))
        add(m, "Speech", nil).submenu = speech
        return m
    }

    private static func formatMenu() -> NSMenu {
        let m = NSMenu(title: "Format")
        add(m, "Body", #selector(W.setBody(_:)), "0")
        add(m, "Heading 1", #selector(W.setHeading1(_:)), "1")
        add(m, "Heading 2", #selector(W.setHeading2(_:)), "2")
        add(m, "Heading 3", #selector(W.setHeading3(_:)), "3")
        m.addItem(.separator())
        add(m, "Bold", #selector(W.toggleBold(_:)), "b")
        add(m, "Italic", #selector(W.toggleItalic(_:)), "i")
        add(m, "Strikethrough", #selector(W.toggleStrikethrough(_:)), "x", [.command, .shift])
        add(m, "Highlight", #selector(W.toggleHighlight(_:)), "h", [.command, .shift])
        add(m, "Inline Code", #selector(W.toggleInlineCode(_:)), "c", [.command, .shift])
        m.addItem(.separator())
        add(m, "Link", #selector(W.insertLink(_:)), "k")
        add(m, "Image…", #selector(W.insertImage(_:)), "i", [.command, .shift])
        add(m, "Inline Equation", #selector(W.insertInlineMath(_:)), "m", [.command, .control])
        add(m, "Display Equation", #selector(W.insertDisplayMath(_:)), "m", [.command, .control, .shift])
        m.addItem(.separator())
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        add(m, "Show Files", #selector(W.toggleFiles(_:)), "s", [.command, .control])
        m.addItem(.separator())
        add(m, "Bigger", #selector(AppDelegate.increaseTextSize(_:)), "+")
        add(m, "Smaller", #selector(AppDelegate.decreaseTextSize(_:)), "-")
        add(m, "Actual Size", #selector(AppDelegate.resetTextSize(_:)), "0", [.command, .option])
        m.addItem(.separator())
        let font = NSMenu(title: "Font")
        for choice in FontChoice.allCases {
            add(font, choice.title, #selector(AppDelegate.setFontChoice(_:))).representedObject = choice.rawValue
        }
        add(m, "Font", nil).submenu = font
        let appearance = NSMenu(title: "Appearance")
        for a in AppearanceSetting.allCases {
            add(appearance, a.title, #selector(AppDelegate.setAppearanceChoice(_:))).representedObject = a.rawValue
        }
        add(m, "Appearance", nil).submenu = appearance
        add(m, "Always Show Markdown", #selector(AppDelegate.toggleSyntaxVisibility(_:)), "m", [.command, .option])
        m.addItem(.separator())
        add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
        m.addItem(.separator())
        add(m, "Notes", #selector(AppDelegate.showMainWindow(_:)), "1", [.command, .option])
        m.addItem(.separator())
        add(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return m
    }
}
