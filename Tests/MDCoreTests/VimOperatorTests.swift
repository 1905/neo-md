import Foundation
import Testing
@testable import MDCore

private func replaceCount(_ actions: [VimAction]) -> Int {
    actions.filter { if case .replace = $0 { return true }; return false }.count
}

private func check(_ c: EditCase) {
    let r = run(c.text, cursor: c.cursor, c.keys)
    #expect(r.text == c.expectedText)
    #expect(r.cursor == NSRange(location: c.expectedCursor, length: 0))
    #expect(r.mode == c.expectedMode)
    #expect(!r.actions.contains(.beep))
}

@Suite struct VimDeleteOperatorTests {
    static let cases: [EditCase] = [
        .init("foo bar", 0, "dw", "bar", 0, .normal),
        .init("foo bar\nbaz", 4, "dw", "foo \nbaz", 3, .normal),   // dw stops at the line end
        .init("foo bar baz", 0, "d2w", "baz", 0, .normal),
        .init("foo bar baz", 0, "2dw", "baz", 0, .normal),
        // `dw` on the last word of a line stops at that line's end, whatever the next line holds.
        .init("one\n  two\nthree", 0, "dw", "\n  two\nthree", 0, .normal),
        .init("foo\n\nbar", 0, "dw", "\n\nbar", 0, .normal),
        .init("one\r\n  two", 0, "dw", "\r\n  two", 0, .normal),
        .init("a b\n  c\nd", 0, "2dw", "\n  c\nd", 0, .normal),
        // Only the last `w` step stops at the line end; earlier steps cross lines.
        .init("a b\nc d\ne", 2, "2dw", "a d\ne", 2, .normal),
        .init("привет мир", 0, "dw", "мир", 0, .normal),
        .init("foo bar", 0, "de", " bar", 0, .normal),
        .init("foo bar", 4, "db", "bar", 0, .normal),
        .init("foo bar", 2, "d0", "o bar", 0, .normal),
        .init("foo bar", 0, "dl", "oo bar", 0, .normal),
        .init("foo bar", 2, "dh", "fo bar", 1, .normal),
        .init("abcdef", 0, "d3l", "def", 0, .normal),
        .init("abcdef", 0, "2d2l", "ef", 0, .normal),
        .init("a👍b", 1, "dl", "ab", 1, .normal),
        .init("foo bar", 4, "d$", "foo ", 3, .normal),
        .init("foo bar", 4, "D", "foo ", 3, .normal),
        .init("ab\ncd\nef", 1, "2D", "a\nef", 0, .normal),
        // dd
        .init("a\nb\nc", 2, "dd", "a\nc", 2, .normal),
        .init("a\n  b\nc", 0, "dd", "  b\nc", 2, .normal),
        .init("a\nb\nc", 0, "2dd", "c", 0, .normal),
        .init("a\nb\nc", 4, "dd", "a\nb", 2, .normal),           // last line takes the newline before it
        .init("a\r\nb", 3, "dd", "a", 0, .normal),
        .init("abc", 1, "dd", "", 0, .normal),                    // only line
        // linewise motions
        .init("a\nb\nc", 0, "dj", "c", 0, .normal),
        .init("a\nb\nc", 4, "dk", "a", 0, .normal),
        .init("a\nb\nc", 2, "dG", "a", 0, .normal),
        .init("a\nb\nc", 2, "dgg", "c", 0, .normal),
    ]

    @Test(arguments: cases)
    func delete(_ c: EditCase) { check(c) }

    @Test func dollarOnAnEmptyLineKeepsTheNewline() {
        let r = run("ab\n\ncd", cursor: 3, "d$")
        #expect(r.text == "ab\n\ncd")
    }

    @Test(arguments: ["dZ", "d<C-r>", "dx", "a<Esc>dj"])
    func invalidOperatorBeeps(_ keys: String) {
        let r = run("a\nb", cursor: 2, keys)
        #expect(r.actions.contains(.beep))
        #expect(r.text == "a\nb")
    }

    @Test func escapeCancelsAPendingOperator() {
        let r = run("abc", cursor: 0, "d<Esc>l")
        #expect(r.text == "abc")
        #expect(r.cursor.location == 1)
    }

