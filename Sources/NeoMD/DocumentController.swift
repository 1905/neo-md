import AppKit

/// The app runs only while a document is open. This controller decides when to quit:
/// after a document closes, after an open finishes, and after an Open panel finishes.
/// `main.swift` creates it first, so it becomes `NSDocumentController.shared`.
@MainActor
final class DocumentController: NSDocumentController {
    /// Opens in flight: Finder, Open panel, Open Recent, links. The app never quits during one.
    private var pendingOpens = 0

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        pendingOpens += 1
        super.openDocument(withContentsOf: url, display: displayDocument) { document, wasOpen, error in
            MainActor.assumeIsolated {
                completionHandler(document, wasOpen, error)
                self.pendingOpens -= 1
                self.quitIfNoDocuments()
            }
        }
    }

    /// ⌘O and the launch panel. After the panel's handler ran (it starts any open), check once:
    /// a cancel with no document open quits.
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        super.beginOpenPanel(openPanel, forTypes: inTypes) { result in
            completionHandler(result)
            MainActor.assumeIsolated { self.quitSoonIfNoDocuments() }
        }
    }

    /// The document leaves `documents` here, after its window closed.
    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        quitSoonIfNoDocuments()
    }

    /// On the next pass, so an open that a closing panel starts is counted first.
    func quitSoonIfNoDocuments() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.quitIfNoDocuments() }
        }
    }

    /// Quits when no document is open or opening and no panel or alert waits for the user.
    func quitIfNoDocuments() {
        guard documents.isEmpty, pendingOpens == 0, NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) else { return }
        NSApp.terminate(nil)
    }
}
