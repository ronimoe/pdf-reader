import Foundation
import ReaderCore

/// App-wide preferences, kept in `UserDefaults`. The Settings window (⌘,) and the View menu
/// change them.
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

    static let annotationColorKey = "AnnotationColor"
    /// The author written into new annotations' `/T` (B4). Empty by default; Settings (M5) sets it.
    static let annotationAuthorKey = "annotationAuthor"

    /// The colour of the last annotation created or recoloured (B4). Yellow at first.
    var annotationColor: AnnotationColorPreset {
        get { (value(Self.annotationColorKey) as? String).flatMap(AnnotationColorPreset.init(rawValue:)) ?? .default }
        set {
            setValue(newValue.rawValue, Self.annotationColorKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Never filled in from the Mac account (B4).
    var annotationAuthor: String {
        get { value(Self.annotationAuthorKey) as? String ?? "" }
        set { setValue(newValue, Self.annotationAuthorKey) }
    }

    static let checksForUpdatesAutomaticallyKey = "CheckForUpdatesAutomatically"

    /// The answer to the first-launch question (A4): nil until the user answers, then whether
    /// Lectern may check for updates on its own. Never asked again once set.
    var checksForUpdatesAutomatically: Bool? {
        get { value(Self.checksForUpdatesAutomaticallyKey) as? Bool }
        set {
            if let newValue { setValue(newValue, Self.checksForUpdatesAutomaticallyKey) } else { removeValue(Self.checksForUpdatesAutomaticallyKey) }
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

    private func removeValue(_ key: String) {
        if let defaults { defaults.removeObject(forKey: key) } else { memory[key] = nil }
    }
}
