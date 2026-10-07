import AppKit
import QuickLookUI

/// Finder's Quick Look (Space on a note): the note drawn by the editor's own styler
/// and layout, read only, with every bit of Markdown syntax tucked away.
final class PreviewViewController: NSViewController, QLPreviewingController, ImageResolving {
    private let storage = NSTextStorage()
    private let layout = MarkdownLayoutManager()
    private let styler = MarkdownStyler(config: .current)
    private var textView: PreviewTextView!
    private var noteURL: URL?

    override func loadView() {
        let config = styler.config
        storage.addLayoutManager(layout)
        layout.gutter = config.gutter
        layout.bodyLineSpacing = config.typography.lineSpacing
        layout.typoParagraphGap = config.typography.paragraphSpacing
        layout.captionFont = config.typography.text(bold: false, italic: true, size: round(config.typography.size * 0.8))
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        styler.imageResolver = self

        let tv = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        tv.gutter = config.gutter
        tv.columnWidth = AppSettings.shared.lineWidth.points
        tv.onColumnChange = { [weak self] column in self?.columnChanged(column) }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.drawsBackground = true
        tv.backgroundColor = Palette.background
        tv.linkTextAttributes = [
            .foregroundColor: Palette.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: Palette.linkUnderline,
        ]
        textView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.background
        scroll.borderType = .noBorder
        scroll.appearance = AppSettings.shared.appearance.appearance
        view = scroll
        preferredContentSize = NSSize(width: config.columnWidth + config.gutter * 2 + 80, height: 800)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        var encoding = String.Encoding.utf8
        let text = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, usedEncoding: &encoding)
        noteURL = url
        _ = view
        storage.setAttributedString(NSAttributedString(string: text))
        restyle()
        if let container = textView.textContainer, storage.length < 400_000 { layout.ensureLayout(for: container) }
        textView.scroll(.zero)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        textView.scroll(.zero)
    }

    private func columnChanged(_ column: CGFloat) {
        guard styler.config.columnWidth != column else { return }
        styler.config.columnWidth = column
        if storage.length > 0 { restyle() }
    }

    private func restyle() {
        guard let container = textView.textContainer else { return }
        styler.styleAll(storage, selection: [])
        if let bottom = layout.placeFloats(in: container, styler: styler) {
            textView.minSize = NSSize(width: 0, height: bottom + textView.textContainerInset.height * 2 + 40)
        }
        textView.needsDisplay = true
    }

    // MARK: Images

    /// Looks beside the note, then in the folders above it (a vault's attachments),
    /// since the preview doesn't know which vault the note belongs to.
    ///
    /// Each place is actually tried. The sandbox may refuse files beyond the note itself
    /// (the App Store preview has no exception to read the rest of the disk), and only
    /// then does the image become a placeholder that says so. An image that simply
    /// isn't there stays missing, as in the editor.
    func image(for ref: ImageRef) -> NSImage? {
        guard let noteURL else { return nil }
        let source = ref.source.removingPercentEncoding ?? ref.source
        guard !source.hasPrefix("http://"), !source.hasPrefix("https://") else { return nil }
        var denied = false
        func load(_ url: URL) -> NSImage? {
            do {
                return NSImage(data: try Data(contentsOf: url.standardizedFileURL))
            } catch {
                if Self.isPermissionError(error) { denied = true }
                return nil
            }
        }
        defer {
            #if DEBUG
            NSLog("IndiumQL %@ image %@: denied=%d", Bundle.main.bundleIdentifier ?? "-", source, denied ? 1 : 0)
            #endif
        }
        if source.hasPrefix("/") {
            return load(URL(fileURLWithPath: source)) ?? (denied ? Self.unreadablePlaceholder(source) : nil)
        }
        let name = (source as NSString).lastPathComponent
        var folder = noteURL.deletingLastPathComponent()
        for _ in 0..<4 {
            for candidate in [folder.appendingPathComponent(source), folder.appendingPathComponent("attachments/\(name)")] {
                if let image = load(candidate) { return image }
            }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".obsidian").path) { break }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return denied ? Self.unreadablePlaceholder(source) : nil
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// An honest stand-in for an image Quick Look isn't allowed to read.
    private static func unreadablePlaceholder(_ source: String) -> NSImage {
        let size = NSSize(width: 420, height: 96)
        return NSImage(size: size, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            Palette.background.blended(withFraction: 0.06, of: .labelColor)?.setFill()
            box.fill()
            NSColor.separatorColor.setStroke()
            box.lineWidth = 1
            box.stroke()
            if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: 22, y: (rect.height - s.height) / 2, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 0.45)
            }
            let title = NSAttributedString(string: "Image not shown in Quick Look", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            let detail = NSAttributedString(string: "Open the note in Indium to see \((source as NSString).lastPathComponent).", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
            title.draw(at: NSPoint(x: 64, y: rect.midY + 2))
            detail.draw(at: NSPoint(x: 64, y: rect.midY - 16))
            return true
        }
    }
}

/// Centers the note's column like the editor does and draws floating tables and images.
final class PreviewTextView: NSTextView {
    var columnWidth: CGFloat = 700 { didSet { updateGeometry() } }
    var gutter: CGFloat = 56 { didSet { updateGeometry() } }
    var onColumnChange: ((CGFloat) -> Void)?
    private var insetX: CGFloat = 0
    private var column: CGFloat = 0
    private let topPadding: CGFloat = 36

    override var textContainerOrigin: NSPoint { NSPoint(x: insetX, y: topPadding) }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { updateGeometry() }
    }

    private func updateGeometry() {
        let available = bounds.width
        let newColumn = max(200, min(columnWidth, available - gutter * 2 - 24))
        insetX = max(0, floor((available - newColumn) / 2 - gutter))
        textContainerInset = NSSize(width: insetX, height: topPadding)
        let width = min(newColumn + gutter * 2, max(available - insetX * 2, 0))
        if let textContainer, textContainer.size.width != width {
            textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        if newColumn != column {
            column = newColumn
            onColumnChange?(newColumn)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (layoutManager as? MarkdownLayoutManager)?.drawFloats(in: dirtyRect, origin: textContainerOrigin)
    }
}
