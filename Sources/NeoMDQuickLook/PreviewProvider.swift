import Foundation
import MDCore
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based Quick Look preview: renders the Markdown file to a script-free HTML page.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    enum PreviewError: Error {
        case notUTF8
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PreviewError.notUTF8
        }
        let html = MarkdownRenderer.render(text)?.html ?? "<p>Could not render this file.</p>"
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 1000)) { _ in
            Data(HTMLTemplate.staticPage(body: html).utf8)
        }
    }
}
