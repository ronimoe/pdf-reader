import AppKit
import ReaderCore
import ReaderUI
import SwiftUI

/// Settings (⌘,): a SwiftUI view in a small AppKit window. Each change goes straight to its
/// preference; the View menu's Preview Links on Hover and Settings share one preference.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    let preferences: ReaderPreferences
    let updates: UpdateController
    private let systemKeepsWindows: () -> Bool
    private var observer: (any NSObjectProtocol)?

    init(
        preferences: ReaderPreferences = AppEnvironment.preferences,
        updates: UpdateController = AppEnvironment.updates,
        systemKeepsWindows: @escaping () -> Bool = { SessionRestorer.systemKeepsWindows() }
    ) {
        self.preferences = preferences
        self.updates = updates
        self.systemKeepsWindows = systemKeepsWindows
        model = SettingsModel()
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("Settings")
        super.init(window: window)
        window.delegate = self
        load()
        model.onChange = { [weak self] setting in self?.store(setting) }
        model.onCheckNow = { [weak self] in self?.updates.checkNow() }
        // The View menu toggles the hover preference too.
        observer = NotificationCenter.default.addObserver(forName: ReaderPreferences.didChange, object: preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window, centred the first time, with the current values.
    func show() {
        load()
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// Reads every preference into the model.
    func load() {
        let onChange = model.onChange
        model.onChange = { _ in }
        defer { model.onChange = onChange }
        model.sessionRestore = preferences.sessionRestore
        model.previewsLinksOnHover = preferences.previewsLinksOnHover
        model.distractionFreeEntersFullScreen = preferences.distractionFreeEntersFullScreen
        model.systemKeepsWindows = systemKeepsWindows()
        model.annotationAuthor = preferences.annotationAuthor
        model.annotationColor = preferences.annotationColor
        model.checksForUpdatesAutomatically = updates.automaticallyChecks
    }

    private func store(_ setting: SettingsModel.Setting) {
        switch setting {
        case .sessionRestore: preferences.sessionRestore = model.sessionRestore
        case .previewsLinksOnHover: preferences.previewsLinksOnHover = model.previewsLinksOnHover
        case .distractionFreeEntersFullScreen: preferences.distractionFreeEntersFullScreen = model.distractionFreeEntersFullScreen
        // Never filled in automatically (B4): only what the user types.
        case .annotationAuthor: preferences.annotationAuthor = model.annotationAuthor
        case .annotationColor: preferences.annotationColor = model.annotationColor
        case .checksForUpdatesAutomatically: updates.setAutomaticChecks(model.checksForUpdatesAutomatically)
        }
    }

    /// Escape closes Settings, like other Mac settings windows.
    override func cancelOperation(_ sender: Any?) {
        window?.performClose(sender)
    }
}
