import AppKit

/// The app's Settings window (⌘,): one window, `.preference` toolbar with the
/// General and Appearance panes. The title follows the selected pane. The window
/// keeps its position between launches; it is not resizable, its height follows
/// the pane.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private enum Pane: String, CaseIterable {
        case general = "neo-md.settings.general"
        case appearance = "neo-md.settings.appearance"

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }

        var title: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            }
        }
    }

    private let general = GeneralSettingsView()
    private let appearance = AppearanceSettingsView()
    private var pane: Pane = .general

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "neo-md.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.center()
        window.setFrameAutosaveName("neo-md.settings")
        // After the saved frame comes back: fit the height to the pane, keep the saved top left.
        select(.general, animate: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Opens the window on the last selected pane, or brings it to the front.
    func show() {
        if pane == .general { general.refreshDefaultApp() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func view(for pane: Pane) -> NSView {
        switch pane {
        case .general: general
        case .appearance: appearance
        }
    }

    private func select(_ newPane: Pane, animate: Bool) {
        guard let window else { return }
        pane = newPane
        window.toolbar?.selectedItemIdentifier = newPane.identifier
        window.title = newPane.title
        if newPane == .general { general.refreshDefaultApp() }

        let content = view(for: newPane)
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        window.contentView = content
        // Keep the top edge in place while the height changes.
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    @objc private func paneClicked(_ sender: NSToolbarItem) {
        guard let newPane = Pane(rawValue: sender.itemIdentifier.rawValue), newPane != pane else { return }
        select(newPane, animate: true)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(paneClicked(_:))
        return item
    }
}
