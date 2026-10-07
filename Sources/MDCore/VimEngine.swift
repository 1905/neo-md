import Foundation

/// Pure Vim state machine: one key + the buffer → actions for the text view.
/// It never edits the buffer itself; every edit is a `.replace` action.
public final class VimEngine {
    public private(set) var mode: VimMode = .normal
    public private(set) var commandLine: String?
    public private(set) var register: String = ""
    public private(set) var registerIsLinewise = false

    /// Digits typed before a command. nil = no count.
    private var pendingCount: Int?
    /// `g` typed, waiting for the second key (`gg`).
    private var pendingG = false
    /// Column `j`/`k` aim for. Valid only while the cursor is still at `columnAnchor`,
    /// so a mouse click or an edit drops it.
    private var preferredColumn: Int?
    private var columnAnchor: Int?

    private static let maxCount = 99_999

    public init() {}

    /// text = full buffer, selection = current NSRange (length 0 = cursor). Returns actions in apply order.
    /// In .insert mode it returns [] for any key except Escape and Ctrl-[, so the text view inserts the key itself.
    public func handle(_ key: VimKey, text: NSString, selection: NSRange) -> [VimAction] {
        switch mode {
        case .insert:
            return handleInsert(key, text: text, selection: selection)
        case .normal:
            return handleNormal(key, text: text, cursor: TextNav.normalCursor(selection.location, in: text))
        case .visual, .visualLine, .command:
            // Entered only by Task 9 keys; fall back to normal until then.
            reset()
            return [.setMode(.normal), .beep]
        }
    }

    /// Back to .normal, clears pending count/operator.
    public func reset() {
        mode = .normal
        commandLine = nil
        clearPending()
        preferredColumn = nil
        columnAnchor = nil
    }

    // MARK: insert mode

    private func handleInsert(_ key: VimKey, text: NSString, selection: NSRange) -> [VimAction] {
        guard Self.isEscape(key) else { return [] }
        mode = .normal
        // Vim rule: leaving insert mode moves the cursor one left, but not past the line start.
        let cursor = selection.location
        let ln = TextNav.line(at: cursor, in: text)
        let target = cursor > ln.start ? TextNav.previousGrapheme(before: cursor, in: text) : cursor
        return [.setMode(.normal), .setSelection(NSRange(location: target, length: 0))]
    }

    private static func isEscape(_ key: VimKey) -> Bool {
        key == .escape || (key.control && (key.chars == "[" || key.chars == "\u{1b}"))
    }

    // MARK: normal mode

    private func handleNormal(_ key: VimKey, text: NSString, cursor: Int) -> [VimAction] {
        if Self.isEscape(key) {
            clearPending()
            return []
        }
        if key.control {
            if key.chars == "r" { return Array(repeating: .redo, count: takeCount()) }
            return beep()
        }
        if pendingG {
            pendingG = false
            return key.chars == "g" ? move(.firstLine, text: text, cursor: cursor) : beep()
        }
        if let digit = Int(key.chars), digit >= 0, digit <= 9, key.chars.count == 1,
           digit > 0 || pendingCount != nil {
            pendingCount = min((pendingCount ?? 0) * 10 + digit, Self.maxCount)
            return []
        }
        if let motion = Self.motions[key.chars] {
            return move(motion, text: text, cursor: cursor)
        }
        switch key.chars {
        case "g":
            pendingG = true
            return []
        case "i", "a", "I", "A", "o", "O":
            return enterInsert(key.chars, text: text, cursor: cursor)
        case "x":
            return deleteCharacters(text: text, cursor: cursor)
        case "u":
            return Array(repeating: .undo, count: takeCount())
        default:
            return beep()
        }
    }

    private static let motions: [String: VimMotion] = [
        "h": .left, VimKey.left.chars: .left,
        "l": .right, VimKey.right.chars: .right,
        "j": .down, VimKey.down.chars: .down,
        "k": .up, VimKey.up.chars: .up,
        "w": .wordForward, "b": .wordBackward, "e": .wordEnd,
        "0": .lineStart, "^": .firstNonBlank, "$": .lineEnd,
        "G": .lastLine,
    ]

    /// Plain cursor movement. Task 9 adds the operator-pending branch here:
    /// with a pending operator, turn `target` into a range instead of moving.
    private func move(_ motion: VimMotion, text: NSString, cursor: Int) -> [VimAction] {
        let count = pendingCount
        clearPending()
        let column = columnAnchor == cursor ? preferredColumn : nil
        let target = motion.target(from: cursor, count: count, in: text, preferredColumn: column)
        let position = TextNav.normalCursor(target.position, in: text)
        if position == cursor, motion.beepsWhenStuck { return [.beep] }
        preferredColumn = target.column
        columnAnchor = position
        return [.setSelection(NSRange(location: position, length: 0))]
    }

    private func enterInsert(_ command: String, text: NSString, cursor: Int) -> [VimAction] {
        clearPending()
        let ln = TextNav.line(at: cursor, in: text)
        var actions: [VimAction] = []
        let position: Int
        switch command {
        case "a": position = cursor < ln.contentsEnd ? TextNav.nextGrapheme(after: cursor, in: text) : cursor
        case "I": position = Self.firstNonBlankOrEnd(ln, text)
        case "A": position = ln.contentsEnd
        case "o":
            actions.append(.replace(NSRange(location: ln.contentsEnd, length: 0), "\n"))
            position = ln.contentsEnd + 1
        case "O":
            actions.append(.replace(NSRange(location: ln.start, length: 0), "\n"))
            position = ln.start
        default: position = cursor  // "i"
        }
        mode = .insert
        return actions + [.setMode(.insert), .setSelection(NSRange(location: position, length: 0))]
    }

    private static func firstNonBlankOrEnd(_ ln: TextLine, _ text: NSString) -> Int {
        let p = TextNav.firstNonBlank(of: ln, in: text)
        let c = p < ln.contentsEnd ? text.character(at: p) : 0
        return c == 0x20 || c == 0x09 ? ln.contentsEnd : p
    }

    /// `x`: delete up to `count` graphemes on the current line (Vim's `dl`).
    private func deleteCharacters(text: NSString, cursor: Int) -> [VimAction] {
        let count = pendingCount
        clearPending()
        let end = VimMotion.right.target(from: cursor, count: count, in: text, preferredColumn: nil).position
        guard end > cursor else { return [.beep] }
        let range = NSRange(location: cursor, length: end - cursor)
        setRegister(text.substring(with: range), linewise: false)
        let after = text.replacingCharacters(in: range, with: "") as NSString
        let position = TextNav.normalCursor(cursor, in: after)
        return [.replace(range, ""), .setSelection(NSRange(location: position, length: 0))]
    }

    // MARK: state helpers

    func setRegister(_ s: String, linewise: Bool) {
        register = s
        registerIsLinewise = linewise
    }

    private func takeCount() -> Int {
        let n = pendingCount ?? 1
        clearPending()
        return n
    }

    private func clearPending() {
        pendingCount = nil
        pendingG = false
    }

    private func beep() -> [VimAction] {
        clearPending()
        return [.beep]
    }
}
