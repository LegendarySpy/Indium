import AppKit

/// The editor finds embedded notes the way it follows wiki links: through the vault,
/// preferring a note beside the one doing the embedding. Anything that isn't a note
/// (a PDF, a canvas) isn't embedded.
extension EditorController: NoteEmbedResolving {
    var embeddingNoteURL: URL? { note?.url }

    func noteURL(forEmbed target: String, from note: URL?) -> URL? {
        NoteEmbedRefresher.watch(self)
        guard let url = workspace?.resolveWiki(target, from: note),
              Workspace.markdownExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    func image(for ref: ImageRef, from note: URL?) -> NSImage? {
        if ref.source.hasPrefix("http://") || ref.source.hasPrefix("https://") {
            return URL(string: ref.source).flatMap { ImageCache.shared.remote($0) }
        }
        return workspace?.resolveImage(ref, from: note).flatMap { ImageCache.shared.image(at: $0) }
    }
}

/// Redraws embeds when a note they show changes on disk (another app, sync, the note
/// edited in another window), nested notes included, without touching the embed line.
enum NoteEmbedRefresher {
    private static let editors = NSHashTable<EditorController>.weakObjects()
    private static var observer: NSObjectProtocol?

    static func watch(_ editor: EditorController) {
        editors.add(editor)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: Workspace.filesTouched, object: nil, queue: .main) { n in
            let paths = Set((n.userInfo?["paths"] as? [String] ?? []).map { NoteEmbed.key(URL(fileURLWithPath: $0)) })
            // The vault's file index catches up a moment later; a newly created note
            // must be findable before a "not found" embed looks for it again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                for editor in editors.allObjects { refresh(editor, paths: paths) }
            }
        }
    }

    private static func refresh(_ editor: EditorController, paths: Set<String>) {
        let storage = editor.storage
        var stale: [Int] = []
        storage.enumerateAttribute(.mdEmbed, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let embed = value as? NoteEmbed else { return }
            let missing: Bool
            if case .message = embed.content { missing = true } else { missing = false }
            if missing || !embed.dependencies.isDisjoint(with: paths) { stale.append(range.location) }
        }
        for location in stale {
            editor.styler.restyleBlock(at: location, in: storage)
            let line = (storage.string as NSString).lineRange(for: NSRange(location: location, length: 0))
            editor.layoutManager.invalidateLayout(forCharacterRange: line, actualCharacterRange: nil)
            editor.layoutManager.invalidateDisplay(forCharacterRange: line)
        }
    }
}
