import AppKit
import Persistence
import ReaderKit

/// App-wide services the windows use.
enum AppEnvironment {
    /// Per-document state (A2), in the app's container. Nil until launch
    /// finishes; tests inject their own store instead.
    static var stateStore: DocumentStateStore?
    /// The crash journal of unsaved annotations (A1), beside the state store.
    static var journal: AnnotationJournal?

    /// The one way a URL leaves the app (A4). While hosting tests it only
    /// records, so a test that forgets to inject its own can't open anything.
    static var urlOpener: any URLOpening = isHostingTests ? RecordingURLOpener() : WorkspaceURLOpener()

    /// Reading preferences. While hosting tests they live in memory: the
    /// test host is the app, and its standard defaults are the user's.
    static var preferences: ReaderPreferences = isHostingTests ? .ephemeral() : ReaderPreferences(defaults: .standard)

    /// Opt-in updates (A4). While hosting tests, Sparkle is never created and nothing is asked.
    static let updates: UpdateController = isHostingTests
        ? UpdateController(preferences: preferences, question: RecordingUpdateQuestion(), makeUpdater: { RecordingUpdater() })
        : UpdateController(preferences: preferences, question: AlertUpdateQuestion(), makeUpdater: { SparkleUpdater() })

    /// True when the app is hosting the unit tests.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Application Support in the container; a throwaway folder while
    /// hosting tests, so documents tests open never reach the user's state.
    static var stateDirectory: URL {
        guard isHostingTests else { return DocumentStateStore.defaultDirectory() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(testFolderPrefix)\(UUID().uuidString)", directoryHint: .isDirectory)
        testStateFolder = folder
        removeAbandonedTestFolders()
        // The test host ends with exit(), not terminate:.
        atexit { AppEnvironment.removeTestStateFolder() }
        return folder
    }

    static let testFolderPrefix = "LecternTestState-"

    /// The test host's throwaway state folder, removed when it exits.
    nonisolated(unsafe) private(set) static var testStateFolder: URL?

    nonisolated static func removeTestStateFolder() {
        guard let testStateFolder else { return }
        try? FileManager.default.removeItem(at: testStateFolder)
    }

    /// Folders left by test hosts that crashed or were killed. Only old ones:
    /// other test runs may share this container right now.
    private static func removeAbandonedTestFolders() {
        let temporary = FileManager.default.temporaryDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries where entry.lastPathComponent.hasPrefix(testFolderPrefix) {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if created < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// While hosting tests the empty state never reads the recent documents. That read
    /// (`NSDocumentController.recentDocumentURLs`) waits on an operation, and when the empty state
    /// reappears inside a test's nested run loop it deadlocks the main thread: the intermittent
    /// 5-minute test hang first seen in M3 (sampled in M5, see architecture §9).
    let emptyState = AppEnvironment.isHostingTests ? EmptyStateController(recentURLs: { [] }) : EmptyStateController()
    private(set) lazy var settings = SettingsWindowController()
    private(set) lazy var keyboardShortcuts = KeyboardShortcutsWindowController()
    /// Last session's windows and tabs (B3), and the empty state. Its restorer is nil while
    /// hosting tests, so the test host never restores or saves a session.
    private(set) var sessions: SessionCoordinator?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let store = DocumentStateStore(directory: AppEnvironment.stateDirectory)
        AppEnvironment.stateStore = store
        AppEnvironment.journal = AnnotationJournal(directory: store.directory.appending(path: "Journal", directoryHint: .isDirectory))
        let restorer = AppEnvironment.isHostingTests ? nil
            : SessionRestorer(fileURL: store.directory.appending(path: "Session.json"), policy: { AppEnvironment.preferences.sessionRestore })
        let emptyState = emptyState
        let sessions = SessionCoordinator(
            restorer: restorer,
            emptyStateDidChange: { emptyState.documentsDidChange(count: $0) },
            showEmptyState: { emptyState.show() },
            hideEmptyState: { emptyState.hide() }
        )
        self.sessions = sessions
        let controller = NSDocumentController.shared as? ReaderDocumentController
        controller?.onDocumentsChange = { sessions.documentsDidChange(count: $0) }
        controller?.onWillReviewForQuit = { sessions.willReviewForQuit() }
        controller?.onReviewEnded = { sessions.reviewEnded(didReviewAll: $0) }
        sessions.launch()
    }

    // A reader has no "new document". AppKit asks for an untitled file at
    // launch (when nothing was opened or restored) and on a Dock click with
    // no windows; both show the empty state instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        sessions?.openUntitled() ?? emptyState.show()
        return true
    }

    /// Lectern ▸ Settings… (⌘,)
    @objc func showSettings(_ sender: Any?) {
        settings.show()
    }

    /// Help ▸ Keyboard Shortcuts (⌘/)
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        keyboardShortcuts.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Not while hosting tests, nor in a test launch that ignores saved state (verify-dmg):
        // the first-launch question would wait for an answer nobody gives.
        guard Self.asksAboutUpdatesAtLaunch(hostingTests: AppEnvironment.isHostingTests, ignoresState: SessionRestorer.launchIgnoresPersistentState()) else { return }
        // After the launch's own windows: the first-launch question (A4), or scheduled checks.
        DispatchQueue.main.async { AppEnvironment.updates.start() }
    }

    /// The first-launch question and scheduled checks start only in a real launch.
    static func asksAboutUpdatesAtLaunch(hostingTests: Bool, ignoresState: Bool) -> Bool {
        !hostingTests && !ignoresState
    }

    /// Lectern ▸ Check for Updates…
    @objc func checkForUpdates(_ sender: Any?) {
        AppEnvironment.updates.checkNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Quitting doesn't close windows first, so remember every open
    /// document's position and write it all out now (Journey A step 5).
    func applicationWillTerminate(_ notification: Notification) {
        for document in NSDocumentController.shared.documents {
            (document as? ReaderDocument)?.readerWindowController?.saveAnchor()
        }
        AppEnvironment.stateStore?.flush()
        sessions?.willTerminate()
    }
}
