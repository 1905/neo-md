import AppKit

/// Settings → Appearance: Theme, Reading font, Editor font, Text size. Every
/// control writes `Settings.shared` at once and follows `Settings.didChange`.
/// The font panel sets only the family; the size comes from the text size step.
@MainActor
final class AppearanceSettingsView: NSView {
    private enum FontTarget { case reading, editor }

    private let theme = NSSegmentedControl(labels: ["Follow macOS", "Light", "Dark"], trackingMode: .selectOne,
                                           target: nil, action: nil)
    private let readingName = NSTextField(labelWithString: "")
    private let editorName = NSTextField(labelWithString: "")
    private let readingReset = NSButton(title: "Reset", target: nil, action: nil)
    private let editorReset = NSButton(title: "Reset", target: nil, action: nil)
    private let sizeStepper = NSSegmentedControl(labels: ["−", "+"], trackingMode: .momentary,
                                                 target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    /// The font row the open font panel edits.
    private var fontTarget: FontTarget?

    init() {
        super.init(frame: .zero)
        theme.target = self
        theme.action = #selector(themeChanged(_:))
        theme.segmentStyle = .rounded
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeClicked(_:))
        sizeStepper.segmentStyle = .rounded
        sizeStepper.setWidth(32, forSegment: 0)
        sizeStepper.setWidth(32, forSegment: 1)
        sizeStepper.setToolTip("Smaller", forSegment: 0)
        sizeStepper.setToolTip("Bigger", forSegment: 1)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        for button in [readingReset, editorReset] {
            button.isBordered = false
            button.contentTintColor = .linkColor
            button.target = self
            button.action = #selector(resetFont(_:))
        }

        SettingsForm.install(rows: [
            ("Theme:", theme),
            ("Reading font:", fontRow(name: readingName, reset: readingReset,
                                      change: #selector(changeReadingFont(_:)))),
            ("Editor font:", fontRow(name: editorName, reset: editorReset,
                                     change: #selector(changeEditorFont(_:)))),
            ("Text size:", Self.hStack([sizeStepper, sizeLabel])),
        ], in: self)

        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: Settings.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func fontRow(name: NSTextField, reset: NSButton, change: Selector) -> NSView {
        let button = NSButton(title: "Change…", target: self, action: change)
        button.bezelStyle = .rounded
        name.lineBreakMode = .byTruncatingTail
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return Self.hStack([name, button, reset])
    }

    private static func hStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return stack
    }

    // MARK: - State

    private func refresh() {
        let settings = Settings.shared
        switch settings.theme {
        case .system: theme.selectedSegment = 0
        case .light: theme.selectedSegment = 1
        case .dark: theme.selectedSegment = 2
        }
        readingName.stringValue = Self.displayName(settings.readingFont, fallback: "System font")
        editorName.stringValue = Self.displayName(settings.editorFont, fallback: "SF Mono")
        readingReset.isHidden = settings.readingFont.isEmpty
        editorReset.isHidden = settings.editorFont.isEmpty
        sizeLabel.stringValue = "\(Int((Self.factor(step: settings.fontScale) * 100).rounded())) %"
        sizeStepper.setEnabled(settings.fontScale > Settings.fontScaleSteps.lowerBound, forSegment: 0)
        sizeStepper.setEnabled(settings.fontScale < Settings.fontScaleSteps.upperBound, forSegment: 1)
    }

    /// The saved family, or "<fallback> (default)" when it is empty or no longer installed.
    private static func displayName(_ family: String, fallback: String) -> String {
        if !family.isEmpty, NSFontManager.shared.availableFontFamilies.contains(family) { return family }
        return "\(fallback) (default)"
    }

    /// TODO(Task 3): use FontScale.factor from MDCore.
    private static func factor(step: Int) -> Double {
        let table: [Int: Double] = [-3: 0.75, -2: 0.85, -1: 0.92, 0: 1.0, 1: 1.1, 2: 1.25, 3: 1.4, 4: 1.6, 5: 1.8]
        return table[Settings.clampFontScale(step)] ?? 1.0
    }

    @objc private func settingsDidChange(_ note: Notification) { refresh() }

    // MARK: - Actions

    @objc private func themeChanged(_ sender: NSSegmentedControl) {
        let themes: [AppTheme] = [.system, .light, .dark]
        guard themes.indices.contains(sender.selectedSegment) else { return }
        Settings.shared.theme = themes[sender.selectedSegment]
    }

    @objc private func sizeClicked(_ sender: NSSegmentedControl) {
        let current = Settings.shared.fontScale
        let next = current + (sender.selectedSegment == 0 ? -1 : 1)
        guard Settings.fontScaleSteps.contains(next) else {
            NSSound.beep()
            return
        }
        Settings.shared.fontScale = next
    }

    @objc private func resetFont(_ sender: NSButton) {
        if sender === readingReset {
            Settings.shared.readingFont = ""
        } else {
            Settings.shared.editorFont = ""
        }
    }

    @objc private func changeReadingFont(_ sender: Any?) { openFontPanel(for: .reading) }

    @objc private func changeEditorFont(_ sender: Any?) { openFontPanel(for: .editor) }

    // MARK: - Font panel

    private func currentFont(for target: FontTarget) -> NSFont {
        let size = NSFont.systemFontSize
        switch target {
        case .reading:
            return NSFont(name: Settings.shared.readingFont, size: size)
                ?? NSFontManager.shared.font(withFamily: Settings.shared.readingFont, traits: [], weight: 5, size: size)
                ?? .systemFont(ofSize: size)
        case .editor:
            return NSFontManager.shared.font(withFamily: Settings.shared.editorFont, traits: [], weight: 5, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private func openFontPanel(for target: FontTarget) {
        fontTarget = target
        // The panel asks the first responder for its modes, and sends `changeFont:` to the target.
        window?.makeFirstResponder(self)
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(currentFont(for: target), isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    override var acceptsFirstResponder: Bool { true }

    /// Families only: no size, no effects.
    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face]
    }

    /// Keeps only the family. The editor font must be fixed-pitch: otherwise beep and keep the old value.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let target = fontTarget, let manager = sender else { return }
        let font = manager.convert(currentFont(for: target))
        guard var family = font.familyName else { return }
        // Hidden system families (".AppleSystemUIFont…") are the defaults: store them as "".
        if family.hasPrefix(".") { family = "" }
        switch target {
        case .reading:
            if family != Settings.shared.readingFont { Settings.shared.readingFont = family }
        case .editor:
            guard font.isFixedPitch else {
                NSSound.beep()
                return
            }
            if family != Settings.shared.editorFont { Settings.shared.editorFont = family }
        }
    }
}
