import Foundation

public enum MarkdownToken: Equatable, Sendable { case heading, headingMarker, listMarker, codeSpan, fence, boldMarker, bold, link, hr }

public struct HighlightSpan: Equatable, Sendable {
    public let range: NSRange
    public let token: MarkdownToken

    public init(range: NSRange, token: MarkdownToken) {
        self.range = range
        self.token = token
    }
}

/// Line-based Markdown syntax colouring for the raw editor.
///
/// It is not a full CommonMark parser. It finds the tokens the editor colours
/// and it keeps fenced-code state correct, so a partial re-colour of edited
/// lines gives the same result as a full pass.
public enum MarkdownHighlighter {
    /// Returns spans for the lines in `lineRange` (expanded to whole lines).
    /// All ranges are UTF-16 offsets into `text`, in the order block tokens,
    /// code spans, bold, links. Later spans can overlap earlier ones (for
    /// example a code span inside a heading), so apply them in order.
    public static func spans(in text: NSString, lineRange: NSRange) -> [HighlightSpan] {
        let length = text.length
        guard length > 0, lineRange.location <= length else { return [] }
        let clamped = NSRange(
            location: lineRange.location,
            length: min(lineRange.length, length - lineRange.location)
        )
        let lines = text.lineRange(for: clamped)
        let end = NSMaxRange(lines)
        guard end > lines.location else { return [] }

        // One copy of the prefix: the fence prescan and the line scan both read it.
        var buffer = [unichar](repeating: 0, count: end)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: end))

        return buffer.withUnsafeBufferPointer { chars in
            var scanner = LineScanner(chars: chars)
            var fence: Fence?

            // Prescan: fence lines only, from the text start to the first line.
            var i = 0
            while i < lines.location {
                let (contentEnd, next) = scanner.lineBounds(from: i, limit: lines.location)
                _ = scanner.updateFence(&fence, start: i, end: contentEnd)
                i = next
            }

            i = lines.location
            while i < end {
                let (contentEnd, next) = scanner.lineBounds(from: i, limit: end)
                scanner.scanLine(start: i, end: contentEnd, fence: &fence)
                i = next
            }
            return scanner.out
        }
    }
}

private struct Fence {
    let char: unichar
    let count: Int
}

private enum Ch {
    static let lf: unichar = 0x0A
    static let cr: unichar = 0x0D
    static let space: unichar = 0x20
    static let tab: unichar = 0x09
    static let hash: unichar = 0x23            // #
    static let star: unichar = 0x2A            // *
    static let plus: unichar = 0x2B            // +
    static let dash: unichar = 0x2D            // -
    static let underscore: unichar = 0x5F      // _
    static let backtick: unichar = 0x60        // `
    static let tilde: unichar = 0x7E           // ~
    static let backslash: unichar = 0x5C       // \
    static let bang: unichar = 0x21            // !
    static let openBracket: unichar = 0x5B     // [
    static let closeBracket: unichar = 0x5D    // ]
    static let openParen: unichar = 0x28       // (
    static let closeParen: unichar = 0x29      // )
    static let dot: unichar = 0x2E             // .
    static let zero: unichar = 0x30
    static let nine: unichar = 0x39

    static let originalOpen = Array("<<<ORIGINAL".utf16)
    static let originalClose = Array("ORIGINAL>>>".utf16)
}

private struct LineScanner {
    let chars: UnsafeBufferPointer<unichar>
    var out: [HighlightSpan] = []

    init(chars: UnsafeBufferPointer<unichar>) {
        self.chars = chars
    }

    // MARK: Lines

    /// Line terminators match `NSString.lineRange(for:)`: LF, CR, CRLF, NEL, LS, PS.
    func lineBounds(from start: Int, limit: Int) -> (contentEnd: Int, next: Int) {
        var i = start
        while i < limit {
            let c = chars[i]
            if c == Ch.lf || c == 0x0085 || c == 0x2028 || c == 0x2029 {
                return (i, i + 1)
            }
            if c == Ch.cr {
                if i + 1 < limit, chars[i + 1] == Ch.lf { return (i, i + 2) }
                return (i, i + 1)
            }
            i += 1
        }
        return (limit, limit)
    }

