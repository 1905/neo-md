import AppKit

/// Warn-tinted strip above the content (mockup frame 12).
/// Changed: "Changed on disk. You have unsaved edits." + [Keep mine] [Reload].
/// Deleted: "Deleted on disk." + [Keep mine].
@MainActor
final class DiskChangeBanner: NSView {
    enum Kind { case changed, deleted }

    /// Light #b25e00, dark #f0a640 (mockup `--warn`).
    static let warnColor = EditorStyle.dynamic(light: 0xb25e00, dark: 0xf0a640)

    var kind: Kind = .changed { didSet { applyKind() } }
    var onKeepMine: (() -> Void)?
    var onReload: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let keepButton = NSButton(title: "Keep mine", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let bottomLine = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(bottomLine)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Self.warnColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .labelColor

        for button in [keepButton, reloadButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 12)
            button.target = self
        }
        keepButton.action = #selector(keepMine(_:))
        reloadButton.action = #selector(reload(_:))
        // Primary look without a key equivalent: Return must stay with the editor.
        reloadButton.bezelColor = .controlAccentColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [titleLabel, messageLabel, spacer, keepButton, reloadButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.setCustomSpacing(8, after: keepButton)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyKind()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyKind() {
        switch kind {
        case .changed:
            titleLabel.stringValue = "Changed on disk."
            messageLabel.stringValue = "You have unsaved edits."
            messageLabel.isHidden = false
            reloadButton.isHidden = false
        case .deleted:
            titleLabel.stringValue = "Deleted on disk."
            messageLabel.stringValue = ""
            messageLabel.isHidden = true
            reloadButton.isHidden = true
        }
    }

    @objc private func keepMine(_ sender: Any?) { onKeepMine?() }
    @objc private func reload(_ sender: Any?) { onReload?() }

    // MARK: - Colours (mockup `.banner`: warn 12 % over the window, bottom line warn 30 %)

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let base = NSColor.textBackgroundColor
        let fill = base.blended(withFraction: 0.12, of: Self.warnColor) ?? base
        layer?.backgroundColor = fill.cgColor
        bottomLine.backgroundColor = Self.warnColor.withAlphaComponent(0.3).cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
    }
}
