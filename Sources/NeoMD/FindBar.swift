import AppKit

/// Render tab find bar: search field, previous/next buttons and Done. 32 pt high.
/// Enter / ⌘G = next, ⇧Enter / ⇧⌘G = previous, Escape / Done = hide.
/// The owner does the search through `onFind` and calls `showNoMatch()` when nothing matched.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 32
    static let noMatchDuration: TimeInterval = 0.6

    /// (search string, backwards). Called on Enter, the arrow buttons and ⌘G.
    var onFind: ((String, Bool) -> Void)?
    /// Escape or Done.
    var onClose: (() -> Void)?

    let searchField = NSSearchField()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var noMatchWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 6

        configure(previousButton, symbol: "chevron.left", tip: "Previous match (⇧⌘G)", action: #selector(findPrevious(_:)))
        configure(nextButton, symbol: "chevron.right", tip: "Next match (⌘G)", action: #selector(findNext(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.target = self
        doneButton.action = #selector(close(_:))

        let separator = NSBox()
        separator.boxType = .separator

        for view in [searchField, previousButton, nextButton, doneButton, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            previousButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 6),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            doneButton.leadingAnchor.constraint(greaterThanOrEqualTo: nextButton.trailingAnchor, constant: 8),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let preferredWidth = searchField.widthAnchor.constraint(equalToConstant: 320)
        preferredWidth.priority = .defaultLow
        preferredWidth.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    // MARK: - Actions

    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }
    @objc private func close(_ sender: Any?) { onClose?() }

    private func find(backwards: Bool) {
        let string = searchField.stringValue
        guard !string.isEmpty else { return }
        onFind?(string, backwards)
    }

    /// Red tint on the search field for `noMatchDuration`.
    func showNoMatch() {
        noMatchWork?.cancel()
        searchField.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
        searchField.textColor = .systemRed
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.searchField.layer?.backgroundColor = nil
                self?.searchField.textColor = .controlTextColor
                self?.noMatchWork = nil
            }
        }
        noMatchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noMatchDuration, execute: work)
    }

    /// ⌘G / ⇧⌘G while the bar is on screen, wherever the focus is in the window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, Self.isFindAgain(event) else {
            return super.performKeyEquivalent(with: event)
        }
        find(backwards: event.modifierFlags.contains(.shift))
        return true
    }

    static func isFindAgain(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.type == .keyDown
            && flags.subtracting(.shift) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "g"
    }

    // MARK: - NSSearchFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
