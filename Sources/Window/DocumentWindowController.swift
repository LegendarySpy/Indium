import AppKit
import UniformTypeIdentifiers

/// A window showing one page. The vault window switches between notes in place;
/// temporary windows hold a single memory-only page, and file windows hold one
/// Markdown file from outside the folder, opened on its own.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    enum Kind { case vault, temporary, file }

    let kind: Kind
    let editor = EditorController()
    private let titleBar = TitleBarView()
    private let emptyState = EmptyStateView()
    private let root = RootView()
    private let topFade = CAGradientLayer()
    private let fadeMask = CALayer()
    private let scrollerStrip = CALayer()
    private let findHost = FindBarHost()
    private var sidebar: SidebarView?
    private var sidebarGlass: NSView?
    private var sidebarVisible = false
    /// Where the page starts: past the sidebar when it's open and there's room.
    private var pageLeading: [NSLayoutConstraint] = []
    private var quickOpen: QuickOpenView?
    private var monitors: [Any] = []
    private var observers: [Any] = []
    private var noteCache: [URL: Note] = [:]
    private var noteOrder: [URL] = []
    /// File windows watch the file's folder for edits from other apps.
    private var fileWatcher: FileWatcher?

    var workspace: Workspace? { AppDelegate.shared.workspace }
    var note: Note? { editor.note }

    init(kind: Kind) {
        self.kind = kind
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none

        window.backgroundColor = Palette.background
        window.minSize = NSSize(width: 520, height: 380)
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.contentView = root
        window.isRestorable = kind == .vault
        if kind == .vault {
            window.setFrameAutosaveName("IndiumMain")
            if !window.setFrameUsingName("IndiumMain") { window.center() }
        } else {
            window.setContentSize(NSSize(width: 820, height: 720))
            cascade(window)
        }
        buildLayout()
        wireEditor()

        if kind == .file { editor.workspace = nil }
        if kind == .temporary {
            titleBar.isTemporary = true
            editor.load(Note(temporary: ()))
            titleBar.title = "Temporary Note"
            window.title = "Temporary Note"
        } else {
            titleBar.isTemporary = false
            refreshEmptyState()
            if kind == .vault, UserDefaults.standard.bool(forKey: Self.sidebarKey) {
                setSidebarVisible(true, remember: false)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func cascade(_ window: NSWindow) {
        if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 28, y: key.frame.maxY - 28))
        } else {
            window.center()
        }
    }

    private func buildLayout() {
        let scroll = editor.scrollView
        for v in [scroll, emptyState, findHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        pageLeading = [
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        ]
        NSLayoutConstraint.activate(pageLeading + [
            // The page begins below the title bar, so nothing of it sits under the controls.
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: TitleBarView.height),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: root.topAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            findHost.topAnchor.constraint(equalTo: root.topAnchor, constant: TitleBarView.height + 6),
            findHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            findHost.widthAnchor.constraint(equalToConstant: 540).withPriority(.defaultHigh),
            findHost.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
        ])
        editor.attachFindBar(findHost)
        // The controls live in the window's own title bar, above the system's soft scroll
        // edge, so the page scrolls under them the way it does in Apple's apps.
        hostTitleBar(inFullScreen: false)
        editor.textView.topPadding = 44
        emptyState.isHidden = true

        // The page fades into the paper under the title bar. It's an alpha mask on the
        // scroll view itself, so there is no separate surface whose color could differ.
        // The scroller's strip stays fully opaque so it never fades at the top.
        scroll.wantsLayer = true
        topFade.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.25).cgColor, NSColor.black.cgColor]
        topFade.startPoint = CGPoint(x: 0.5, y: 0)
        topFade.endPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.addSublayer(topFade)
        scrollerStrip.backgroundColor = NSColor.black.cgColor
        fadeMask.addSublayer(scrollerStrip)
        scroll.layer?.mask = fadeMask
        for view in [scroll, scroll.contentView] as [NSView] {
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                self?.layoutTopFade()
            })
        }

        titleBar.onIconClick = { [weak self] anchor in self?.showIconPicker(from: anchor) }
        titleBar.headingLevel = { [weak self] in self?.editor.currentHeadingLevel() ?? 0 }
        titleBar.onRename = { [weak self] name in self?.rename(to: name) }
        titleBar.onLiveRename = { [weak self] name in self?.rename(to: name, quietly: true) }
        titleBar.onRenameEnded = { [weak self] in
            guard let self, self.note != nil else { return }
            self.window?.makeFirstResponder(self.editor.textView)
        }

        observers.append(NotificationCenter.default.addObserver(forName: Workspace.didChange, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? Workspace) === self.workspace else { return }
            self.sidebar?.sync()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NoteIcons.didChange, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            if let url = n.object as? URL { self.sidebar?.refreshIcon(for: url) }
            if let url = n.object as? URL, url.standardizedFileURL == self.note?.url?.standardizedFileURL {
                self.titleBar.setIcon(NoteIcons.shared.icon(for: url, in: self.workspace))
            }
        })

        // Chrome comes back with any pointer movement; typing hides it again.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            if event.window === self?.window { self?.titleBar.setChromeVisible(true) }
            return event
        } as Any)

    }

    private func wireEditor() {
        editor.workspace = workspace
        editor.onTyping = { [weak self] in self?.titleBar.setChromeVisible(false) }
        editor.onTitleChange = { [weak self] in self?.updateTitle() }
        editor.onOpenNote = { [weak self] url in self?.open(url) }
        editor.onNoteMissing = { [weak self] in
            guard let self else { return }
            if self.kind == .file {
                self.close()
                return
            }
            self.editor.load(nil)
            self.refreshEmptyState()
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        titleBar.alignWithTrafficLights()
        layoutTopFade()
        if sidebarVisible { applyPageInset(pageInset()) }
    }

    /// Windowed, the controls live in the system title bar so they get its clicks. In
    /// full screen macOS hides that bar, so they move onto the page and stay visible.
    private func hostTitleBar(inFullScreen fullScreen: Bool) {
        let host: NSView? = fullScreen ? root : window?.standardWindowButton(.closeButton)?.superview
        guard let host, titleBar.superview !== host else { return }
        titleBar.removeFromSuperview()
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(titleBar)
        var constraints = [
            titleBar.topAnchor.constraint(equalTo: host.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ]
        constraints.append(fullScreen ? titleBar.heightAnchor.constraint(equalToConstant: TitleBarView.height)
                                      : titleBar.bottomAnchor.constraint(equalTo: host.bottomAnchor))
        NSLayoutConstraint.activate(constraints)
        titleBar.alignWithTrafficLights()
    }

    private func layoutTopFade() {
        let scroll = editor.scrollView
        let h = max(scroll.bounds.height, 1)
        let strip: CGFloat = 16
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = scroll.bounds
        topFade.frame = CGRect(x: 0, y: 0, width: max(0, scroll.bounds.width - strip), height: scroll.bounds.height)
        scrollerStrip.frame = CGRect(x: scroll.bounds.width - strip, y: 0, width: strip, height: scroll.bounds.height)
        // An eased ramp over a longer reach: nearly clear at the edge, then picking up
        // gradually, so text softens away under the title bar instead of reading as a
        // straight fade line (most visible over selections and tinted blocks).
        let reach: CGFloat = 46
        let steps = 10
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let eased = pow(t * t * (3 - 2 * t), 1.6)
            colors.append(NSColor.black.withAlphaComponent(eased).cgColor)
            locations.append(NSNumber(value: Double(t * reach / h)))
        }
        colors.append(NSColor.black.cgColor)
        locations.append(1)
        topFade.colors = colors
        topFade.locations = locations
        CATransaction.commit()
    }

    func windowDidResize(_ notification: Notification) {
        titleBar.alignWithTrafficLights()
        layoutTopFade()
        if sidebarVisible, pageLeading.first?.constant != pageInset() { applyPageInset(pageInset()) }
    }
    func windowDidEnterFullScreen(_ notification: Notification) { titleBar.alignWithTrafficLights() }
    func windowWillEnterFullScreen(_ notification: Notification) { hostTitleBar(inFullScreen: true) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { hostTitleBar(inFullScreen: false) }
    func windowWillExitFullScreen(_ notification: Notification) { hostTitleBar(inFullScreen: false) }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { hostTitleBar(inFullScreen: true) }
    func windowDidExitFullScreen(_ notification: Notification) { titleBar.alignWithTrafficLights() }

    // MARK: Single files

    /// Shows a file from outside the folder in this (file) window.
    func openFile(_ url: URL) throws {
        let note = try Note(url: url.standardizedFileURL)
        editor.load(note)
        refreshEmptyState()
        updateTitle()
        window?.makeFirstResponder(editor.textView)
        fileWatcher = FileWatcher(url: url.deletingLastPathComponent()) { [weak self] _ in
            self?.editor.checkForExternalChanges()
        }
    }

    // MARK: Workspace

    func workspaceDidChange() {
        editor.workspace = workspace
        noteCache.removeAll()
        noteOrder.removeAll()
        sidebar?.workspace = workspace
        if kind == .vault {
            editor.load(nil)
            refreshEmptyState()
            if workspace == nil {
                setSidebarVisible(false, remember: false)
            } else if UserDefaults.standard.bool(forKey: Self.sidebarKey), !sidebarVisible {
                setSidebarVisible(true, remember: false)
            }
        }
    }

    private func showIconPicker(from anchor: NSView) {
        guard let url = note?.url, let workspace else { return }
        let picker = IconPickerController()
        picker.current = NoteIcons.shared.icon(for: url, in: workspace)
        picker.onPick = { symbol in NoteIcons.shared.set(symbol, for: url, in: workspace) }
        picker.onSuggest = { [weak self] in
            guard let self else { return }
            NoteIcons.shared.suggest(for: url, text: self.editor.text, in: workspace, force: true)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func refreshEmptyState() {
        let hasNote = editor.note != nil
        emptyState.isHidden = hasNote
        editor.scrollView.isHidden = !hasNote
        titleBar.formattingEnabled = hasNote
        titleBar.titleIsRenamable = hasNote && kind != .file
        if !hasNote {
            if workspace == nil { emptyState.showNoFolder() } else { emptyState.showNoNote() }
            titleBar.title = workspace?.name ?? ""
            window?.title = workspace?.name ?? "Indium"
            window?.representedURL = nil
        }
        titleBar.iconAvailable = hasNote && kind == .vault && workspace != nil
        titleBar.filesButton.isHidden = workspace == nil || kind != .vault
        titleBar.searchButton.isHidden = workspace == nil || kind != .vault
    }

    private func updateTitle() {
        guard let note else { return }
        titleBar.title = note.title
        titleBar.setIcon(note.url.flatMap { NoteIcons.shared.icon(for: $0, in: workspace) })
        window?.title = note.title
        window?.representedURL = note.url
        sidebar?.currentURL = note.url
        if kind == .vault, let url = note.url, let ws = workspace {
            UserDefaults.standard.set(ws.relativePath(url), forKey: "lastNote")
        }
    }

    /// Opens a note in this window, keeping undo history for recently used notes.
    func open(_ url: URL, select query: String? = nil) {
        guard kind == .vault else {
            AppDelegate.shared.openDocument(url)
            return
        }
        let key = url.standardizedFileURL
        let note: Note
        if let cached = noteCache[key], FileManager.default.fileExists(atPath: key.path) {
            note = cached
            if case let .changed(text) = cached.checkDisk() { cached.adopt(diskText: text) }
        } else {
            do { note = try Note(url: key) } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) }
                return
            }
            noteCache[key] = note
        }
        noteOrder.removeAll { $0 == key }
        noteOrder.append(key)
        if noteOrder.count > 24 { noteCache.removeValue(forKey: noteOrder.removeFirst()) }

        // Switching notes is instant: no transition between pages.
        if editor.note !== note { editor.load(note) }
        refreshEmptyState()
        updateTitle()
        window?.makeFirstResponder(editor.textView)
        if let query, !query.isEmpty {
            let r = (editor.text as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            if r.location != NSNotFound {
                editor.textView.setSelectedRange(r)
                editor.textView.scrollRangeToVisible(r)
                editor.textView.showFindIndicator(for: r)
            }
        }
    }

    #if DEBUG
    func debugRename(_ name: String) { rename(to: name) }

    func debugSidebar(steps: [String], out: String?) {
        setSidebarVisible(true, remember: false)
        root.layoutSubtreeIfNeeded()
        guard let sidebar else { exit(1) }
        print("START\n" + sidebar.debugDump())
        func run(_ i: Int) {
            guard i < steps.count else {
                if let out, let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
            if steps[i] == "wait" {
                // Long enough for the file watcher's rescan to land.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    print("AFTER WAIT\n" + sidebar.debugDump())
                    run(i + 1)
                }
                return
            }
            sidebar.debugStep(steps[i])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                print("STEP \(steps[i])\n" + sidebar.debugDump())
                run(i + 1)
            }
        }
        run(0)
    }
    #endif

    private func rename(to name: String, quietly: Bool = false) {
        guard let url = note?.url, let workspace else { return }
        editor.saveNow()
        do {
            let newURL = try workspace.rename(url, to: name)
            if let n = noteCache.removeValue(forKey: url.standardizedFileURL) { noteCache[newURL.standardizedFileURL] = n }
            noteOrder = noteOrder.map { $0 == url.standardizedFileURL ? newURL.standardizedFileURL : $0 }
        } catch {
            NSLog("Indium rename failed: %@", String(describing: error))
            if !quietly, let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
        updateTitle()
    }

    // MARK: Sidebar

    private static let sidebarKey = "showSidebar"
    private static let sidebarInset: CGFloat = 8
    /// Narrower than this and the sidebar floats over the page instead of moving it.
    private static let minPageWidth: CGFloat = 440

    @objc func toggleFiles(_ sender: Any?) {
        setSidebarVisible(!sidebarVisible, animated: true)
        // From the keyboard, arrow keys go to the list; a click leaves you in the note.
        if sidebarVisible, NSApp.currentEvent?.type == .keyDown { sidebar?.focus() }
    }

    /// The sidebar docks on the window's left edge and stays while you work. It blurs
    /// in and out, and the page slides over to make room when the window is wide enough.
    private func setSidebarVisible(_ visible: Bool, animated: Bool = false, remember: Bool = true) {
        guard kind == .vault else { return }
        if visible, workspace == nil { return }
        if remember { UserDefaults.standard.set(visible, forKey: Self.sidebarKey) }
        guard visible != sidebarVisible else { return }
        sidebarVisible = visible
        titleBar.filesButton.isOn = visible
        if visible { installSidebar() }
        guard let glass = sidebarGlass, let sidebar else { return }
        // Settle its frame first, so only the fade and blur animate.
        root.layoutSubtreeIfNeeded()
        if !visible, sidebar.hasFocus, note != nil { window?.makeFirstResponder(editor.textView) }

        let inset = pageInset()
        guard animated, window?.isVisible == true else {
            glass.alphaValue = visible ? 1 : 0
            glass.isHidden = !visible
            applyPageInset(inset)
            return
        }
        glass.isHidden = false
        editor.textView.isAnimatingFrame = true
        blur(sidebar, from: visible ? 14 : 0, to: visible ? 0 : 14, duration: 0.3)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            context.allowsImplicitAnimation = true
            glass.animator().alphaValue = visible ? 1 : 0
            for c in pageLeading { c.animator().constant = inset }
            titleBar.setContentInset(inset, animated: true)
            root.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            // Toggled again before this finished: the newer animation cleans up.
            guard let self, self.sidebarVisible == visible else { return }
            self.editor.textView.isAnimatingFrame = false
            if !visible { glass.isHidden = true }
            sidebar.contentFilters = []
        })
    }

    private func installSidebar() {
        guard sidebar == nil else { return }
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: SidebarView.width, height: 480))
        view.workspace = workspace
        view.currentURL = note?.url
        view.onOpen = { [weak self] url in self?.open(url) }
        view.onDismiss = { [weak self] in
            guard let self, self.note != nil else { return }
            self.window?.makeFirstResponder(self.editor.textView)
        }
        view.onCreateNote = { [weak self] folder in self?.createNote(in: folder, renameIn: .sidebar) }
        let glass = Glass.make(cornerRadius: 16, content: view)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.alphaValue = 0
        glass.isHidden = true
        // Under the title bar's controls when they're on the page (full screen); over the page.
        if titleBar.superview === root {
            root.addSubview(glass, positioned: .below, relativeTo: titleBar)
        } else {
            root.addSubview(glass)
        }
        let inset = Self.sidebarInset
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            // Below the title bar row, so the window buttons and controls sit clear above it.
            glass.topAnchor.constraint(equalTo: root.topAnchor, constant: TitleBarView.height + 2),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            glass.widthAnchor.constraint(equalToConstant: SidebarView.width),
        ])
        sidebar = view
        sidebarGlass = glass
    }

    private func pageInset() -> CGFloat {
        let reserve = SidebarView.width + Self.sidebarInset
        guard sidebarVisible, root.bounds.width - reserve >= Self.minPageWidth else { return 0 }
        return reserve
    }

    private func applyPageInset(_ inset: CGFloat) {
        for c in pageLeading { c.constant = inset }
        titleBar.setContentInset(inset, animated: false)
    }

    /// Softens a view in or out of focus while it fades.
    private func blur(_ view: NSView, from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        filter.name = "blur"
        filter.setValue(to, forKey: kCIInputRadiusKey)
        view.contentFilters = [filter]
        let animation = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        view.layer?.add(animation, forKey: "blur")
    }

    // MARK: Quick open

    @objc func openQuickly(_ sender: Any?) {
        presentQuickOpen()
    }

    @objc func searchNotes(_ sender: Any?) {
        let selected = editor.textView.selectedRange()
        let query = selected.length > 0 && selected.length < 80 ? (editor.text as NSString).substring(with: selected) : ""
        presentQuickOpen(query: query)
    }

    private func presentQuickOpen(query: String = "") {
        guard let workspace else {
            AppDelegate.shared.openFolder(nil)
            return
        }
        if quickOpen == nil {
            let view = QuickOpenView()
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            view.onOpen = { [weak self] url, q in
                self?.dismissQuickOpen()
                self?.open(url, select: q)
            }
            view.onCreate = { [weak self] name in
                self?.dismissQuickOpen()
                self?.createNote(in: nil, name: name, renameIn: .none)
            }
            view.onDismiss = { [weak self] in self?.dismissQuickOpen() }
            quickOpen = view
        }
        quickOpen?.workspace = workspace
        quickOpen?.present(query: query)
        quickOpen?.animateIn()
    }

    private func dismissQuickOpen() {
        guard let view = quickOpen else { return }
        quickOpen = nil
        if note != nil { window?.makeFirstResponder(editor.textView) }
        view.animateOut { view.removeFromSuperview() }
    }

    // MARK: Note commands

    @objc func newNote(_ sender: Any?) {
        guard kind == .vault else {
            AppDelegate.shared.mainWindowController().newNote(sender)
            return
        }
        let folder = note?.url?.deletingLastPathComponent()
        createNote(in: folder)
    }

    enum RenameTarget { case none, titleBar, sidebar }

    private func createNote(in folder: URL?, name: String = "Untitled", renameIn target: RenameTarget = .titleBar) {
        guard let workspace else {
            AppDelegate.shared.openFolder(nil)
            return
        }
        do {
            let url = try workspace.createNote(in: folder ?? note?.url?.deletingLastPathComponent(), name: name)
            open(url)
            switch target {
            case .none: break
            case .titleBar: titleBar.beginRename()
            case .sidebar: sidebar?.beginRename(url, focusPage: true)
            }
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc func renameNote(_ sender: Any?) {
        titleBar.setChromeVisible(true)
        titleBar.beginRename()
    }

    @objc func revealInFinder(_ sender: Any?) {
        if let url = note?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func trashNote(_ sender: Any?) {
        guard let url = note?.url, let workspace else { return }
        editor.saveNow()
        editor.load(nil)
        noteCache.removeValue(forKey: url.standardizedFileURL)
        do { try workspace.trash(url) } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
        refreshEmptyState()
    }

    @objc func saveNote(_ sender: Any?) {
        if note?.isTemporary == true { saveTemporaryToVault(closeAfter: false) } else { editor.saveNow() }
    }

    // MARK: Formatting

    @objc func toggleBold(_ sender: Any?) { editor.toggleWrap("**", name: "Bold") }
    @objc func toggleItalic(_ sender: Any?) { editor.toggleWrap("*", name: "Italic") }
    @objc func toggleStrikethrough(_ sender: Any?) { editor.toggleWrap("~~", name: "Strikethrough") }
    @objc func toggleInlineCode(_ sender: Any?) { editor.toggleWrap("`", name: "Code") }
    @objc func toggleHighlight(_ sender: Any?) { editor.toggleWrap("==", name: "Highlight") }
    @objc func insertLink(_ sender: Any?) { editor.insertLink() }
    @objc func insertInlineMath(_ sender: Any?) { editor.insertMath(block: false) }
    @objc func insertDisplayMath(_ sender: Any?) { editor.insertMath(block: true) }
    @objc func setBody(_ sender: Any?) { editor.setHeading(0) }
    @objc func setHeading1(_ sender: Any?) { editor.setHeading(1) }
    @objc func setHeading2(_ sender: Any?) { editor.setHeading(2) }
    @objc func setHeading3(_ sender: Any?) { editor.setHeading(3) }


    @objc func insertImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.window?.makeFirstResponder(self.editor.textView)
            self.editor.insertImageFiles(panel.urls)
        }
    }

    // MARK: Export

    @objc func exportPDF(_ sender: Any?) {
        guard let note, let window else { return }
        editor.saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = note.title + ".pdf"
        panel.directoryURL = note.url?.deletingLastPathComponent()
        panel.canSelectHiddenExtension = true
        let accessory = PDFOptionsView(options: .saved)
        panel.accessoryView = accessory
        let text = editor.text
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let options = accessory.options
            options.save()
            let data = PDFExporter.makePDF(text: text, title: note.title, resolver: self.editor, options: options)
            do { try data.write(to: url, options: .atomic) } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func printNote(_ sender: Any?) {
        guard let note, let window,
              let op = PDFExporter.printOperation(text: editor.text, title: note.title, resolver: editor) else { return }
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasNote = note != nil
        switch item.action {
        case #selector(toggleFiles(_:)):
            item.title = sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return workspace != nil && kind == .vault
        case #selector(openQuickly(_:)), #selector(searchNotes(_:)):
            return workspace != nil
        case #selector(renameNote(_:)), #selector(trashNote(_:)):
            return hasNote && note?.isTemporary == false && kind != .file
        case #selector(revealInFinder(_:)):
            return hasNote && note?.isTemporary == false
        case #selector(setBody(_:)), #selector(setHeading1(_:)), #selector(setHeading2(_:)), #selector(setHeading3(_:)):
            let level = hasNote ? editor.currentHeadingLevel() : -1
            let tag = [#selector(setBody(_:)), #selector(setHeading1(_:)), #selector(setHeading2(_:)), #selector(setHeading3(_:))]
                .firstIndex(of: item.action!) ?? -2
            item.state = tag == level ? .on : .off
            return hasNote && editor.tableEditor == nil
        case #selector(insertDisplayMath(_:)), #selector(insertImage(_:)):
            // Block insertions have no place in a table cell.
            return hasNote && editor.tableEditor == nil
        case #selector(newNote(_:)):
            return workspace != nil
        case #selector(saveNote(_:)):
            item.title = note?.isTemporary == true ? "Save to Vault…" : "Save"
            return hasNote
        default:
            return hasNote
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if kind == .temporary, !editor.isEmpty {
            confirmTemporaryClose()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        editor.saveNow()
        if kind != .vault { AppDelegate.shared.windowClosed(self) }
    }

    func windowDidResignKey(_ notification: Notification) {
        editor.saveNow()
    }

    private func confirmTemporaryClose() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Keep this temporary note?"
        alert.informativeText = "Temporary notes live only in memory. Save it to your vault to keep it."
        alert.addButton(withTitle: "Save to Vault…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                DispatchQueue.main.async { self.saveTemporaryToVault(closeAfter: true) }
            case .alertSecondButtonReturn:
                self.discardAndClose()
            default:
                break
            }
        }
    }

    func discardAndClose() {
        editor.load(nil)
        window?.close()
    }

    /// Writes a temporary note (and any pasted images) to a location the user picks.
    func saveTemporaryToVault(closeAfter: Bool) {
        guard let note, note.isTemporary, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("net.daringfireball.markdown") ?? .plainText]
        panel.nameFieldStringValue = suggestedName() + ".md"
        panel.directoryURL = workspace?.root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Save this temporary note as a Markdown file."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                var text = self.editor.text
                let ws = self.workspace.flatMap { $0.contains(url) ? $0 : nil }
                let root = ws?.root ?? url.deletingLastPathComponent()
                let folder = ws?.attachmentFolder(for: url) ?? root.appendingPathComponent("attachments")
                for (path, data) in note.memoryImages {
                    let name = (path as NSString).lastPathComponent
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = Workspace.uniqueURL(in: folder, base: (name as NSString).deletingPathExtension, ext: (name as NSString).pathExtension)
                    try data.write(to: target, options: .atomic)
                    let newRef = Workspace.markdownPath(for: target, from: url, root: root)
                    let oldRef = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                    text = text.replacingOccurrences(of: "](\(oldRef))", with: "](\(newRef))")
                }
                try note.becomePermanent(at: url, text: text)
                if closeAfter {
                    self.editor.load(nil)
                    window.close()
                } else {
                    window.close()
                }
                if let ws, ws.contains(url) {
                    ws.rescanNow()
                    AppDelegate.shared.openInMainWindow(url)
                }
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func suggestedName() -> String {
        let firstLine = editor.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        var cleaned = firstLine.replacingOccurrences(of: #"^[#>\-*\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\$[^$]*\$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`$\[\]]"#, with: "", options: .regularExpression)
        if let colon = cleaned.firstIndex(where: { ":.?!".contains($0) }) { cleaned = String(cleaned[..<colon]) }
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if cleaned.count > 60 { cleaned = cleaned.prefix(60).split(separator: " ").dropLast().joined(separator: " ") }
        let name = Workspace.sanitize(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ,;-")))
        return name.isEmpty ? "Untitled" : name
    }
}

/// Save panel accessory: appearance, paper and page numbers.
private final class PDFOptionsView: NSView {
    private let appearancePopUp = NSPopUpButton()
    private let paper = NSPopUpButton()
    private let numbers = NSButton(checkboxWithTitle: "Page numbers", target: nil, action: nil)

    init(options: PDFOptions) {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 48))
        appearancePopUp.addItems(withTitles: ["Light", "Dark", "Match Editor"])
        appearancePopUp.selectItem(at: PDFOptions.Appearance.allCases.firstIndex(of: options.appearance) ?? 0)
        paper.addItems(withTitles: ["US Letter", "A4"])
        paper.selectItem(at: options.paper == .a4 ? 1 : 0)
        numbers.state = options.pageNumbers ? .on : .off
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.textColor = .secondaryLabelColor
            return l
        }
        let row = NSStackView(views: [label("Appearance"), appearancePopUp, label("Paper"), paper, numbers])
        row.spacing = 8
        row.setCustomSpacing(18, after: appearancePopUp)
        row.setCustomSpacing(18, after: paper)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var options: PDFOptions {
        PDFOptions(appearance: PDFOptions.Appearance.allCases[max(0, appearancePopUp.indexOfSelectedItem)],
                   paper: paper.indexOfSelectedItem == 1 ? .a4 : .letter,
                   pageNumbers: numbers.state == .on)
    }
}

private final class RootView: NSView {
    override var isFlipped: Bool { true }
}