    @Test func registerFlags() {
        let e = VimEngine()
        _ = run("a\nb", cursor: 0, "dd", engine: e)
        #expect(e.register == "a\n")
        #expect(e.registerIsLinewise)
        _ = run("foo bar", cursor: 0, "dw", engine: e)
        #expect(e.register == "foo ")
        #expect(!e.registerIsLinewise)
        _ = run("a\nb", cursor: 2, "dd", engine: e)
        #expect(e.register == "b\n")
    }

    @Test(arguments: ["2dd", "dw", "D", "cw", "cc", "dG", "yyp", "ywP", "vjd", "Vd"])
    func oneReplacePerCommand(_ keys: String) {
        let r = run("foo bar\nbaz qux\nend", cursor: 0, keys)
        #expect(replaceCount(r.actions) == 1)
    }
}

@Suite struct VimChangeOperatorTests {
    static let cases: [EditCase] = [
        .init("foo bar", 0, "cw", " bar", 0, .insert),             // cw = ce
        .init("foo bar", 2, "cw", "fo bar", 2, .insert),           // at a word end: only that character
        .init("foo bar", 0, "cwxy<Esc>", "xy bar", 1, .normal),
        .init("foo bar baz", 0, "c2w", " baz", 0, .insert),
        .init("foo  bar", 3, "cw", "foo bar", 3, .insert),         // on a blank: one character
        .init("one\n  two", 0, "cw", "\n  two", 0, .insert),
        .init("foo bar", 4, "C", "foo ", 4, .insert),
        .init("foo bar", 4, "c$", "foo ", 4, .insert),
        .init("a\nbc\nd", 2, "cc", "a\n\nd", 2, .insert),
        .init("a\nbc\nd", 2, "ccx<Esc>", "a\nx\nd", 2, .normal),
        .init("abc", 1, "cc", "", 0, .insert),
        .init("a\nb\nc", 0, "cj", "\nc", 0, .insert),
    ]

    @Test(arguments: cases)
    func change(_ c: EditCase) { check(c) }

    @Test func ccStoresALinewiseRegister() {
        let e = VimEngine()
        _ = run("a\nbc\nd", cursor: 2, "cc", engine: e)
        #expect(e.register == "bc\n")
        #expect(e.registerIsLinewise)
    }
}

@Suite struct VimYankPasteTests {
    static let cases: [EditCase] = [
        .init("a\nb", 0, "yyp", "a\na\nb", 2, .normal),
        .init("a\nb", 2, "yyp", "a\nb\nb", 4, .normal),           // below the last line
        .init("a\nb", 2, "yyP", "a\nb\nb", 2, .normal),
        .init("a\nb", 0, "yyP", "a\na\nb", 0, .normal),
        .init("  a\nb", 0, "yyjp", "  a\nb\n  a", 8, .normal),
        .init("a\nb", 0, "yy2p", "a\na\na\nb", 2, .normal),
        .init("a\nb\nc", 0, "ddp", "b\na\nc", 2, .normal),
        .init("foo bar", 0, "ywp", "ffoo oo bar", 4, .normal),     // charwise after the cursor
        .init("foo bar", 0, "ywP", "foo foo bar", 3, .normal),
        .init("foo", 0, "yw$p", "foofoo", 5, .normal),
        .init("ab", 0, "xp", "ba", 1, .normal),
        .init("foo bar", 4, "yb", "foo bar", 0, .normal),
        .init("a\nb\nc", 4, "yk", "a\nb\nc", 2, .normal),
        .init("a\nb\nc", 2, "yy", "a\nb\nc", 2, .normal),
    ]

    @Test(arguments: cases)
    func yankPaste(_ c: EditCase) { check(c) }

    @Test(arguments: [
        ("foo bar", 0, "yw", "foo "),
        ("one\n  two", 0, "yw", "one"),
        ("one\r\n  two", 0, "yw", "one"),
        ("a\nb", 0, "yy", "a\n"),
        ("a\nb", 2, "yy", "b\n"),
        ("foo bar", 0, "vey", "foo"),
        ("a\nb\nc", 0, "Vjy", "a\nb\n"),
    ])
    func yankCopiesToPasteboard(_ text: String, _ cursor: Int, _ keys: String, _ copied: String) {
        let e = VimEngine()
        let r = run(text, cursor: cursor, keys, engine: e)
        #expect(r.actions.contains(.copyToPasteboard(copied)))
        #expect(e.register == copied)
        #expect(r.text == text)
    }

    @Test func pasteWithAnEmptyRegisterBeeps() {
        let r = run("abc", cursor: 0, "p")
        #expect(r.actions == [.beep])
    }
}

