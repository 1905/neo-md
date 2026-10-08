import Foundation
import MDCore

enum KeyBindings: String { case standard, vim }

enum DocTab: Int { case render = 0, raw = 1, split = 2 }

enum AppTheme: String { case system, light, dark }

/// App-wide settings backed by `UserDefaults`. Every change posts `Settings.didChange`.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("NeoMDSettingsDidChange")

    private enum Key {
        static let keyBindings = "keyBindings"
        static let defaultTab = "defaultTab"
        static let outlineVisible = "outlineVisible"
        static let fontScale = "fontScale"
        static let readingFont = "readingFont"
        static let editorFont = "editorFont"
        static let theme = "theme"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.keyBindings: KeyBindings.standard.rawValue,
            Key.defaultTab: DocTab.render.rawValue,
            Key.outlineVisible: true,
            Key.fontScale: 0,
            Key.readingFont: "",
            Key.editorFont: "",
            Key.theme: AppTheme.system.rawValue,
        ])
    }

    var keyBindings: KeyBindings {
        get { KeyBindings(rawValue: defaults.string(forKey: Key.keyBindings) ?? "") ?? .standard }
        set { set(newValue.rawValue, for: Key.keyBindings) }
    }

    var defaultTab: DocTab {
        get { DocTab(rawValue: defaults.integer(forKey: Key.defaultTab)) ?? .render }
        set { set(newValue.rawValue, for: Key.defaultTab) }
    }

    var outlineVisible: Bool {
        get { defaults.bool(forKey: Key.outlineVisible) }
        set { set(newValue, for: Key.outlineVisible) }
    }

    /// Text size step (`FontScale.steps`). The setter clamps to the allowed range.
    var fontScale: Int {
        get { FontScale.clamp(defaults.integer(forKey: Key.fontScale)) }
        set { set(FontScale.clamp(newValue), for: Key.fontScale) }
    }

    /// Reading font family. Empty = the system font.
    var readingFont: String {
        get { defaults.string(forKey: Key.readingFont) ?? "" }
        set { set(newValue, for: Key.readingFont) }
    }

    /// Editor font family. Empty = SF Mono.
    var editorFont: String {
        get { defaults.string(forKey: Key.editorFont) ?? "" }
        set { set(newValue, for: Key.editorFont) }
    }

    var theme: AppTheme {
        get { AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system }
        set { set(newValue.rawValue, for: Key.theme) }
    }

    private func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }
}
