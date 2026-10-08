import Foundation
import Testing
@testable import MDCore

@Test func cssCoversLightDarkAndAccent() {
    let css = HTMLTemplate.css
    #expect(!css.isEmpty)
    #expect(css.contains("prefers-color-scheme: dark"))
    #expect(css.contains("var(--accent)"))
    #expect(css.contains("max-width: 100%"))
}

@Test func staticPageEmbedsCssCspAndBody() {
    let body = "<h1 data-sourcepos=\"1:1-1:7\">Привет</h1>"
    let page = HTMLTemplate.staticPage(body: body)
    #expect(page.contains(HTMLTemplate.css))
    #expect(page.contains(
        #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">"#
    ))
    #expect(page.contains("default-src 'none'"))
    #expect(page.contains(body))
    #expect(page.hasPrefix("<!DOCTYPE html>"))
}

@Test func staticPageHasNoScript() throws {
    let html = try #require(MarkdownRenderer.render("# Title\n\n<script>alert(1)</script>\n")).html
    let page = HTMLTemplate.staticPage(body: html)
    #expect(!page.lowercased().contains("<script"))
}

@Test func cssUsesTypographyVariablesAndEm() {
    let css = HTMLTemplate.css
    #expect(css.contains("var(--reading-size)"))
    #expect(css.contains("var(--reading-font)"))
    #expect(css.contains("body.split article { max-width: none; padding: 0 44px; font-size: var(--split-size); }"))
    let expected = [
        "h1 { font-size: 1.935em;", "h2 { font-size: 1.355em;", "h3 { font-size: 0.774em;",
        "h4 { font-size: 1.032em;", "h5 { font-size: 0.903em;", "h6 { font-size: 0.839em;",
    ]
    for rule in expected {
        #expect(css.contains(rule), "\(rule)")
    }
    #expect(css.contains("font-size: .86em"))
    #expect(css.contains("font-size: 0.806em"))
    // No fixed px font sizes remain in the stylesheet.
    #expect(css.range(of: #"font-size: [0-9.]+px"#, options: .regularExpression) == nil)
}

@Test func typographyCSSDefault() {
    let css = HTMLTemplate.typographyCSS(readingFont: "", scale: 1)
    #expect(css.hasPrefix(":root{"))
    #expect(css.contains("--reading-font:-apple-system, BlinkMacSystemFont"))
    #expect(css.contains("--reading-size:15.5px"))
    #expect(css.contains("--split-size:14.5px"))
}

@Test func typographyCSSFontAndScale() {
    let css = HTMLTemplate.typographyCSS(readingFont: "Georgia", scale: 1.1)
    #expect(css.contains(#"--reading-font:"Georgia", -apple-system"#))
    #expect(css.contains("--reading-size:17.05px"))
    #expect(css.contains("--split-size:15.95px"))
}

@Test func typographyCSSEscapesFamily() {
    let css = HTMLTemplate.typographyCSS(readingFont: #"Bad"Font\x</style>"#, scale: 1)
    #expect(css.contains(#"--reading-font:"Bad\"Font\\x\3c /style>""#))
    #expect(!css.contains("</style"))
}

@Test func exportPageContent() {
    let body = "<h1>Hello</h1><p>World</p>"
    let page = HTMLTemplate.exportPage(body: body, title: "notes.md", readingFont: "Georgia", scale: 1.25)
    #expect(page.hasPrefix("<!DOCTYPE html>"))
    #expect(page.contains(#"<meta charset="utf-8">"#))
    #expect(page.contains("<title>notes.md</title>"))
    #expect(page.contains(HTMLTemplate.css))
    #expect(page.contains(body))
    #expect(page.contains(#"--reading-font:"Georgia""#))
    #expect(page.contains("--reading-size:19.375px"))
    #expect(!page.lowercased().contains("<script"))
}

@Test func exportPageEscapesTitle() {
    let page = HTMLTemplate.exportPage(body: "", title: "a<b>&\"c", readingFont: "", scale: 1)
    #expect(page.contains("<title>a&lt;b&gt;&amp;&quot;c</title>"))
}

@Test func staticPageKeepsDefaultTypography() {
    let page = HTMLTemplate.staticPage(body: "x")
    #expect(page.contains(HTMLTemplate.typographyCSS(readingFont: "", scale: 1)))
}