@Suite struct VimVisualTests {
    static let cases: [EditCase] = [
        .init("foo bar", 0, "ved", " bar", 0, .normal),
        .init("foo bar", 4, "vbd", "ar", 0, .normal),
        .init("foo bar", 0, "vex", " bar", 0, .normal),
        .init("ab\ncd", 1, "vjd", "a", 0, .normal),
        .init("a\nb\nc", 0, "Vjd", "c", 0, .normal),
        .init("a\nb\nc", 2, "Vd", "a\nc", 2, .normal),
        .init("foo bar", 0, "vey", "foo bar", 0, .normal),
        .init("foo bar", 4, "vy", "foo bar", 4, .normal),
        .init("foo bar", 0, "vecxy<Esc>", "xy bar", 1, .normal),
        .init("a\nbc\nd", 2, "Vcx<Esc>", "a\nx\nd", 2, .normal),
        .init("a\nb\nc", 0, "Vjy", "a\nb\nc", 0, .normal),
        .init("foo", 0, "vl<Esc>", "foo", 1, .normal),
        .init("foo", 0, "vv", "foo", 0, .normal),
        .init("foo", 0, "VV", "foo", 0, .normal),
    ]

    @Test(arguments: cases)
    func visual(_ c: EditCase) { check(c) }

    @Test func motionsExtendTheSelection() {
        let r = run("foo bar", cursor: 0, "ve")
        #expect(r.mode == .visual)
        #expect(r.cursor == NSRange(location: 0, length: 3))
        let back = run("foo bar", cursor: 4, "vb")
        #expect(back.cursor == NSRange(location: 0, length: 5))
    }

    @Test func visualLineSelectsWholeLines() {
        let r = run("a\nb\nc", cursor: 0, "Vj")
        #expect(r.mode == .visualLine)
        #expect(r.cursor == NSRange(location: 0, length: 4))
        #expect(run("abc", cursor: 1, "vV").mode == .visualLine)
        #expect(run("abc", cursor: 1, "Vv").mode == .visual)
    }

    @Test func visualYankIsCharwiseOrLinewise() {
        let e = VimEngine()
        _ = run("foo bar", cursor: 0, "vey", engine: e)
        #expect(!e.registerIsLinewise)
        _ = run("a\nb", cursor: 0, "Vy", engine: e)
        #expect(e.registerIsLinewise)
        #expect(e.register == "a\n")
    }

    /// A selection changed outside the engine (mouse drag, a native action) replaces
    /// the engine's own: anchor = its first character, head = its last.
    @Test func operatorUsesASelectionChangedOutsideTheEngine() {
        let e = VimEngine()
        let text = "alpha beta"
        _ = run(text, cursor: 0, "ve", engine: e)
        let actions = e.handle(VimKey("d"), text: text as NSString, selection: NSRange(location: 6, length: 4))
        #expect(actions.contains(.replace(NSRange(location: 6, length: 4), "")))
        #expect(e.register == "beta")
        #expect(e.mode == .normal)
    }

    @Test func motionExtendsASelectionChangedOutsideTheEngine() {
        let e = VimEngine()
        let text = "alpha beta gamma"
        _ = run(text, cursor: 0, "ve", engine: e)
        let actions = e.handle(VimKey("e"), text: text as NSString, selection: NSRange(location: 6, length: 4))
        #expect(actions == [.setSelection(NSRange(location: 6, length: 10))])
        #expect(e.mode == .visual)
        #expect(e.visualCursor == 15)
    }

    @Test func visualDeleteFillsTheRegister() {
        let e = VimEngine()
        _ = run("foo bar", cursor: 0, "ved", engine: e)
        #expect(e.register == "foo")
    }
}

@Suite struct VimSearchTests {
    static let cases: [CursorCase] = [
        .init("foo bar foo", 0, "/foo<CR>", 8),
        .init("foo bar foo", 8, "/foo<CR>", 0),                 // wraps at the end
        .init("a foo b foo", 0, "/foo<CR>n", 8),
        .init("a foo b foo", 0, "/foo<CR>nn", 2),
        .init("a foo b foo", 0, "/foo<CR>N", 8),
        .init("a foo b foo", 0, "/foo<CR>NN", 2),
        .init("привет мир привет", 0, "/мир<CR>", 7),
        .init("foo\nbar foo", 0, "/bar<CR>", 4),
        .init("a foo b foo", 0, "/foo<CR>/<CR>", 8),             // empty pattern reuses the last one
        .init("abc", 0, "/b<BS>c<CR>", 2),
    ]

