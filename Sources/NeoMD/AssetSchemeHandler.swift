import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `mdv-asset://doc/<absolute file path>`. The page base is the document folder
/// (`baseURL(for:)`), so relative links and `../` paths resolve to absolute paths.
/// Assets are served only from inside `documentFolder`: any other path gets HTTP 403.
/// A missing file gets 404.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdv-asset"
    static let host = "doc"

    var documentFolder: URL?

    /// Tasks that WebKit has not stopped yet. Only touched on the main thread.
    private var activeTasks = Set<ObjectIdentifier>()

    /// `mdv-asset://doc/<percent-encoded absolute folder path>/`, or `mdv-asset://doc/` without a folder.
    static func baseURL(for folder: URL?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var path = folder?.standardizedFileURL.path ?? "/"
        if !path.hasSuffix("/") { path += "/" }
        // The `path` setter percent-encodes spaces, `%`, `?`, `#` and non-ASCII.
        components.path = path
        return components.url ?? URL(string: "\(scheme)://\(host)/")!
    }

    /// Maps an `mdv-asset://doc/…` URL to the absolute file URL it names, anywhere on disk.
    /// Returns nil for another scheme or host, or for the root path.
    static func fileURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        // `URL.path` is percent-decoded. Standardizing removes `.` and `..`.
        let file = URL(fileURLWithPath: url.path).standardizedFileURL
        guard file.path != "/" else { return nil }
        return file
    }

    /// Like `fileURL(for:)`, but only for a file inside `folder`. Asset loads use this.
    static func resolve(_ url: URL, in folder: URL) -> URL? {
        guard let file = fileURL(for: url) else { return nil }
        let base = folder.standardizedFileURL.path
        let basePath = base.hasSuffix("/") ? base : base + "/"
        guard file.path.hasPrefix(basePath) else { return nil }
        return file
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
