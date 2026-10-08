import AppKit
import UniformTypeIdentifiers

/// Settings → General: Key bindings (Normal / Vim), Open files in (Render / Raw),
/// Default app. Every control writes `Settings.shared` at once and follows
/// `Settings.didChange`. The Default app row reads the system state each time
/// the pane shows.
@MainActor
final class GeneralSettingsView: NSView {
    private let keyBindings = NSSegmentedControl(labels: ["Normal", "Vim"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let openIn = NSSegmentedControl(labels: ["Render", "Raw"], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private let defaultStatus = NSTextField(labelWithString: "")
    private let makeDefaultButton = NSButton(title: "Make default", target: nil, action: nil)
    private let defaultError = NSTextField(wrappingLabelWithString: "")
    private static let markdownType = UTType("net.daringfireball.markdown")

    init() {
        super.init(frame: .zero)
        keyBindings.target = self
        keyBindings.action = #selector(keyBindingsChanged(_:))
        openIn.target = self
        openIn.action = #selector(openInChanged(_:))
        makeDefaultButton.target = self
        makeDefaultButton.action = #selector(makeDefaultClicked(_:))
        makeDefaultButton.bezelStyle = .rounded
        defaultStatus.textColor = .secondaryLabelColor
        defaultError.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        defaultError.textColor = .systemRed
        defaultError.preferredMaxLayoutWidth = 260
        defaultError.isHidden = true
        for control in [keyBindings, openIn] {
            control.segmentStyle = .rounded
            control.setWidth(72, forSegment: 0)
            control.setWidth(72, forSegment: 1)
        }

        let defaultApp = NSStackView(views: [defaultStatus, makeDefaultButton, defaultError])
        defaultApp.orientation = .vertical
        defaultApp.alignment = .leading
        defaultApp.spacing = 6

        SettingsForm.install(rows: [
            ("Key bindings:", keyBindings),
            ("Open files in:", openIn),
            ("Default app:", defaultApp),
        ], in: self)

        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: Settings.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        keyBindings.selectedSegment = Settings.shared.keyBindings == .vim ? 1 : 0
        openIn.selectedSegment = Settings.shared.defaultTab == .raw ? 1 : 0
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
    func refreshDefaultApp(error: String? = nil) {
        showDefaultState(isDefault: isDefaultApp(), error: error)
    }

    private func showDefaultState(isDefault: Bool, error: String?) {
        defaultStatus.stringValue = isDefault ? "neo-md is the default" : ""
        defaultStatus.isHidden = !isDefault
        makeDefaultButton.isHidden = isDefault
        makeDefaultButton.isEnabled = true
        defaultError.stringValue = error ?? ""
        defaultError.isHidden = error == nil
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
                    self.showDefaultState(isDefault: true, error: nil)
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

/// The two-column form of the Settings panes: right-aligned labels, controls on the left edge.
@MainActor
enum SettingsForm {
    static let width: CGFloat = 480

    static func install(rows: [(String, NSView)], in view: NSView) {
        let grid = NSGridView(views: rows.map { title, control in
            [NSTextField(labelWithString: title), control]
        })
        grid.rowSpacing = 14
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        // Stacks and other baseline-less views align at the top of the row.
        for index in 0..<grid.numberOfRows where rows[index].1 is NSStackView {
            grid.row(at: index).yPlacement = .top
            grid.row(at: index).rowAlignment = .none
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
        ])
    }
}
