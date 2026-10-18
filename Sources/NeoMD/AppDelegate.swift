import AppKit
import UniformTypeIdentifiers
import MDCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Lifecycle: the app runs only while a document is open

    /// Launch without a file (Dock, Spotlight, `open -a`): show the Open panel.
    /// AppKit asks this only when no document opens at launch.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard NSDocumentController.shared.documents.isEmpty else { return true }
        NSApp.activate()
        NSDocumentController.shared.beginOpenPanel { urls in
            MainActor.assumeIsolated {
                guard let urls, !urls.isEmpty else {
                    NSApp.terminate(nil)
                    return
                }
                Self.open(urls)
            }
        }
        return true
    }

    /// Files from Finder, the Dock icon or `open`. If none opens, the app quits.
    func application(_ application: NSApplication, open urls: [URL]) {
        Self.open(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        claimDefaultAppOnce()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(settingsDidChange),
                           name: Settings.didChange, object: nil)
        Updater.shared.start()
    }

    /// A staged update replaces the bundle now. The next start runs the new version.
    func applicationWillTerminate(_ notification: Notification) {
        Updater.shared.installStagedUpdate()
    }

    /// Opens each URL as a document. Errors show as an alert. If every file fails,
    /// `DocumentController` quits the app after the last alert.
    static func open(_ urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    /// First start from an Applications folder: make neo-md the default app for Markdown
    /// files, without a question (user decision, 2026-10-08). Runs once. Copies outside an
    /// Applications folder (build output) never claim the default.
    private func claimDefaultAppOnce() {
        let settings = Settings.shared
        guard !settings.claimedDefaultApp,
              Bundle.main.isInApplicationsFolder,
              let markdown = UTType("net.daringfireball.markdown") else { return }
        settings.claimedDefaultApp = true
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: markdown) { _ in }
    }

    /// ⌘, (app menu "Settings…"). Lives on the delegate, so it works with no document window open.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    // MARK: - Text size

    /// ⌘+ and ⌘=. One size step up in all windows; a beep at the largest step.
    @objc func biggerText(_ sender: Any?) {
        stepFontScale(by: 1)
    }

    /// ⌘-. One size step down in all windows; a beep at the smallest step.
    @objc func smallerText(_ sender: Any?) {
        stepFontScale(by: -1)
    }

    /// ⌘0. Back to step 0.
    @objc func actualSizeText(_ sender: Any?) {
        guard Settings.shared.fontScale != 0 else { return }
        Settings.shared.fontScale = 0
    }

    private func stepFontScale(by delta: Int) {
        if !Settings.shared.stepFontScale(by: delta) { NSSound.beep() }
    }

    // MARK: - Theme

    @objc private func settingsDidChange(_ note: Notification) {
        applyTheme()
    }

    /// `system` follows macOS (`nil`); `light` and `dark` force the app appearance.
    private func applyTheme() {
        let name: NSAppearance.Name?
        switch Settings.shared.theme {
        case .system: name = nil
        case .light: name = .aqua
        case .dark: name = .darkAqua
        }
        guard NSApp.appearance?.name != name else { return }
        NSApp.appearance = name.flatMap { NSAppearance(named: $0) }
    }
}
