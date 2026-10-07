import AppKit

/// A small glass bar floating at the bottom of a file window, offering to grant the
/// note's folder. In the App Store build, a note opened on its own from Finder may read
/// only itself, so the images saved beside it stay hidden until you allow the folder.
final class FolderAccessBar: NSView {
    var onGrant: (() -> Void)?
    var onDismiss: (() -> Void)?

    init(folderName: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        let label = NSTextField(labelWithString: "Images beside this note need access to “\(folderName)”.")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let grant = NSButton(title: "Grant Access to Folder…", target: self, action: #selector(grantClicked))
        grant.bezelStyle = .glass
        grant.keyEquivalent = ""
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss") ?? NSImage(),
                             target: self, action: #selector(dismissClicked))
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        let row = NSStackView(views: [icon, label, grant, close])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        let glass = Glass.make(cornerRadius: 18, content: row)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label.stringValue)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func grantClicked() { onGrant?() }
    @objc private func dismissClicked() { onDismiss?() }

    #if DEBUG
    func debugGrant() { grantClicked() }
    #endif
}
