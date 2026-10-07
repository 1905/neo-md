import Foundation
import Testing
@testable import MDCore

private func spans(_ s: String) -> [HighlightSpan] {
    let ns = s as NSString
    return MarkdownHighlighter.spans(in: ns, lineRange: NSRange(location: 0, length: ns.length))
}

/// Spans for the line with the given zero-based index only.
private func spans(_ s: String, line index: Int) -> [HighlightSpan] {
    let ns = s as NSString
    var start = 0
    for _ in 0..<index {
        let r = ns.lineRange(for: NSRange(location: start, length: 0))
        start = NSMaxRange(r)
    }
    let r = ns.lineRange(for: NSRange(location: start, length: 0))
    return MarkdownHighlighter.spans(in: ns, lineRange: r)
}

private func span(_ loc: Int, _ len: Int, _ token: MarkdownToken) -> HighlightSpan {
    HighlightSpan(range: NSRange(location: loc, length: len), token: token)
}

private func tokens(_ list: [HighlightSpan]) -> [MarkdownToken] { list.map(\.token) }

@Test func headingMarkerAndText() {
    let s = spans("# Title")
    #expect(s.contains(span(0, 2, .headingMarker)))
    #expect(s.contains(span(2, 5, .heading)))
}

@Test func headingNeedsSpaceAfterHashes() {
    #expect(!tokens(spans("#hashtag")).contains(.heading))
    #expect(!tokens(spans("####### seven")).contains(.heading))
    #expect(spans("### Three").contains(span(0, 4, .headingMarker)))
}

@Test func cyrillicHeadingLengthIsUTF16() {
    let s = spans("# Привет")
    #expect(s.contains(span(2, ("Привет" as NSString).length, .heading)))
}

@Test func emojiShiftsLaterRangesInUTF16() {
    // "😀" is two UTF-16 units, so "**b**" starts at 3.
    let s = spans("😀 **b**")
    #expect(s.contains(span(3, 2, .boldMarker)))
    #expect(s.contains(span(5, 1, .bold)))
}

@Test func listMarkers() {
    #expect(spans("- item").contains(span(0, 1, .listMarker)))
    #expect(spans("* item").contains(span(0, 1, .listMarker)))
    #expect(spans("  + item").contains(span(2, 1, .listMarker)))
    #expect(spans("12. item").contains(span(0, 3, .listMarker)))
    #expect(!tokens(spans("-item")).contains(.listMarker))
}

@Test func codeSpan() {
    #expect(spans("a `b` c") == [span(2, 3, .codeSpan)])
    #expect(spans("x ``a ` b`` y").contains(span(2, 9, .codeSpan)))
    #expect(!tokens(spans("a `unclosed")).contains(.codeSpan))
}

@Test func headingInsideCodeSpanIsNotHeading() {
    let s = spans("`# not heading`")
    #expect(!tokens(s).contains(.heading))
    #expect(!tokens(s).contains(.headingMarker))
    #expect(s.contains(span(0, 15, .codeSpan)))
}

@Test func boldInsideCodeSpanIsIgnored() {
    #expect(spans("`**x**`") == [span(0, 7, .codeSpan)])
}

@Test func fenceLines() {
    #expect(spans("```") == [span(0, 3, .fence)])
    #expect(spans("```swift") == [span(0, 8, .fence)])
    #expect(spans("~~~") == [span(0, 3, .fence)])
    #expect(spans("<<<ORIGINAL") == [span(0, 11, .fence)])
    #expect(spans("ORIGINAL>>>") == [span(0, 11, .fence)])
}

@Test func originalMarkersDoNotOpenCodeBlock() {
    let text = "<<<ORIGINAL\n# h\nORIGINAL>>>\n"
    #expect(spans(text, line: 0) == [span(0, 11, .fence)])
    #expect(spans(text, line: 1).contains(span(14, 1, .heading)))
    #expect(spans(text, line: 2) == [span(16, 11, .fence)])
}

@Test func bold() {
    let s = spans("**x**")
    #expect(s == [span(0, 2, .boldMarker), span(2, 1, .bold), span(3, 2, .boldMarker)])
    #expect(spans("__y__").contains(span(2, 1, .bold)))
    #expect(!tokens(spans("**unclosed")).contains(.bold))
    #expect(!tokens(spans("****")).contains(.bold))
}

@Test func escapedMarkersAreIgnored() {
    #expect(spans(#"\*\*x\*\*"#).isEmpty)
    #expect(spans(#"\`code\`"#).isEmpty)
}

@Test func link() {
    #expect(spans("[t](u)") == [span(0, 6, .link)])
    #expect(spans("see [a b](http://x.y/z) end").contains(span(4, 19, .link)))
    #expect(spans("![img](p.png)").contains(span(0, 13, .link)))
    #expect(!tokens(spans("[t] (u)")).contains(.link))
    #expect(!tokens(spans("[t](u")).contains(.link))
}

