import AppKit
#if !APPSTORE
import Sparkle
#endif
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var workspace: Workspace?
    private var mainController: DocumentWindowController?
    private var temporaryControllers: [DocumentWindowController] = []
    /// Windows for single files opened from outside the folder.
    private var fileControllers: [DocumentWindowController] = []
    private var settingsWindow: NSWindow?
    #if !APPSTORE
    /// Sparkle: checks the appcast in the background and offers updates natively.
    /// (The App Store build has no Sparkle; the store updates it.)
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != "",
                                                            updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        AppSettings.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !APPSTORE
        _ = updater
        #endif
        AppSettings.shared.shareWithQuickLook()
        // Opening a file from Finder launches straight into that file's own window, and
        // shouldn't stop on a folder panel first.
        let launchedForFile = !fileControllers.isEmpty
        let d = UserDefaults.standard
        #if APPSTORE
        IconImport.copyOnFirstLaunch()
        let firstRun = (d.string(forKey: "vaultPath") ?? "").isEmpty && !d.bool(forKey: "didOnboard")
        if firstRun, !launchedForFile {
            chooseNotesFolderOnFirstRun()
            return
        }
        #else
        onboardIfNeeded()
        #endif
        if let path = d.string(forKey: "vaultPath"), !path.isEmpty {
            // Moving from the direct-download build, the path came over but no permission
            // did: ask once, with the panel already showing that folder.
            let upgrading = FolderAccess.isSandboxed && !FolderAccess.hasBookmark(for: path)
            if let opened = FolderAccess.open(folderAt: path, prompt: !launchedForFile, reason: upgrading ? .upgrade : .reopen) {
                setWorkspace(opened.url, access: opened.lease, reopenLastNote: true)
            }
        }
        if !launchedForFile {
            mainWindowController().showWindow(nil)
            #if APPSTORE
            DispatchQueue.main.async { IconImport.offerIfNeeded(in: self.mainController?.window) }
            #endif
        }
        #if DEBUG
        DebugSnapshot.runIfRequested(mainWindowController())
        #endif
    }

    #if APPSTORE
    /// First launch of the App Store build: Indium can only use a folder you choose, so
    /// it asks for one up front. Cancelling still leaves you writing, in a temporary note.
    private func chooseNotesFolderOnFirstRun() {
        let d = UserDefaults.standard
        d.set(true, forKey: "didOnboard")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose or create a notes folder. Indium keeps your notes there as plain Markdown files, and an Obsidian vault works as is."
        FolderAccess.log("panel shown: first run")
        var chosen: URL?
        #if DEBUG
        // `-IndiumPanelDirectory /tmp/x`: tests open the panel on their fixture folder.
        if let dir = d.string(forKey: "IndiumPanelDirectory") { panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true) }
        if d.bool(forKey: "IndiumNoAccessPanels") {
            FolderAccess.log("panel suppressed: first run")
        } else if panel.runModal() == .OK { chosen = panel.url }
        #else
        if panel.runModal() == .OK { chosen = panel.url }
        #endif
        guard let url = chosen else {
            FolderAccess.log("panel cancelled: first run")
            _ = mainWindowController()
            newTemporaryNote(nil)
            return
        }
        FolderAccess.log("panel granted: first run \(url.path)")
        let lease = FolderAccess.lease(url)
        // A new, empty folder gets the welcome note; an existing vault is left alone.
        let fm = FileManager.default
        let isEmpty = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).allSatisfy { $0.hasPrefix(".") }
        let name = "Welcome to Indium.md"
        if isEmpty, let source = Bundle.main.url(forResource: "Welcome", withExtension: "md"),
           (try? fm.copyItem(at: source, to: url.appendingPathComponent(name))) != nil {
            d.set(name, forKey: "lastNote")
        }
        setWorkspace(url, access: lease, reopenLastNote: true)
        let c = mainWindowController()
        c.showWindow(nil)
        if !isEmpty { c.openQuickly(nil) }
        #if DEBUG
        DebugSnapshot.runIfRequested(c)
        #endif
    }
    #endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController().showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainController?.editor.saveNow(interactive: false)
        fileControllers.forEach { $0.editor.saveNow(interactive: false) }
        // A save that failed (no permission, disk full, a sync conflict) already showed
        // its error on the window; don't let quitting throw those edits away silently.
        let failed = ([mainController].compactMap { $0 } + fileControllers).filter { $0.editor.hasUnsavedEdits && $0.note?.isTemporary == false }
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = failed.count == 1 ? "“\(failed[0].note?.title ?? "A note")” couldn't be saved." : "\(failed.count) notes couldn't be saved."
            alert.informativeText = "If you quit now, the changes that weren't saved will be lost. You can copy the text somewhere safe first."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            alert.buttons[1].hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else {
                failed.first?.showWindow(nil)
                return .terminateCancel
            }
        }
        let unsaved = temporaryControllers.filter { !$0.editor.isEmpty }
        guard !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1 ? "Discard your temporary note?" : "Discard \(unsaved.count) temporary notes?"
        alert.informativeText = "Temporary notes are never written to disk unless you save them to your vault."
        alert.addButton(withTitle: "Review…")
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            return .terminateNow
        case .alertFirstButtonReturn:
            unsaved.first?.showWindow(nil)
            unsaved.first?.window?.performClose(nil)
            return .terminateCancel
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainController?.editor.saveNow(interactive: false)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openDocument)
    }

    /// A folder becomes the vault; a note inside it opens in the main window; any other
    /// file opens in a window of its own, leaving the folder as it was.
    func openDocument(_ url: URL) {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            // Opened from Finder or the Dock: this URL carries the grant.
            setWorkspace(url, access: FolderAccess.lease(url), reopenLastNote: false)
            mainWindowController().showWindow(nil)
        } else if let ws = workspace, ws.contains(url) {
            openInMainWindow(url)
        } else if let open = fileControllers.first(where: { $0.note?.url?.standardizedFileURL == url.standardizedFileURL }) {
            open.showWindow(nil)
        } else {
            let c = DocumentWindowController(kind: .file)
            do { try c.openFile(url, access: FolderAccess.lease(url)) } catch {
                NSAlert(error: error).runModal()
                return
            }
            fileControllers.append(c)
            c.showWindow(nil)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    /// First launch: a notes folder in Documents holding a short welcome note, opened
    /// right away, so there's something to read instead of an empty window.
    private func onboardIfNeeded() {
        let d = UserDefaults.standard
        guard (d.string(forKey: "vaultPath") ?? "").isEmpty, !d.bool(forKey: "didOnboard") else { return }
        d.set(true, forKey: "didOnboard")
        var base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if let root = d.string(forKey: "IndiumOnboardRoot") { base = URL(fileURLWithPath: root, isDirectory: true) }
        #endif
        let folder = base.appendingPathComponent("Indium", isDirectory: true)
        let name = "Welcome to Indium.md"
        let welcome = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: welcome.path),
               let source = Bundle.main.url(forResource: "Welcome", withExtension: "md") {
                try FileManager.default.copyItem(at: source, to: welcome)
            }
        } catch {
            return
        }
        d.set(folder.path, forKey: "vaultPath")
        d.set(name, forKey: "lastNote")
    }

    // MARK: Windows

    func mainWindowController() -> DocumentWindowController {
        if let mainController { return mainController }
        let c = DocumentWindowController(kind: .vault)
        mainController = c
        if let ws = workspace, let rel = UserDefaults.standard.string(forKey: "lastNote") {
            let url = ws.root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { c.open(url) }
        }
        return c
    }

    func openInMainWindow(_ url: URL) {
        let c = mainWindowController()
        c.showWindow(nil)
        c.open(url)
    }

    func windowClosed(_ controller: DocumentWindowController) {
        temporaryControllers.removeAll { $0 === controller }
        fileControllers.removeAll { $0 === controller }
    }

    /// `access` is the lease on the folder (from a panel, Finder, or a resolved bookmark).
    /// The old workspace lets go of its folder once nothing else uses it.
    /// Returns false when the open note couldn't be saved: the folder stays as it was
    /// until that's resolved (the window says why and offers what to do).
    @discardableResult
    private func setWorkspace(_ url: URL, access: FolderAccess.Lease, reopenLastNote: Bool) -> Bool {
        let changed = workspace?.root.standardizedFileURL != url.standardizedFileURL
        guard changed else { return true }
        guard mainController?.canLeaveNote() ?? true else {
            mainController?.showWindow(nil)
            return false
        }
        FolderAccess.remember(url)
        let d = UserDefaults.standard
        // Each folder remembers its own last note, so switching back picks up where you were.
        var lastNotes = d.dictionary(forKey: "lastNoteByFolder") as? [String: String] ?? [:]
        if let old = workspace?.root.path, let note = d.string(forKey: "lastNote") { lastNotes[old] = note }
        d.set(lastNotes, forKey: "lastNoteByFolder")
        workspace = Workspace(root: url, access: access)
        d.set(url.path, forKey: "vaultPath")
        if !reopenLastNote {
            if let note = lastNotes[url.standardizedFileURL.path] { d.set(note, forKey: "lastNote") }
            else { d.removeObject(forKey: "lastNote") }
        }
        rememberFolder(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        mainController?.workspaceDidChange()
        if let ws = workspace {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NoteIcons.shared.backfill(ws) }
        }
        for c in temporaryControllers { c.editor.workspace = workspace }
        return true
    }

    // MARK: Folders

    /// Folders opened before, most recent first (only ones that still exist). In the
    /// sandbox Indium can't look at a folder it hasn't been granted again yet, so all
    /// are listed; choosing one it can't reopen asks for it.
    var recentFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [])
            .filter { FolderAccess.isSandboxed || FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func rememberFolder(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        paths.removeAll { $0 == url.standardizedFileURL.path }
        paths.insert(url.standardizedFileURL.path, at: 0)
        paths = Array(paths.prefix(8))
        UserDefaults.standard.set(paths, forKey: "recentFolders")
    }

    /// Recent folders (the current one checked), then Open Folder…. Used by the File
    /// menu and the folder name in the files popover.
    func fillFolderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = workspace?.root.standardizedFileURL.path
        var folders = recentFolders
        if let ws = workspace, !folders.contains(where: { $0.standardizedFileURL.path == current }) { folders.insert(ws.root, at: 0) }
        for url in folders {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(switchFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.state = url.standardizedFileURL.path == current ? .on : .off
            menu.addItem(item)
        }
        if !folders.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Add Folder…", action: #selector(openFolder(_:)), keyEquivalent: "")
        add.target = self
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(add)
        // Folders other than the open one can be taken off the list (nothing is deleted).
        let others = folders.filter { $0.standardizedFileURL.path != current }
        if !others.isEmpty {
            let remove = NSMenuItem(title: "Remove from List", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for url in others {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(forgetFolder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                sub.addItem(item)
            }
            remove.submenu = sub
            menu.addItem(remove)
        }
    }

    @objc func forgetFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        var paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        paths.removeAll { $0 == url.standardizedFileURL.path }
        UserDefaults.standard.set(paths, forKey: "recentFolders")
        FolderAccess.forget(url.standardizedFileURL.path)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == MainMenu.switchFolderMenu { fillFolderMenu(menu) }
    }

    @objc func switchFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard url.standardizedFileURL != workspace?.root.standardizedFileURL else { return }
        // Settle the open note first, before any panel asks for the other folder.
        guard mainController?.canLeaveNote() ?? true else { return }
        guard let opened = FolderAccess.open(folderAt: url.standardizedFileURL.path, prompt: true) else {
            // In the sandbox, declining the panel is answer enough.
            if !FolderAccess.isSandboxed {
                let alert = NSAlert()
                alert.messageText = "“\(url.lastPathComponent)” can't be found."
                alert.informativeText = "It may have been moved, renamed or deleted."
                alert.runModal()
            }
            return
        }
        guard setWorkspace(opened.url, access: opened.lease, reopenLastNote: false) else { return }
        let c = mainWindowController()
        c.showWindow(nil)
        if let ws = workspace, let rel = UserDefaults.standard.string(forKey: "lastNote"),
           FileManager.default.fileExists(atPath: ws.root.appendingPathComponent(rel).path) {
            c.open(ws.root.appendingPathComponent(rel))
        } else {
            c.openQuickly(nil)
        }
    }

    // MARK: Actions

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a folder of Markdown files. Nothing is moved or converted."
        if let current = workspace?.root { panel.directoryURL = current.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard setWorkspace(url, access: FolderAccess.lease(url), reopenLastNote: false) else { return }
        let c = mainWindowController()
        c.showWindow(nil)
        c.openQuickly(nil)
    }

    @objc func newTemporaryNote(_ sender: Any?) {
        let c = DocumentWindowController(kind: .temporary)
        temporaryControllers.append(c)
        c.showWindow(nil)
        c.window?.makeFirstResponder(c.editor.textView)
    }

    #if !APPSTORE
    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates(sender)
    }
    #endif

    @objc func showMainWindow(_ sender: Any?) {
        mainWindowController().showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = "Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func increaseTextSize(_ sender: Any?) { AppSettings.shared.adjustTextSize(by: 1) }
    @objc func decreaseTextSize(_ sender: Any?) { AppSettings.shared.adjustTextSize(by: -1) }
    @objc func resetTextSize(_ sender: Any?) { AppSettings.shared.textSize = 17 }

    @objc func setFontChoice(_ sender: NSMenuItem) {
        if let choice = FontChoice(rawValue: sender.representedObject as? String ?? "") { AppSettings.shared.font = choice }
    }

    @objc func setAppearanceChoice(_ sender: NSMenuItem) {
        if let a = AppearanceSetting(rawValue: sender.representedObject as? String ?? "") { AppSettings.shared.appearance = a }
    }

    @objc func toggleSyntaxVisibility(_ sender: Any?) {
        AppSettings.shared.syntax = AppSettings.shared.syntax == .always ? .whileEditing : .always
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setFontChoice(_:)):
            item.state = (item.representedObject as? String) == AppSettings.shared.font.rawValue ? .on : .off
        case #selector(setAppearanceChoice(_:)):
            item.state = (item.representedObject as? String) == AppSettings.shared.appearance.rawValue ? .on : .off
        case #selector(toggleSyntaxVisibility(_:)):
            item.state = AppSettings.shared.syntax == .always ? .on : .off
        #if !APPSTORE
        case #selector(checkForUpdates(_:)):
            return updater.updater.canCheckForUpdates
        #endif
        default:
            break
        }
        return true
    }
}
