import Foundation
import Testing
@testable import MDCore

struct CursorCase: CustomTestStringConvertible, Sendable {
    let text: String
    let cursor: Int
    let keys: String
    let expected: Int
    var testDescription: String { "\(keys) in \(text.debugDescription) from \(cursor)" }
    init(_ text: String, _ cursor: Int, _ keys: String, _ expected: Int) {
        self.text = text; self.cursor = cursor; self.keys = keys; self.expected = expected
    }
}

struct EditCase: CustomTestStringConvertible, Sendable {
    let text: String
    let cursor: Int
    let keys: String
    let expectedText: String
    let expectedCursor: Int
    let expectedMode: VimMode
    var testDescription: String { "\(keys) in \(text.debugDescription) from \(cursor)" }
    init(_ text: String, _ cursor: Int, _ keys: String,
         _ expectedText: String, _ expectedCursor: Int, _ expectedMode: VimMode) {
        self.text = text; self.cursor = cursor; self.keys = keys
        self.expectedText = expectedText; self.expectedCursor = expectedCursor
        self.expectedMode = expectedMode
    }
}

@Suite struct VimMotionTests {
    static let motions: [CursorCase] = [
        // h j k l and arrows
        .init("abc", 0, "l", 1),
        .init("abc", 0, "ll", 2),
        .init("abc", 2, "h", 1),
        .init("abc", 0, "<Right>", 1),
        .init("abc", 2, "<Left>", 1),
        .init("ab\ncd", 1, "j", 4),
        .init("ab\ncd", 1, "<Down>", 4),
        .init("ab\ncd", 4, "k", 1),
        .init("ab\ncd", 4, "<Up>", 1),
        .init("abc", 0, "10l", 2),
        .init("abcdefghijklmnop", 0, "10l", 10),
        // counts
        .init("a\nb\nc\nd\ne", 0, "3j", 6),
        .init("a\nb\nc", 0, "9j", 4),           // a big count stops at the last line
        // w b e
        .init("foo bar baz", 0, "w", 4),
        .init("foo bar baz", 0, "2w", 8),
        .init("foo.bar", 0, "w", 3),
        .init("foo.bar", 3, "w", 4),
        .init("foo  bar", 0, "w", 5),
        .init("foo\nbar", 0, "w", 4),
        .init("foo\n\nbar", 0, "w", 4),         // an empty line is a word
        .init("foo\n\nbar", 4, "w", 5),
        .init("foo bar", 4, "b", 0),
        .init("foo bar", 6, "b", 4),
        .init("foo.bar", 4, "b", 3),
        .init("foo\nbar", 4, "b", 0),
        .init("foo\n\nbar", 5, "b", 4),
        // An empty CRLF line is a word too: the cursor sits on its `\r`.
        .init("foo\r\n\r\nbar", 0, "w", 5),
        .init("foo\r\n\r\nbar", 5, "w", 7),
        .init("foo\r\n\r\n\r\nbar", 5, "w", 7),
        .init("foo\n\n\nbar", 4, "w", 5),
        .init("foo\r\n\r\nbar", 7, "b", 5),
        .init("foo\r\n\r\n\r\nbar", 7, "b", 5),
        .init("foo\n\n\nbar", 5, "b", 4),
        .init("\r\nfoo", 2, "b", 0),
        .init("\nfoo", 1, "b", 0),
        .init("foo\r\n\r\nbar", 2, "e", 9),
        .init("foo\n\nbar", 2, "e", 7),
        .init("foo bar", 0, "e", 2),
        .init("foo bar", 2, "e", 6),
        .init("foo.bar", 0, "e", 2),
        .init("foo.bar", 2, "e", 3),
        .init("foo bar baz", 0, "2e", 6),
        // Cyrillic words
        .init("привет мир", 0, "w", 7),
        .init("привет мир", 0, "e", 5),
        .init("привет мир", 7, "b", 0),
        .init("привет, мир", 0, "w", 6),
        .init("привет, мир", 0, "2w", 8),
        // 0 ^ $
        .init("  foo bar", 6, "0", 0),
        .init("  foo bar", 6, "^", 2),
        .init("  foo bar", 0, "^", 2),
        .init("  foo bar", 0, "$", 8),
        .init("ab\ncdef", 0, "2$", 6),
        // gg G
        .init("a\nb\nc", 4, "gg", 0),
        .init("a\nb\nc", 0, "G", 4),
        .init("  a\nb", 4, "gg", 2),
        .init("l1\nl2\nl3\nl4\nl5\nl6", 0, "5G", 12),
        .init("l1\nl2\nl3\nl4\nl5\nl6", 0, "2gg", 3),
        .init("l1\nl2\nl3\nl4\nl5\nl6", 0, "99G", 15),
        // graphemes
        .init("aпb", 0, "l", 1),
        .init("aпb", 0, "ll", 2),
        .init("a👍b", 0, "l", 1),
        .init("a👍b", 0, "ll", 3),
        .init("a👍b", 3, "h", 1),
        .init("a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b", 0, "ll", 9),
        .init("e\u{301}x", 0, "l", 2),
        // j keeps the column; the preferred column survives a short line
        .init("abcdef\nab\nabcdef", 4, "j", 8),
        .init("abcdef\nab\nabcdef", 4, "jj", 14),
        .init("a👍bc\nabcd", 3, "j", 8),        // column counts graphemes
        .init("abc\nabcdef", 0, "$j", 9),        // $ sticks to the line end
        .init("abcdef\nab\nabcdef", 4, "jhj", 10),
    ]