    @Test(arguments: cases)
    func search(_ c: CursorCase) {
        let r = run(c.text, cursor: c.cursor, c.keys)
        #expect(r.cursor == NSRange(location: c.expected, length: 0))
        #expect(r.mode == .normal)
        #expect(r.text == c.text)
        #expect(!r.actions.contains(.beep))
    }

    @Test(arguments: ["/zz<CR>", "n", "N", "/<CR>"])
    func noMatchBeeps(_ keys: String) {
        let r = run("abc", cursor: 1, keys)
        #expect(r.actions.contains(.beep))
        #expect(r.cursor.location == 1)
        #expect(r.mode == .normal)
    }

    @Test func typingShowsTheSearchLine() {
        let r = run("abc", cursor: 0, "/fo")
        #expect(r.actions == [.setMode(.command), .setCommandLine("/"),
                              .setCommandLine("/f"), .setCommandLine("/fo")])
        #expect(r.mode == .command)
    }
}

@Suite struct VimCommandLineTests {
    @Test(arguments: [
        (":w<CR>", [VimAction.save]),
        (":q<CR>", [.close]),
        (":wq<CR>", [.save, .close]),
        (":x<CR>", [.save, .close]),
        (":q!<CR>", [.forceClose]),
    ])
    func commands(_ keys: String, _ expected: [VimAction]) {
        let e = VimEngine()
        let r = run("abc", cursor: 0, keys, engine: e)
        #expect(Array(r.actions.suffix(expected.count)) == expected)
        #expect(r.actions.contains(.setCommandLine(nil)))
        #expect(r.mode == .normal)
        #expect(e.commandLine == nil)
        for other in [VimAction.save, .close, .forceClose] where !expected.contains(other) {
            #expect(!r.actions.contains(other))
        }
    }

    @Test func lineNumberGoesToFirstNonBlank() {
        let lines = (1...15).map { "  x\($0)" }
        let text = lines.joined(separator: "\n")
        let line12 = lines[0..<11].reduce(0) { $0 + ($1 as NSString).length + 1 }
        #expect(run(text, cursor: 0, ":12<CR>").cursor == NSRange(location: line12 + 2, length: 0))
        let last = lines[0..<14].reduce(0) { $0 + ($1 as NSString).length + 1 }
        #expect(run(text, cursor: 0, ":99<CR>").cursor == NSRange(location: last + 2, length: 0))
        #expect(run(text, cursor: 20, ":1<CR>").cursor == NSRange(location: 2, length: 0))
    }

    @Test func typingShowsTheCommandLine() {
        let e = VimEngine()
        let r = run("abc", cursor: 0, ":wq", engine: e)
        #expect(r.actions == [.setMode(.command), .setCommandLine(":"),
                              .setCommandLine(":w"), .setCommandLine(":wq")])
        #expect(e.commandLine == ":wq")
        #expect(r.mode == .command)
    }

    @Test func escapeCancels() {
        let e = VimEngine()
        let r = run("abc", cursor: 1, ":w<Esc>", engine: e)
        #expect(r.mode == .normal)
        #expect(r.actions.last == .setCommandLine(nil))
        #expect(!r.actions.contains(.save))
        #expect(e.commandLine == nil)
        #expect(r.cursor.location == 1)
    }

    @Test func backspaceDeletesOneCharacter() {
        let r = run("abc", cursor: 0, ":ab<BS>")
        #expect(r.actions.last == .setCommandLine(":a"))
        #expect(r.mode == .command)
    }

    @Test(arguments: [":<BS>", ":a<BS><BS>"])
    func backspaceOnAnEmptyLineReturnsToNormal(_ keys: String) {
        let r = run("abc", cursor: 0, keys)
        #expect(r.mode == .normal)
        #expect(r.actions.last == .setCommandLine(nil))
    }

    @Test(arguments: [":zz<CR>", ":w!x<CR>"])
    func unknownCommandBeeps(_ keys: String) {
        let r = run("abc", cursor: 0, keys)
        #expect(r.actions.contains(.beep))
        #expect(r.mode == .normal)
    }

    @Test func emptyCommandJustCloses() {
        let r = run("abc", cursor: 1, ":<CR>")
        #expect(r.mode == .normal)
        #expect(!r.actions.contains(.beep))
        #expect(r.cursor.location == 1)
    }
}
