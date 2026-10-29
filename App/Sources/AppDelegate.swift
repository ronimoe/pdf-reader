import AppKit
import Persistence
import ReaderKit

/// App-wide services the windows use.
enum AppEnvironment {
    /// Per-document state (A2), in the app's container. Nil until launch
    /// finishes; tests inject their own store instead.
    static var stateStore: DocumentStateStore?

    /// The one way a URL leaves the app (A4). While hosting tests it only
    /// records, so a test that forgets to inject its own can't open anything.
    static var urlOpener: any URLOpening = isHostingTests ? RecordingURLOpener() : WorkspaceURLOpener()

    /// Reading preferences. While hosting tests they live in memory: the
    /// test host is the app, and its standard defaults are the user's.
    static var preferences: ReaderPreferences = isHostingTests ? .ephemeral() : ReaderPreferences(defaults: .standard)

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
    /// While hosting tests the empty state lists no recents: reading
    /// `recentDocumentURLs` as a test closes its last document intermittently
    /// blocked the main thread in AppKit (`waitUntilFinished`, seen in M3's
    /// test runs), hanging the whole run.
    let emptyState = AppEnvironment.isHostingTests ? EmptyStateController(recentURLs: { [] }) : EmptyStateController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppEnvironment.stateStore = DocumentStateStore(directory: AppEnvironment.stateDirectory)
        (NSDocumentController.shared as? ReaderDocumentController)?.onDocumentsChange = { [weak self] count in
            self?.emptyState.documentsDidChange(count: count)
        }
    }

    // A reader has no "new document". AppKit asks for an untitled file at
    // launch (when nothing was opened or restored) and on a Dock click with
    // no windows; both show the empty state instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        emptyState.show()
        return true
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
    }
}
