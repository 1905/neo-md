import AppKit
import WebKit
import MDCore

/// The Render view: a `WKWebView` that loads `Template.page` once and updates the article through JS.
@MainActor
final class PreviewWebView: NSView {
    /// Source line at the top of the visible area, posted by the page on scroll (throttled to 100 ms).
    var onVisibleLine: ((Int) -> Void)?

    /// Base folder for `mdv-asset://` (images) and relative `.md` links.
    var documentFolder: URL? {
        didSet { assetHandler.documentFolder = documentFolder }
    }

    /// True for the Split tab preview: adds class `split` to `<body>` (narrower padding, full width).
    var isSplit = false {
        didSet { applyBodyClass() }
    }

    private let webView: WKWebView
    private let assetHandler = AssetSchemeHandler()
    private var pageLoaded = false
    private var pendingHTML: String?
    private var pendingLine: Int?
    private var lastHTML: String?
    /// The typography CSS the page has now. Nil after a (re)load, so the next apply always runs.
    private var appliedTypography: String?

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assetHandler, forURLScheme: AssetSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)

        // The content controller retains its handler. A weak proxy avoids a retain cycle.
        config.userContentController.add(WeakMessageHandler(self), name: "visibleLine")

        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: Settings.didChange, object: nil)
        loadTemplate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Public API

    /// Replaces the article body and keeps the scroll offset. Calls before the page loads are queued.
    func update(html: String) {
        lastHTML = html
        guard pageLoaded else {
            pendingHTML = html
            return
        }
        webView.evaluateJavaScript("update(\(Self.jsStringLiteral(html)))", completionHandler: nil)
    }

    func scrollToLine(_ line: Int) {
        guard pageLoaded else {
            pendingLine = line
            return
        }
        webView.evaluateJavaScript("scrollToLine(\(line))", completionHandler: nil)
    }

    func showError(_ message: String) {
        update(html: "<p class=\"error\">\(Self.escapeHTML(message))</p>")
    }

    /// Selects the next (or previous) match, wrapping, case-insensitive. `completion(true)` = a match was found.
    func find(_ string: String, backwards: Bool, completion: @escaping (Bool) -> Void) {
        guard !string.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(string, configuration: config) { result in
            completion(result.matchFound)
        }
    }

    /// Gives keyboard focus to the page (after the find bar closes).
    func focusPage() {
        window?.makeFirstResponder(webView)
    }

    // MARK: - Page

    private func loadTemplate() {
        pageLoaded = false
        appliedTypography = nil
        pendingHTML = lastHTML
        webView.loadHTMLString(Template.page, baseURL: URL(string: "\(AssetSchemeHandler.scheme)://\(AssetSchemeHandler.host)/"))
    }

    private func pageDidLoad() {
        pageLoaded = true
        applyTypography()
        applyAccent()
        applyBodyClass()
        if let html = pendingHTML {
            pendingHTML = nil
            update(html: html)
        }
        if let line = pendingLine {
            pendingLine = nil
            scrollToLine(line)
        }
    }

    private func applyBodyClass() {
        guard pageLoaded else { return }
        webView.evaluateJavaScript("document.body.classList.toggle(\"split\", \(isSplit))", completionHandler: nil)
    }

    @objc private func settingsDidChange(_ note: Notification) {
        applyTypography()
    }

    /// Sets the reading font and text size from `Settings` on the page. Skips the call if nothing changed.
    func applyTypography() {
        guard pageLoaded else { return }
        let settings = Settings.shared
        let css = HTMLTemplate.typographyCSS(readingFont: settings.readingFont,
                                             scale: FontScale.factor(step: settings.fontScale))
        guard css != appliedTypography else { return }
        appliedTypography = css
        webView.evaluateJavaScript("setTypography(\(Self.jsStringLiteral(css)))", completionHandler: nil)
    }

    @objc private func systemColorsChanged(_ note: Notification) {
        applyAccent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccent()
    }

    private func applyAccent() {
        guard pageLoaded else { return }
        var hex = "#0a64d8"
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                hex = String(format: "#%02x%02x%02x",
                             Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()),
                             Int((rgb.blueComponent * 255).rounded()))
            }
        }
        webView.evaluateJavaScript("setAccent(\(Self.jsStringLiteral(hex)))", completionHandler: nil)
    }

    fileprivate func receivedVisibleLine(_ body: Any) {
        if let line = (body as? NSNumber)?.intValue {
            onVisibleLine?(line)
        }
    }

    // MARK: - Links

    fileprivate func handleLink(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let folder = documentFolder,
              let file = AssetSchemeHandler.resolve(url, in: folder),
              WelcomeWindowController.markdownExtensions.contains(file.pathExtension.lowercased()) else { return }
        WelcomeWindowController.open([file])
    }

    // MARK: - Helpers

    /// A JS string literal for `s`: the JSON array `["…"]` indexed with `[0]`.
    static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return "\(json)[0]"
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension PreviewWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the template load itself may navigate. Links open elsewhere or do nothing.
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url { handleLink(url) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(pageLoaded ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageDidLoad()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The web process crashed: reload the page. `loadTemplate` queues the last HTML again.
        loadTemplate()
    }
}

/// Forwards script messages to a `PreviewWebView` without retaining it.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: PreviewWebView?

    init(_ target: PreviewWebView) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.receivedVisibleLine(message.body)
    }
}
