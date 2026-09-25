import Foundation

/// Title and full-text search. Direct scanning over a lazily filled content cache;
/// no index files, no database. Cache entries are dropped when files change.
final class NoteSearch {
    struct TitleHit {
        let url: URL
        let score: Int
    }

    struct TextHit {
        let url: URL
        let snippet: String
        /// Range of the match within `snippet`.
        let match: NSRange
    }

    private var cache: [URL: String] = [:]
    private let lock = NSLock()
    private var generation = 0
    private let queue = DispatchQueue(label: "indium.search", qos: .userInitiated)

    func invalidate(_ paths: [String]) {
        lock.lock()
        for p in paths { cache.removeValue(forKey: URL(fileURLWithPath: p).standardizedFileURL) }
        lock.unlock()
    }

    /// Subsequence match with bonuses for prefixes and word starts.
    static func titleMatches(_ query: String, in notes: [URL], relativeTo root: URL) -> [TitleHit] {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else {
            let dated = notes.map { ($0, Note.modificationDate($0) ?? .distantPast) }
            return dated.sorted { $0.1 > $1.1 }.prefix(30).map { TitleHit(url: $0.0, score: 0) }
        }
        var hits: [TitleHit] = []
        for url in notes {
            let name = url.deletingPathExtension().lastPathComponent
            if let s = score(q, Array(name.lowercased())) {
                hits.append(TitleHit(url: url, score: s + 20))
            } else {
                let rel = url.deletingPathExtension().path.dropFirst(root.path.count + 1)
                if let s = score(q, Array(rel.lowercased())) { hits.append(TitleHit(url: url, score: s)) }
            }
        }
        return hits.sorted {
            $0.score != $1.score ? $0.score > $1.score
                : $0.url.lastPathComponent.count < $1.url.lastPathComponent.count
        }
    }

    private static func score(_ q: [Character], _ s: [Character]) -> Int? {
        var qi = 0, total = 0, last = -2
        for (i, c) in s.enumerated() where qi < q.count && c == q[qi] {
            var bonus = 1
            if i == 0 { bonus += 8 }
            else if !s[i - 1].isLetter && !s[i - 1].isNumber { bonus += 5 }
            if i == last + 1 { bonus += 4 }
            total += bonus
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return total - s.count / 8
    }

    /// Full-text search on a background queue. Results arrive on the main queue;
    /// stale queries are dropped.
    func searchText(_ query: String, in notes: [URL], limit: Int = 40, completion: @escaping ([TextHit]) -> Void) {
        lock.lock()
        generation += 1
        let token = generation
        lock.unlock()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            completion([])
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            var hits: [TextHit] = []
            for url in notes {
                if self.isStale(token) { return }
                guard let text = self.content(of: url) else { continue }
                guard let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                hits.append(Self.snippet(text, around: r, url: url))
                if hits.count >= limit { break }
            }
            DispatchQueue.main.async {
                if !self.isStale(token) { completion(hits) }
            }
        }
    }

    private func isStale(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != generation
    }

    private func content(of url: URL) -> String? {
        let key = url.standardizedFileURL
        lock.lock()
        if let c = cache[key] {
            lock.unlock()
            return c
        }
        lock.unlock()
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 4_000_000,
              let text = try? Note.read(url) else { return nil }
        lock.lock()
        cache[key] = text
        lock.unlock()
        return text
    }

    private static func snippet(_ text: String, around r: Range<String.Index>, url: URL) -> TextHit {
        let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let start = text.index(r.lowerBound, offsetBy: -40, limitedBy: lineStart) ?? lineStart
        let end = text.index(r.upperBound, offsetBy: 80, limitedBy: lineEnd) ?? lineEnd
        var prefix = String(text[start..<r.lowerBound])
        if start > lineStart { prefix = "…" + prefix.drop(while: { !$0.isWhitespace }).drop(while: \.isWhitespace) }
        let leading = prefix.replacingOccurrences(of: "\t", with: " ")
        let matched = String(text[r])
        var trailing = String(text[r.upperBound..<end])
        if end < lineEnd { trailing += "…" }
        let snippet = leading + matched + trailing
        return TextHit(url: url, snippet: snippet,
                       match: NSRange(location: (leading as NSString).length, length: (matched as NSString).length))
    }
}
