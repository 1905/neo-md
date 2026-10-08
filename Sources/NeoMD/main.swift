import AppKit
import UniformTypeIdentifiers

// Command-line modes run before the UI starts and exit without showing a window.

/// `--make-default`: register neo-md as the default app for Markdown, print the
/// result and exit (0 ok, 1 error, 2 timeout). The completion handler can need
/// the main run loop, so the main thread spins it in short steps instead of
/// blocking on a semaphore.
func makeDefaultAndExit() -> Never {
    guard let markdown = UTType("net.daringfireball.markdown") else {
        print("default: error unknown content type net.daringfireball.markdown")
        exit(1)
    }
    NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                             toOpen: markdown) { error in
        if let error {
            print("default: error \(error.localizedDescription)")
            exit(1)
        }
        print("default: ok")
        exit(0)
    }
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    print("default: timeout")
    exit(2)
}

if CommandLine.arguments.contains("--make-default") {
    makeDefaultAndExit()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = MainMenu.build()
    // `app.delegate` is weak. Keep the delegate alive for the whole run loop.
    withExtendedLifetime(delegate) { app.run() }
}
