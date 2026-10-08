import AppKit
import MDCore

/// Owns the disk-change banner (top, hidden by default), the content area and the status bar (bottom).
/// Render = `outline` left (hideable) + `findBar` over `preview` right. Raw = `editor`. Split = `editor` left + `splitPreview` right.
/// One `EditorPane` moves between Raw and Split, so the cursor and undo stack survive a tab switch.
@MainActor
final class ContentController: NSViewController {
    /// Above this size (UTF-8 bytes) text changes do not re-render. ⌘R still renders once.
    static let livePreviewLimit = 5 * 1024 * 1024
    static let renderDebounce: TimeInterval = 0.150
    static let scrollSyncInterval: TimeInterval = 0.050

    let document: MarkdownDocument
    let preview = PreviewWebView()
    /// Headings of the last successful render, Render tab only. Shown while `Settings.shared.outlineVisible`.
    let outline = OutlineSidebar()
    let statusBar = StatusBar()
    /// Holds the view of the current tab.
    let contentContainer = NSView()
    /// "Changed on disk." / "Deleted on disk." strip above the content (frame 12).
    let banner = DiskChangeBanner()
    /// Render tab find bar. Height 0 (and hidden) until ⌘F.
    let findBar = FindBar()
    private var findBarHeight: NSLayoutConstraint!
    private var contentTopToRoot: NSLayoutConstraint!
    private var contentTopToBanner: NSLayoutConstraint!
    /// Editor scroll offset saved by `willRevert`, restored by `didRevert`.
    private var savedEditorOrigin: NSPoint?

    private(set) var currentTab: DocTab = .render

