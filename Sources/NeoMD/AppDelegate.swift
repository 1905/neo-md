import AppKit
import UniformTypeIdentifiers
import MDCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files from Finder open during launch. Wait this long before the welcome window decides.
    static let welcomeDelay: TimeInterval = 0.3

    private var welcome: WelcomeWindowController?

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        claimDefaultAppOnce()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(settingsDidChange),
                           name: Settings.didChange, object: nil)
        center.addObserver(self, selector: #selector(windowDidBecomeKey),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose),
                           name: NSWindow.willCloseNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.welcomeDelay) { [weak self] in
            MainActor.assumeIsolated { self?.showWelcomeIfNoDocuments() }
        }
    }

    /// ⌘, (app menu "Settings…"). Lives on the delegate, so it works with no document window open.
    /// First start from an Applications folder: make neo-md the default app for Markdown
    /// files, without a question (user decision, 2026-10-08). Runs once. Copies outside an
    /// Applications folder (build output) never claim the default.
    private func claimDefaultAppOnce() {
        let settings = Settings.shared
        guard !settings.claimedDefaultApp,
              Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications",
              let markdown = UTType("net.daringfireball.markdown") else { return }
        settings.claimedDefaultApp = true
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: markdown) { _ in }
    }

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

    /// Dock click with no visible window: show the welcome window. Minimized documents come back as usual.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcomeIfNoDocuments() }
        return true
    }

    private func showWelcomeIfNoDocuments() {
        guard NSDocumentController.shared.documents.isEmpty else { return }
        let controller = welcome ?? WelcomeWindowController()
        welcome = controller
        controller.showWindow(nil)
    }

    /// A document window came up: the welcome window goes away.
    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.windowController?.document != nil else { return }
        welcome?.close()
    }

    /// The last document window closed: show the welcome window again.
    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.windowController?.document != nil else { return }
        // The document leaves `documents` after its window closes, so check on the next pass.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.showWelcomeIfNoDocuments() }
        }
    }
}
