import AppKit

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    /// Posted (object: the document) after `text` changes: on read, on revert, and by the editor.
    static let textDidChange = Notification.Name("NeoMDMarkdownDocumentTextDidChange")
    /// Posted (object: the document) after a successful save.
    static let didSave = Notification.Name("NeoMDMarkdownDocumentDidSave")
    /// Posted (object: the document) when the file changed or was deleted on disk and the window
    /// must show the banner. userInfo `deletedKey`: Bool.
    static let diskDidChange = Notification.Name("NeoMDMarkdownDocumentDiskDidChange")
    static let deletedKey = "deleted"
    /// Posted (object: the document) right before and right after a revert, so views can keep their scroll position.
    static let willRevert = Notification.Name("NeoMDMarkdownDocumentWillRevert")
    static let didRevert = Notification.Name("NeoMDMarkdownDocumentDidRevert")

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
        // One window per document. A second call (for example from state restoration) adds nothing.
        guard windowControllers.isEmpty else { return }
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
        return encoded(text)
    }

    /// The bytes a save writes for `string` with the current line ending.
    private func encoded(_ string: String) -> Data {
        let utf8 = Data(string.utf8)
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

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        NotificationCenter.default.post(name: Self.willRevert, object: self)
        defer { NotificationCenter.default.post(name: Self.didRevert, object: self) }
        try super.revert(toContentsOf: url, ofType: typeName)
        // The disk now holds `text`; the old save no longer describes it.
        lastSavedText = nil
    }

    // MARK: - Disk changes (NSFilePresenter)

    // NSDocument calls these on its presenter queue. The work runs on the main queue.
    // `presentedItemDidMove(to:)` keeps the NSDocument default: it updates `fileURL`.

    override func presentedItemDidChange() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.handleDiskChange() }
        }
    }

    /// The window stays open and shows the "Deleted on disk." banner.
    override func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.postDiskChange(deleted: true) }
        }
        completionHandler(nil)
    }

    @MainActor
    private func handleDiskChange() {
        guard let url = fileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            postDiskChange(deleted: true)
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        if data == encoded(text) || lastSavedText.map({ data == encoded($0) }) == true {
            // Own save or same content: nothing to show. Take the new date so the next ⌘S does not warn.
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                fileModificationDate = date
            }
            return
        }
        // The disk moved past our last save, so a later match with it is not our own echo.
        lastSavedText = nil
        if isDocumentEdited {
            postDiskChange(deleted: false)
            return
        }
        do {
            try revert(toContentsOf: url, ofType: fileType ?? "net.daringfireball.markdown")
        } catch {
            presentError(error)
        }
    }

    @MainActor
    private func postDiskChange(deleted: Bool) {
        NotificationCenter.default.post(name: Self.diskDidChange, object: self, userInfo: [Self.deletedKey: deleted])
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
