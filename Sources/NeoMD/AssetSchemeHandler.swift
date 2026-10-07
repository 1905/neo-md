import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `mdv-asset://doc/<path>` from `documentFolder/<path>`.
/// A path that leaves the folder gets HTTP 403. A missing file gets 404.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdv-asset"
    static let host = "doc"

    var documentFolder: URL?

    /// Tasks that WebKit has not stopped yet. Only touched on the main thread.
    private var activeTasks = Set<ObjectIdentifier>()

    /// Maps an `mdv-asset://doc/…` URL to a file URL inside `folder`.
    /// Returns nil when the URL has another scheme or host, or when the path leaves the folder.
    static func resolve(_ url: URL, in folder: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let base = folder.standardizedFileURL
        // `URL.path` is percent-decoded.
        let relative = url.path.drop { $0 == "/" }
        guard !relative.isEmpty else { return nil }
        let resolved = base.appendingPathComponent(String(relative)).standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard resolved.path.hasPrefix(basePath) else { return nil }
        return resolved
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard let folder = documentFolder, let file = Self.resolve(url, in: folder) else {
            respond(urlSchemeTask, url: url, status: 403, mime: "text/plain", data: Data())
            return
        }

        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: file)
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            DispatchQueue.main.async {
                guard let self, self.activeTasks.remove(id) != nil else { return }
                if let data {
                    self.respond(urlSchemeTask, url: url, status: 200, mime: mime, data: data)
                } else {
                    self.respond(urlSchemeTask, url: url, status: 404, mime: "text/plain", data: Data())
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, mime: String, data: Data) {
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
        ]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