    private(set) lazy var editor = EditorPane(document: document)
    private lazy var splitPreview: PreviewWebView = {
        let view = PreviewWebView()
        view.isSplit = true
        return view
    }()
    private lazy var splitView: NSSplitView = {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        return split
    }()
    private var splitNeedsInitialPosition = true
    /// The Render tab: `outline` (220 pt) | 1 pt line | `previewColumn`. Plain constraints, no split view:
    /// hiding the outline hides it and the line and pins `previewColumn` to the left edge.
    private let outlineDivider: NSBox = {
        let line = NSBox()
        line.boxType = .separator
        return line
    }()
    private var previewAfterOutline: NSLayoutConstraint!
    private var previewAtLeadingEdge: NSLayoutConstraint!
    private lazy var renderPane: NSView = {
        let pane = NSView()
        for view in [outline, outlineDivider, previewColumn] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        previewAfterOutline = previewColumn.leadingAnchor.constraint(equalTo: outlineDivider.trailingAnchor)
        previewAtLeadingEdge = previewColumn.leadingAnchor.constraint(equalTo: pane.leadingAnchor)
        NSLayoutConstraint.activate([
            outline.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            outline.topAnchor.constraint(equalTo: pane.topAnchor),
            outline.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            outline.widthAnchor.constraint(equalToConstant: OutlineSidebar.width),
            outlineDivider.leadingAnchor.constraint(equalTo: outline.trailingAnchor),
            outlineDivider.topAnchor.constraint(equalTo: pane.topAnchor),
            outlineDivider.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            outlineDivider.widthAnchor.constraint(equalToConstant: 1),
            previewColumn.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            previewColumn.topAnchor.constraint(equalTo: pane.topAnchor),
            previewColumn.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        applyOutlineVisibility()
        return pane
    }()
    /// `findBar` on top of `preview`. The bar slides in by animating its height from 0 to 32 pt.
    private lazy var previewColumn: NSView = {
        let column = NSView()
        for view in [findBar, preview] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(view)
        }
        findBar.isHidden = true
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            findBar.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            findBar.topAnchor.constraint(equalTo: column.topAnchor),
            findBarHeight,
            preview.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            preview.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            preview.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        return column
    }()

    /// Bumped on every text change. A preview is current when its version matches.
    private var textVersion = 0
    /// Text version of `renderedHTML`; -1 = nothing rendered yet.
    private var renderedVersion = -1
    /// HTML of the last render; nil = cmark failed.
    private var renderedHTML: String?
    private var previewVersion = -1
    private var splitPreviewVersion = -1
    private var isLarge = false
    private var pendingRender: DispatchWorkItem?

    private var lastScrollSync = Date.distantPast
    private var pendingScrollSync: DispatchWorkItem?

    init(document: MarkdownDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = FindKeyView()
        root.onFindAgain = { [weak self] backwards in self?.findAgain(backwards: backwards) ?? false }
        for view in [banner, contentContainer, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        banner.isHidden = true
        contentTopToRoot = contentContainer.topAnchor.constraint(equalTo: root.topAnchor)
        contentTopToBanner = contentContainer.topAnchor.constraint(equalTo: banner.bottomAnchor)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            banner.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentTopToRoot,
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        isLarge = Self.exceedsLiveLimit(document.text)
        show(renderPane)
        outline.onSelect = { [weak self] item in self?.preview.scrollToLine(item.line) }
        preview.onVisibleLine = { [weak self] line in self?.outline.highlight(line: line) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(settingsDidChange),
                           name: Settings.didChange, object: nil)
        center.addObserver(self, selector: #selector(textDidChange),
                           name: MarkdownDocument.textDidChange, object: document)
        center.addObserver(self, selector: #selector(diskDidChange),
                           name: MarkdownDocument.diskDidChange, object: document)
        center.addObserver(self, selector: #selector(willRevert),
                           name: MarkdownDocument.willRevert, object: document)
        center.addObserver(self, selector: #selector(didRevert),
                           name: MarkdownDocument.didRevert, object: document)
        center.addObserver(self, selector: #selector(documentDidSave),
                           name: MarkdownDocument.didSave, object: document)
        center.addObserver(self, selector: #selector(documentDidMove),
                           name: MarkdownDocument.fileURLDidChange, object: document)
        banner.onKeepMine = { [weak self] in self?.setBannerVisible(false) }
        banner.onReload = { [weak self] in self?.reloadFromDisk() }
        findBar.onFind = { [weak self] string, backwards in self?.findInPreview(string, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        render()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionSplitIfNeeded()
    }

    // MARK: - Outline

    @objc private func settingsDidChange(_ note: Notification) {
        applyOutlineVisibility()
    }

    /// Shows or hides the outline and its line. Hidden: `previewColumn` takes the full width.
    private func applyOutlineVisibility() {
        let visible = Settings.shared.outlineVisible
        let leading: NSLayoutConstraint = visible ? previewAfterOutline : previewAtLeadingEdge
        guard !leading.isActive else { return }
        outline.isHidden = !visible
        outlineDivider.isHidden = !visible
        // Deactivate the other one first, so the two leading constraints are never active together.
        (visible ? previewAtLeadingEdge : previewAfterOutline).isActive = false
        leading.isActive = true
    }

    // MARK: - Tabs

    func select(_ tab: DocTab) {
        currentTab = tab
        switch tab {
        case .render:
            show(renderPane)
        case .raw:
            show(editor)
        case .split:
            if editor.superview !== splitView {
                editor.translatesAutoresizingMaskIntoConstraints = true
                splitView.insertArrangedSubview(editor, at: 0)
            }
            if splitPreview.superview !== splitView {
                splitView.addArrangedSubview(splitPreview)
            }
            show(splitView)
            positionSplitIfNeeded()
        }
        if tab != .render {
            observeEditor()
            view.window?.makeFirstResponder(editor.textView)
        }
        refreshVisiblePreview()
        if tab == .split { syncScroll() }
        updateStatus()
    }

    private func show(_ child: NSView) {
        guard child.superview !== contentContainer else { return }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        child.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            child.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    /// 50/50 the first time the split view has a real width.
    private func positionSplitIfNeeded() {
        guard splitNeedsInitialPosition, currentTab == .split else { return }
        contentContainer.layoutSubtreeIfNeeded()
        let width = splitView.bounds.width
        guard width > 0 else { return }
        splitNeedsInitialPosition = false
        splitView.setPosition((width - splitView.dividerThickness) / 2, ofDividerAt: 0)
    }

    private var observingEditor = false

    /// Selection changes drive Ln/Col. Clip-view bounds changes drive scroll sync. Set up once.
    private func observeEditor() {
        guard !observingEditor else { return }
        observingEditor = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(selectionDidChange),
                           name: NSTextView.didChangeSelectionNotification, object: editor.textView)
        let clip = editor.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(editorDidScroll),
                           name: NSView.boundsDidChangeNotification, object: clip)
    }

    /// The preview shown by the current tab, if any.
    private var visiblePreview: PreviewWebView? {
        switch currentTab {
        case .render: return preview
        case .raw: return nil
        case .split: return splitPreview
        }
    }

    // MARK: - Find

    /// ⌘F and the toolbar button. Render: slides in `findBar`. Raw / Split: the text view's standard find bar.
    func showFind() {
        if currentTab == .render {
            showFindBar()
        } else {
            view.window?.makeFirstResponder(editor.textView)
            editor.textView.performFindPanelAction(Self.findPanelItem(.showFindPanel))
        }
    }

    private func showFindBar() {
        if findBar.isHidden {
            findBar.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                findBarHeight.animator().constant = FindBar.height
                previewColumn.layoutSubtreeIfNeeded()
            }
        }
        view.window?.makeFirstResponder(findBar.searchField)
        findBar.searchField.selectText(nil)
    }

    private func hideFindBar() {
        guard !findBar.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            findBarHeight.animator().constant = 0
            previewColumn.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.findBarHeight.constant == 0 else { return }
                self.findBar.isHidden = true
            }
        })
        preview.focusPage()
    }

    private func findInPreview(_ string: String, backwards: Bool) {
        preview.find(string, backwards: backwards) { [weak self] found in
            if !found { self?.findBar.showNoMatch() }
        }
    }

    /// ⌘G / ⇧⌘G in Raw and Split (the main menu has no Find Next item). Render handles it in `FindBar`.
    private func findAgain(backwards: Bool) -> Bool {
        guard currentTab != .render, observingEditor else { return false }
        editor.textView.performFindPanelAction(Self.findPanelItem(backwards ? .previous : .next))
        return true
    }

    /// `performFindPanelAction(_:)` reads the action from the sender's `tag`.
    private static func findPanelItem(_ action: NSFindPanelAction) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        return item
    }

    /// Escape with the focus in the page: the web view passes unused keys up the responder chain to here.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, currentTab == .render, !findBar.isHidden {
            hideFindBar()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Rendering

    /// `text.utf8.count > livePreviewLimit`, without the UTF-8 count for most texts:
    /// one UTF-16 unit is 1 to 3 UTF-8 bytes.
    private static func exceedsLiveLimit(_ text: String) -> Bool {
        let units = text.utf16.count
        if units > livePreviewLimit { return true }
        if units * 3 <= livePreviewLimit { return false }
        return text.utf8.count > livePreviewLimit
    }

    @objc private func textDidChange(_ note: Notification) {
        textVersion += 1
        isLarge = Self.exceedsLiveLimit(document.text)
        pendingRender?.cancel()
        pendingRender = nil
        if !isLarge && visiblePreview != nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingRender = nil
                    self.refreshVisiblePreview()
                }
            }
            pendingRender = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.renderDebounce, execute: work)
        }
        updateStatus()
    }

    /// Brings the visible preview up to date. Above the size limit it only shows the last render.
    private func refreshVisiblePreview() {
        guard visiblePreview != nil else { return }
        if renderedVersion != textVersion && !isLarge {
            renderText()
        }
        pushToVisiblePreview()
    }

    /// Renders `document.text` into the visible preview now, whatever its size. Used by `renderNow:` (⌘R).
    func render() {
        pendingRender?.cancel()
        pendingRender = nil
        renderText()
        pushToVisiblePreview()
        updateStatus()
    }

    private func renderText() {
        if let result = MarkdownRenderer.render(document.text) {
            renderedHTML = result.html
            outline.items = result.outline
        } else {
            renderedHTML = nil
        }
        renderedVersion = textVersion
    }

    private func pushToVisiblePreview() {
        guard let target = visiblePreview, renderedVersion >= 0 else { return }
        // Before the version guard: the file may have moved while the text stayed the same.
        target.documentFolder = documentFolder
        let shown = target === preview ? previewVersion : splitPreviewVersion
        guard shown != renderedVersion else { return }
        if let html = renderedHTML {
            target.update(html: html)
        } else {
            target.showError("Could not render this file.")
        }
        if target === preview { previewVersion = renderedVersion } else { splitPreviewVersion = renderedVersion }
    }

    private var documentFolder: URL? { document.folderURL }

    /// The file moved or was saved under a new name: relative links and images must
    /// resolve against the new folder, so both previews get it and a fresh push.
    /// The Split preview is lazy; it gets the folder on its next push.
    @objc private func documentDidMove(_ note: Notification) {
        preview.documentFolder = documentFolder
        previewVersion = -1
        splitPreviewVersion = -1
        pushToVisiblePreview()
    }

    // MARK: - Scroll sync (Split only, editor → preview)

    @objc private func editorDidScroll(_ note: Notification) {
        guard currentTab == .split else { return }
        let elapsed = Date().timeIntervalSince(lastScrollSync)
        if elapsed >= Self.scrollSyncInterval {
            pendingScrollSync?.cancel()
            pendingScrollSync = nil
            syncScroll()
        } else if pendingScrollSync == nil {
            // Trailing call, so the final position always reaches the preview.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingScrollSync = nil
                    if self.currentTab == .split { self.syncScroll() }
                }
            }
            pendingScrollSync = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.scrollSyncInterval - elapsed), execute: work)
        }
    }

    private func syncScroll() {
        lastScrollSync = Date()
        splitPreview.scrollToLine(topVisibleLine())
    }

    /// 1-based logical line of the character at the top-left of the visible editor area.
    private func topVisibleLine() -> Int {
        let textView = editor.textView
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return 1 }
        let origin = textView.textContainerOrigin
        let point = NSPoint(x: 0, y: max(0, textView.visibleRect.minY - origin.y))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return textView.lineNumber(at: min(index, storage.length))
    }

    // MARK: - Disk changes

    @objc private func diskDidChange(_ note: Notification) {
        let deleted = note.userInfo?[MarkdownDocument.deletedKey] as? Bool ?? false
        banner.kind = deleted ? .deleted : .changed
        setBannerVisible(true)
    }

    private func setBannerVisible(_ visible: Bool) {
        guard banner.isHidden == visible else { return }
        banner.isHidden = !visible
        contentTopToRoot.isActive = !visible
        contentTopToBanner.isActive = visible
    }

    /// [Reload]: unsaved edits are lost.
    private func reloadFromDisk() {
        setBannerVisible(false)
        document.revertToDisk()
    }

    /// After ⌘S the disk holds this window's text again.
    @objc private func documentDidSave(_ note: Notification) {
        setBannerVisible(false)
    }

    /// The preview keeps its own scroll (`update(html:)`). The editor reloads its text, so save its offset.
    /// `observingEditor` is true once the editor exists; do not create it just for this.
    @objc private func willRevert(_ note: Notification) {
        savedEditorOrigin = observingEditor ? editor.scrollView.contentView.bounds.origin : nil
    }

    @objc private func didRevert(_ note: Notification) {
        setBannerVisible(false)
        guard let origin = savedEditorOrigin else { return }
        savedEditorOrigin = nil
        restoreEditorOrigin(origin)
        // The text view may finish its layout later in this run loop pass; apply once more after it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.restoreEditorOrigin(origin) }
        }
    }

    private func restoreEditorOrigin(_ origin: NSPoint) {
        let textView = editor.textView
        let clip = editor.scrollView.contentView
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            let target = NSRect(x: 0, y: origin.y, width: clip.bounds.width, height: clip.bounds.height)
            layoutManager.ensureLayout(forBoundingRect: target, in: container)
        }
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maxY)))
        editor.scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Status

    @objc private func selectionDidChange(_ note: Notification) {
        if currentTab != .render { updateStatus() }
    }

    func updateStatus() {
        let info: String
        if currentTab == .render {
            info = StatusBar.renderInfo(for: document.text)
        } else {
            let textView = editor.textView
            let text = textView.string as NSString
            // Vim visual modes: the moving end (head), not the selection start.
            let location = min(editor.vim.visualCursor ?? textView.selectedRange().location, text.length)
            let line = textView.lineNumber(at: location)
            let column = StatusBar.column(in: text, lineStart: textView.lineStart(ofLine: line), location: location)
            info = StatusBar.editorInfo(line: line, column: column, lineEnding: document.lineEnding)
        }
        statusBar.info = isLarge ? "Preview paused · \(info)" : info
    }
}

/// Root view of `ContentController`. Catches ⌘G / ⇧⌘G before the main menu sees them.
@MainActor
private final class FindKeyView: NSView {
    /// Returns true when the key was used.
    var onFindAgain: ((Bool) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard FindBar.isFindAgain(event) else { return false }
        return onFindAgain?(event.modifierFlags.contains(.shift)) ?? false
    }
}