    private func isBlank(_ c: unichar) -> Bool { c == Ch.space || c == Ch.tab }

    /// Index after at most 3 leading spaces, or nil when the line is indented more.
    private func skipIndent(_ start: Int, _ end: Int) -> Int? {
        var i = start
        while i < end, chars[i] == Ch.space {
            i += 1
            if i - start > 3 { return nil }
        }
        return i
    }

    private func lastNonBlank(_ start: Int, _ end: Int) -> Int {
        var e = end
        while e > start, isBlank(chars[e - 1]) { e -= 1 }
        return e
    }

    private mutating func emit(_ loc: Int, _ len: Int, _ token: MarkdownToken) {
        out.append(HighlightSpan(range: NSRange(location: loc, length: len), token: token))
    }

    // MARK: Fences

    /// Updates the fenced-code state for one line. Returns true when the line
    /// opens or closes a fenced block.
    func updateFence(_ state: inout Fence?, start: Int, end: Int) -> Bool {
        guard let i = skipIndent(start, end), i < end else { return false }
        let c = chars[i]
        guard c == Ch.backtick || c == Ch.tilde else { return false }
        var j = i
        while j < end, chars[j] == c { j += 1 }
        let count = j - i
        guard count >= 3 else { return false }

        if let open = state {
            guard c == open.char, count >= open.count else { return false }
            while j < end {
                if !isBlank(chars[j]) { return false }
                j += 1
            }
            state = nil
            return true
        }
        if c == Ch.backtick {
            // A backtick fence info string must not contain a backtick.
            while j < end {
                if chars[j] == Ch.backtick { return false }
                j += 1
            }
        }
        state = Fence(char: c, count: count)
        return true
    }

    private func hasPrefix(_ prefix: [unichar], at i: Int, _ end: Int) -> Bool {
        guard end - i >= prefix.count else { return false }
        for k in 0..<prefix.count where chars[i + k] != prefix[k] { return false }
        return true
    }

    // MARK: Line scan

    mutating func scanLine(start: Int, end: Int, fence: inout Fence?) {
        let wasInFence = fence != nil
        if updateFence(&fence, start: start, end: end) {
            emit(start, end - start, .fence)
            return
        }
        if wasInFence || start == end { return }

        var first = start
        while first < end, isBlank(chars[first]) { first += 1 }
        if first == end { return }

        if hasPrefix(Ch.originalOpen, at: first, end) || hasPrefix(Ch.originalClose, at: first, end) {
            emit(start, end - start, .fence)
            return
        }
        if scanHorizontalRule(start, end) { return }

        var inlineStart = first
        if let after = scanHeading(start, end) {
            inlineStart = after
        } else if let after = scanListMarker(first, end) {
            inlineStart = after
        }
        scanInline(inlineStart, end)
    }

    /// `---`, `***`, `___`, spaces allowed between the characters.
    private mutating func scanHorizontalRule(_ start: Int, _ end: Int) -> Bool {
        guard let i = skipIndent(start, end), i < end else { return false }
        let c = chars[i]
        guard c == Ch.dash || c == Ch.star || c == Ch.underscore else { return false }
        var count = 0
        for k in i..<end {
            if chars[k] == c {
                count += 1
            } else if !isBlank(chars[k]) {
                return false
            }
        }
        guard count >= 3 else { return false }
        emit(i, lastNonBlank(i, end) - i, .hr)
        return true
    }

    /// ATX heading. Returns the index after the marker when the line is a heading.
    private mutating func scanHeading(_ start: Int, _ end: Int) -> Int? {
        guard let i = skipIndent(start, end) else { return nil }
        var j = i
        while j < end, chars[j] == Ch.hash { j += 1 }
        let level = j - i
        guard level >= 1, level <= 6 else { return nil }
        guard j == end || isBlank(chars[j]) else { return nil }
        while j < end, isBlank(chars[j]) { j += 1 }
        emit(i, j - i, .headingMarker)
        let textEnd = lastNonBlank(j, end)
        if textEnd > j { emit(j, textEnd - j, .heading) }
        return j
    }

