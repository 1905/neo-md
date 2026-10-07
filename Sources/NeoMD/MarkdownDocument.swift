import AppKit

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    /// Posted (object: the document) after `text` changes: on read, on revert, and by the editor.
    static let textDidChange = Notification.Name("NeoMDMarkdownDocumentTextDidChange")

    /// The source. The editor writes here.
    var text: String = ""
    /// "\n" or "\r\n", detected on read, kept on write.
    var lineEnding: String = "\n"
    /// Text written by the last save. Disk-change logic ignores events that match it.
    var lastSavedText: String?

    override class var autosavesInPlace: Bool { false }

    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                         for saveOperation: NSDocument.SaveOperationType) -> Bool {
        false
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError, userInfo: [
                NSLocalizedDescriptionKey: "neo-md can only open UTF-8 text.",
            ])
        }
        text = decoded
        lineEnding = data.range(of: Data("\r\n".utf8)) != nil ? "\r\n" : "\n"
        NotificationCenter.default.post(name: MarkdownDocument.textDidChange, object: self)
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }
}
