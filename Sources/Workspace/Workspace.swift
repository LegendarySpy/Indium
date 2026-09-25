import AppKit

final class FileNode {
    let url: URL
    let isFolder: Bool
    var children: [FileNode]
    weak var parent: FileNode?

    init(url: URL, isFolder: Bool, children: [FileNode] = []) {
        self.url = url
        self.isFolder = isFolder
        self.children = children
    }

    var name: String {
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

/// An opened folder of Markdown files. The filesystem is the only database.
final class Workspace {
    static let didChange = Notification.Name("IndiumWorkspaceDidChange")
    /// userInfo: "from": URL, "to": URL
    static let didMoveItem = Notification.Name("IndiumWorkspaceDidMoveItem")
    /// Posted as soon as files change, before the (debounced) rescan: open notes use
    /// it to show another app's or an agent's edits live.
    static let filesTouched = Notification.Name("IndiumWorkspaceFilesTouched")

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]

    let root: URL
    private(set) var tree: FileNode
    private(set) var notes: [URL] = []
    private var filesByName: [String: [URL]] = [:]
    private var watcher: FileWatcher?
    private var rescanPending = false
    let search = NoteSearch()

    var name: String { root.lastPathComponent }

    /// True until the first scan lands.
    private(set) var isScanning = true

    init(root: URL) {
        self.root = root.standardizedFileURL
        tree = FileNode(url: self.root, isFolder: true)
        watcher = FileWatcher(url: self.root) { [weak self] paths in self?.filesChanged(paths) }
        // Listing a folder in iCloud Drive can wait on iCloud for seconds (folders and
        // files may not be downloaded yet), so the first scan never runs on the main
        // thread; windows fill in when it lands.
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            let scan = Workspace.scan(root)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tree = scan.tree
                self.notes = scan.notes
                self.filesByName = scan.byName
                self.isScanning = false
                NotificationCenter.default.post(name: Workspace.didChange, object: self, userInfo: ["paths": [String](), "initial": true])
            }
        }
    }

    // MARK: Scanning

    private struct Scan {
        var tree: FileNode
        var notes: [URL]
        var byName: [String: [URL]]
    }

    private static func scan(_ root: URL) -> Scan {
        var notes: [URL] = []
        var byName: [String: [URL]] = [:]
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]

        func walk(_ url: URL) -> FileNode {
            let node = FileNode(url: url, isFolder: true)
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            var folders: [FileNode] = []
            var files: [FileNode] = []
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    let child = walk(item)
                    child.parent = node
                    folders.append(child)
                } else {
                    byName[name.lowercased(), default: []].append(item)
                    if markdownExtensions.contains(item.pathExtension.lowercased()) {
                        notes.append(item)
                        byName[item.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(item)
                        let f = FileNode(url: item, isFolder: false)
                        f.parent = node
                        files.append(f)
                    }
                }
            }
            let order: (FileNode, FileNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            node.children = folders.sorted(by: order) + files.sorted(by: order)
            return node
        }

        let tree = walk(root)
        return Scan(tree: tree, notes: notes, byName: byName)
    }

    private func filesChanged(_ paths: [String]) {
        search.invalidate(paths)
        NotificationCenter.default.post(name: Workspace.filesTouched, object: self, userInfo: ["paths": paths])
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let root = self.root
            DispatchQueue.global(qos: .userInitiated).async {
                let scan = Workspace.scan(root)
                DispatchQueue.main.async {
                    self.rescanPending = false
                    self.tree = scan.tree
                    self.notes = scan.notes
                    self.filesByName = scan.byName
                    NotificationCenter.default.post(name: Workspace.didChange, object: self, userInfo: ["paths": paths])
                }
            }
        }
    }

    func rescanNow() {
        let scan = Workspace.scan(root)
        tree = scan.tree
        notes = scan.notes
        filesByName = scan.byName
        NotificationCenter.default.post(name: Workspace.didChange, object: self, userInfo: ["paths": [String]()])
    }

    func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    func relativePath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : url.lastPathComponent
    }

    // MARK: Link resolution

    /// Obsidian-style `[[Target]]`, `[[folder/Target#Heading|Alias]]`.
    func resolveWiki(_ target: String, from note: URL?) -> URL? {
        var t = target.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains("/") {
            if !Workspace.markdownExtensions.contains((t as NSString).pathExtension.lowercased()),
               !MarkdownScanner.imageExtensions.contains((t as NSString).pathExtension.lowercased()) {
                t += ".md"
            }
            let u = root.appendingPathComponent(t)
            if FileManager.default.fileExists(atPath: u.path) { return u }
            t = (t as NSString).lastPathComponent
        }
        let candidates = filesByName[t.lowercased()] ?? filesByName[(t as NSString).deletingPathExtension.lowercased()] ?? []
        guard !candidates.isEmpty else { return nil }
        if let dir = note?.deletingLastPathComponent().standardizedFileURL,
           let near = candidates.first(where: { $0.deletingLastPathComponent().standardizedFileURL == dir }) {
            return near
        }
        return candidates.sorted { $0.pathComponents.count < $1.pathComponents.count }.first
    }

    /// A path written in a standard Markdown link or image.
    func resolveRelative(_ path: String, from note: URL?) -> URL? {
        let decoded = path.removingPercentEncoding ?? path
        let clean = decoded.components(separatedBy: "#")[0]
        guard !clean.isEmpty else { return nil }
        if clean.hasPrefix("/") {
            let u = URL(fileURLWithPath: clean)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        var bases: [URL] = [root]
        if let note { bases.insert(note.deletingLastPathComponent(), at: 0) }
        for base in bases {
            let u = base.appendingPathComponent(clean).standardizedFileURL
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return filesByName[(clean as NSString).lastPathComponent.lowercased()]?.first
    }

    func resolveImage(_ ref: ImageRef, from note: URL?) -> URL? {
        ref.isWiki ? resolveWiki(ref.source, from: note) : resolveRelative(ref.source, from: note)
    }

    // MARK: Attachments

    /// Honors Obsidian's attachment folder setting when present, else `attachments/`.
    func attachmentFolder(for note: URL?) -> URL {
        var setting = "attachments"
        let config = root.appendingPathComponent(".obsidian/app.json")
        if let data = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = json["attachmentFolderPath"] as? String, !path.isEmpty {
            setting = path
        }
        if setting == "/" { return root }
        if setting.hasPrefix("./") {
            let base = note?.deletingLastPathComponent() ?? root
            let rest = String(setting.dropFirst(2))
            return rest.isEmpty ? base : base.appendingPathComponent(rest)
        }
        return root.appendingPathComponent(setting)
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    static func imageBaseName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "image-\(f.string(from: Date()))"
    }

    /// Writes image data into the attachments folder and returns its URL.
    func storeImage(_ data: Data, ext: String, for note: URL?, preferredName: String? = nil) throws -> URL {
        let folder = attachmentFolder(for: note)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = preferredName.map { ($0 as NSString).deletingPathExtension } ?? Workspace.imageBaseName()
        let url = Workspace.uniqueURL(in: folder, base: base, ext: ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: File operations

    func createNote(in folder: URL?, name: String = "Untitled", contents: String = "") throws -> URL {
        let dir = folder ?? root
        let url = Workspace.uniqueURL(in: dir, base: Workspace.sanitize(name), ext: "md")
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        rescanNow()
        return url
    }

    func createFolder(in folder: URL?, name: String = "New Folder") throws -> URL {
        let url = Workspace.uniqueURL(in: folder ?? root, base: Workspace.sanitize(name), ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        rescanNow()
        return url
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        let clean = Workspace.sanitize(newName)
        guard !clean.isEmpty else { return url }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let ext = isDir ? "" : url.pathExtension
        let target = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? clean : "\(clean).\(ext)")
        return try move(url, to: target)
    }

    func move(_ url: URL, into folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(url.lastPathComponent)
        return try move(url, to: target)
    }

    private func move(_ url: URL, to target: URL) throws -> URL {
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        // Allow case-only renames on case-insensitive volumes.
        let caseOnly = target.path.lowercased() == url.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: target.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        try FileManager.default.moveItem(at: url, to: target)
        NoteIcons.shared.moved(from: url, to: target, in: self)
        NotificationCenter.default.post(name: Workspace.didMoveItem, object: self, userInfo: ["from": url, "to": target])
        rescanNow()
        return target
    }

    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        rescanNow()
    }

    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Relative, percent-encoded path suitable for a Markdown link from `note`.
    static func markdownPath(for file: URL, from note: URL?, root: URL) -> String {
        let base = (note?.deletingLastPathComponent() ?? root).standardizedFileURL.pathComponents
        let target = file.standardizedFileURL.pathComponents
        var i = 0
        while i < min(base.count, target.count), base[i] == target[i] { i += 1 }
        let parts = Array(repeating: "..", count: base.count - i) + target[i...]
        let path = parts.joined(separator: "/")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