    /// `-`, `*`, `+` or `1.` / `1)` followed by a blank. Returns the index after the marker.
    private mutating func scanListMarker(_ first: Int, _ end: Int) -> Int? {
        let c = chars[first]
        var markerEnd: Int
        if c == Ch.dash || c == Ch.star || c == Ch.plus {
            markerEnd = first + 1
        } else {
            var j = first
            while j < end, chars[j] >= Ch.zero, chars[j] <= Ch.nine, j - first < 9 { j += 1 }
            guard j > first, j < end, chars[j] == Ch.dot || chars[j] == Ch.closeParen else { return nil }
            markerEnd = j + 1
        }
        guard markerEnd < end, isBlank(chars[markerEnd]) else { return nil }
        emit(first, markerEnd - first, .listMarker)
        return markerEnd
    }

    // MARK: Inline

    private mutating func scanInline(_ start: Int, _ end: Int) {
        guard end > start else { return }
        // blocked[k - start] is true for escaped characters and code-span content.
        var blocked = [Bool](repeating: false, count: end - start)

        // Pass 1: escapes and code spans.
        var i = start
        while i < end {
            let c = chars[i]
            if c == Ch.backslash, i + 1 < end {
                blocked[i - start] = true
                blocked[i + 1 - start] = true
                i += 2
                continue
            }
            guard c == Ch.backtick else { i += 1; continue }
            var j = i
            while j < end, chars[j] == Ch.backtick { j += 1 }
            let run = j - i
            if let close = findBacktickRun(run, from: j, end) {
                let spanEnd = close + run
                emit(i, spanEnd - i, .codeSpan)
                for k in i..<spanEnd { blocked[k - start] = true }
                i = spanEnd
            } else {
                i = j
            }
        }

        func free(_ k: Int) -> Bool { !blocked[k - start] }

        // Pass 2: bold with `**` or `__`. Each scan searches a suffix of the previous
        // one, so once a marker has no closer, no later opener of it has one either.
        var starClosed = true, underscoreClosed = true
        i = start
        while i + 1 < end {
            let c = chars[i]
            guard (c == Ch.star ? starClosed : c == Ch.underscore && underscoreClosed),
                  chars[i + 1] == c, free(i), free(i + 1) else {
                i += 1
                continue
            }
            var j = i + 2
            var close: Int?
            while j + 1 < end {
                if chars[j] == c, chars[j + 1] == c, free(j), free(j + 1) { close = j; break }
                j += 1
            }
            if let close, close > i + 2 {
                emit(i, 2, .boldMarker)
                emit(i + 2, close - i - 2, .bold)
                emit(close, 2, .boldMarker)
                i = close + 2
            } else {
                if close == nil {
                    if c == Ch.star { starClosed = false } else { underscoreClosed = false }
                }
                i += 2
            }
        }

        // Pass 3: links and images, `[text](url)` / `![alt](src)`. Every `[` before `k`
        // finds the same `]` at `k`, and every later scan searches a suffix of this one,
        // so the pass stays linear: skip past `k`, or stop when a closer is missing.
        i = start
        while i < end {
            guard chars[i] == Ch.openBracket, free(i) else { i += 1; continue }
            var k = i + 1
            while k < end, !(chars[k] == Ch.closeBracket && free(k)) { k += 1 }
            guard k + 1 < end else { break }
            guard chars[k + 1] == Ch.openParen else { i = k + 1; continue }
            var m = k + 2
            while m < end, !(chars[m] == Ch.closeParen && free(m)) { m += 1 }
            guard m < end else { break }
            let linkStart = (i > start && chars[i - 1] == Ch.bang && free(i - 1)) ? i - 1 : i
            emit(linkStart, m + 1 - linkStart, .link)
            i = m + 1
        }
    }

    /// Start of the next run of exactly `run` backticks at or after `from`.
    private func findBacktickRun(_ run: Int, from: Int, _ end: Int) -> Int? {
        var i = from
        while i < end {
            guard chars[i] == Ch.backtick else { i += 1; continue }
            var j = i
            while j < end, chars[j] == Ch.backtick { j += 1 }
            if j - i == run { return i }
            i = j
        }
        return nil
    }
}
