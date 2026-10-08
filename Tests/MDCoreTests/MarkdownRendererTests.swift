import Foundation
import Testing
@testable import MDCore

private func fixtureText() throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: "sample-ru", withExtension: "md", subdirectory: "Fixtures")
    )
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func renderResultStoresValues() {
    let item = OutlineItem(level: 1, text: "Title", line: 1)
    let result = RenderResult(html: "<h1>Title</h1>", outline: [item])
    #expect(result.outline == [item])
    #expect(result.html == "<h1>Title</h1>")
}

@Test func fixtureOutlineMatchesHeadings() throws {
    let text = try fixtureText()
    let result = try #require(MarkdownRenderer.render(text))
    let outline = result.outline

    #expect(outline.filter { $0.level == 1 }.count == 1)
    #expect(outline.filter { $0.level == 2 }.count == 26)
    #expect(outline.filter { $0.level == 3 }.count == 104)
    #expect(outline.count == 131)
    #expect(outline[1].text == "C01")

    // Every heading line in the source, in order, as (line, level, text).
    let lines = text.components(separatedBy: "\n")
    var expected: [OutlineItem] = []
    for (index, line) in lines.enumerated() {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { continue }
        let title = String(line.dropFirst(hashes + 1))
        expected.append(OutlineItem(level: hashes, text: title, line: index + 1))
    }
    #expect(outline.map(\.line) == expected.map(\.line))
    #expect(outline.map(\.level) == expected.map(\.level))
    // Headings in the fixture have no inline markup, so the plain text is the source text.
    #expect(outline.map(\.text) == expected.map(\.text))
}

@Test func blockTagsCarrySourcepos() throws {
    let extra = """

    > цитата

    | a | b |
    |---|---|
    | 1 | 2 |

    ```
    code
    ```

    #### h4

    ##### h5

    ###### h6
    """
    let html = try #require(MarkdownRenderer.render(try fixtureText() + extra)).html

    let pattern = #"<(h[1-6]|p|ul|li|pre|blockquote|table|hr)(?=[\s>/])[^>]*>"#
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = html as NSString
    let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
    let tags = Set(matches.map { ns.substring(with: $0.range(at: 1)) })
    #expect(tags.isSuperset(of: ["h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "li", "pre", "blockquote", "table", "hr"]))
    for match in matches {
        let tag = ns.substring(with: match.range)
        #expect(tag.contains("data-sourcepos=\""), "missing sourcepos: \(tag)")
    }
}

@Test func cyrillicSurvives() throws {
    let html = try #require(MarkdownRenderer.render("Привет, мир")).html
    #expect(html.contains("Привет, мир"))
}

@Test func rawHTMLIsOmitted() throws {
    let html = try #require(MarkdownRenderer.render("<script>alert(1)</script>")).html
    #expect(html.contains("<!-- raw HTML omitted -->"))
    #expect(!html.contains("<script>"))
}

@Test func gfmExtensionsAreOn() throws {
    let table = try #require(MarkdownRenderer.render("| a | b |\n|---|---|\n| 1 | 2 |\n")).html
    #expect(table.contains("<table"))

    let strike = try #require(MarkdownRenderer.render("~~x~~")).html
    #expect(strike.contains("<del>"))

    let link = try #require(MarkdownRenderer.render("see https://example.com")).html
    #expect(link.contains("<a href=\"https://example.com\""))

    let task = try #require(MarkdownRenderer.render("- [ ] a")).html
    #expect(task.contains("type=\"checkbox\""))
}

@Test func headingTextStripsInlineMarkup() throws {
    let result = try #require(MarkdownRenderer.render("# Hello **bold** `code`"))
    #expect(result.outline == [OutlineItem(level: 1, text: "Hello bold code", line: 1)])
}

@Test func emptyInputRendersNothing() throws {
    let result = try #require(MarkdownRenderer.render(""))
    #expect(result.html == "")
    #expect(result.outline == [])
}
