import AppKit

/// Scroll view + `MarkdownTextView` + line-number ruler for one document.
///
/// It has no state tied to its superview, so one instance can move between the
/// Raw and Split tabs and keep its cursor and undo stack.
/// Edits go to `document.text`, then `MarkdownDocument.textDidChange` is posted.
/// When the document text changes elsewhere
/// (read, revert), the pane reloads it.
final class EditorPane: NSView, NSTextViewDelegate {
    let document: MarkdownDocument
    let scrollView: NSScrollView
    let textView: MarkdownTextView
    /// Vim key mode for `textView`. It follows `Settings.keyBindings` by itself.
    let vim: VimController

    /// True while this pane posts `textDidChange`, so it does not reload its own edit.
    private var isPushingText = false

    init(document: MarkdownDocument) {
        self.document = document
        let textView = MarkdownTextView.make()
        let scrollView = NSScrollView()
        self.textView = textView
        self.scrollView = scrollView
        vim = VimController(textView: textView, document: document)
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUp() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.delegate = self
        textView.vimController = vim
        textView.vimStateDidChange()
        scrollView.documentView = textView

        scrollView.verticalRulerView = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        reloadFromDocument()
        NotificationCenter.default.addObserver(self, selector: #selector(documentTextDidChange),
                                               name: MarkdownDocument.textDidChange, object: document)
        NotificationCenter.default.addObserver(self, selector: #selector(documentDidSave),
                                               name: MarkdownDocument.didSave, object: document)
    }

    /// Typing after a save starts a new undo step, so one undo does not cross the save point.
    @objc private func documentDidSave(_ note: Notification) {
        textView.breakUndoCoalescing()
    }

    /// Replaces the editor text with `document.text`. Keeps the cursor if it still fits.
    /// Does not register undo.
    func reloadFromDocument() {
        let location = textView.selectedRange().location
        textView.string = document.text
        let length = (document.text as NSString).length
        textView.setSelectedRange(NSRange(location: min(location, length), length: 0))
    }

    @objc private func documentTextDidChange(_ note: Notification) {
        guard !isPushingText else { return }
        reloadFromDocument()
    }

    // MARK: - NSTextViewDelegate

    /// Edits register on the document's undo manager, so "Edited" follows undo and redo.
    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }

    func textDidChange(_ notification: Notification) {
        isPushingText = true
        defer { isPushingText = false }
        document.text = textView.string
        NotificationCenter.default.post(name: MarkdownDocument.textDidChange, object: document)
    }
}
