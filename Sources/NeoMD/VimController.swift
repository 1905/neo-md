import AppKit
import MDCore

/// Vim colours from `mockup/base.css` (`--vim-normal`, `--vim-insert`, `--vim-visual`).
enum VimStyle {
    static let normal = EditorStyle.dynamic(light: 0x2f7d32, dark: 0x5fbf62)
    static let insert = EditorStyle.dynamic(light: 0x0a64d8, dark: 0x4c9bff)
    static let visual = EditorStyle.dynamic(light: 0x8a4fd0, dark: 0xb388ff)

    /// Badge text and colour for a mode. `.command` shows the command line instead of a badge.
    static func badge(for mode: VimMode) -> (text: String, color: NSColor) {
        switch mode {
        case .normal, .command: return ("NORMAL", normal)
        case .insert: return ("INSERT", insert)
        case .visual: return ("VISUAL", visual)
        case .visualLine: return ("V-LINE", visual)
        }
    }
}

/// Connects a `VimEngine` to one `MarkdownTextView`: turns key events into engine
/// keys and applies the engine's actions to the text view and the document.
@MainActor
final class VimController: NSObject {
    private weak var textView: MarkdownTextView?
    private weak var document: MarkdownDocument?
    private let engine = VimEngine()

    /// Follows `Settings.keyBindings`. A change resets the engine to normal mode.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            engine.reset()
            if let textView {
                let location = textView.selectedRange().location
                textView.setSelectedRange(NSRange(location: location, length: 0))
            }
            notify()
        }
    }

    /// Mode or command line may have changed (read `mode`, `commandLine`). Called after every handled key and on toggle.
    var onModeChange: (() -> Void)?

    var mode: VimMode { engine.mode }
    var commandLine: String? { engine.commandLine }
    /// Moving end of the visual selection; nil outside visual modes.
    var visualCursor: Int? { engine.visualCursor }
    /// True when the text view draws the block cursor instead of the caret.
    var showsBlockCursor: Bool { isEnabled && engine.mode != .insert }

    init(textView: MarkdownTextView, document: MarkdownDocument) {
        self.textView = textView
        self.document = document
        isEnabled = Settings.shared.keyBindings == .vim
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: Settings.didChange, object: nil)
    }

    @objc private func settingsDidChange(_ note: Notification) {
        isEnabled = Settings.shared.keyBindings == .vim
    }

    /// AppKit function-key characters that keep their standard meaning in every mode:
    /// Home, End, Page Up, Page Down.
    private static let passThroughKeys: Set<Character> = ["\u{F729}", "\u{F72B}", "\u{F72C}", "\u{F72D}"]

    /// true = consumed. Key events with ⌘ are never consumed, so menu shortcuts work in every mode.
    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled, let textView, let storage = textView.textStorage,
              var chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        let flags = event.modifierFlags
        if flags.contains(.command) { return false }
        if let first = chars.first, Self.passThroughKeys.contains(first) { return false }
        if chars == "\u{3}" { chars = VimKey.enter.chars }   // keypad Enter

        let wasInsert = engine.mode == .insert
        let key = VimKey(chars, control: flags.contains(.control))
        let actions = engine.handle(key, text: storage.string as NSString, selection: textView.selectedRange())
        // Insert mode: the engine answers only Escape and Ctrl-[. The text view inserts everything else.
        if wasInsert && actions.isEmpty { return false }
        if wasInsert { textView.breakUndoCoalescing() }   // typing in one insert session = one undo step
        apply(actions, to: textView)
        notify()
        return true
    }

    private func apply(_ actions: [VimAction], to textView: MarkdownTextView) {
        let undoManager = document?.undoManager ?? textView.undoManager
        let closesAfterSave = actions.contains(.save) && actions.contains(.close)
        var grouped = false
        for action in actions {
            switch action {
            case .setSelection(let range):
                let length = textView.textStorage?.length ?? 0
                let location = min(range.location, length)
                let clamped = NSRange(location: location, length: min(range.length, length - location))
                textView.setSelectedRange(clamped)
                textView.scrollRangeToVisible(clamped)
            case .replace(let range, let string):
                if !grouped {
                    textView.breakUndoCoalescing()
                    undoManager?.beginUndoGrouping()
                    grouped = true
                }
                guard textView.shouldChangeText(in: range, replacementString: string) else { continue }
                textView.textStorage?.replaceCharacters(in: range, with: string)
                textView.didChangeText()
            case .setMode, .setCommandLine:
                break   // `notify()` reads the engine state after the loop.
            case .copyToPasteboard(let string):
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(string, forType: .string)
            case .undo, .redo:
                textView.breakUndoCoalescing()
                guard let undoManager, action == .undo ? undoManager.canUndo : undoManager.canRedo else {
                    NSSound.beep()
                    continue
                }
                if action == .undo { undoManager.undo() } else { undoManager.redo() }
                // Undo selects the restored text; normal mode wants a cursor.
                let location = textView.selectedRange().location
                textView.setSelectedRange(NSRange(location: location, length: 0))
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            case .save:
                if closesAfterSave {
                    // `:wq` / `:x`: close only after the save finished, so no save prompt appears.
                    document?.save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)),
                                   contextInfo: nil)
                } else {
                    document?.save(nil)
                }
            case .close:
                if !closesAfterSave { textView.window?.performClose(nil) }
            case .forceClose:
                document?.close()
            case .beep:
                NSSound.beep()
            }
        }
        if grouped { undoManager?.endUndoGrouping() }
    }

    @objc private func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didSave else { return }
        textView?.window?.performClose(nil)
    }

    private func notify() {
        textView?.vimStateDidChange()
        onModeChange?()
    }
}
