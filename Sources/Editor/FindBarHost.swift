import AppKit

/// Hosts the system find bar (NSTextFinder) in a floating glass capsule under the
/// title bar, instead of wedging it into the top of the page.
final class FindBarHost: NSView, NSTextFinderBarContainer {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private let content = NSView()
    private var glass: NSView!
    private var heightConstraint: NSLayoutConstraint!
    weak var textView: NSTextView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        installArrowCursorArea()
        translatesAutoresizingMaskIntoConstraints = false
        glass = Glass.make(cornerRadius: 16, content: content)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
        isHidden = true
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 14
            s.shadowOffset = NSSize(width: 0, height: -4)
            s.shadowColor = NSColor.black.withAlphaComponent(0.12)
            return s
        }()
    }

    required init?(coder: NSCoder) { fatalError() }

    // The finder takes a bar that's in a window as already showing, so it only goes in
    // while visible.
    var findBarView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            findBarView?.autoresizingMask = [.width, .minYMargin]
            if isFindBarVisible { installBar() }
        }
    }

    private func installBar() {
        guard let bar = findBarView, bar.superview !== content else { return }
        content.addSubview(bar)
    }

    var isFindBarVisible = false {
        didSet {
            guard oldValue != isFindBarVisible else { return }
            if isFindBarVisible { installBar() }
            layoutBar()
            if isFindBarVisible {
                isHidden = false
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
            } else {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; animator().alphaValue = 0 },
                                                     completionHandler: { [weak self] in
                    guard let self, !self.isFindBarVisible else { return }
                    self.isHidden = true
                    self.findBarView?.removeFromSuperview()
                    if let tv = self.textView { tv.window?.makeFirstResponder(tv) }
                })
            }
        }
    }

    func findBarViewDidChangeHeight() {
        layoutBar()
    }

    func contentView() -> NSView? {
        textView?.enclosingScrollView
    }

    private static let inset: CGFloat = 6

    private func layoutBar() {
        guard let bar = findBarView else { return }
        heightConstraint.constant = bar.frame.height + Self.inset * 2
        superview?.layoutSubtreeIfNeeded()
        placeBar(bar)
    }

    private func placeBar(_ bar: NSView) {
        bar.frame = NSRect(x: Self.inset, y: Self.inset, width: max(content.bounds.width - Self.inset * 2, 100), height: bar.frame.height)
    }

    override func layout() {
        super.layout()
        if let bar = findBarView { placeBar(bar) }
    }
}

/// NSTextView implements the finder's client methods but doesn't declare it to Swift;
/// without this the finder gets no client and Find does nothing.
extension EditorTextView: NSTextFinderClient {}
