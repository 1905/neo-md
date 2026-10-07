import AppKit
import MDCore

/// Owns the content area (above) and the status bar (below).
/// Task 3 shows the Render tab only. Task 7 adds Raw and Split, Task 11 the outline.
@MainActor
final class ContentController: NSViewController {
    let document: MarkdownDocument
    let preview = PreviewWebView()
    let statusBar = StatusBar()
    /// Holds the view of the current tab.
    let contentContainer = NSView()

    private(set) var currentTab: DocTab = .render
    /// The last successful render. Task 11 reads `outline` from it.
    private(set) var lastResult: RenderResult?

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
        show(preview)
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange),
                                               name: MarkdownDocument.textDidChange, object: document)
        render()
    }

    // MARK: - Tabs

    /// Switches the content area to `tab`. Task 3 supports `.render` only; Task 7 adds `.raw` and `.split`.
    func select(_ tab: DocTab) {
        guard tab == .render else { return }
        currentTab = tab
        show(preview)
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

    // MARK: - Rendering

    @objc private func textDidChange(_ note: Notification) {
        render()
    }

    /// Renders `document.text` into the preview now. Also used by `renderNow:` (⌘R).
    func render() {
        preview.documentFolder = document.fileURL?.deletingLastPathComponent()
        if let result = MarkdownRenderer.render(document.text) {
            lastResult = result
            preview.update(html: result.html)
        } else {
            preview.showError("Could not render this file.")
        }
        updateStatus()
    }

    func updateStatus() {
        statusBar.info = StatusBar.renderInfo(for: document.text)
    }
}
