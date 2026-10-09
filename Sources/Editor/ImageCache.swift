import AppKit

/// Images the editor draws, decoded once. Remote ones load in the background.
final class ImageCache {
    static let shared = ImageCache()
    static let remoteImageLoaded = Notification.Name("IndiumRemoteImageLoaded")

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()
    private var loading = Set<URL>()

    func image(at url: URL) -> NSImage? {
        let stamp = Note.modificationDate(url)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key, cost: cost(image))
        return image
    }

    func image(data: Data, key: String) -> NSImage? {
        let k = "mem|\(key)|\(data.count)" as NSString
        if let hit = cache.object(forKey: k) { return hit }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: k, cost: data.count)
        return image
    }

    /// Whether `url` is there but Indium isn't allowed to read it (the sandbox, or the
    /// file's permissions), as opposed to missing.
    static func isAccessDenied(_ url: URL) -> Bool {
        do {
            try FileHandle(forReadingFrom: url).close()
            return false
        } catch {
            func denied(_ error: Error) -> Bool {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
                if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
                return (ns.userInfo[NSUnderlyingErrorKey] as? Error).map(denied) ?? false
            }
            return denied(error)
        }
    }

    /// Returns the cached image or starts a fetch and returns nil.
    func remote(_ url: URL) -> NSImage? {
        let key = "remote|\(url.absoluteString)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                self.loading.remove(url)
                if let data, let image = NSImage(data: data) {
                    self.cache.setObject(image, forKey: key, cost: data.count)
                    NotificationCenter.default.post(name: Self.remoteImageLoaded, object: url)
                }
            }
        }.resume()
        return nil
    }

    private func cost(_ image: NSImage) -> Int {
        let rep = image.representations.first
        return max(1, (rep?.pixelsWide ?? 100) * (rep?.pixelsHigh ?? 100) * 4)
    }
}
