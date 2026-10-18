import AppKit

/// One document window: unified toolbar + `ContentController`.
/// Menu actions reach it through the responder chain.
@MainActor
final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    enum ItemID {
        static let outline = NSToolbarItem.Identifier("neo-md.outline")
        static let tabs = NSToolbarItem.Identifier("neo-md.tabs")
        static let find = NSToolbarItem.Identifier("neo-md.find")
    }

    let contentController: ContentController
    let tabControl = NSSegmentedControl(labels: ["Render", "Raw", "Split"], trackingMode: .selectOne,
                                        target: nil, action: #selector(selectTab(_:)))
    private(set) var outlineItem: NSToolbarItem?

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

        // Toolbars with the same identifier sync their items across windows. The outline item
        // depends on this window's tab, so every window gets its own identifier.
        let toolbar = NSToolbar(identifier: "neo-md.document.\(UUID().uuidString)")
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

        updateModeSlot()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: Settings.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Title

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        updateSubtitle(edited: (document as? NSDocument)?.isDocumentEdited ?? false)
    }

    /// NSDocument calls this on its window controllers whenever its edited state changes
    /// (edits, undo back to the saved state, save, revert).
    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        updateSubtitle(edited: dirtyFlag)
    }

    /// Subtitle = folder path, prefixed with "Edited · " while there are unsaved changes.
    /// With a subtitle, the macOS title bar shows only the close-button dot for unsaved changes.
    private func updateSubtitle(edited: Bool) {
        var parts: [String] = []
        if edited { parts.append("Edited") }
        if let folder = (document as? MarkdownDocument)?.folderURL {
            parts.append((folder.path as NSString).abbreviatingWithTildeInPath)
        }
        window?.subtitle = parts.joined(separator: " · ")
    }

    // MARK: - Vim

    @objc private func settingsDidChange(_ note: Notification) {
        updateModeSlot()
    }

    /// Status bar badge: shown in Raw and Split while Vim is on. The editor is only touched
    /// outside the Render tab, so a Render-only window never builds it.
    private func updateModeSlot() {
        let statusBar = contentController.statusBar
        guard contentController.currentTab != .render, Settings.shared.keyBindings == .vim else {
            statusBar.showVim(mode: nil, commandLine: nil)
            return
        }
        let vim = contentController.editor.vim
        if vim.onModeChange == nil {
            vim.onModeChange = { [weak self] in
                self?.updateModeSlot()
                // Visual-line head moves can leave the selection unchanged; Ln/Col follows the head.
                self?.contentController.updateStatus()
            }
        }
        statusBar.showVim(mode: vim.mode, commandLine: vim.commandLine)
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.outline, .flexibleSpace, ItemID.tabs, .flexibleSpace, ItemID.find]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.outline, .flexibleSpace, ItemID.tabs, ItemID.find]
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
            item.isEnabled = contentController.currentTab == .render
            outlineItem = item
        case ItemID.tabs:
            item.label = "View"
            item.view = tabControl
        case ItemID.find:
            item.label = "Find"
            item.toolTip = "Find"
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
            item.action = #selector(showFind(_:))
            item.target = self
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = true
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
        outlineItem?.isEnabled = contentController.currentTab == .render
        updateModeSlot()
    }

    /// ⇧⌘O and the `sidebar.left` button. Flips the app-wide setting; every window follows `Settings.didChange`.
    @objc func toggleOutline(_ sender: Any?) {
        guard contentController.currentTab == .render else { return }
        Settings.shared.outlineVisible.toggle()
    }

    /// ⌘R: render the current text now.
    @objc func renderNow(_ sender: Any?) {
        contentController.render()
    }

    /// File > Export as PDF… / Export as HTML….
    @objc func exportPDF(_ sender: Any?) {
        guard let doc = document as? MarkdownDocument, let window else { return }
        Exporter.exportPDF(document: doc, window: window)
    }

    @objc func exportHTML(_ sender: Any?) {
        guard let doc = document as? MarkdownDocument, let window else { return }
        Exporter.exportHTML(document: doc, window: window)
    }

    /// ⌘F and the magnifier button. Render: the web find bar. Raw / Split: the text view's find bar.
    @objc func showFind(_ sender: Any?) {
        contentController.showFind()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectTab(_:)):
            menuItem.state = menuItem.tag == contentController.currentTab.rawValue ? .on : .off
            return DocTab(rawValue: menuItem.tag) != nil
        case #selector(toggleOutline(_:)):
            menuItem.title = Settings.shared.outlineVisible ? "Hide Outline" : "Show Outline"
            return contentController.currentTab == .render
        default:
            return true
        }
    }
}
