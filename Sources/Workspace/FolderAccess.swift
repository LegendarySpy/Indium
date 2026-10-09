import AppKit

/// Keeps Indium able to reach the folders and files you chose, across launches.
///
/// In the App Store build, which runs in the App Sandbox, a path string isn't enough.
/// The app may only touch what you picked in an Open panel or opened from Finder, and
/// only until it quits, unless it keeps a security-scoped bookmark. Every folder Indium
/// opens goes through here in both builds, so there's one code path. Outside the
/// sandbox, bookmarks still work (and follow a folder that was moved), and starting
/// access is a harmless no-op.
///
/// **Lifetimes.** Access is reference counted per path. A `Lease` is held by everything
/// that still needs the folder: the workspace and its FSEvents watcher, the workspace's
/// background scans, every open note (including notes cached by a window) and file
/// windows. The system grant is released only when the last lease goes away, so
/// switching folders never pulls access out from under a scan that's still running or
/// a window that still shows one of the old folder's notes.
enum FolderAccess {
    /// True in the App Store build (and any other sandboxed build).
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    // MARK: Leases

    /// One holder's claim on a folder or file. Releasing the last lease on a path ends
    /// security-scoped access to it. Thread-safe; it may be released on any queue.
    final class Lease {
        let url: URL
        fileprivate let key: String
        fileprivate init(url: URL, key: String) {
            self.url = url
            self.key = key
        }
        deinit { FolderAccess.release(key) }
    }

    private struct Entry {
        var url: URL
        var count: Int
        var started: Bool
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    /// Paths are compared standardized (`/private/tmp` and `/tmp` are one folder).
    static func key(_ url: URL) -> String { url.standardizedFileURL.path }
    static func key(_ path: String) -> String { key(URL(fileURLWithPath: path)) }

    /// Starts (or joins) access to `url`. Pass the URL exactly as it came from an Open
    /// panel, from Finder, or from resolving a bookmark: that instance carries the grant.
    static func lease(_ url: URL) -> Lease {
        let key = key(url)
        lock.lock()
        if var entry = entries[key] {
            entry.count += 1
            // An earlier holder may have had a URL without a grant; this one may have one.
            if !entry.started, url.startAccessingSecurityScopedResource() {
                entry.started = true
                entry.url = url
            }
            entries[key] = entry
        } else {
            entries[key] = Entry(url: url, count: 1, started: url.startAccessingSecurityScopedResource())
        }
        let count = entries[key]?.count ?? 0
        lock.unlock()
        log("lease \(key) count=\(count)")
        return Lease(url: url, key: key)
    }

    private static func release(_ key: String) {
        lock.lock()
        guard var entry = entries[key] else { lock.unlock(); return }
        entry.count -= 1
        if entry.count > 0 {
            entries[key] = entry
            lock.unlock()
            log("release \(key) count=\(entry.count)")
            return
        }
        entries[key] = nil
        lock.unlock()
        if entry.started { entry.url.stopAccessingSecurityScopedResource() }
        log("stop \(key)")
    }

    /// How many holders still use `url` (0 when access has ended).
    static func holders(of url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries[key(url)]?.count ?? 0
    }

    // MARK: Bookmarks

    private static let bookmarksKey = "folderBookmarks"

