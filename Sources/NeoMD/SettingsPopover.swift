import AppKit

/// The ⌘, popover (mockup frame 14). Rows: Key bindings (Normal / Vim),
/// Theme ("Follows macOS"), Open files in (Render / Raw). Every control writes
/// `Settings.shared` at once; the popover also follows `Settings.didChange`.
@MainActor
final class SettingsPopover: NSPopover {
    private let keyBindings = NSSegmentedControl(labels: ["Normal", "Vim"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let openIn = NSSegmentedControl(labels: ["Render", "Raw"], trackingMode: .selectOne,
                                            target: nil, action: nil)

    override init() {
        super.init()
        behavior = .transient
        animates = true
        keyBindings.target = self
        keyBindings.action = #selector(keyBindingsChanged(_:))
        openIn.target = self
        openIn.action = #selector(openInChanged(_:))
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
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[2])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 18, right: 16)
        for view in stack.arrangedSubviews where view is NSStackView {
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

    @objc private func settingsDidChange(_ note: Notification) { refresh() }

    @objc private func keyBindingsChanged(_ sender: NSSegmentedControl) {
        Settings.shared.keyBindings = sender.selectedSegment == 1 ? .vim : .standard
    }

    @objc private func openInChanged(_ sender: NSSegmentedControl) {
        Settings.shared.defaultTab = sender.selectedSegment == 1 ? .raw : .render
    }
}
