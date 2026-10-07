import Foundation

public enum VimMode: Equatable, Sendable { case normal, insert, visual, visualLine, command }

public enum VimAction: Equatable, Sendable {
    case setSelection(NSRange)
    case replace(NSRange, String)
    case setMode(VimMode)
    case setCommandLine(String?)
    case copyToPasteboard(String)
    case undo, redo, save, close, forceClose, beep
}

public struct VimKey: Equatable, Sendable {
    /// `charactersIgnoringModifiers`, e.g. "j", "\u{1b}".
    public let chars: String
    public let control: Bool

    public init(_ chars: String, control: Bool = false) {
        self.chars = chars
        self.control = control
    }

    public static let escape = VimKey("\u{1b}")
    public static let enter = VimKey("\r")
    public static let backspace = VimKey("\u{7f}")
    // AppKit function-key characters (NSUpArrowFunctionKey and friends).
    public static let up = VimKey("\u{F700}")
    public static let down = VimKey("\u{F701}")
    public static let left = VimKey("\u{F702}")
    public static let right = VimKey("\u{F703}")
}
