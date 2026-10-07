import AppKit

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    /// Posted (object: the document) after `text` changes: on read, on revert, and by the editor.
    static let textDidChange = Notification.Name("NeoMDMarkdownDocumentTextDidChange")
    /// Posted (object: the document) after a successful save.
    static let didSave = Notification.Name("NeoMDMarkdownDocumentDidSave")

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

    /// Text handed to the last `data(ofType:)` call; becomes `lastSavedText` when the save succeeds.
    private var pendingSavedText: String?

    override func data(ofType typeName: String) throws -> Data {
        pendingSavedText = text
        let utf8 = Data(text.utf8)
        return lineEnding == "\r\n" ? Self.convertingLoneLFToCRLF(utf8) : utf8
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        pendingSavedText = nil
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if let self, error == nil, let saved = self.pendingSavedText {
                self.lastSavedText = saved
            }
            if let self, error == nil {
                NotificationCenter.default.post(name: MarkdownDocument.didSave, object: self)
            }
            self?.pendingSavedText = nil
            completionHandler(error)
        }
    }

    /// Every "\n" not already after "\r" becomes "\r\n". The text view may insert lone "\n".
    static func convertingLoneLFToCRLF(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + data.count / 32)
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A, previous != 0x0D { out.append(0x0D) }
            out.append(byte)
            previous = byte
        }
        return out
    }
}
