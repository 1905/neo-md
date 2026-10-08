import AppKit

/// One document window: unified toolbar + `ContentController`.
/// Menu actions reach it through the responder chain.
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
    private lazy var settingsPopover = SettingsPopover()

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

        vimChip.target = self
        vimChip.action = #selector(toggleVim(_:))
        updateVimChip()
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
        if let folder = (document as? NSDocument)?.fileURL?.deletingLastPathComponent() {
            parts.append((folder.path as NSString).abbreviatingWithTildeInPath)
        }
        window?.subtitle = parts.joined(separator: " · ")
    }

    // MARK: - Vim

    @objc private func settingsDidChange(_ note: Notification) {
        updateVimChip()
        updateModeSlot()
    }

    /// Dim when off; green text and border when on (`.chip` / `.chip.on` in the mockup).
    private func updateVimChip() {
        let on = Settings.shared.keyBindings == .vim
        vimChip.contentTintColor = on ? VimStyle.normal : .tertiaryLabelColor
        vimChip.borderColor = on ? VimStyle.normal.withAlphaComponent(0.45) : .separatorColor
        vimChip.toolTip = on ? "Vim key bindings: on" : "Vim key bindings: off"
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

    /// The `VIM` chip: toggles Vim mode for the whole app.
    @objc func toggleVim(_ sender: Any?) {
        Settings.shared.keyBindings = Settings.shared.keyBindings == .vim ? .standard : .vim
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
            item.isEnabled = contentController.currentTab == .render
            outlineItem = item
        case ItemID.tabs:
            item.label = "View"
            item.view = tabControl
        case ItemID.vim:
            item.label = "Vim"
            item.toolTip = "Vim key bindings"
            item.view = vimChip
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

    /// ⌘F and the magnifier button. Render: the web find bar. Raw / Split: the text view's find bar.
    @objc func showFind(_ sender: Any?) {
        contentController.showFind()
    }

    /// ⌘, opens the settings popover under the `VIM` chip. A second ⌘, closes it.
    @objc func showSettings(_ sender: Any?) {
        if settingsPopover.isShown {
            settingsPopover.performClose(sender)
            return
        }
        if vimChip.window != nil, !vimChip.isHiddenOrHasHiddenAncestor {
            settingsPopover.show(relativeTo: vimChip.bounds, of: vimChip, preferredEdge: .minY)
        } else if let content = window?.contentView {
            // Toolbar hidden: anchor at the top right of the content.
            let anchor = NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 1, width: 1, height: 1)
            settingsPopover.show(relativeTo: anchor, of: content, preferredEdge: .minY)
        }
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

/// Toolbar chip: small bordered text button (`VIM`). The owner sets the on/off colours.
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
