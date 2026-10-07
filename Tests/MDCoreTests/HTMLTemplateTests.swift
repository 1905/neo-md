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
