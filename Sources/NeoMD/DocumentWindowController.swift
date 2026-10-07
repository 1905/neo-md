import AppKit

/// One document window: unified toolbar + `ContentController`.
/// Menu actions reach it through the responder chain. Stubs for later tasks are marked.
@MainActor
final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    enum ItemID {
        static let outline = NSToolbarItem.Identifier("neo-md.outline")
        static let tabs = NSToolbarItem.Identifier("neo-md.tabs")
        static let vim = NSToolbarItem.Identifier("neo-md.vim")
        static let find = NSToolbarItem.Identifier("neo-md.find")
    }

    let contentController: ContentController
    let tabControl = NSSegmentedControl(labels: ["Render", "Raw", "Split"], trackingMode: .selectOne,
                                        target: nil, action: #selector(selectTab(_:)))
    let vimChip = ChipButton(title: "VIM")
    private(set) var outlineItem: NSToolbarItem?
    private(set) var findItem: NSToolbarItem?

    init(document: MarkdownDocument) {
        contentController = ContentController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.minSize = NSSize(width: 520, height: 360)
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.contentViewController = contentController
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        super.init(window: window)

        tabControl.target = self

        let toolbar = NSToolbar(identifier: "neo-md.document")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [ItemID.tabs]
        window.toolbar = toolbar

        window.setFrameAutosaveName("neo-md.document")
        shouldCascadeWindows = true

        // New windows start in the default tab.
        contentController.select(Settings.shared.defaultTab)
        tabControl.selectedSegment = contentController.currentTab.rawValue
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Title

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        guard let folder = document?.fileURL?.deletingLastPathComponent() else {
            window?.subtitle = ""
            return
        }
        window?.subtitle = (folder.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.outline, .flexibleSpace, ItemID.tabs, .flexibleSpace, ItemID.vim, ItemID.find]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case ItemID.outline:
            item.label = "Outline"
            item.toolTip = "Show or hide the outline"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Outline")
            item.action = #selector(toggleOutline(_:))
            item.target = self
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = false   // Task 11 wires the outline.
            outlineItem = item
        case ItemID.tabs:
            item.label = "View"
            item.view = tabControl
        case ItemID.vim:
            item.label = "Vim"
            item.toolTip = "Vim key bindings"
            vimChip.isEnabled = false   // Task 10 wires the chip.
            item.view = vimChip
        case ItemID.find:
            item.label = "Find"
            item.toolTip = "Find"
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
            item.action = #selector(showFind(_:))
            item.target = self
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = false   // Task 12 wires find.
            findItem = item
        default:
            return nil
        }
        return item
    }

    // MARK: - Actions (responder chain)

    /// ⌘1/⌘2/⌘3 (menu tag) and the segmented control (selected segment).
    @objc func selectTab(_ sender: Any?) {
        let raw: Int
        if let control = sender as? NSSegmentedControl {
            raw = control.selectedSegment
        } else if let item = sender as? NSMenuItem {
            raw = item.tag
        } else {
            return
        }
        guard let tab = DocTab(rawValue: raw) else { return }
        contentController.select(tab)
        tabControl.selectedSegment = contentController.currentTab.rawValue
    }

    /// ⇧⌘O and the `sidebar.left` button. Stub: Task 11.
    @objc func toggleOutline(_ sender: Any?) {}

    /// ⌘R: render the current text now.
    @objc func renderNow(_ sender: Any?) {
        contentController.render()
    }

    /// ⌘F and the magnifier button. Stub: Task 12.
    @objc func showFind(_ sender: Any?) {}

    /// ⌘, opens the settings popover under the `VIM` chip. Stub: Task 10.
    @objc func showSettings(_ sender: Any?) {}

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectTab(_:)):
            menuItem.state = menuItem.tag == contentController.currentTab.rawValue ? .on : .off
            return DocTab(rawValue: menuItem.tag) != nil
        case #selector(renderNow(_:)):
            return true
        case #selector(toggleOutline(_:)), #selector(showFind(_:)), #selector(showSettings(_:)):
            return false   // Not wired yet (Tasks 10–12).
        default:
            return true
        }
    }
}

/// Toolbar chip: small bordered text button (`VIM`). Task 10 adds the on/off colours.
@MainActor
final class ChipButton: NSButton {
    var borderColor: NSColor = .separatorColor { didSet { updateBorder() } }

    convenience init(title: String) {
        self.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        contentTintColor = .tertiaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        updateBorder()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 16, height: max(size.height + 6, 22))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = borderColor.cgColor
        }
    }
}
