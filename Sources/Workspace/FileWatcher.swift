import CoreServices
import Foundation

/// FSEvents stream over a folder. Idle cost is zero: the kernel pushes
/// coalesced batches and nothing polls.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(url: URL, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(Array(array.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.08, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Watches one file, for a note opened on its own from Finder. In the App Store build
/// Indium may read only that file, not its folder, so a folder stream could stay
/// silent; a vnode source on the file itself still fires. Editors that save by
/// replacing the file (a new inode) end this source, so it reattaches to whatever now
/// sits at the path.
final class SingleFileWatcher {
    private let url: URL
    private let handler: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchWorkItem?
    /// Grows while the file stays missing, so a deleted note isn't polled hard.
    private var retryDelay = 0.15

    init(url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
        attach()
    }

    private func attach() {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-replace or gone: look again shortly (a missing note is handled by the
            // editor, which closes the window when it notices).
            scheduleRetry()
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self, let s = self.source else { return }
            let replaced = !s.data.isDisjoint(with: [.delete, .rename, .revoke])
            self.handler()
            if replaced { self.scheduleRetry() }
        }
        s.setCancelHandler { close(fd) }
        source = s
        retryDelay = 0.15
        s.resume()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.attach()
            self?.handler()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 5)
    }

    deinit {
        retry?.cancel()
        source?.cancel()
    }
}
