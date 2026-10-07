import AppKit
import UniformTypeIdentifiers

/// The ⌘, popover (mockup frame 14). Rows: Key bindings (Normal / Vim),
/// Theme ("Follows macOS"), Open files in (Render / Raw), Default app. Every
/// control writes `Settings.shared` at once; the popover also follows
/// `Settings.didChange`. The Default app row reads the system state each time
/// the popover opens.
@MainActor
final class SettingsPopover: NSPopover {
    private let keyBindings = NSSegmentedControl(labels: ["Normal", "Vim"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let openIn = NSSegmentedControl(labels: ["Render", "Raw"], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private let defaultStatus = NSTextField(labelWithString: "")
    private let makeDefaultButton = NSButton(title: "Make default", target: nil, action: nil)
    private let defaultError = NSTextField(wrappingLabelWithString: "")
    private static let markdownType = UTType("net.daringfireball.markdown")

    override init() {
        super.init()
        behavior = .transient
        animates = true
        keyBindings.target = self
        keyBindings.action = #selector(keyBindingsChanged(_:))
        openIn.target = self
        openIn.action = #selector(openInChanged(_:))
        makeDefaultButton.target = self
        makeDefaultButton.action = #selector(makeDefaultClicked(_:))
        makeDefaultButton.bezelStyle = .rounded
        makeDefaultButton.controlSize = .regular
        makeDefaultButton.font = .systemFont(ofSize: 12)
        defaultStatus.font = .systemFont(ofSize: 12)
        defaultStatus.textColor = .secondaryLabelColor
        defaultError.font = .systemFont(ofSize: 11)
        defaultError.textColor = .systemRed
        defaultError.preferredMaxLayoutWidth = 220
        defaultError.isHidden = true
        for control in [keyBindings, openIn] {
            control.segmentStyle = .rounded
            control.controlSize = .regular
            control.font = .systemFont(ofSize: 12)
            control.setWidth(56, forSegment: 0)
            control.setWidth(56, forSegment: 1)
        }

        let controller = NSViewController()
        let content = makeContent()
        controller.view = content
        controller.preferredContentSize = content.fittingSize
        contentViewController = controller
        refresh()
        refreshDefaultApp()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: Settings.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeContent() -> NSView {
        let theme = NSTextField(labelWithString: "Follows macOS")
        theme.font = .systemFont(ofSize: 12)
        theme.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            Self.header("Editing"),
            Self.row("Key bindings", keyBindings),
            Self.header("Appearance"),
            Self.row("Theme", theme),
            Self.row("Open files in", openIn),
            Self.header("System"),
            Self.row("Default app", NSStackView(views: [defaultStatus, makeDefaultButton])),
            defaultError,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[2])
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[4])
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[5])
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[6])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 18, right: 16)
        for view in stack.arrangedSubviews where view is NSStackView || view === defaultError {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 252).isActive = true
        return stack
    }

    private static func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func refresh() {
        keyBindings.selectedSegment = Settings.shared.keyBindings == .vim ? 1 : 0
        openIn.selectedSegment = Settings.shared.defaultTab == .raw ? 1 : 0
    }

    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView,
                       preferredEdge: NSRectEdge) {
        refreshDefaultApp()
        super.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
    }

    /// True when Launch Services opens Markdown files with this app bundle.
    private func isDefaultApp() -> Bool {
        guard let type = Self.markdownType,
              let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        let own = Bundle.main.bundleURL
        return current.standardizedFileURL.resolvingSymlinksInPath().path
            == own.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Shows "neo-md is the default" or the "Make default" button, plus an
    /// optional error line under the row.
    private func refreshDefaultApp(error: String? = nil) {
        let isDefault = isDefaultApp()
        defaultStatus.stringValue = isDefault ? "neo-md is the default" : ""
        defaultStatus.isHidden = !isDefault
        makeDefaultButton.isHidden = isDefault
        makeDefaultButton.isEnabled = true
        defaultError.stringValue = error ?? ""
        defaultError.isHidden = error == nil
        resizeToFit()
    }

    private func resizeToFit() {
        guard let view = contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        contentViewController?.preferredContentSize = view.fittingSize
    }

    @objc private func makeDefaultClicked(_ sender: NSButton) {
        guard let type = Self.markdownType else {
            refreshDefaultApp(error: "Unknown content type net.daringfireball.markdown")
            return
        }
        sender.isEnabled = false
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                 toOpen: type) { error in
            let message = error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let message {
                    self.refreshDefaultApp(error: message)
                } else {
                    // Show the result of the call even if Launch Services has
                    // not caught up yet.
                    self.defaultStatus.stringValue = "neo-md is the default"
                    self.defaultStatus.isHidden = false
                    self.makeDefaultButton.isHidden = true
                    self.defaultError.isHidden = true
                    self.resizeToFit()
                }
            }
        }
    }

    @objc private func settingsDidChange(_ note: Notification) { refresh() }

    @objc private func keyBindingsChanged(_ sender: NSSegmentedControl) {
        Settings.shared.keyBindings = sender.selectedSegment == 1 ? .vim : .standard
    }

    @objc private func openInChanged(_ sender: NSSegmentedControl) {
        Settings.shared.defaultTab = sender.selectedSegment == 1 ? .raw : .render
    }
}
