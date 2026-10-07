#if APPSTORE
import AppKit
import UniformTypeIdentifiers

/// Brings note icons over from the direct-download Indium, which keeps them in
/// ~/Library/Application Support/Indium/icons.json. The App Store edition keeps its own
/// copy in its container, so on its first launch it copies that file's icons in. The
/// original is only read: never moved or changed, so the direct build keeps its icons.
/// Icons already chosen in this edition always win.
///
/// The sandbox usually refuses that read. Then, if the direct build was used on this Mac
/// (its preferences came over), Indium offers once to import the file through an Open
/// panel showing it. Settings keeps the same button for later. No bookmark is kept.
enum IconImport {
    /// `copied`, `none` (nothing to copy), `pending` (refused; offer once), `refused`
    /// (refused, no sign of the direct build), `declined`, `imported`.
    private static let stateKey = "iconImport"

    /// The direct-download build's icons.json, outside the container.
    static var directStore: URL? {
        #if DEBUG
        // Test builds only ever look at a fixture (`-IndiumDirectIconStore /tmp/x/icons.json`).
        return UserDefaults.standard.string(forKey: "IndiumDirectIconStore").map { URL(fileURLWithPath: $0) }
        #else
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Indium/icons.json")
        #endif
    }

    /// Runs once, at the start of the first launch (before onboarding writes any settings).
    static func copyOnFirstLaunch() {
        let d = UserDefaults.standard
        guard d.string(forKey: stateKey) == nil, let source = directStore else { return }
        // The direct build was used here if its notes folder came over with its preferences.
        let usedDirectBuild = !(d.string(forKey: "vaultPath") ?? "").isEmpty
        do {
            let added = try importIcons(from: source)
            FolderAccess.log("icons: copied \(added) from \(source.path)")
            d.set("copied", forKey: stateKey)
        } catch let error as NSError where isPermissionError(error) {
            FolderAccess.log("icons: read refused (\(error.domain) \(error.code)), offer: \(usedDirectBuild)")
            d.set(usedDirectBuild ? "pending" : "refused", forKey: stateKey)
        } catch {
            FolderAccess.log("icons: nothing to copy (\((error as NSError).domain) \((error as NSError).code))")
            d.set("none", forKey: stateKey)
        }
    }

    /// Asks once, after a refused read, whether to import the icons. Either answer is
    /// remembered; Settings has the same import for later.
    static func offerIfNeeded(in window: NSWindow?) {
        let d = UserDefaults.standard
        guard d.string(forKey: stateKey) == "pending" else { return }
        d.set("declined", forKey: stateKey)
        let alert = NSAlert()
        alert.messageText = "Bring over your note icons?"
        alert.informativeText = "The direct-download Indium kept icons for your notes. To use them here, select its icons.json in the next window. Indium copies the icons and leaves that file as it is.\n\nYou can also do this later in Settings."
        alert.addButton(withTitle: "Import Icons…")
        alert.addButton(withTitle: "Not Now")
        FolderAccess.log("icons: offer shown")
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            FolderAccess.log("icons: offer answered \(response == .alertFirstButtonReturn ? "import" : "not now")")
            if response == .alertFirstButtonReturn { DispatchQueue.main.async { importWithPanel() } }
        }
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
    }

    /// Opens a panel on the direct build's icons.json, copies in what you select, and
    /// says how it went. Cancelling changes nothing.
    static func importWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Select icons.json from the direct-download Indium. Indium copies its icons and leaves the file as it is."
        // Showing the file itself selects it in its folder.
        panel.directoryURL = directStore
        FolderAccess.log("panel shown: icons")
        guard panel.runModal() == .OK, let url = panel.url else {
            FolderAccess.log("panel cancelled: icons")
            return
        }
        let alert = NSAlert()
        do {
            let added = try importIcons(from: url)
            UserDefaults.standard.set("imported", forKey: stateKey)
            FolderAccess.log("icons: imported \(added) from \(url.path)")
            alert.messageText = added == 1 ? "Imported 1 note icon" : "Imported \(added) note icons"
            alert.informativeText = added == 0 ? "Every note in that file already has an icon here." : "Icons you'd already chosen here were kept."
        } catch {
            FolderAccess.log("icons: import failed \((error as NSError).domain) \((error as NSError).code)")
            alert.alertStyle = .warning
            alert.messageText = "Couldn't import note icons"
            alert.informativeText = error is DecodingError
                ? "That file isn't a set of Indium note icons. Choose icons.json from the direct-download Indium."
                : error.localizedDescription
        }
        alert.runModal()
    }

    /// Reads (only reads) a store and merges it in. Returns how many icons were added.
    private static func importIcons(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let icons = try JSONDecoder().decode([String: [String: String]].self, from: data)
        return NoteIcons.shared.merge(icons)
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }
}
#endif
