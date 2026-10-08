import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files from Finder open during launch. Wait this long before the welcome window decides.
    static let welcomeDelay: TimeInterval = 0.3

    private var welcome: WelcomeWindowController?

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowDidBecomeKey),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose),
                           name: NSWindow.willCloseNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.welcomeDelay) { [weak self] in
            MainActor.assumeIsolated { self?.showWelcomeIfNoDocuments() }
        }
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
