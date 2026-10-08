public struct OutlineItem: Equatable, Sendable {
    public let level: Int        // 1...6
    public let text: String      // plain text of the heading, inline markup removed
    public let line: Int         // 1-based source line where the heading starts

    public init(level: Int, text: String, line: Int) {
        self.level = level
        self.text = text
        self.line = line
    }
}

public struct RenderResult: Equatable, Sendable {
    public let html: String      // HTML body fragment, no <html>/<body>
    public let outline: [OutlineItem]

    public init(html: String, outline: [OutlineItem]) {
        self.html = html
        self.outline = outline
    }
}
