import Foundation

/// Which notes link to which, worked out off the main thread after each scan. Only each
/// note's link targets are kept, and a note is read again only when its date changes. A
/// note iCloud hasn't brought here isn't read; its arrival sets off another scan.
final class BacklinkIndex {
    private struct Source {
        let date: Date?
        let targets: [String]
    }

    private let queue = DispatchQueue(label: "indium.backlinks", qos: .utility)
    private var sources: [URL: Source] = [:]
    private var incoming: [String: [URL]] = [:]
    private let lock = NSLock()
    private var generation = 0

    func links(to note: URL) -> [URL] {
        incoming[Self.key(note)] ?? []
    }

    /// `changed` runs on the main queue when any note's list came out different.
    func update(notes: [URL], files: [String: [URL]], root: URL, access: FolderAccess.Lease, changed: @escaping () -> Void) {
        lock.lock()
        generation += 1
        let token = generation
        lock.unlock()
        queue.async { [self] in
            let found: [String: [URL]]? = withExtendedLifetime(access) {
                guard read(notes, token: token) else { return nil }
                return resolve(notes, files: files, root: root)
            }
            guard let found else { return }
            DispatchQueue.main.async { [self] in
                guard !isStale(token), found != incoming else { return }
                incoming = found
                changed()
            }
        }
    }

    /// False when a newer scan took over; what was read so far stays for it.
    private func read(_ notes: [URL], token: Int) -> Bool {
        var fresh: [URL: Source] = [:]
        fresh.reserveCapacity(notes.count)
        for url in notes {
            if isStale(token) { return false }
            let date = Note.modificationDate(url)
            if let known = sources[url], known.date == date || !Note.isDownloaded(url) {
                fresh[url] = known
            } else if Note.isDownloaded(url),
                      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 4_000_000,
                      let text = try? Note.read(url) {
                let source = Source(date: date, targets: MarkdownScanner.wikiTargets(in: text as NSString))
                fresh[url] = source
                sources[url] = source
            }
        }
        sources = fresh
        return true
    }

    private func resolve(_ notes: [URL], files: [String: [URL]], root: URL) -> [String: [URL]] {
        var found: [String: Set<URL>] = [:]
        let keys = notes.map(Self.key)
        let known = Set(keys)
        // A link can differ from the file in case on a disk that ignores case.
        let folded = Dictionary(keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for url in notes {
            for target in sources[url]?.targets ?? [] {
                guard let linked = Workspace.resolveWiki(target, from: url, root: root, files: files) else { continue }
                var key = Self.key(linked)
                if !known.contains(key) { key = folded[key.lowercased()] ?? key }
                if key != Self.key(url) { found[key, default: []].insert(url) }
            }
        }
        return found.mapValues { urls in
            urls.sorted { $0.path.lowercased() < $1.path.lowercased() }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }

    private func isStale(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != generation
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
