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
    func image(for ref: ImageRef) -> NSImage? {
        guard let noteURL else { return nil }
        let source = ref.source.removingPercentEncoding ?? ref.source
        guard !source.hasPrefix("http://"), !source.hasPrefix("https://") else { return nil }
        if source.hasPrefix("/") { return NSImage(contentsOfFile: source) }
        let name = (source as NSString).lastPathComponent
        var folder = noteURL.deletingLastPathComponent()
        for _ in 0..<4 {
            for candidate in [folder.appendingPathComponent(source), folder.appendingPathComponent("attachments/\(name)")] {
                if let image = NSImage(contentsOf: candidate.standardizedFileURL) { return image }
            }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".obsidian").path) { break }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return nil
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
