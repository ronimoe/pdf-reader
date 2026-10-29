import Foundation

/// App-wide reading preferences, kept in `UserDefaults`. Settings arrive in
/// M5; until then the View menu changes them.
final class ReaderPreferences {
    static let didChange = Notification.Name("LecternReaderPreferencesDidChange")
    static let previewLinksOnHoverKey = "PreviewLinksOnHover"

    /// Nil keeps values in memory only.
    let defaults: UserDefaults?
    private var memory: [String: Any] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// Hover opens link previews after about half a second (A3). On by default.
    var previewsLinksOnHover: Bool {
        get { value(Self.previewLinksOnHoverKey) as? Bool ?? true }
        set {
            setValue(newValue, Self.previewLinksOnHoverKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Preferences that live only in memory, for tests: the test host is the
    /// app, so the standard defaults are the user's own.
    static func ephemeral() -> ReaderPreferences {
        ReaderPreferences(defaults: nil)
    }

    private func value(_ key: String) -> Any? {
        defaults.map { $0.object(forKey: key) } ?? memory[key]
    }

    private func setValue(_ value: Any, _ key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }
}
