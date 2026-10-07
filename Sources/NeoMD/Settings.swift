import Foundation

enum KeyBindings: String { case standard, vim }

enum DocTab: Int { case render = 0, raw = 1, split = 2 }

/// App-wide settings backed by `UserDefaults`. Every change posts `Settings.didChange`.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("NeoMDSettingsDidChange")

    private enum Key {
        static let keyBindings = "keyBindings"
        static let defaultTab = "defaultTab"
        static let outlineVisible = "outlineVisible"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.keyBindings: KeyBindings.standard.rawValue,
            Key.defaultTab: DocTab.render.rawValue,
            Key.outlineVisible: true,
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

    private func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }
}
