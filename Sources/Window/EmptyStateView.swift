import AppKit

/// Quiet centered message shown when there is nothing to edit.
final class EmptyStateView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Open Folder…", target: nil, action: #selector(AppDelegate.openFolder(_:)))
    private let actions = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        heading.font = Typography.baseFont(.serif, size: 30, weight: .regular)
        heading.textColor = Palette.tertiaryText
        message.font = NSFont.systemFont(ofSize: 13)
        message.textColor = Palette.secondaryText
        message.alignment = .center
        button.bezelStyle = .glass
        button.controlSize = .large

        actions.spacing = 10
        let stack = NSStackView(views: [heading, message, button, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(4, after: heading)
        stack.setCustomSpacing(20, after: message)
        stack.setCustomSpacing(18, after: button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func showNoFolder() {
        heading.stringValue = "Indium"
        heading.isHidden = false
        message.stringValue = "Open a folder of Markdown files to begin.\nAn existing Obsidian vault works as is."
        button.isHidden = false
        setActions([("Temporary Note", "⇧⌘N", #selector(AppDelegate.newTemporaryNote(_:)))])
    }

    func showNoNote() {
        heading.isHidden = true
        message.stringValue = "No note open"
        button.isHidden = true
        setActions([("New Note", "⌘N", #selector(DocumentWindowController.newNote(_:))),
                    ("Open Note", "⌘O", #selector(DocumentWindowController.openQuickly(_:)))])
    }

    /// Real buttons rather than a line of shortcut hints.
    private func setActions(_ items: [(String, String, Selector)]) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (title, shortcut, action) in items {
            let b = NSButton(title: "\(title)  \(shortcut)", target: nil, action: action)
            b.bezelStyle = .glass
            b.controlSize = .large
            actions.addArrangedSubview(b)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        dirtyRect.fill()
    }
}