@Test func horizontalRule() {
    #expect(spans("---") == [span(0, 3, .hr)])
    #expect(spans("***") == [span(0, 3, .hr)])
    #expect(spans("- - -") == [span(0, 5, .hr)])
    #expect(spans("______") == [span(0, 6, .hr)])
    #expect(!tokens(spans("--")).contains(.hr))
    #expect(!tokens(spans("--- x")).contains(.hr))
}

@Test func fencedBlockContentHasNoTokens() {
    let text = "```\n# h\n- x **b** `c`\n```\nafter **b**\n"
    let s = spans(text)
    let ns = text as NSString
    let inner = NSRange(location: 4, length: ns.range(of: "\n```\n").location - 4)
    #expect(s.allSatisfy { NSIntersectionRange($0.range, inner).length == 0 })
    #expect(s.contains(span(0, 3, .fence)))
    let closing = ns.range(of: "\n```\n").location + 1
    #expect(s.contains(span(closing, 3, .fence)))
    #expect(tokens(s).contains(.bold))
}

@Test func fenceStateComesFromTextBeforeLineRange() {
    let text = "intro\n```\n# inside\n```\n# outside\n"
    #expect(spans(text, line: 2).isEmpty)
    #expect(spans(text, line: 3) == [span(19, 3, .fence)])
    #expect(spans(text, line: 4).contains(span(25, 7, .heading)))
}

@Test func closingFenceMustMatchOpeningKind() {
    let text = "~~~\n```\n# still code\n~~~\n# out\n"
    #expect(spans(text, line: 1).isEmpty)
    #expect(spans(text, line: 2).isEmpty)
    #expect(spans(text, line: 3) == [span(21, 3, .fence)])
    #expect(tokens(spans(text, line: 4)).contains(.heading))
}

@Test func longerOpeningFenceNeedsLongerClose() {
    let text = "````\n```\n# code\n````\n# out\n"
    #expect(spans(text, line: 1).isEmpty)
    #expect(spans(text, line: 2).isEmpty)
    #expect(tokens(spans(text, line: 4)).contains(.heading))
}

@Test func spansStayInsideLineRange() {
    let text = "# a\n# b\n# c\n"
    let s = spans(text, line: 1)
    #expect(s == [span(4, 2, .headingMarker), span(6, 1, .heading)])
}

@Test func crlfLineEndingsAreExcluded() {
    let text = "# T\r\n- x\r\n"
    let s = spans(text)
    #expect(s.contains(span(2, 1, .heading)))
    #expect(s.contains(span(5, 1, .listMarker)))
}

@Test func headingCanHoldInlineTokens() {
    let s = spans("## a `b`")
    #expect(s.contains(span(3, 5, .heading)))
    #expect(s.contains(span(5, 3, .codeSpan)))
}

@Test func emptyInput() {
    #expect(spans("").isEmpty)
    #expect(MarkdownHighlighter.spans(in: "abc", lineRange: NSRange(location: 3, length: 0)).isEmpty)
}

@Test func lastLineOfLargeDocumentIsFast() {
    // ~100 KB with many fences; the prescan must stay linear and cheap.
    var text = ""
    while text.utf16.count < 100_000 {
        text += "# Head **b** [l](u)\n- item `c`\n```\nlet x = 1\n```\nplain line of text here\n"
    }
    text += "# tail\n"
    let ns = text as NSString
    let last = ns.lineRange(for: NSRange(location: ns.length - 1, length: 0))
    let start = Date()
    for _ in 0..<100 {
        _ = MarkdownHighlighter.spans(in: ns, lineRange: last)
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(MarkdownHighlighter.spans(in: ns, lineRange: last).contains(span(last.location + 2, 4, .heading)))
    #expect(elapsed < 1.0, "100 calls took \(elapsed) s")
}

/// Unmatched openers must not rescan the rest of the line for each opener.
@Test(arguments: [
    String(repeating: "[", count: 20_000),
    String(repeating: "[", count: 19_999) + "]",
    String(repeating: "[](", count: 7_000),
    String(repeating: "**", count: 10_000),
    "**" + String(repeating: "a", count: 20_000),
    String(repeating: "*_", count: 10_000),
])
func longLineWithUnmatchedOpenersIsLinear(_ line: String) {
    let elapsed = ContinuousClock().measure { _ = spans(line) }
    #expect(elapsed < .milliseconds(200))
}

@Test func linkAfterABracketWithoutParenthesis() {
    #expect(spans("[a] [b](c)").contains(span(4, 6, .link)))
    #expect(spans("[a [b](c)").contains(span(0, 9, .link)))
    #expect(!tokens(spans("[a](b")).contains(.link))
}
