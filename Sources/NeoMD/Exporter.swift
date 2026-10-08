import AppKit
import MDCore
import UniformTypeIdentifiers
import WebKit

/// File > Export as PDF… and Export as HTML…. Both render the document text themselves,
/// so they do not depend on the preview.
@MainActor
enum Exporter {
    /// Asks for a target and writes the standalone export page as UTF-8, in one atomic write.
    static func exportHTML(document: MarkdownDocument, window: NSWindow) {
        askForTarget(document: document, window: window, type: .html, ext: "html") { url in
            do {
                let page = try exportPage(for: document)
                try Data(page.utf8).write(to: url, options: .atomic)
            } catch {
                window.presentError(error)
            }
        }
    }

    /// Asks for a target, loads the export page in an offscreen light web view and prints it to the file
    /// as real pages, without a print dialog.
    static func exportPDF(document: MarkdownDocument, window: NSWindow) {
        askForTarget(document: document, window: window, type: .pdf, ext: "pdf") { url in
            do {
                let page = try exportPage(for: document)
                PDFExportJob.start(page: page, documentFolder: document.fileURL?.deletingLastPathComponent(),
                                   title: baseName(of: document), target: url, window: window)
            } catch {
                window.presentError(error)
            }
        }
    }

    // MARK: - Helpers

    private static func askForTarget(document: MarkdownDocument, window: NSWindow, type: UTType, ext: String,
                                     completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(baseName(of: document)).\(ext)"
        // Next to the Markdown file, so relative links and images keep working.
        if let folder = document.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    /// The file name without its extension, for example `notes` for `notes.md`.
    private static func baseName(of document: MarkdownDocument) -> String {
        document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName
    }

    private static func exportPage(for document: MarkdownDocument) throws -> String {
        guard let result = MarkdownRenderer.render(document.text) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "The document could not be rendered.",
            ])
        }
        let settings = Settings.shared
        return HTMLTemplate.exportPage(body: result.html, title: baseName(of: document),
                                       readingFont: settings.readingFont,
                                       scale: FontScale.factor(step: settings.fontScale))
    }
}

/// One PDF export: an offscreen web view, its asset handler and the print operation.
/// `active` keeps the job alive until the print operation reports back.
@MainActor
private final class PDFExportJob: NSObject, WKNavigationDelegate {
    private static var active: [PDFExportJob] = []

    /// 20 mm in points.
    private static let margin: CGFloat = 56.7

    private let webView: WKWebView
    private let assetHandler = AssetSchemeHandler()
    private let title: String
    private let target: URL
    private weak var window: NSWindow?
    private var printing = false

    static func start(page: String, documentFolder: URL?, title: String, target: URL, window: NSWindow) {
        let job = PDFExportJob(documentFolder: documentFolder, title: title, target: target, window: window)
        active.append(job)
        job.webView.loadHTMLString(page, baseURL: URL(string: "\(AssetSchemeHandler.scheme)://\(AssetSchemeHandler.host)/"))
    }

    private init(documentFolder: URL?, title: String, target: URL, window: NSWindow) {
        assetHandler.documentFolder = documentFolder
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assetHandler, forURLScheme: AssetSchemeHandler.scheme)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100), configuration: config)
        // Paper is light: a dark PDF wastes ink and reads badly.
        webView.appearance = NSAppearance(named: .aqua)
        self.title = title
        self.target = target
        self.window = window
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the export page itself loads. Nothing in it may navigate away.
        decisionHandler(printing ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !printing else { return }
        printing = true
        guard let window else {
            finish()
            return
        }

        let info = NSPrintInfo()
        info.paperSize = NSPrintInfo.shared.paperSize
        info.topMargin = Self.margin
        info.bottomMargin = Self.margin
        info.leftMargin = Self.margin
        info.rightMargin = Self.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = target

        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // Without a frame, an offscreen WKWebView prints blank pages.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(Self.error("The PDF renderer stopped unexpectedly."))
    }

    // MARK: - Print

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        if success {
            finish()
        } else {
            fail(Self.error("The PDF could not be written to \u{201C}\(target.lastPathComponent)\u{201D}."))
        }
    }

    // MARK: - End

    private func fail(_ error: Error) {
        let window = self.window
        finish()
        window?.presentError(error)
    }

    private func finish() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        Self.active.removeAll { $0 === self }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
