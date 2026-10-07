import AppKit

// Command-line modes run before the UI starts and exit without showing a window.
// Task 14 adds the `--make-default` check here.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = MainMenu.build()
    // `app.delegate` is weak. Keep the delegate alive for the whole run loop.
    withExtendedLifetime(delegate) { app.run() }
}
