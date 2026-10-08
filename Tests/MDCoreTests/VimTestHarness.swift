import Foundation
import Testing
@testable import MDCore

/// Parses a key string. Escapes: `<Esc>`, `<CR>`, `<BS>`, `<C-r>`, `<C-[>`,
/// `<Left>`, `<Right>`, `<Up>`, `<Down>`. Any other character is one key.
func vimKeys(_ s: String) -> [VimKey] {
    let named: [String: VimKey] = [
        "Esc": .escape, "CR": .enter, "BS": .backspace,
        "Left": .left, "Right": .right, "Up": .up, "Down": .down,
    ]
    var keys: [VimKey] = []
    var rest = Substring(s)
    while let ch = rest.first {
        if ch == "<", let close = rest.firstIndex(of: ">") {
            let name = String(rest[rest.index(after: rest.startIndex)..<close])
            if let key = named[name] {
                keys.append(key)
                rest = rest[rest.index(after: close)...]
                continue
            }
            if name.hasPrefix("C-"), name.count == 3 {
                keys.append(VimKey(String(name.last!), control: true))
                rest = rest[rest.index(after: close)...]
                continue
            }
        }
        keys.append(VimKey(String(ch)))
        rest = rest.dropFirst()
    }
    return keys
}

/// Key that puts a fresh engine into `mode` before the test keys run.
private func entryKey(for mode: VimMode) -> VimKey? {
    switch mode {
    case .normal: return nil
    case .insert: return VimKey("i")
    case .visual: return VimKey("v")
    case .visualLine: return VimKey("V")
    case .command: return VimKey(":")
    }
}

/// Feeds `keys` to `engine` and applies the actions to a local buffer the way
/// `VimController` does. In insert mode, a key the engine leaves alone (`[]`)
/// is typed into the buffer, as the text view would do.
/// `actions` holds the actions of `keys` only, not of the mode-entry key.
func run(
    _ text: String, cursor: Int, _ keys: String, mode: VimMode = .normal,
    engine: VimEngine = VimEngine()
) -> (text: String, cursor: NSRange, mode: VimMode, actions: [VimAction]) {
    let buffer = NSMutableString(string: text)
    var selection = NSRange(location: cursor, length: 0)
    var currentMode = engine.mode
    var all: [VimAction] = []

    func apply(_ actions: [VimAction]) {
        for action in actions {
            switch action {
            case .setSelection(let r): selection = r
            case .replace(let r, let s):
                buffer.replaceCharacters(in: r, with: s)
                selection = NSRange(location: r.location + (s as NSString).length, length: 0)
            case .setMode(let m): currentMode = m
            default: break
            }
        }
    }

    func type(_ key: VimKey) {
        if key == .backspace {
            guard selection.length > 0 || selection.location > 0 else { return }
            let r = selection.length > 0
                ? selection : buffer.rangeOfComposedCharacterSequence(at: selection.location - 1)
            buffer.replaceCharacters(in: r, with: "")
            selection = NSRange(location: r.location, length: 0)
            return
        }
        let s = key == .enter ? "\n" : key.chars
        buffer.replaceCharacters(in: selection, with: s)
        selection = NSRange(location: selection.location + (s as NSString).length, length: 0)
    }

    if let entry = entryKey(for: mode) {
        apply(engine.handle(entry, text: buffer, selection: selection))
    }
    for key in vimKeys(keys) {
        let before = engine.mode
        let actions = engine.handle(key, text: buffer, selection: selection)
        all += actions
        apply(actions)
        if before == .insert, actions.isEmpty, !key.control,
           ![VimKey.left, .right, .up, .down].contains(key) {
            type(key)
        }
    }
    #expect(currentMode == engine.mode, "setMode actions disagree with engine.mode")
    return (buffer as String, selection, currentMode, all)
}