    @Test(arguments: motions)
    func motion(_ c: CursorCase) {
        let r = run(c.text, cursor: c.cursor, c.keys)
        #expect(r.cursor == NSRange(location: c.expected, length: 0))
        #expect(r.text == c.text)
        #expect(r.mode == .normal)
        #expect(!r.actions.contains(.beep))
    }

    static let beeps: [CursorCase] = [
        .init("abc", 2, "l", 2),
        .init("abc\ndef", 2, "l", 2),         // l never moves onto the newline
        .init("abc", 0, "h", 0),
        .init("ab\ncd", 3, "h", 3),              // h stops at column 0
        .init("abc", 0, "k", 0),
        .init("abc", 0, "j", 0),
        .init("abc", 0, "Zx", 0),             // Z then anything but Z or Q
        .init("abc", 0, "gZ", 0),
        .init("abc", 0, "<C-x>", 0),
        .init("a\n\nb", 2, "x", 2),
        .init("", 0, "x", 0),
    ]

    @Test(arguments: beeps)
    func beep(_ c: CursorCase) {
        let r = run(c.text, cursor: c.cursor, c.keys)
        #expect(r.actions.contains(.beep))
        #expect(r.text == c.text)
        #expect(r.cursor.location == c.expected)
        #expect(r.mode == .normal)
    }

    @Test func countIsClearedAfterBeep() {
        // "3Zx" beeps and drops the count, so "l" moves one character.
        let r = run("abcdef", cursor: 0, "3Zxl")
        #expect(r.cursor.location == 1)
    }
}

@Suite struct VimZCommandTests {
    @Test func zzSavesAndCloses() {
        let r = run("abc", cursor: 1, "ZZ")
        #expect(r.actions.contains(.save))
        #expect(r.actions.contains(.close))
        #expect(r.actions.firstIndex(of: .save)! < r.actions.firstIndex(of: .close)!)
        #expect(r.text == "abc")
    }

    @Test func zqClosesWithoutSaving() {
        let r = run("abc", cursor: 1, "ZQ")
        #expect(r.actions.contains(.forceClose))
        #expect(!r.actions.contains(.save))
    }

    @Test func escapeCancelsZ() {
        let r = run("abc", cursor: 0, "Z<Esc>l")
        #expect(!r.actions.contains(.save))
        #expect(r.cursor.location == 1)
    }
}

