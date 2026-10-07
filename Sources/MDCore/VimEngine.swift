import Foundation

/// Pure Vim state machine: one key + the buffer → actions for the text view.
/// It never edits the buffer itself; every edit is a `.replace` action, one per
/// command, so one command is one undo step.
public final class VimEngine {
    public private(set) var mode: VimMode = .normal
    public private(set) var commandLine: String?
    public private(set) var register: String = ""
    public private(set) var registerIsLinewise = false

    /// Digits typed before a command (or before the motion of an operator). nil = no count.
    private var pendingCount: Int?
    /// `g` typed, waiting for the second key (`gg`).
    private var pendingG = false
    /// `d c y` typed, waiting for a motion or a second `d c y`.
    private var pendingOperator: VimOperator?
    /// Count typed before the operator (`2` in `2dw`).
    private var operatorCount: Int?
    /// Column `j`/`k` aim for. Valid only while the cursor is still at `columnAnchor`,
    /// so a mouse click or an edit drops it.
    private var preferredColumn: Int?
    private var columnAnchor: Int?
    /// Visual mode: the fixed end and the moving end of the selection (grapheme starts).
    private var visualAnchor = 0
    private var visualCursor = 0
    /// Last `/` pattern, for `n`, `N` and an empty `/`.
    private var lastSearch: String?

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
        case .visual, .visualLine:
            return handleVisual(key, text: text)
        case .command:
            return handleCommand(key, text: text, cursor: TextNav.normalCursor(selection.location, in: text))
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

    // MARK: counts, `g` prefix and motion keys (normal and visual)

    private enum MotionKey { case pending, motion(VimMotion), invalid, other }

