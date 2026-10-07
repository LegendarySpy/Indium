import AppKit

/// One Markdown file (or a temporary, memory-only page).
/// The file on disk is the source of truth; this only tracks what we last saw there.
final class Note {
    private(set) var url: URL?
    /// Text as last read from or written to disk.
    private(set) var savedText: String
    private(set) var diskDate: Date?
    let undoManager = UndoManager()

    var selection = NSRange(location: 0, length: 0)
    var scrollOffset: CGFloat = 0

    /// Images pasted into a temporary note, keyed by the path used in the Markdown.
    var memoryImages: [String: Data] = [:]

    /// Keeps the note's folder (or the file itself) reachable while the note is open,
    /// even after the window's workspace has moved on. See `FolderAccess`.
    var access: FolderAccess.Lease?

    var isTemporary: Bool { url == nil }

    var title: String {
        guard let url else { return "Temporary Note" }
        return url.deletingPathExtension().lastPathComponent
    }

    init(temporary: ()) {
        url = nil
        savedText = ""
    }

    init(url: URL) throws {
        self.url = url
        savedText = try Note.read(url)
        diskDate = Note.modificationDate(url)
    }

    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    enum DiskState {
        case unchanged
        case changed(String)
        case missing
    }

    /// Compares the file on disk against what we last saw.
    func checkDisk() -> DiskState {
        guard let url else { return .unchanged }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let date = Note.modificationDate(url)
        if date == diskDate { return .unchanged }
        guard let text = try? Note.read(url) else { return .unchanged }
        if text == savedText {
            diskDate = date
            return .unchanged
        }
        return .changed(text)
    }

    /// Accepts the disk version as the new baseline.
    /// `keepUndo` when the change was applied as an undoable edit.
    func adopt(diskText: String, keepUndo: Bool = false) {
        savedText = diskText
        if let url { diskDate = Note.modificationDate(url) }
        if !keepUndo { undoManager.removeAllActions() }
    }

    func write(_ text: String) throws {
        guard let url else { return }
        if text == savedText, FileManager.default.fileExists(atPath: url.path) { return }
        #if DEBUG
        // `-IndiumFailSaves YES`: every note save fails, to exercise the failed-save paths.
        if UserDefaults.standard.bool(forKey: "IndiumFailSaves") {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        #endif
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Note.safeWrite(Data(text.utf8), to: url)
        savedText = text
        diskDate = Note.modificationDate(url)
    }

    /// The file was renamed or moved (by us or externally).
    func relocate(to newURL: URL) {
        url = newURL
        diskDate = Note.modificationDate(newURL)
    }

    /// A temporary note being saved for the first time.
    func becomePermanent(at newURL: URL, text: String) throws {
        try Note.safeWrite(Data(text.utf8), to: newURL)
        url = newURL
        savedText = text
        diskDate = Note.modificationDate(newURL)
        memoryImages = [:]
    }

    // MARK: Safe writing

    /// Replaces the file's contents without ever leaving it half written: coordinated
    /// with other apps (iCloud Drive, Obsidian, sync tools) through `NSFileCoordinator`,
    /// and written to a temporary file that is then swapped in.
    ///
    /// The usual temporary file lives beside the note. When Indium may only touch the
    /// note itself (a single file opened from Finder in the App Store build), it can't
    /// create that file, so the new contents go to the system's replacement folder on
    /// the same volume and `replaceItemAt` swaps them in. There is deliberately no
    /// in-place fallback: if neither works, the error reaches you and the file on disk
    /// stays exactly as it was.
    static func safeWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch where FolderAccess.isPermissionError(error) && FileManager.default.fileExists(atPath: target.path) {
                FolderAccess.log("save beside the note refused; replacing via the system's replacement folder: \(target.path)")
                do { try replaceViaTemporaryFile(data, at: target) } catch { writeError = error }
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private static func replaceViaTemporaryFile(_ data: Data, at url: URL) throws {
        let fm = FileManager.default
        let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: folder) }
        let temp = folder.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temp)
        _ = try fm.replaceItemAt(url, withItemAt: temp)
    }
}
