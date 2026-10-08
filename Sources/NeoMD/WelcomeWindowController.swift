import AppKit

/// The window shown when no document is open (mockup frame 13): a drop zone and up to 8 recent files.
@MainActor
final class WelcomeWindowController: NSWindowController {
    static let maxRecent = 8
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    private let recentStack = NSStackView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "neo-md"
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let root = BackgroundView()
        let drop = DropZone()
        drop.translatesAutoresizingMaskIntoConstraints = false

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 0
        recentStack.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [drop, recentStack])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 28
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            drop.widthAnchor.constraint(equalToConstant: 420),
            drop.heightAnchor.constraint(equalToConstant: 160),
            recentStack.widthAnchor.constraint(equalToConstant: 420),
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        window.contentView = root
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func showWindow(_ sender: Any?) {
        reloadRecent()
        super.showWindow(sender)
    }

    private func reloadRecent() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = NSDocumentController.shared.recentDocumentURLs.prefix(Self.maxRecent)
        for url in urls {
            let row = RecentRow(url: url)
            row.translatesAutoresizingMaskIntoConstraints = false
            recentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
        }
        recentStack.isHidden = urls.isEmpty
    }

    /// Opens each URL as a document. Errors show as an alert.
    static func open(_ urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
}

/// Plain view with the text background colour (white in light mode, like the mockup).
@MainActor
private final class BackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}

/// Dashed rounded box. Click → Open panel. Drop `.md` / `.markdown` files → open them.
@MainActor
private final class DropZone: NSView {
    private var isDragTarget = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])

        let title = NSTextField(labelWithString: "Open a Markdown file")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        let hint = NSTextField(labelWithString: "Drop it here or press ⌘O")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 14, yRadius: 14)
        path.lineWidth = 1.5
        if isDragTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.separatorColor.setStroke()
        }
        path.stroke()
    }

    /// Clicks on the labels count as clicks on this view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    /// Needed so `mouseUp` reaches this view.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSDocumentController.shared.openDocument(nil)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Drop

    private func markdownURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { WelcomeWindowController.markdownExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !markdownURLs(sender).isEmpty
        isDragTarget = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTarget = false
        let urls = markdownURLs(sender)
        guard !urls.isEmpty else { return false }
        WelcomeWindowController.open(urls)
        return true
    }
}

/// One recent file: name left, parent folder (with `~`) right, line on top. Click → open.
@MainActor
private final class RecentRow: NSView {
    private let url: URL
    private let topLine = NSBox()

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 12.5)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let folderPath = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let folder = NSTextField(labelWithString: folderPath)
        folder.font = .systemFont(ofSize: 12.5)
        folder.textColor = .tertiaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        folder.alignment = .right
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        topLine.boxType = .separator

        for view in [topLine, name, folder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            folder.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 16),
            folder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            folder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = url.path
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks on the labels count as clicks on this view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    /// Needed so `mouseUp` reaches this view.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        WelcomeWindowController.open([url])
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