    /// Consumes count digits and the `g` prefix; resolves a motion key.
    private func motionKey(_ key: VimKey) -> MotionKey {
        if pendingG {
            pendingG = false
            return key.chars == "g" ? .motion(.firstLine) : .invalid
        }
        if let digit = Int(key.chars), digit >= 0, digit <= 9, key.chars.count == 1,
           digit > 0 || pendingCount != nil {
            pendingCount = min((pendingCount ?? 0) * 10 + digit, Self.maxCount)
            return .pending
        }
        if let motion = Self.motions[key.chars] { return .motion(motion) }
        if key.chars == "g" {
            pendingG = true
            return .pending
        }
        return .other
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

    // MARK: normal mode

    private func handleNormal(_ key: VimKey, text: NSString, cursor: Int) -> [VimAction] {
        if Self.isEscape(key) {
            clearPending()
            return []
        }
        if key.control {
            if key.chars == "r", pendingOperator == nil { return Array(repeating: .redo, count: takeCount()) }
            return beep()
        }
        switch motionKey(key) {
        case .pending: return []
        case .invalid: return beep()
        case .motion(let motion): return move(motion, text: text, cursor: cursor)
        case .other: break
        }
        if let op = pendingOperator {
            // `dd`, `cc`, `yy`: whole lines.
            guard key.chars == op.rawValue else { return beep() }
            let count = operatorTotalCount() ?? 1
            clearPending()
            let first = TextNav.line(at: cursor, in: text)
            let last = TextNav.line(index: TextNav.lineIndex(at: cursor, in: text) + count - 1, in: text)
            return applyLinewise(op, first: first, last: last, text: text, yankCursor: cursor)
        }
        switch key.chars {
        case "d", "c", "y":
            operatorCount = pendingCount
            pendingCount = nil
            pendingOperator = VimOperator(rawValue: key.chars)
            return []
        case "D", "C":
            operatorCount = pendingCount
            pendingCount = nil
            pendingOperator = key.chars == "D" ? .delete : .change
            return move(.lineEnd, text: text, cursor: cursor)
        case "i", "a", "I", "A", "o", "O":
            return enterInsert(key.chars, text: text, cursor: cursor)
        case "x":
            return deleteCharacters(text: text, cursor: cursor)
        case "p", "P":
            return paste(after: key.chars == "p", text: text, cursor: cursor)
        case "v", "V":
            clearPending()
            visualAnchor = cursor
            visualCursor = cursor
            columnAnchor = nil
            return enterVisual(key.chars == "v" ? .visual : .visualLine, text: text)
        case ":", "/":
            clearPending()
            mode = .command
            commandLine = key.chars
            return [.setMode(.command), .setCommandLine(key.chars)]
        case "n", "N":
            let count = takeCount()
            guard let pattern = lastSearch else { return [.beep] }
            return search(pattern, forward: key.chars == "n", count: count, text: text, cursor: cursor)
        case "u":
            return Array(repeating: .undo, count: takeCount())
        default:
            return beep()
        }
    }

    /// Plain cursor movement, or with a pending operator the operator over the motion's range.
    private func move(_ motion: VimMotion, text: NSString, cursor: Int) -> [VimAction] {
        let op = pendingOperator
        let count = operatorTotalCount()
        clearPending()
        let column = columnAnchor == cursor ? preferredColumn : nil
        if let op { return operate(op, motion: motion, count: count, text: text, cursor: cursor) }
        let target = motion.target(from: cursor, count: count, in: text, preferredColumn: column)
        let position = TextNav.normalCursor(target.position, in: text)
        if position == cursor, motion.beepsWhenStuck { return [.beep] }
        preferredColumn = target.column
        columnAnchor = position
        return [.setSelection(NSRange(location: position, length: 0))]
    }

    // MARK: operators

    /// `op` + motion → range. Linewise motions cover whole lines; inclusive
    /// motions cover the character they land on.
    private func operate(_ op: VimOperator, motion: VimMotion, count: Int?,
                         text: NSString, cursor: Int) -> [VimAction] {
        var target = motion.target(from: cursor, count: count, in: text, preferredColumn: nil)
        if op == .change, motion == .wordForward,
           let cw = VimMotion.changeWordTarget(from: cursor, count: count, in: text) {
            target = cw
        }
        if target.linewise {
            let lo = min(cursor, target.position), hi = max(cursor, target.position)
            let first = TextNav.line(at: lo, in: text), last = TextNav.line(at: hi, in: text)
            // `dj` on the last line or `dk` on the first fails, as in Vim.
            if motion == .up || motion == .down, first == last { return [.beep] }
            return applyLinewise(op, first: first, last: last, text: text, yankCursor: lo)
        }
        let lo = min(cursor, target.position)
        var hi = max(cursor, target.position)
        if target.inclusive {
            let ln = TextNav.line(at: target.position, in: text)
            hi = max(cursor, min(TextNav.nextGrapheme(after: target.position, in: text), ln.contentsEnd))
        } else if motion == .wordForward,
                  TextNav.lineIndex(at: target.position, in: text) > TextNav.lineIndex(at: cursor, in: text) {
            // `dw` on the last word of a line stops at the line end, it does not join lines.
            hi = max(lo, TextNav.line(at: target.position - 1, in: text).contentsEnd)
        }
        return applyCharwise(op, range: NSRange(location: lo, length: hi - lo), text: text)
    }

    private func applyCharwise(_ op: VimOperator, range: NSRange, text: NSString) -> [VimAction] {
        let removed = text.substring(with: range)
        if range.length == 0, op != .change { return finish(.normal) + [.beep] }
        setRegister(removed, linewise: false)
        switch op {
        case .yank:
            let position = TextNav.normalCursor(range.location, in: text)
            return [.copyToPasteboard(removed)] + finish(.normal) + [.setSelection(NSRange(location: position, length: 0))]
        case .delete:
            let after = text.replacingCharacters(in: range, with: "") as NSString
            let position = TextNav.normalCursor(range.location, in: after)
            return [.replace(range, "")] + finish(.normal) + [.setSelection(NSRange(location: position, length: 0))]
        case .change:
            return [.replace(range, "")] + finish(.insert) + [.setSelection(NSRange(location: range.location, length: 0))]
        }
    }

    /// Lines `first...last`. The register always ends with a newline.
    private func applyLinewise(_ op: VimOperator, first: TextLine, last: TextLine,
                               text: NSString, yankCursor: Int) -> [VimAction] {
        let whole = NSRange(location: first.start, length: last.end - first.start)
        let lines = text.substring(with: whole) + (last.hasNewline ? "" : "\n")
        setRegister(lines, linewise: true)
        switch op {
        case .yank:
            let position = TextNav.normalCursor(yankCursor, in: text)
            return [.copyToPasteboard(lines)] + finish(.normal) + [.setSelection(NSRange(location: position, length: 0))]
        case .delete:
            var range = whole
            if !last.hasNewline, first.start > 0 {
                // The last line has no newline to take, so take the one before it.
                let start = TextNav.line(at: first.start - 1, in: text).contentsEnd
                range = NSRange(location: start, length: last.end - start)
            }
            let after = text.replacingCharacters(in: range, with: "") as NSString
            let ln = TextNav.line(at: range.location, in: after)
            let position = TextNav.firstNonBlank(of: ln, in: after)
            return [.replace(range, "")] + finish(.normal) + [.setSelection(NSRange(location: position, length: 0))]
        case .change:
            let range = NSRange(location: first.start, length: last.contentsEnd - first.start)
            return [.replace(range, "")] + finish(.insert) + [.setSelection(NSRange(location: first.start, length: 0))]
        }
    }

    /// `p` / `P`: linewise text goes below / above the line, charwise text after / at the cursor.
    private func paste(after: Bool, text: NSString, cursor: Int) -> [VimAction] {
        let count = takeCount()
        guard !register.isEmpty else { return [.beep] }
        let chunk = String(repeating: register, count: count)
        let ln = TextNav.line(at: cursor, in: text)
        if registerIsLinewise {
            var insert = chunk
            let at = after ? ln.end : ln.start
            var firstLine = at
            if after, !ln.hasNewline {
                // Below the last line: add the newline before, drop the one after.
                insert = "\n" + String(chunk.dropLast())
                firstLine = at + 1
            }
            let result = text.replacingCharacters(in: NSRange(location: at, length: 0), with: insert) as NSString
            let position = TextNav.firstNonBlank(of: TextNav.line(at: firstLine, in: result), in: result)
            return [.replace(NSRange(location: at, length: 0), insert), .setSelection(NSRange(location: position, length: 0))]
        }
        let at = after && cursor < ln.contentsEnd ? TextNav.nextGrapheme(after: cursor, in: text) : cursor
        let result = text.replacingCharacters(in: NSRange(location: at, length: 0), with: chunk) as NSString
        let end = at + (chunk as NSString).length
        let position = TextNav.normalCursor(TextNav.previousGrapheme(before: end, in: result), in: result)
        return [.replace(NSRange(location: at, length: 0), chunk), .setSelection(NSRange(location: position, length: 0))]
    }

    // MARK: visual mode

    private func handleVisual(_ key: VimKey, text: NSString) -> [VimAction] {
        visualAnchor = TextNav.normalCursor(min(visualAnchor, text.length), in: text)
        visualCursor = TextNav.normalCursor(min(visualCursor, text.length), in: text)
        if Self.isEscape(key) { return exitVisual() }
        if key.control { return beep() }
        switch motionKey(key) {
        case .pending: return []
        case .invalid: return beep()
        case .motion(let motion):
            let count = pendingCount
            clearPending()
            let column = columnAnchor == visualCursor ? preferredColumn : nil
            let target = motion.target(from: visualCursor, count: count, in: text, preferredColumn: column)
            visualCursor = TextNav.normalCursor(target.position, in: text)
            preferredColumn = target.column
            columnAnchor = visualCursor
            return [.setSelection(visualRange(text))]
        case .other: break
        }
        clearPending()
        switch key.chars {
        case "v", "V":
            let next: VimMode = key.chars == "v" ? .visual : .visualLine
            return next == mode ? exitVisual() : enterVisual(next, text: text)
        case "d", "x", "c", "y":
            let op: VimOperator = key.chars == "c" ? .change : key.chars == "y" ? .yank : .delete
            let lo = min(visualAnchor, visualCursor), hi = max(visualAnchor, visualCursor)
            if mode == .visualLine {
                return applyLinewise(op, first: TextNav.line(at: lo, in: text),
                                     last: TextNav.line(at: hi, in: text), text: text, yankCursor: lo)
            }
            return applyCharwise(op, range: visualRange(text), text: text)
        default:
            return [.beep]
        }
    }

    private func enterVisual(_ visualMode: VimMode, text: NSString) -> [VimAction] {
        mode = visualMode
        return [.setMode(visualMode), .setSelection(visualRange(text))]
    }

    private func exitVisual() -> [VimAction] {
        clearPending()
        return finish(.normal) + [.setSelection(NSRange(location: visualCursor, length: 0))]
    }

    /// The selection to show: characters from anchor to cursor, both included,
    /// or whole lines in visual-line mode. On an empty line it covers the newline.
    private func visualRange(_ text: NSString) -> NSRange {
        let lo = min(visualAnchor, visualCursor), hi = max(visualAnchor, visualCursor)
        if mode == .visualLine {
            let first = TextNav.line(at: lo, in: text), last = TextNav.line(at: hi, in: text)
            return NSRange(location: first.start, length: last.end - first.start)
        }
        return NSRange(location: lo, length: TextNav.nextGrapheme(after: hi, in: text) - lo)
    }

    // MARK: command line (`:` and `/`)

    private func handleCommand(_ key: VimKey, text: NSString, cursor: Int) -> [VimAction] {
        let line = commandLine ?? ":"
        if Self.isEscape(key) { return finish(.normal) }
        if key == .backspace {
            guard line.count > 1 else { return finish(.normal) }
            commandLine = String(line.dropLast())
            return [.setCommandLine(commandLine)]
        }
        if key == .enter {
            let done = finish(.normal)
            if line.hasPrefix("/") {
                let typed = String(line.dropFirst())
                let pattern = typed.isEmpty ? lastSearch : typed
                guard let pattern else { return done + [.beep] }
                lastSearch = pattern
                return done + search(pattern, forward: true, count: 1, text: text, cursor: cursor)
            }
            return done + execute(String(line.dropFirst()), text: text)
        }
        if key.control || [VimKey.left, .right, .up, .down].contains(key) { return [] }
        commandLine = line + key.chars
        return [.setCommandLine(commandLine)]
    }

    private func execute(_ command: String, text: NSString) -> [VimAction] {
        let command = command.trimmingCharacters(in: .whitespaces)
        switch command {
        case "": return []
        case "w": return [.save]
        case "q": return [.close]
        case "wq", "x": return [.save, .close]
        case "q!": return [.forceClose]
        default:
            guard let number = Int(command), number >= 0 else { return [.beep] }
            let ln = TextNav.line(index: max(number, 1) - 1, in: text)
            return [.setSelection(NSRange(location: TextNav.firstNonBlank(of: ln, in: text), length: 0))]
        }
    }

    /// Literal search that wraps around the buffer end.
    private func search(_ pattern: String, forward: Bool, count: Int, text: NSString, cursor: Int) -> [VimAction] {
        let all = NSRange(location: 0, length: text.length)
        var p = cursor
        for _ in 0..<count {
            let from = TextNav.nextGrapheme(after: p, in: text)
            let first = forward
                ? text.range(of: pattern, options: .literal, range: NSRange(location: from, length: text.length - from))
                : text.range(of: pattern, options: [.literal, .backwards], range: NSRange(location: 0, length: p))
            let found = first.location != NSNotFound
                ? first : text.range(of: pattern, options: forward ? .literal : [.literal, .backwards], range: all)
            guard found.location != NSNotFound else { return [.beep] }
            p = found.location
        }
        return [.setSelection(NSRange(location: TextNav.normalCursor(p, in: text), length: 0))]
    }

    // MARK: insert entry and x

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

    /// Switches to `newMode`; emits `.setMode` only on a change. Leaving the
    /// command line also clears it.
    private func finish(_ newMode: VimMode) -> [VimAction] {
        guard mode != newMode else { return [] }
        let wasCommand = mode == .command
        mode = newMode
        preferredColumn = nil
        columnAnchor = nil
        if wasCommand {
            commandLine = nil
            return [.setMode(newMode), .setCommandLine(nil)]
        }
        return [.setMode(newMode)]
    }

    /// Count for an operator's motion: `2d3w` = 6. nil when neither part has a count.
    private func operatorTotalCount() -> Int? {
        guard pendingOperator != nil, operatorCount != nil || pendingCount != nil else { return pendingCount }
        return min((operatorCount ?? 1) * (pendingCount ?? 1), Self.maxCount)
    }

    private func takeCount() -> Int {
        let n = pendingCount ?? 1
        clearPending()
        return n
    }

    private func clearPending() {
        pendingCount = nil
        pendingG = false
        pendingOperator = nil
        operatorCount = nil
    }

    private func beep() -> [VimAction] {
        clearPending()
        return [.beep]
    }
}
