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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
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
        url = newURL
        try Data(text.utf8).write(to: newURL, options: .atomic)
        savedText = text
        diskDate = Note.modificationDate(newURL)
        memoryImages = [:]
    }
}
