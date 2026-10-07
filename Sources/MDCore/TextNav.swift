import Foundation

/// One logical line of a buffer, in UTF-16 offsets.
struct TextLine: Equatable {
    /// First offset of the line.
    let start: Int
    /// Offset after the last visible character (before `\r\n` or `\n`).
    let contentsEnd: Int
    /// Offset after the line terminator; equals `contentsEnd` on the last line without one.
    let end: Int
    /// True if a `\n` ends the line, so another line follows.
    let hasNewline: Bool

    var contents: NSRange { NSRange(location: start, length: contentsEnd - start) }
    var isEmpty: Bool { contentsEnd == start }
}

/// Word classes for `w b e`: runs of the same class form one word.
enum CharClass { case blank, word, punct }

/// Grapheme-aware helpers on NSString UTF-16 offsets. A grapheme is one
/// `rangeOfComposedCharacterSequence(at:)`, so a Cyrillic letter, an emoji
/// or a letter with a combining mark is one step.
enum TextNav {
    static let newline: unichar = 0x0A
    static let carriageReturn: unichar = 0x0D

    // MARK: graphemes

    static func nextGrapheme(after i: Int, in s: NSString) -> Int {
        guard i < s.length else { return s.length }
        return NSMaxRange(s.rangeOfComposedCharacterSequence(at: max(i, 0)))
    }

    static func previousGrapheme(before i: Int, in s: NSString) -> Int {
        guard i > 0 else { return 0 }
        return s.rangeOfComposedCharacterSequence(at: min(i, s.length) - 1).location
    }

    /// Start of the grapheme that contains `i`.
    static func graphemeStart(at i: Int, in s: NSString) -> Int {
        guard i > 0 else { return 0 }
        guard i < s.length else { return s.length }
        return s.rangeOfComposedCharacterSequence(at: i).location
    }

    // MARK: lines

    static func line(at i: Int, in s: NSString) -> TextLine {
        let i = min(max(i, 0), s.length)
        let before = s.range(of: "\n", options: [.literal, .backwards],
                             range: NSRange(location: 0, length: i))
        let start = before.location == NSNotFound ? 0 : NSMaxRange(before)
        let after = s.range(of: "\n", options: .literal,
                            range: NSRange(location: i, length: s.length - i))
        let newlineAt = after.location == NSNotFound ? s.length : after.location
        var contentsEnd = newlineAt
        if contentsEnd > start, s.character(at: contentsEnd - 1) == carriageReturn {
            contentsEnd -= 1
        }
        let hasNewline = after.location != NSNotFound
        return TextLine(start: start, contentsEnd: contentsEnd,
                        end: hasNewline ? newlineAt + 1 : newlineAt, hasNewline: hasNewline)
    }

    /// Contents of the line at `i`, without the terminator.
    static func lineRange(at i: Int, in s: NSString) -> NSRange { line(at: i, in: s).contents }

    /// Zero-based index of the line that contains `i`.
    static func lineIndex(at i: Int, in s: NSString) -> Int {
        var count = 0
        var from = 0
        let limit = min(max(i, 0), s.length)
        while from < limit {
            let r = s.range(of: "\n", options: .literal,
                            range: NSRange(location: from, length: limit - from))
            if r.location == NSNotFound { break }
            count += 1
            from = NSMaxRange(r)
        }
        return count
    }

    /// The line with zero-based `index`, or the last line if the buffer is shorter.
    static func line(index: Int, in s: NSString) -> TextLine {
        var ln = line(at: 0, in: s)
        var n = 0
        while n < index, ln.hasNewline {
            ln = line(at: ln.end, in: s)
            n += 1
        }
        return ln
    }

    /// Start of the last grapheme on the line, or the line start if it is empty.
    static func lastCharacter(of ln: TextLine, in s: NSString) -> Int {
        ln.isEmpty ? ln.start : previousGrapheme(before: ln.contentsEnd, in: s)
    }

    /// First character that is not a space or tab. On a blank line: the last character.
    static func firstNonBlank(of ln: TextLine, in s: NSString) -> Int {
        var i = ln.start
        while i < ln.contentsEnd {
            let c = s.character(at: i)
            if c != 0x20, c != 0x09 { return i }
            i += 1
        }
        return lastCharacter(of: ln, in: s)
    }