@Suite struct VimInsertTests {
    static let cases: [EditCase] = [
        .init("abc", 1, "i", "abc", 1, .insert),
        .init("abc", 1, "a", "abc", 2, .insert),
        .init("abc", 2, "a", "abc", 3, .insert),
        .init("", 0, "a", "", 0, .insert),
        .init("  abc", 4, "I", "  abc", 2, .insert),
        .init("abc", 0, "A", "abc", 3, .insert),
        .init("ab\ncd", 0, "A", "ab\ncd", 2, .insert),
        .init("ab\ncd", 0, "o", "ab\n\ncd", 3, .insert),
        .init("ab\ncd", 4, "O", "ab\n\ncd", 3, .insert),
        .init("ab", 1, "O", "\nab", 0, .insert),
        .init("abc", 1, "ixy<Esc>", "axybc", 2, .normal),
        .init("abc", 0, "i<Esc>", "abc", 0, .normal),
        .init("ab\ncd", 3, "i<Esc>", "ab\ncd", 3, .normal),
        .init("abc", 1, "i<C-[>", "abc", 0, .normal),
        .init("abc", 0, "A<Esc>", "abc", 2, .normal),
        .init("aп", 0, "A<Esc>", "aп", 1, .normal),
        .init("a👍", 0, "A<Esc>", "a👍", 1, .normal),
        .init("ab", 0, "ox<Esc>", "ab\nx", 3, .normal),
        .init("abc", 0, "3i", "abc", 0, .insert),
    ]

    @Test(arguments: cases)
    func insert(_ c: EditCase) {
        let r = run(c.text, cursor: c.cursor, c.keys)
        #expect(r.text == c.expectedText)
        #expect(r.cursor == NSRange(location: c.expectedCursor, length: 0))
        #expect(r.mode == c.expectedMode)
    }

    @Test func insertModeLeavesKeysToTheTextView() {
        let engine = VimEngine()
        _ = engine.handle(VimKey("i"), text: "abc", selection: NSRange(location: 0, length: 0))
        for key in vimKeys("aZ:<CR><BS><Left><Right><Up><Down><C-r>") {
            #expect(engine.handle(key, text: "abc", selection: NSRange(location: 0, length: 0)) == [])
        }
        #expect(engine.mode == .insert)
    }

    @Test func resetReturnsToNormal() {
        let engine = VimEngine()
        _ = engine.handle(VimKey("i"), text: "abc", selection: NSRange(location: 0, length: 0))
        engine.reset()
        #expect(engine.mode == .normal)
        #expect(engine.commandLine == nil)
    }
}

@Suite struct VimDeleteAndUndoTests {
    static let cases: [EditCase] = [
        .init("abc", 0, "x", "bc", 0, .normal),
        .init("abc", 2, "x", "ab", 1, .normal),
        .init("aпb", 1, "x", "ab", 1, .normal),
        .init("a👍b", 1, "x", "ab", 1, .normal),
        .init("abc", 0, "2x", "c", 0, .normal),
        .init("abc", 1, "5x", "a", 0, .normal),
        .init("ab\ncd", 1, "x", "a\ncd", 0, .normal),
        .init("a\nb", 0, "x", "\nb", 0, .normal),
    ]

    @Test(arguments: cases)
    func delete(_ c: EditCase) {
        let r = run(c.text, cursor: c.cursor, c.keys)
        #expect(r.text == c.expectedText)
        #expect(r.cursor == NSRange(location: c.expectedCursor, length: 0))
        #expect(r.mode == c.expectedMode)
    }

    @Test func xStoresTheGraphemeInTheRegister() {
        let engine = VimEngine()
        _ = run("a👍b", cursor: 1, "x", engine: engine)
        #expect(engine.register == "👍")
        #expect(engine.registerIsLinewise == false)
    }

    @Test func xIsOneReplace() {
        let r = run("abcd", cursor: 0, "3x")
        #expect(r.actions.filter { if case .replace = $0 { return true }; return false }.count == 1)
    }

    @Test(arguments: [
        ("u", [VimAction.undo]),
        ("3u", [.undo, .undo, .undo]),
        ("<C-r>", [.redo]),
        ("2<C-r>", [.redo, .redo]),
    ])
    func undoRedo(_ keys: String, _ expected: [VimAction]) {
        #expect(run("abc", cursor: 0, keys).actions == expected)
    }
}
