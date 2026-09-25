import AppKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var workspace: Workspace?
    private var mainController: DocumentWindowController?
    private var temporaryControllers: [DocumentWindowController] = []
    private var settingsWindow: NSWindow?
    /// Sparkle: checks the appcast in the background and offers updates natively.
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != "",
                                                            updaterDelegate: nil, userDriverDelegate: nil)

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        AppSettings.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = updater
        onboardIfNeeded()
        if let path = UserDefaults.standard.string(forKey: "vaultPath"),
           FileManager.default.fileExists(atPath: path) {
            setWorkspace(URL(fileURLWithPath: path, isDirectory: true), reopenLastNote: true)
        }
        mainWindowController().showWindow(nil)
        #if DEBUG
        DebugSnapshot.runIfRequested(mainWindowController())
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController().showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainController?.editor.saveNow()
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
        mainController?.editor.saveNow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                setWorkspace(url, reopenLastNote: false)
            } else if let ws = workspace, ws.contains(url) {
                openInMainWindow(url)
            } else {
                setWorkspace(url.deletingLastPathComponent(), reopenLastNote: false)
                openInMainWindow(url)
            }
        }
        mainWindowController().showWindow(nil)
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

    func temporaryWindowClosed(_ controller: DocumentWindowController) {
        temporaryControllers.removeAll { $0 === controller }
    }

    private func setWorkspace(_ url: URL, reopenLastNote: Bool) {
        mainController?.editor.saveNow()
        let changed = workspace?.root.standardizedFileURL != url.standardizedFileURL
        guard changed else { return }
        workspace = Workspace(root: url)
        UserDefaults.standard.set(url.path, forKey: "vaultPath")
        if !reopenLastNote { UserDefaults.standard.removeObject(forKey: "lastNote") }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        mainController?.workspaceDidChange()
        if let ws = workspace {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NoteIcons.shared.backfill(ws) }
        }
        for c in temporaryControllers { c.editor.workspace = workspace }
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
        setWorkspace(url, reopenLastNote: false)
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

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates(sender)
    }

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
        case #selector(checkForUpdates(_:)):
            return updater.updater.canCheckForUpdates
        default:
            break
        }
        return true
    }
}