    /// Number of graphemes between the line start and `i`.
    static func column(of i: Int, in ln: TextLine, s: NSString) -> Int {
        var col = 0
        var p = ln.start
        while p < i, p < ln.contentsEnd {
            p = nextGrapheme(after: p, in: s)
            col += 1
        }
        return col
    }

    /// Offset of grapheme column `col`, clamped to the last character of the line.
    static func offset(ofColumn col: Int, in ln: TextLine, s: NSString) -> Int {
        let last = lastCharacter(of: ln, in: s)
        var p = ln.start
        var n = 0
        while n < col, p < last {
            p = nextGrapheme(after: p, in: s)
            n += 1
        }
        return p
    }

    /// A valid normal-mode cursor: on a grapheme start, never on the line end
    /// unless the line is empty.
    static func normalCursor(_ i: Int, in s: NSString) -> Int {
        let ln = line(at: i, in: s)
        if i >= ln.contentsEnd { return lastCharacter(of: ln, in: s) }
        return graphemeStart(at: i, in: s)
    }

    // MARK: words

    static func charClass(at i: Int, in s: NSString) -> CharClass {
        let c = s.character(at: i)
        var scalar = Unicode.Scalar(c)
        if scalar == nil, UTF16.isLeadSurrogate(c), i + 1 < s.length {
            let lo = s.character(at: i + 1)
            if UTF16.isTrailSurrogate(lo) {
                scalar = Unicode.Scalar(0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(lo) - 0xDC00))
            }
        }
        guard let u = scalar else { return .punct }
        if CharacterSet.whitespacesAndNewlines.contains(u) { return .blank }
        if u == "_" || CharacterSet.alphanumerics.contains(u) { return .word }
        return .punct
    }

    /// True at the `\n` of an empty line. Vim treats an empty line as a word.
    static func isEmptyLine(at i: Int, in s: NSString) -> Bool {
        i < s.length && s.character(at: i) == newline && (i == 0 || s.character(at: i - 1) == newline)
    }

    /// Vim `w`: start of the next word, or `s.length` if there is none.
    static func nextWordStart(from i: Int, in s: NSString) -> Int {
        let len = s.length
        guard i < len else { return len }
        var p = i
        let start = charClass(at: p, in: s)
        if start != .blank {
            while p < len, charClass(at: p, in: s) == start { p = nextGrapheme(after: p, in: s) }
        }
        while p < len, charClass(at: p, in: s) == .blank {
            if s.character(at: p) == newline, isEmptyLine(at: p + 1, in: s) { return p + 1 }
            p = nextGrapheme(after: p, in: s)
        }
        return p
    }

    /// Vim `e`: last character of the current or next word. Stays on the last
    /// character of the buffer if no word follows.
    static func wordEnd(from i: Int, in s: NSString) -> Int {
        let len = s.length
        guard len > 0 else { return 0 }
        var p = nextGrapheme(after: i, in: s)
        while p < len, charClass(at: p, in: s) == .blank { p = nextGrapheme(after: p, in: s) }
        guard p < len else { return previousGrapheme(before: len, in: s) }
        let cls = charClass(at: p, in: s)
        while true {
            let n = nextGrapheme(after: p, in: s)
            if n >= len || charClass(at: n, in: s) != cls { return p }
            p = n
        }
    }

    /// Vim `b`: start of the current or previous word. Stops at empty lines.
    static func previousWordStart(from i: Int, in s: NSString) -> Int {
        guard i > 0 else { return 0 }
        var p = previousGrapheme(before: i, in: s)
        while charClass(at: p, in: s) == .blank {
            if isEmptyLine(at: p, in: s) || p == 0 { return p }
            p = previousGrapheme(before: p, in: s)
        }
        let cls = charClass(at: p, in: s)
        while p > 0 {
            let q = previousGrapheme(before: p, in: s)
            if charClass(at: q, in: s) != cls { break }
            p = q
        }
        return p
    }
}
