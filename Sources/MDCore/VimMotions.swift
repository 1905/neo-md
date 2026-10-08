import Foundation

/// `d c y`: what an operator does with the range of a motion.
enum VimOperator: String {
    case delete = "d", change = "c", yank = "y"
}

/// A cursor motion. `target` gives the raw position; the engine clamps it to a
/// normal-mode cursor for plain movement, and operators turn it into a range
/// with `linewise` and `inclusive`.
enum VimMotion: Equatable {
    case left, right, up, down
    case wordForward, wordBackward, wordEnd
    case lineStart, firstNonBlank, lineEnd
    /// `gg` / `G`: the count is a 1-based line number. Without a count: first / last line.
    case firstLine, lastLine

    var isLinewise: Bool {
        switch self {
        case .up, .down, .firstLine, .lastLine: return true
        default: return false
        }
    }

    /// Inclusive motions land on the last character the operator covers.
    var isInclusive: Bool { self == .wordEnd || self == .lineEnd }

    /// Plain movement that cannot move beeps, as in Vim.
    var beepsWhenStuck: Bool {
        switch self {
        case .left, .right, .up, .down, .wordForward, .wordBackward, .wordEnd: return true
        default: return false
        }
    }
}

struct MotionTarget: Equatable {
    /// Raw target offset. `right` and `wordForward` may return the line end or
    /// `text.length` (exclusive end); `lineEnd` and `wordEnd` return the last
    /// character (inclusive end).
    var position: Int
    var linewise: Bool
    var inclusive: Bool
    /// Grapheme column `j`/`k` should aim for next. nil = the column of `position`.
    /// `Int.max` after `$`.
    var column: Int?
}

extension VimMotion {
    func target(from cursor: Int, count: Int?, in s: NSString, preferredColumn: Int?) -> MotionTarget {
        let n = max(count ?? 1, 1)
        let ln = TextNav.line(at: cursor, in: s)
        var p = cursor
        var column: Int?

        switch self {
        case .left:
            for _ in 0..<n {
                guard p > ln.start else { break }
                p = TextNav.previousGrapheme(before: p, in: s)
            }
        case .right:
            for _ in 0..<n {
                guard p < ln.contentsEnd else { break }
                p = TextNav.nextGrapheme(after: p, in: s)
            }
        case .up, .down:
            let col = preferredColumn ?? TextNav.column(of: cursor, in: ln, s: s)
            let index = TextNav.lineIndex(at: cursor, in: s)
            let targetIndex = self == .down ? index + n : max(index - n, 0)
            let target = TextNav.line(index: targetIndex, in: s)
            p = TextNav.offset(ofColumn: col, in: target, s: s)
            column = col
        case .wordForward:
            for _ in 0..<n { p = TextNav.nextWordStart(from: p, in: s) }
        case .wordBackward:
            for _ in 0..<n { p = TextNav.previousWordStart(from: p, in: s) }
        case .wordEnd:
            for _ in 0..<n { p = TextNav.wordEnd(from: p, in: s) }
        case .lineStart:
            p = ln.start
        case .firstNonBlank:
            p = TextNav.firstNonBlank(of: ln, in: s)
        case .lineEnd:
            let target = TextNav.line(index: TextNav.lineIndex(at: cursor, in: s) + n - 1, in: s)
            p = TextNav.lastCharacter(of: target, in: s)
            column = Int.max
        case .firstLine, .lastLine:
            let index: Int
            if let count { index = count - 1 } else if self == .firstLine { index = 0 } else { index = Int.max }
            p = TextNav.firstNonBlank(of: TextNav.line(index: index, in: s), in: s)
        }
        return MotionTarget(position: p, linewise: isLinewise, inclusive: isInclusive, column: column)
    }
}

extension VimMotion {
    /// Vim's `cw`: on a word it acts as `ce` but never leaves the current word,
    /// so `cw` on the last character changes only that character. On a blank,
    /// `cw` changes one character; with a count it acts as `dw`.
    static func changeWordTarget(from cursor: Int, count: Int?, in s: NSString) -> MotionTarget? {
        guard cursor < s.length else { return nil }
        let n = max(count ?? 1, 1)
        let cls = TextNav.charClass(at: cursor, in: s)
        if cls == .blank {
            guard n == 1, s.character(at: cursor) != TextNav.newline else { return nil }
            return MotionTarget(position: cursor, linewise: false, inclusive: true, column: nil)
        }
        var p = cursor
        while true {
            let next = TextNav.nextGrapheme(after: p, in: s)
            if next >= s.length || TextNav.charClass(at: next, in: s) != cls { break }
            p = next
        }
        for _ in 1..<n { p = TextNav.wordEnd(from: p, in: s) }
        return MotionTarget(position: p, linewise: false, inclusive: true, column: nil)
    }
}