    private static var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: bookmarksKey) }
    }

    static func hasBookmark(for path: String) -> Bool { bookmarks[key(path)] != nil }

    /// Saves a bookmark for a folder Indium can reach right now (call it while a lease is
    /// held, or right after an Open panel), so it can be reopened after a restart.
    @discardableResult
    static func remember(_ url: URL) -> Bool {
        let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (isSandboxed ? nil : try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let data else {
            log("bookmark failed \(key(url))")
            return false
        }
        bookmarks[key(url)] = data
        log("bookmark saved \(key(url))")
        return true
    }

    static func forget(_ path: String) {
        bookmarks[key(path)] = nil
    }

    private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        if !isSandboxed, let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                                            relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        return nil
    }

    // MARK: Opening remembered folders

    enum Reason {
        /// The folder you had open last time (or picked from the folder list).
        case reopen
        /// The first launch of the App Store build after the direct-download one.
        case upgrade
    }

    /// Opens a folder remembered by its path. Resolves its bookmark (refreshing a stale
    /// one while access is active). If there's no usable bookmark: outside the sandbox
    /// the path is enough, as it always was; in the sandbox, when `prompt` is set, an
    /// Open panel preset to the old place asks you to grant it again.
    /// Returns the folder (possibly at a new path, if it moved) and a lease on it.
    static func open(folderAt rawPath: String, prompt: Bool, reason: Reason = .reopen) -> (url: URL, lease: Lease)? {
        let path = key(rawPath)
        let fm = FileManager.default
        if let data = bookmarks[path], let resolved = resolve(data) {
            let moved = key(resolved.url) != path
            // Outside the sandbox the path stays authoritative (a test or a launch
            // argument may point at a different folder that happens to share the path).
            if !(moved && !isSandboxed && fm.fileExists(atPath: path)) {
                let lease = lease(resolved.url)
                if fm.fileExists(atPath: resolved.url.path) {
                    if moved {
                        log("followed moved folder \(path) -> \(key(resolved.url))")
                        bookmarks[path] = nil
                    }
                    if resolved.stale || moved { remember(resolved.url) }
                    return (resolved.url.standardizedFileURL, lease)
                }
                log("bookmark resolved but folder unreachable \(key(resolved.url))")
            }
        } else if bookmarks[path] != nil {
            log("bookmark unresolvable \(path)")
        }
        if !isSandboxed {
            guard fm.fileExists(atPath: path) else { return nil }
            // The caller remembers it (bookmarks it) once it's in use.
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return (url, lease(url))
        }
        guard prompt, let url = askAgain(for: path, reason: reason) else { return nil }
        let lease = lease(url)
        remember(url)
        if key(url) != path { bookmarks[path] = nil }
        return (url.standardizedFileURL, lease)
    }

    /// The re-grant panel: an Open panel showing the folder's old place, so a single
    /// click on Open grants it again.
    private static func askAgain(for path: String, reason: Reason) -> URL? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "IndiumNoAccessPanels") {
            log("panel suppressed: regrant \(path)")
            return nil
        }
        #endif
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let name = folder.lastPathComponent
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.directoryURL = folder
        switch reason {
        case .reopen:
            panel.message = "Indium needs your permission to open “\(name)” again. Choose the folder and click Open."
        case .upgrade:
            panel.message = "Indium now asks before opening a folder. To keep using “\(name)”, choose it and click Open."
        }
        log("panel shown: regrant \(path)")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else {
            log("panel cancelled: regrant \(path)")
            return nil
        }
        log("panel granted: \(key(url))")
        return url
    }

    /// A folder granted earlier that contains `file` (its own folder or one above it),
    /// reopened silently from its bookmark. Used for notes opened on their own.
    static func reopenFolder(containing file: URL) -> Lease? {
        var folder = file.deletingLastPathComponent().standardizedFileURL
        while folder.path != "/" {
            if hasBookmark(for: folder.path), let opened = open(folderAt: folder.path, prompt: false) {
                let wanted = key(file)
                if wanted.hasPrefix(key(opened.url) + "/") { return opened.lease }
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: Folders the user grants later

    /// Asks for a folder Indium can't reach yet (for example, the folder beside a note
    /// saved outside the vault, where its images go). Returns a lease, or nil if you
    /// declined or picked a folder that doesn't contain `folder`.
    static func requestFolder(_ folder: URL, message: String, prompt: String = "Allow") -> Lease? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "IndiumNoAccessPanels") { return nil }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = folder
        log("panel shown: request \(key(folder))")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else {
            log("panel cancelled: request \(key(folder))")
            return nil
        }
        let chosen = key(url)
        let wanted = key(folder)
        guard wanted == chosen || wanted.hasPrefix(chosen + "/") else { return nil }
        log("panel granted: \(chosen)")
        return lease(url)
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    // MARK: Debug

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "IndiumAccessLog") { print("ACCESS:", message()) }
        #endif
    }
}
