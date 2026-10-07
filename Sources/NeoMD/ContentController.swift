import AppKit
import MDCore

/// Owns the content area (above) and the status bar (below).
/// Render = `preview`. Raw = `editor`. Split = `editor` left + `splitPreview` right.
/// One `EditorPane` moves between Raw and Split, so the cursor and undo stack survive a tab switch.
/// Task 11 adds the outline to the Render tab.
@MainActor
final class ContentController: NSViewController {
    /// Above this size (UTF-8 bytes) text changes do not re-render. ⌘R still renders once.
    static let livePreviewLimit = 5 * 1024 * 1024
    static let renderDebounce: TimeInterval = 0.150
    static let scrollSyncInterval: TimeInterval = 0.050

    let document: MarkdownDocument
    let preview = PreviewWebView()
    let statusBar = StatusBar()
    /// Holds the view of the current tab.
    let contentContainer = NSView()

    private(set) var currentTab: DocTab = .render
    /// The last successful render. Task 11 reads `outline` from it.
    private(set) var lastResult: RenderResult?

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
        let root = NSView()
        for view in [contentContainer, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        isLarge = document.text.utf8.count > Self.livePreviewLimit
        show(preview)
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange),
                                               name: MarkdownDocument.textDidChange, object: document)
        render()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionSplitIfNeeded()
    }

    // MARK: - Tabs

    func select(_ tab: DocTab) {
        currentTab = tab
        switch tab {
        case .render:
            show(preview)
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

    // MARK: - Rendering

    @objc private func textDidChange(_ note: Notification) {
        textVersion += 1
        isLarge = document.text.utf8.count > Self.livePreviewLimit
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
            lastResult = result
            renderedHTML = result.html
        } else {
            renderedHTML = nil
        }
        renderedVersion = textVersion
    }

    private func pushToVisiblePreview() {
        guard let target = visiblePreview, renderedVersion >= 0 else { return }
        let shown = target === preview ? previewVersion : splitPreviewVersion
        guard shown != renderedVersion else { return }
        target.documentFolder = document.fileURL?.deletingLastPathComponent()
        if let html = renderedHTML {
            target.update(html: html)
        } else {
            target.showError("Could not render this file.")
        }
        if target === preview { previewVersion = renderedVersion } else { splitPreviewVersion = renderedVersion }
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
            let location = min(textView.selectedRange().location, text.length)
            let line = textView.lineNumber(at: location)
            let starts = textView.lineStarts
            let lineStart = line - 1 < starts.count ? starts[line - 1] : 0
            let column = StatusBar.column(in: text, lineStart: lineStart, location: location)
            info = StatusBar.editorInfo(line: line, column: column, lineEnding: document.lineEnding)
        }
        statusBar.info = isLarge ? "Preview paused · \(info)" : info
    }
}
