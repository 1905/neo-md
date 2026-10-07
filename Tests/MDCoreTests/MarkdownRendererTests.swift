import Testing
@testable import MDCore

@Test func renderResultStoresValues() {
    let item = OutlineItem(level: 1, text: "Title", line: 1)
    let result = RenderResult(html: "<h1>Title</h1>", outline: [item])
    #expect(result.outline == [item])
    #expect(result.html == "<h1>Title</h1>")
}
