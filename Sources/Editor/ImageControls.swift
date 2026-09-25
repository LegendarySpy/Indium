import AppKit

/// Tiny contextual bar shown only while an image is selected.
final class ImageControlsView: PopoverSurface {
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    var onWidth: ((CGFloat?) -> Void)?
    var onCaption: (() -> Void)?
    var onRemove: (() -> Void)?
    private var sizeButtons: [HoverButton] = []
    private let captionButton: HoverButton

    private static let fractions: [(String, String, CGFloat?)] = [
        ("S", "Small", 0.33), ("M", "Medium", 0.5), ("L", "Large", 0.75), ("Fit", "Fit to column", nil),
    ]

    override init(frame: NSRect) {
        captionButton = HoverButton(symbol: "text.below.photo", label: "Caption", pointSize: 12, target: nil, action: nil)
        super.init(frame: frame)
        installArrowCursorArea()
        cornerRadius = 8
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, (short, label, _)) in Self.fractions.enumerated() {
            let b = HoverButton(text: short, label: label, target: self, action: #selector(sizeClicked(_:)))
            b.tag = i
            sizeButtons.append(b)
            stack.addArrangedSubview(b)
        }
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = Palette.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 14).isActive = true
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(6, after: sizeButtons.last!)
        stack.setCustomSpacing(6, after: divider)
        captionButton.target = self
        captionButton.action = #selector(captionClicked)
        stack.addArrangedSubview(captionButton)
        stack.addArrangedSubview(HoverButton(symbol: "trash", label: "Remove Image", pointSize: 12, target: self, action: #selector(removeClicked)))
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            // Soft, so the hidden (zero-sized) bar doesn't fight its own contents.
            stack.trailingAnchor.constraint(equalTo: trailingAnchor).withPriority(.init(999)),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor).withPriority(.init(999)),
        ])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Image")
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(currentWidth: CGFloat?, column: CGFloat, captionAllowed: Bool) {
        for (i, b) in sizeButtons.enumerated() {
            let f = Self.fractions[i].2
            if let f, let w = currentWidth { b.isOn = abs(w - round(column * f)) < 2 }
            else { b.isOn = f == nil && currentWidth == nil }
        }
        captionButton.isHidden = !captionAllowed
    }

    @objc private func sizeClicked(_ sender: HoverButton) { onWidth?(Self.fractions[sender.tag].2) }
    @objc private func captionClicked() { onCaption?() }
    @objc private func removeClicked() { onRemove?() }
}

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
